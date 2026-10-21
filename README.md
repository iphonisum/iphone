# iPhone 15 Pro Max Real-Time Cinema Camera & Spatial LUT Engine

A zero-latency, hardware-accelerated cinema camera application and spatial optical grading engine engineered specifically for the **iPhone 15 Pro Max (Apple A17 Pro SoC)**.

![Target Hardware](https://img.shields.io/badge/Hardware-iPhone%2015%20Pro%20Max%20(A17%20Pro)-black?style=for-the-badge&logo=apple)
![Pipeline Latency](https://img.shields.io/badge/Pipeline%20Latency-Zero--Copy%20(%3C%201.4%20ms)-00ff66?style=for-the-badge)
![Max Capture Spec](https://img.shields.io/badge/Capture%20Format-4K%20120FPS%2010--Bit%20Apple%20Log-ff9900?style=for-the-badge)
![Color Space](https://img.shields.io/badge/Color%20Pipeline-Rec.2020%20%2F%20Apple%20Log-0099ff?style=for-the-badge)

---

## 1. System Architecture Overview

Standard `.cube` 3D LUTs are mathematically restricted to per-pixel color transformations $(R_{in}, G_{in}, B_{in}) \rightarrow (R_{out}, G_{out}, B_{out})$ and cannot evaluate spatial neighborhoods required for optical phenomena such as **film halation**, **Pro-Mist bloom glow**, or **anamorphic horizontal flare streaks**.

This architecture introduces the **`.cinemalut` bundle** (combining a 33x33x33 or 64x64x64 `.cube` 3D LUT with an `optics.json` spatial shader manifest) executed in real time on the 6-core A17 Pro GPU via a **zero-copy IOSurface / CVMetalTextureCache pipeline**.

```
  ┌───────────────────────────────────────────────────────────────────────────┐
  │                   CMOS SENSOR CAPTURE (AVCaptureSession)                  │
  │     10-Bit Bi-Planar Apple Log (kCVPixelFormatType_420YpCbCr10BiPlanar)   │
  └─────────────────────────────────────┬─────────────────────────────────────┘
                                        │ DMA Zero CPU Memory Copy
                                        ▼
  ┌───────────────────────────────────────────────────────────────────────────┐
  │                   DMA TEXTURE MAPPING (CVMetalTextureCache)               │
  │     IOSurface Plane 0 (Luma .r16Unorm) & Plane 1 (Chroma .rg16Unorm)      │
  └─────────────────────────────────────┬─────────────────────────────────────┘
                                        │ Single Command Buffer (< 1.4 ms)
                                        ▼
  ┌───────────────────────────────────────────────────────────────────────────┐
  │                   METAL COMPUTE ENGINE (A17 Pro 6-Core GPU)               │
  │  Pass 1: Specular Peak Extraction (Luma > 0.78, Soft Knee 0.15)          │
  │  Pass 2: 4-Level Dual-Kawase Downsample / Upsample Pyramid (Bloom Glow)   │
  │  Pass 3: 1D Horizontal Strided Blur (Anamorphic Blue Flare Streaks)       │
  │  Pass 4: Red-Channel Film Halation Scatter (Kodak 5219 Emulsion)          │
  │  Pass 5: Screen/Soft-Light Composite + 3D LUT Tetrahedral + Aspect Matte  │
  └──────────────────────────────┬─────────────────────────────┬──────────────┘
                                 │                             │
          Direct Viewfinder Draw │                             │ Hardware Encode
                                 ▼                             ▼
  ┌──────────────────────────────────────────┐  ┌─────────────────────────────┐
  │         120Hz PROMOTION VIEWFINDER       │  │    ZERO-COPY RECORDER       │
  │ CAMetalLayer (presentsWithTransaction =  │  │ AVAssetWriterInputAdaptor   │
  │ false, 0-frame display latency)          │  │ Ring of 6 IOSurface Buffers │
  │ HUD Overlays: Sobel Peaking, False Color │  │ ProRes 422 HQ / 10-Bit HEVC │
  │ Zebra Stripes, Exposure Histogram        │  │ USB-C 3.2 Gen 2 SSD (10Gbps)│
  └──────────────────────────────────────────┘  └─────────────────────────────┘
```

---

## 2. Antigravity IDE Module Hierarchy

The codebase is organized into five isolated, thread-safe modules executing across dedicated serial hardware queues and high-priority Metal queues:

```
iPhoneCinemaCamera/
├── Package.swift                           # Swift Package Manager definition
├── Sources/
│   ├── App/
│   │   ├── CinemaCameraApp.swift          # App lifecycle & lock prevention
│   │   └── Info.plist                     # Camera, Mic & USB-C entitlements
│   ├── CoreCaptureEngine/
│   │   └── CoreCaptureEngine.swift        # AVCaptureSession, 4K120 & Apple Log negotiation,
│   │                                      # hot lens swapping, manual locks (ISO, Shutter, WB)
│   ├── MetalShaderPipeline/
│   │   ├── CinemaMetalContext.swift       # Shared MTLDevice, CommandQueue & CVMetalTextureCache
│   │   ├── SpatialOpticsPipeline.swift    # Multi-pass GPU kernel dispatch & pyramid textures
│   │   ├── CubeLUTParser.swift            # 3D .cube file parser into MTLTextureType3D
│   │   ├── CinemaLUTBundle.swift          # .cinemalut bundle loader & optics.json decoder
│   │   ├── AspectRatioDefinition.swift    # Framing geometry & CinemaUniforms struct
│   │   └── Shaders/
│   │       └── CinemaSpatialOptics.metal  # MSL kernels (Kawase, Streak, Halation, Composite)
│   ├── ZeroCopyRecorder/
│   │   ├── ZeroCopyRecorder.swift         # AVAssetWriter, ProRes 422 HQ & 10-bit HEVC encoder
│   │   ├── PixelBufferPoolManager.swift   # Pre-allocated 6-buffer IOSurface ring pool
│   │   └── ExternalStorageManager.swift   # USB-C 3.2 Gen 2 (10Gbps) NVMe mounting & telemetry
│   ├── CinemaHUDView/
│   │   ├── CinemaHUDView.swift            # Tactile cinema overlay (Dials, Scopes, Docks)
│   │   ├── MetalViewContainer.swift       # 120Hz ProMotion CAMetalLayer UIViewRepresentable
│   │   ├── ViewModels/
│   │   │   └── CinemaCameraViewModel.swift# Reactive pipeline state coordinator
│   │   └── Components/
│   │       ├── TactileDial.swift          # Rotary cinema dials with angle calculations
│   │       ├── HistogramView.swift        # IRE exposure distribution & middle-grey scope
│   │       └── LUTBrowserSheet.swift      # Import .cinemalut from Files app / external SSD
│   └── Bundles/
│       ├── GoldAnamorphic35.cinemalut/    # 2.39:1, Blue Anamorphic Flare, Warm Gold
│       ├── KodakVision3_250D.cinemalut/   # 1.85:1, Authentic Kodak 5207 Halation
│       └── BleachBypass50.cinemalut/      # 2.00:1, Silver retention, Cold Contrast
└── Tests/
    ├── OpticsManifestTests.swift          # Manifest JSON decoding & aspect bounds tests
    └── CubeLUTParserTests.swift           # .cube parser format validation tests
```

---

## 3. Physical Lens Matrix & Sensor Negotiation

To guarantee manual control without automatic lens-jumping artifacts, the engine binds directly to physical sensor modules:

| Lens Module | AVCaptureDeviceType | Focal Length & Aperture | Supported Resolutions | Supported Frame Rates |
| :--- | :--- | :--- | :--- | :--- |
| **Main Wide** | `.builtInWideAngleCamera` | 24mm (28mm/35mm crop), ƒ/1.78 | 3840×2160, 1920×1080 | 23.98, 24, 25, 29.97, 30, 50, 60, 120 FPS |
| **Ultra Wide** | `.builtInUltraWideCamera` | 13mm, ƒ/2.2, 120° FOV, Macro | 3840×2160, 1920×1080 | 24, 25, 30, 60 FPS (120 FPS in 1080p) |
| **5x Telephoto** | `.builtInTelephotoCamera` | 120mm, ƒ/2.8, Tetraprism OIS | 3840×2160, 1920×1080 | 24, 25, 30, 60 FPS |
| **Front TrueDepth**| `.builtInTrueDepthCamera` | 23mm, ƒ/1.9, PDAF | 3840×2160, 1920×1080 | 24, 25, 30, 60 FPS |

### Hardware Format Negotiation Protocol
1. **Format Filtering:** Iterates through `device.formats`, matching `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` with `.appleLog` color space.
2. **Exact Frame Duration Lock:** Sets `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` to identical `CMTimeMake(1, targetFPS)` values to prevent ISP shutter hunting in low-light conditions.
3. **Zero-Lag Stabilization Rule:** Sets `connection.preferredVideoStabilizationMode = .off` or `.standard` (forbidding `.cinematicExtended`) to eliminate the 12-frame stabilization lookahead buffer.

---

## 4. Manual Sensor Controls & Shutter Formula

* **Cinema Shutter Angle:**
  $$\text{Exposure Duration (seconds)} = \frac{\text{Shutter Angle}}{360.0} \times \frac{1}{\text{Target FPS}}$$
  Automatically recalculated across 24, 30, 60, and 120 FPS.
* **ISO Control & Dual Gain Sweet Spot:** Locks between `minISO` (~34) and `maxISO` (~3200). Explicitly alerts users to the native **ISO 800 - 1250** dual-conversion gain sweet spot for Apple Log.
* **White Balance:** 2,000K to 10,000K Kelvin with -150 to +150 Tint, converted to hardware RGB gains clamped to `[1.0, maxWhiteBalanceGain]`.
* **Manual Rack Focus:** 0.0 (macro limit) to 1.0 (infinity) with Sobel edge peaking overlay.

---

## 5. Aspect Ratio Matrix & True-Crop vs Letterbox

| Aspect Ratio | 4K True-Crop | 1080p True-Crop | Normalized Bounds $[Y_{min}, Y_{max}]$ | Description |
| :--- | :--- | :--- | :--- | :--- |
| **2.39 : 1** | 3840 × 1606 | 1920 × 804 | `[0.1282, 0.8718]` | Anamorphic Widescreen Cinema |
| **2.00 : 1** | 3840 × 1920 | 1920 × 960 | `[0.0556, 0.9444]` | Univisium (Streaming Standard) |
| **1.85 : 1** | 3840 × 2076 | 1920 × 1038 | `[0.0194, 0.9806]` | Theatrical Flat Widescreen |
| **16 : 9** | 3840 × 2160 | 1920 × 1080 | `[0.0000, 1.0000]` | Native UHD Broadcast |
| **4 : 3** | 2880 × 2160 | 1440 × 1080 | `X: [0.1250, 0.8750]`| Classic Academy / IMAX |

Includes real-time **1.33x** and **1.55x** Anamorphic Desqueeze support for users shooting with external anamorphic lenses.

---

## 6. The `.cinemalut` Bundle Specification

Import custom `.cinemalut` bundles via the iOS Files app or an external USB-C drive:

```
MyAnamorphicGold.cinemalut/
├── grade.cube          # Standard 33x33x33 or 64x64x64 3D LUT
└── optics.json         # Spatial shader parameters
```

```json
{
  "lutFile": "grade.cube",
  "inputColorSpace": "AppleLog",
  "glowIntensity": 0.45,
  "glowThreshold": 0.78,
  "anamorphicStretch": 3.5,
  "anamorphicTintRGB": [0.18, 0.58, 1.0],
  "halationStrength": 0.30,
  "defaultAspectRatio": "2.39:1"
}
```

---

## 7. Storage Bandwidth & USB-C 10Gbps Recording

Recording **4K 120 FPS in Apple ProRes 422 HQ** generates ~1.7 Gbps (~220 MB/s) of uncompressed data bandwidth. The engine handles this via:
1. **Security-Scoped Bookmarks:** Direct mounting of external USB-C 3.2 Gen 2 SSDs (Samsung T7/T9, SanDisk Extreme Pro).
2. **Zero-Allocation CVPixelBufferPool:** Ring buffer of 6 pre-warmed `IOSurface` allocations preventing memory allocations during recording.
3. **Dual-Stream Mode:**
   * **Direct Baked:** Encodes the fully graded & optically composited frame into ProRes or 10-bit HEVC for instant turnaround.
   * **Clean Log + Sidecar:** Encodes un-graded 10-bit Apple Log and saves the `.cinemalut` bundle alongside the `.mov` for one-click import into DaVinci Resolve.
4. **Thermal Throttling Guard:** Monitors `ProcessInfo.thermalState`. If `.serious` is reached during long 4K120 shoots, the Dual-Kawase bloom pyramid downsamples from 1/4x to 1/8x resolution while keeping the 4K120 recording stream pristine.

---

## 8. Xcode & Device Deployment Checklist

1. Clone or copy project into Xcode 15+ on macOS Sonoma.
2. Select target device: **iPhone 15 Pro Max** running iOS 17+.
3. Verify `Info.plist` entitlements:
   * `NSCameraUsageDescription`
   * `NSMicrophoneUsageDescription`
   * `UIFileSharingEnabled = YES`
   * `LSSupportsOpeningDocumentsInPlace = YES`
   * `CADisableMinimumFrameDurationOnPhone = YES` (Enables 120Hz ProMotion)
4. Build & Run (`Cmd + R`).
