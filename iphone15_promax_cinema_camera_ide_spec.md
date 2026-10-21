# System Architecture & IDE Specification // Target: iPhone 15 Pro Max (A17 Pro)
# Zero-Latency Real-Time Cinema Camera & Spatial LUT Engine

Complete Hardware-Accelerated Pipeline for Apple Log, Spatial Glow/Anamorphic Shaders, Multi-Lens Control & 4K 120fps Capture

- **Target SOC & GPU:** A17 Pro (6-Core)
- **Pipeline Latency:** 0-Copy (< 1.4 ms)
- **Max Capture Spec:** 4K @ 120 FPS
- **Color Pipeline:** 10-Bit Apple Log (BT.2020)

---

## 1. Executive System Architecture & Zero-Delay Mandate
Standard 3D Look-Up Tables (`.cube`) are mathematically restricted to 1D/3D per-pixel color transformations $(R_{in}, G_{in}, B_{in}) \rightarrow (R_{out}, G_{out}, B_{out})$ and cannot evaluate neighboring pixels required for optical halation, bloom, or anamorphic flare streaks. To achieve real-time spatial effects alongside LUT grading with zero frame delay on the iPhone 15 Pro Max, this architecture bypasses CPU memory copies entirely. Camera sensor buffers are mapped directly into the A17 Pro GPU via `IOSurface` and `CVMetalTextureCache`, processed in a single command buffer using Metal compute kernels, and dispatched simultaneously to a 120Hz ProMotion `CAMetalLayer` viewfinder and hardware `AVAssetWriter` encoder.

## 2. Antigravity IDE Project Structure & Module Hierarchy
- `CoreCaptureEngine/`: Manages `AVCaptureSession`, multi-lens device discovery, active format negotiation (4K120, Apple Log), manual sensor locks (ISO, shutter angle, white balance Kelvin/Tint), and `AVCaptureVideoDataOutputSampleBufferDelegate`.
- `MetalShaderPipeline/`: Houses `CVMetalTextureCache`, 3D LUT texture parsers (`.cube` to `MTLTextureType3D`), and `.metal` compute kernels for spatial glow, halation, anamorphic horizontal flares, and aspect ratio mattes.
- `ZeroCopyRecorder/`: Implements `AVAssetWriter` with `AVAssetWriterInputPixelBufferAdaptor` backed by a pre-allocated `CVPixelBufferPool`, plus external USB-C 3.2 Gen 2 (10Gbps) SSD directory streaming.
- `CinemaHUDView/`: SwiftUI overlay driving 120Hz `MTKView` / `CAMetalLayer`, real-time false color, focus peaking, zebra stripes, histogram, and tactile dial controls.

## 3. Multi-Lens Optical System & Sensor Format Matrix
- **Main Wide (48MP Quad-Pixel):** `.builtInWideAngleCamera`, 24mm (28mm/35mm sensor crop), ƒ/1.78, 2nd-gen Sensor-Shift OIS. Resolutions: 4K & 1080p @ 23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 120 FPS.
- **Ultra Wide (12MP Macro):** `.builtInUltraWideCamera`, 13mm, ƒ/2.2, 120° FOV, Dual-Pixel AF. Resolutions: 4K & 1080p @ 24, 25, 30, 60 FPS (120 FPS in 1080p).
- **5x Telephoto (Tetraprism):** `.builtInTelephotoCamera`, 120mm, ƒ/2.8, 3D Sensor-Shift OIS. Resolutions: 4K & 1080p @ 24, 25, 30, 60 FPS.
- **TrueDepth Front Camera:** `.builtInTrueDepthCamera`, 23mm, ƒ/1.9. Resolutions: 4K & 1080p @ 24, 25, 30, 60 FPS.

## 4. High-Frame-Rate & Apple Log Negotiation Protocol
1. Filter `device.formats` where format description dimensions match 3840x2160 or 1920x1080, pixel format is `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`, and `supportedColorSpaces` contains `.appleLog`.
2. Exact frame duration lock: set both `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` to `CMTimeMake(1, targetFPS)` inside `lockForConfiguration()`.
3. Set `session.automaticallyConfiguresCaptureDeviceForWideColor = false` and explicitly assign `device.activeColorSpace = .appleLog`. Disable `.cinematicExtended` stabilization during 120 FPS capture to guarantee 0.0 ms viewfinder lag.

## 5. Manual Sensor Controls & Shutter Angle
- Cinema Shutter Angle: $\text{Duration} = (\text{Angle} / 360.0) / \text{FPS}$. Supported angles: 45°, 90°, 172.8°, 180°, 360°.
- ISO: Native dual-conversion gain sweet spot at ISO 800–1250 in Apple Log.
- White Balance: 2000K to 10,000K Temperature; -150 to +150 Tint.
- Focus: 0.0 to 1.0 with Sobel edge peaking.

## 6. Aspect Ratios & Black-Border Mattes
- 2.39:1 (Anamorphic Scope): 3840x1606 (4K), 1920x804 (1080p), Y-Bounds: [0.1282, 0.8718]
- 2.00:1 (Univisium): 3840x1920 (4K), 1920x960 (1080p), Y-Bounds: [0.0556, 0.9444]
- 1.85:1 (Theatrical Flat): 3840x2076 (4K), 1920x1038 (1080p), Y-Bounds: [0.0194, 0.9806]
- 16:9 (Native UHD): 3840x2160 (4K), 1920x1080 (1080p), Bounds: [0.0000, 1.0000]
- 4:3 (IMAX / Academy): 2880x2160 (4K), 1440x1080 (1080p), X-Bounds: [0.1250, 0.8750]

## 7. The .cinemalut Bundle Structure
```
MyAnamorphicGold.cinemalut/
├── grade.cube          # Standard 33x33x33 or 64x64x64 3D LUT
└── optics.json         # Spatial shader parameters
```
