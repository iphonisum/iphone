//
//  CinemaHUDView.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Tactile Cinema HUD Interface:
//  Overlay driving 120Hz MTKView viewfinder, manual exposure dials (Shutter Angle,
//  ISO 800 sweet-spot, Kelvin/Tint, Manual Focus), Multi-Lens switching, and Spatial Optics Drawer.
//

import SwiftUI

public struct CinemaHUDView: View {
    @StateObject public var viewModel = CinemaCameraViewModel()
    @State private var isShowingLUTSheet = false
    @State private var isShowingOpticsDrawer = false
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 1. Metal 120Hz Viewfinder
            MetalViewContainer(viewModel: viewModel)
                .ignoresSafeArea()
            
            // 2. Framing Guide Overlay (if not letterboxed)
            if !viewModel.isLetterboxMode {
                aspectRatioFrameGuide
            }
            
            // 3. HUD Controls Overlay
            VStack(spacing: 0) {
                topStatusBar
                
                Spacer()
                
                HStack(alignment: .bottom) {
                    leftMonitoringPanel
                    Spacer()
                    rightSensorControlsPanel
                }
                .padding(.horizontal, 16)
                
                Spacer()
                
                bottomControlBar
            }
            .padding(.vertical, 8)
            
            // Optics Parameter Slider Drawer
            if isShowingOpticsDrawer {
                opticsDrawerOverlay
            }
        }
        .sheet(isPresented: $isShowingLUTSheet) {
            LUTBrowserSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.startCamera()
        }
        .onDisappear {
            viewModel.stopCamera()
        }
    }
    
    // MARK: - Top Status Bar
    
    private var topStatusBar: some View {
        HStack(spacing: 12) {
            // Recording State & Timecode
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
                
                Text(viewModel.timecodeString)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.isRecording ? .red : .white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65))
            .cornerRadius(4)
            
            // FPS Selection Menu
            Menu {
                ForEach([23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0, 120.0], id: \.self) { fps in
                    Button("\(String(format: "%.2f", fps)) FPS") {
                        viewModel.updateFPS(fps)
                    }
                }
            } label: {
                Text("\(Int(viewModel.currentFPS)) FPS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(4)
            }
            
            // Resolution & Codec Pill
            Menu {
                ForEach(CinemaCodec.allCases) { codec in
                    Button(codec.rawValue) {
                        viewModel.selectedCodec = codec
                    }
                }
            } label: {
                Text("4K • \(viewModel.selectedCodec == .proRes422HQ ? "ProRes HQ" : "10b HEVC")")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(4)
            }
            
            // Apple Log Indicator
            Text("APPLE LOG")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.yellow)
                .cornerRadius(3)
            
            Spacer()
            
            // Storage Telemetry (USB-C NVMe / Internal)
            HStack(spacing: 4) {
                Image(systemName: viewModel.storageManager.activeDrive?.isExternalSSDDrive == true ? "externaldrive.fill" : "iphone")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                
                Text(viewModel.storageManager.activeDrive?.freeGBString ?? "128 GB")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text("(\(viewModel.storageManager.activeDrive?.remainingProRes4KMinutes ?? 45)m)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65))
            .cornerRadius(4)
            
            // GPU Compute Latency badge
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text(String(format: "%.1f ms", viewModel.computeLatencyMs))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65))
            .cornerRadius(4)
            
            // Thermal Status Indicator
            if viewModel.thermalState != .nominal {
                Text(viewModel.thermalState == .serious ? "HOT (THROTTLED)" : "WARM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Left Monitoring Panel
    
    private var leftMonitoringPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistogramView()
            
            // Monitoring Toggles
            VStack(spacing: 8) {
                // Focus Peaking Sobel
                Button(action: {
                    viewModel.isFocusPeakingEnabled.toggle()
                    viewModel.updateUniforms()
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: "dot.scope")
                            .font(.system(size: 14))
                        Text("PEAK")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 44, height: 38)
                    .background(viewModel.isFocusPeakingEnabled ? Color.green : Color.black.opacity(0.65))
                    .foregroundColor(viewModel.isFocusPeakingEnabled ? .black : .white)
                    .cornerRadius(6)
                }
                
                // False Color
                Button(action: {
                    viewModel.isFalseColorEnabled.toggle()
                    viewModel.updateUniforms()
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 14))
                        Text("FALSE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 44, height: 38)
                    .background(viewModel.isFalseColorEnabled ? Color.yellow : Color.black.opacity(0.65))
                    .foregroundColor(viewModel.isFalseColorEnabled ? .black : .white)
                    .cornerRadius(6)
                }
                
                // Zebra Stripes
                Button(action: {
                    viewModel.isZebraEnabled.toggle()
                    viewModel.updateUniforms()
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: "lines.measurement.horizontal")
                            .font(.system(size: 14))
                        Text("ZEBRA")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 44, height: 38)
                    .background(viewModel.isZebraEnabled ? Color.white : Color.black.opacity(0.65))
                    .foregroundColor(viewModel.isZebraEnabled ? .black : .white)
                    .cornerRadius(6)
                }
                
                // Anamorphic Desqueeze (1.0x / 1.33x / 1.55x)
                Button(action: {
                    if viewModel.anamorphicDesqueeze == 1.0 {
                        viewModel.anamorphicDesqueeze = 1.33
                    } else if viewModel.anamorphicDesqueeze == 1.33 {
                        viewModel.anamorphicDesqueeze = 1.55
                    } else {
                        viewModel.anamorphicDesqueeze = 1.0
                    }
                    viewModel.updateUniforms()
                }) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.2fx", viewModel.anamorphicDesqueeze))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        Text("DESQ")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 44, height: 34)
                    .background(viewModel.anamorphicDesqueeze > 1.01 ? Color.blue : Color.black.opacity(0.65))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
            }
        }
    }
    
    // MARK: - Right Sensor Controls Panel
    
    private var rightSensorControlsPanel: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Shutter Angle Dial
            TactileDial(
                title: "Shutter",
                valueString: "\(Int(viewModel.shutterAngle))°",
                value: Binding(
                    get: { viewModel.shutterAngle },
                    set: { viewModel.updateShutterAngle($0) }
                ),
                range: 45.0...360.0,
                step: 1.0
            )
            
            // ISO Slider with Apple Log Sweet Spot (800-1250)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if viewModel.targetISO >= 800 && viewModel.targetISO <= 1250 {
                        Text("SWEET SPOT")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .background(Color.yellow)
                            .cornerRadius(2)
                    }
                    Text("ISO \(Int(viewModel.targetISO))")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                
                Slider(
                    value: Binding(
                        get: { Double(viewModel.targetISO) },
                        set: { viewModel.updateISO(Float($0)) }
                    ),
                    in: 34.0...3200.0,
                    step: 25.0
                )
                .frame(width: 120)
                .accentColor(.yellow)
            }
            .padding(6)
            .background(Color.black.opacity(0.65))
            .cornerRadius(6)
            
            // White Balance (Kelvin & Tint)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(viewModel.kelvin))K")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Slider(
                    value: Binding(
                        get: { Double(viewModel.kelvin) },
                        set: { viewModel.updateWhiteBalance(kelvin: Float($0), tint: viewModel.tint) }
                    ),
                    in: 2000.0...10000.0,
                    step: 100.0
                )
                .frame(width: 120)
                .accentColor(.orange)
            }
            .padding(6)
            .background(Color.black.opacity(0.65))
            .cornerRadius(6)
            
            // Manual Focus Slider
            VStack(alignment: .trailing, spacing: 2) {
                Text("FOCUS \(String(format: "%.2f", viewModel.focusDistance))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Slider(
                    value: Binding(
                        get: { Double(viewModel.focusDistance) },
                        set: { viewModel.updateFocus(distance: Float($0)) }
                    ),
                    in: 0.0...1.0,
                    step: 0.02
                )
                .frame(width: 120)
                .accentColor(.green)
            }
            .padding(6)
            .background(Color.black.opacity(0.65))
            .cornerRadius(6)
        }
    }
    
    // MARK: - Bottom Control Bar
    
    private var bottomControlBar: some View {
        HStack(spacing: 12) {
            // Multi-Lens Physical Switching Bar
            HStack(spacing: 4) {
                ForEach(LensChoice.allCases) { lens in
                    Button(action: { viewModel.updateLens(lens) }) {
                        Text(lensShortName(lens))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedLens == lens ? Color.yellow : Color.black.opacity(0.65))
                            .foregroundColor(viewModel.selectedLens == lens ? .black : .white)
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            // Spatial LUT & Optics Drawer Button
            Button(action: { isShowingOpticsDrawer.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                    Text(viewModel.activeBundle?.name ?? "LUT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.75))
                .foregroundColor(.yellow)
                .cornerRadius(6)
            }
            
            // Aspect Ratio Selector
            Menu {
                ForEach(CinemaAspectRatio.allCases) { aspect in
                    Button(aspect.displayName) {
                        viewModel.selectedAspectRatio = aspect
                        viewModel.updateUniforms()
                    }
                }
                Divider()
                Button(viewModel.isLetterboxMode ? "Switch to True-Crop Encoding" : "Switch to Letterboxed Container") {
                    viewModel.isLetterboxMode.toggle()
                    viewModel.updateUniforms()
                }
            } label: {
                Text(viewModel.selectedAspectRatio.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            
            // Big Cinema Record Button
            Button(action: { viewModel.toggleRecording() }) {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 54, height: 54)
                    
                    if viewModel.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red)
                            .frame(width: 22, height: 22)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 44, height: 44)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Spatial Optics Drawer Overlay
    
    private var opticsDrawerOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SPATIAL OPTICS MANIFEST (A17 PRO)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                Spacer()
                Button("Manage Bundles") {
                    isShowingLUTSheet = true
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.yellow)
                
                Button(action: { isShowingOpticsDrawer = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            Divider().background(Color.white.opacity(0.3))
            
            HStack(spacing: 20) {
                // Bloom / Pro-Mist Glow
                VStack(alignment: .leading, spacing: 4) {
                    Text("GLOW: \(Int(viewModel.glowIntensity * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.glowIntensity) },
                            set: { viewModel.glowIntensity = Float($0); viewModel.updateUniforms() }
                        ),
                        in: 0.0...1.5
                    )
                    .accentColor(.yellow)
                }
                
                // Anamorphic Flare Streak
                VStack(alignment: .leading, spacing: 4) {
                    Text("ANAMORPHIC: \(String(format: "%.1fx", viewModel.anamorphicStretch))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.anamorphicStretch) },
                            set: { viewModel.anamorphicStretch = Float($0); viewModel.updateUniforms() }
                        ),
                        in: 1.0...8.0
                    )
                    .accentColor(.blue)
                }
                
                // Red Halation Scatter
                VStack(alignment: .leading, spacing: 4) {
                    Text("HALATION: \(Int(viewModel.halationStrength * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.halationStrength) },
                            set: { viewModel.halationStrength = Float($0); viewModel.updateUniforms() }
                        ),
                        in: 0.0...1.0
                    )
                    .accentColor(.red)
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 30)
        .offset(y: 80)
    }
    
    // MARK: - Aspect Ratio Framing Guide
    
    private var aspectRatioFrameGuide: some View {
        GeometryReader { geo in
            let bounds = viewModel.selectedAspectRatio.normalizedBounds
            let topH = geo.size.height * CGFloat(bounds.x)
            let bottomH = geo.size.height * CGFloat(1.0 - bounds.y)
            
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 1)
                    .offset(y: topH)
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 1)
                    .offset(y: -bottomH)
            }
        }
    }
    
    private func lensShortName(_ lens: LensChoice) -> String {
        switch lens {
        case .ultraWide13mm: return "0.5x"
        case .mainWide24mm: return "1.0x"
        case .mainWide28mm: return "1.2x"
        case .mainWide35mm: return "1.5x"
        case .telephoto120mm: return "5.0x"
        case .frontTrueDepth: return "FRONT"
        }
    }
}
