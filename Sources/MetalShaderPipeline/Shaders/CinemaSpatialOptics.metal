//
//  CinemaSpatialOptics.metal
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Zero-Latency Spatial LUT Compute Engine
//  Includes: Apple Log YCbCr Decode, 3D LUT Tetrahedral Sample,
//            Dual-Kawase Bloom, Anamorphic Streak Blur, Red Halation,
//            Aspect Ratio Matte/Crop, Focus Peaking Sobel, and False Color.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform Structures

struct CinemaUniforms {
    float glowIntensity;          // 0.0 to 1.5 (Pro-Mist / Bloom strength)
    float glowThreshold;          // e.g. 0.78 specular knee
    float anamorphicStretch;      // 1.0 to 8.0 (Horizontal streak multiplier)
    packed_float3 anamorphicTint; // e.g., float3(0.18, 0.58, 1.0) for classic blue anamorphic streak
    float halationStrength;       // 0.0 to 1.0 (Red/orange emulsion scatter)
    float2 activeCropBounds;      // Normalized [yMin, yMax] or [xMin, xMax]
    float anamorphicDesqueeze;    // 1.0 (none), 1.33, 1.55
    uint isLetterboxMode;         // 1: render black matte bars; 0: true crop
    uint enableFalseColor;        // 1: render false color IRE map
    uint enableFocusPeaking;      // 1: render Sobel edge peaking
    packed_float3 peakingColor;   // e.g., float3(0.0, 1.0, 0.2) neon green
    float peakingThreshold;       // Sobel gradient threshold
    uint enableZebra;             // 1: render zebra stripes on highlights
    float zebraThreshold;         // e.g. 0.95 (95% IRE)
    float zebraFrequency;         // Stripe frequency
};

// MARK: - Color Conversion Helpers

// BT.2020 Apple Log YCbCr to Linear/Apple Log RGB conversion
// Based on ITU-R BT.2020-2 / Apple Log Profile White Paper
inline half3 ycbcrToAppleLogRGB(half yVal, half2 cbcrVal) {
    // 10-bit Video Range normalization: Y [64/1023, 940/1023], Cb/Cr [64/1023, 960/1023]
    half y = (yVal - (64.0h / 1023.0h)) / ((940.0h - 64.0h) / 1023.0h);
    half cb = (cbcrVal.x - (512.0h / 1023.0h)) / ((960.0h - 64.0h) / 1023.0h);
    half cr = (cbcrVal.y - (512.0h / 1023.0h)) / ((960.0h - 64.0h) / 1023.0h);

    y = clamp(y, 0.0h, 1.0h);

    // BT.2020 conversion matrix
    half r = y + 1.4746h * cr;
    half g = y - 0.16455h * cb - 0.5714h * cr;
    half b = y + 1.8814h * cb;

    return clamp(half3(r, g, b), 0.0h, 1.0h);
}

// Compute luminance (REC.2020 coefficients)
inline half calcLuminance(half3 c) {
    return dot(c, half3(0.2627h, 0.6780h, 0.0593h));
}

// MARK: - False Color IRE Mapping
inline half3 calculateFalseColor(half luma) {
    // Standard Cinema False Color Palette:
    // Purple: Underexposure (0 - 2% IRE)
    // Blue: Shadow detail (2% - 10% IRE)
    // Grey/Green: 18% Middle Grey (38% - 43% IRE)
    // Pink: Caucasian Skin tones (52% - 58% IRE)
    // Yellow: High skin / near highlight (70% - 80% IRE)
    // Orange: Specular highlight (80% - 95% IRE)
    // Red: Hard Clipping (> 95% IRE)
    if (luma < 0.02h) return half3(0.5h, 0.0h, 0.5h);       // Deep Purple
    if (luma < 0.10h) return half3(0.0h, 0.3h, 0.8h);       // Deep Blue
    if (luma >= 0.38h && luma <= 0.43h) return half3(0.2h, 0.8h, 0.2h); // Neutral Green (18% Grey)
    if (luma >= 0.52h && luma <= 0.58h) return half3(0.9h, 0.4h, 0.7h); // Pink (Skin tones)
    if (luma >= 0.70h && luma <= 0.80h) return half3(0.95h, 0.9h, 0.1h); // Yellow
    if (luma > 0.80h && luma <= 0.95h) return half3(0.95h, 0.5h, 0.0h);  // Orange
    if (luma > 0.95h) return half3(1.0h, 0.0h, 0.0h);       // Clipped Red
    return half3(luma * 0.4h); // Muted monochrome for intermediate zones
}

// MARK: - Stage 1 & 2: Threshold & Extract Specular Peaks (Glow + Flare Source)
kernel void extractSpecularPeaksKernel(
    texture2d<half, access::read> lumaTex [[texture(0)]],
    texture2d<half, access::read> chromaTex [[texture(1)]],
    texture2d<half, access::write> outPeakTex [[texture(2)]],
    constant CinemaUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outPeakTex.get_width() || gid.y >= outPeakTex.get_height()) return;

    // Sample YUV
    uint2 srcCoord = gid * 2; // Typically runs at half or quarter resolution
    half yVal = lumaTex.read(srcCoord).r;
    half2 cbcrVal = chromaTex.read(srcCoord / 2).rg;
    half3 rgb = ycbcrToAppleLogRGB(yVal, cbcrVal);

    half luma = calcLuminance(rgb);
    half threshold = half(u.glowThreshold);
    half knee = 0.15h;

    // Smooth soft-knee thresholding for organic film roll-off
    half soft = luma - threshold + knee;
    soft = clamp(soft / (2.0h * knee), 0.0h, 1.0h);
    half weight = max(soft * soft, clamp(luma - threshold, 0.0h, 1.0h));

    half3 peak = rgb * weight;
    outPeakTex.write(half4(peak, 1.0h), gid);
}

// MARK: - Dual-Kawase Downsample Kernel
kernel void dualKawaseDownsampleKernel(
    texture2d<half, access::sample> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant float2& invResolution [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) * invResolution;
    float2 halfPix = invResolution * 0.5f;

    // 5-tap Dual-Kawase downsample pattern (center + 4 diagonal corners)
    half4 sum = inTex.sample(s, uv) * 4.0h;
    sum += inTex.sample(s, uv - halfPix);
    sum += inTex.sample(s, uv + halfPix);
    sum += inTex.sample(s, uv + float2(halfPix.x, -halfPix.y));
    sum += inTex.sample(s, uv + float2(-halfPix.x, halfPix.y));

    outTex.write(sum / 8.0h, gid);
}

// MARK: - Dual-Kawase Upsample Kernel
kernel void dualKawaseUpsampleKernel(
    texture2d<half, access::sample> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant float2& invResolution [[buffer(0)]],
    constant float& blurRadius [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) * invResolution;
    float2 offset = invResolution * blurRadius;

    // 8-tap Dual-Kawase upsample pattern
    half4 sum = 0.0h;
    sum += inTex.sample(s, uv + float2(-offset.x * 2.0f, 0.0f));
    sum += inTex.sample(s, uv + float2(-offset.x, offset.y)) * 2.0h;
    sum += inTex.sample(s, uv + float2(0.0f, offset.y * 2.0f));
    sum += inTex.sample(s, uv + float2(offset.x, offset.y)) * 2.0h;
    sum += inTex.sample(s, uv + float2(offset.x * 2.0f, 0.0f));
    sum += inTex.sample(s, uv + float2(offset.x, -offset.y)) * 2.0h;
    sum += inTex.sample(s, uv + float2(0.0f, -offset.y * 2.0f));
    sum += inTex.sample(s, uv + float2(-offset.x, -offset.y)) * 2.0h;

    outTex.write(sum / 12.0h, gid);
}

// MARK: - Anamorphic 1D Horizontal Strided Blur Kernel
// Simulates optical cylindrical elements generating horizontal flare streaks
kernel void anamorphicStreakKernel(
    texture2d<half, access::sample> inPeakTex [[texture(0)]],
    texture2d<half, access::write> outStreakTex [[texture(1)]],
    constant CinemaUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outStreakTex.get_width() || gid.y >= outStreakTex.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(outStreakTex.get_width(), outStreakTex.get_height());

    float widthInv = 1.0f / float(outStreakTex.get_width());
    float streakSpan = widthInv * u.anamorphicStretch * 18.0f;

    half3 accumulated = 0.0h;
    // 17-tap horizontal optical dispersion sample
    const float weights[9] = { 0.22f, 0.17f, 0.13f, 0.09f, 0.06f, 0.04f, 0.025f, 0.015f, 0.005f };

    accumulated += inPeakTex.sample(s, uv).rgb * half(weights[0]);
    for (int i = 1; i < 9; ++i) {
        float off = float(i) * streakSpan;
        half3 sampleL = inPeakTex.sample(s, uv - float2(off, 0.0f)).rgb;
        half3 sampleR = inPeakTex.sample(s, uv + float2(off, 0.0f)).rgb;
        accumulated += (sampleL + sampleR) * half(weights[i]);
    }

    outStreakTex.write(half4(accumulated, 1.0h), gid);
}

// MARK: - Red Halation Kernel (Emulsion Back-Scatter)
kernel void filmHalationKernel(
    texture2d<half, access::sample> inPeakTex [[texture(0)]],
    texture2d<half, access::write> outHalationTex [[texture(1)]],
    constant CinemaUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outHalationTex.get_width() || gid.y >= outHalationTex.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(outHalationTex.get_width(), outHalationTex.get_height());

    // Halation scatter is wider and predominantly deep red/amber
    float2 texelSize = 1.0f / float2(outHalationTex.get_width(), outHalationTex.get_height());
    float radius = 3.5f;

    half3 scatter = 0.0h;
    for (int dx = -2; dx <= 2; ++dx) {
        for (int dy = -2; dy <= 2; ++dy) {
            float2 offset = float2(dx, dy) * texelSize * radius;
            half3 c = inPeakTex.sample(s, uv + offset).rgb;
            half dist = length(float2(dx, dy));
            half w = exp(-dist * 0.8h);
            scatter += c * w;
        }
    }
    scatter /= 6.5h;

    // Shift scatter color profile into Kodak 5219 amber-red emulsion layer
    half3 halationColor = half3(scatter.r * 1.3h, scatter.g * 0.25h, scatter.b * 0.05h) * half(u.halationStrength);
    outHalationTex.write(half4(halationColor, 1.0h), gid);
}

// MARK: - Primary Composite & Aspect Ratio Matte Kernel
kernel void cinemaCompositeKernel(
    texture2d<half, access::read> lumaTex [[texture(0)]],
    texture2d<half, access::read> chromaTex [[texture(1)]],
    texture3d<half, access::sample> lut3D [[texture(2)]],
    texture2d<half, access::sample> bloomTex [[texture(3)]],
    texture2d<half, access::sample> streakTex [[texture(4)]],
    texture2d<half, access::sample> halationTex [[texture(5)]],
    texture2d<half, access::write> outTex [[texture(6)]],
    constant CinemaUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float2 outSize = float2(outTex.get_width(), outTex.get_height());
    float2 uv = float2(gid) / outSize;

    // Aspect Ratio Hard-Matte (Letterboxed Mode)
    if (u.isLetterboxMode == 1) {
        if (u.activeCropBounds.x > 0.0f || u.activeCropBounds.y < 1.0f) {
            // Check Y bounds (Letterbox)
            if (uv.y < u.activeCropBounds.x || uv.y > u.activeCropBounds.y) {
                outTex.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
                return;
            }
        }
    }

    // Anamorphic Lens Desqueeze calculation (if hardware anamorphic adapter attached)
    float2 sampleUV = uv;
    if (u.anamorphicDesqueeze > 1.01f) {
        sampleUV.x = (sampleUV.x - 0.5f) / u.anamorphicDesqueeze + 0.5f;
        if (sampleUV.x < 0.0f || sampleUV.x > 1.0f) {
            outTex.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
            return;
        }
    }

    // 1. Decode BT.2020 Apple Log YCbCr to RGB
    uint2 readCoord = uint2(sampleUV * float2(lumaTex.get_width(), lumaTex.get_height()));
    readCoord = clamp(readCoord, uint2(0), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1));
    
    half yVal = lumaTex.read(readCoord).r;
    half2 cbcrVal = chromaTex.read(readCoord / 2).rg;
    half3 rgb = ycbcrToAppleLogRGB(yVal, cbcrVal);

    // 2. Sample Hardware-Interpolated 3D LUT (Tetrahedral / Trilinear)
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    // Apple Log input maps into [0.0, 1.0] domain
    half3 graded = lut3D.sample(s, float3(rgb)).rgb;

    // 3. Sample Spatial Optics Textures
    half3 glow = bloomTex.sample(s, sampleUV).rgb * half(u.glowIntensity);
    half3 tint = half3(u.anamorphicTint.x, u.anamorphicTint.y, u.anamorphicTint.z);
    half3 streak = streakTex.sample(s, sampleUV).rgb * tint * half(u.anamorphicStretch);
    half3 halation = halationTex.sample(s, sampleUV).rgb;

    // 4. Optical Blending (Photographic Screen / Soft-Light composite)
    // Combine halation directly in linear space before grade screen blend
    graded += halation;
    half3 finalColor = 1.0h - (1.0h - graded) * (1.0h - (glow + streak));

    // 5. Cinema HUD Overlays (Peaking, False Color, Zebra)
    if (u.enableFalseColor == 1) {
        half luma = calcLuminance(finalColor);
        finalColor = calculateFalseColor(luma);
    } else {
        // Focus Peaking Sobel Filter Overlay
        if (u.enableFocusPeaking == 1) {
            // Read 3x3 luminance neighborhood
            half yL = lumaTex.read(clamp(readCoord - uint2(1, 0), uint2(0), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1))).r;
            half yR = lumaTex.read(clamp(readCoord + uint2(1, 0), uint2(0), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1))).r;
            half yT = lumaTex.read(clamp(readCoord - uint2(0, 1), uint2(0), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1))).r;
            half yB = lumaTex.read(clamp(readCoord + uint2(0, 1), uint2(0), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1))).r;

            half gradX = abs(yR - yL);
            half gradY = abs(yB - yT);
            half grad = gradX + gradY;

            if (grad > half(u.peakingThreshold)) {
                half3 peakCol = half3(u.peakingColor.x, u.peakingColor.y, u.peakingColor.z);
                finalColor = mix(finalColor, peakCol, 0.85h);
            }
        }

        // Highlight Zebra Stripes Overlay
        if (u.enableZebra == 1) {
            half luma = calcLuminance(finalColor);
            if (luma >= half(u.zebraThreshold)) {
                float stripe = sin((float(gid.x) + float(gid.y)) * u.zebraFrequency);
                if (stripe > 0.0f) {
                    finalColor = half3(0.0h); // High-contrast black diagonal stripe
                }
            }
        }
    }

    outTex.write(half4(clamp(finalColor, 0.0h, 1.0h), 1.0h), gid);
}
