//
//  CinemaCameraViewModel.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Central View Model coordinating CoreCaptureEngine, SpatialOpticsPipeline,
//  ZeroCopyRecorder, and 120Hz ProMotion CAMetalLayer viewfinder rendering.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import AVFoundation
import Combine
import SwiftUI
import os.log

public final class CinemaCameraViewModel: NSObject, ObservableObject {
    // Engine Subsystems
    public let captureEngine = CoreCaptureEngine()
    public let metalContext = CinemaMetalContext.shared
    public lazy var opticsPipeline = SpatialOpticsPipeline(context: metalContext)
    public let recorder = ZeroCopyRecorder()
    public let storageManager = ExternalStorageManager.shared
    
    // Captured State & UI Bindings
    @Published public var selectedLens: LensChoice = .mainWide24mm
    @Published public var currentFPS: Double = 24.0
    @Published public var shutterAngle: Double = 180.0
    @Published public var targetISO: Float = 800.0
    @Published public var kelvin: Float = 5600.0
    @Published public var tint: Float = 0.0
    @Published public var focusDistance: Float = 0.5
    
    // Spatial LUT & Framing
    @Published public var selectedAspectRatio: CinemaAspectRatio = .scope239
    @Published public var isLetterboxMode: Bool = true
    @Published public var anamorphicDesqueeze: Float = 1.0 // 1.0, 1.33, 1.55
    @Published public var activeBundle: CinemaLUTBundle?
    @Published public var availableBundles: [CinemaLUTBundle] = []
    
    // Fine-Tuning Optics Overrides
    @Published public var glowIntensity: Float = 0.45
    @Published public var glowThreshold: Float = 0.78
    @Published public var anamorphicStretch: Float = 3.5
    @Published public var halationStrength: Float = 0.30
    
    // Cinema Monitoring Tools
    @Published public var isFalseColorEnabled: Bool = false
    @Published public var isFocusPeakingEnabled: Bool = false
    @Published public var isZebraEnabled: Bool = false
    @Published public var peakingColorIndex: Int = 0 // 0: Green, 1: Red, 2: Blue
    
    // Recording & Telemetry
    @Published public var isRecording: Bool = false
    @Published public var selectedCodec: CinemaCodec = .proRes422HQ
    @Published public var recordingMode: RecordingMode = .directBaked
    @Published public var timecodeString: String = "00:00:00:00"
    @Published public var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public var fpsMetric: Double = 120.0
    @Published public var computeLatencyMs: Double = 1.2
    
    // Uniforms Cache
    private var uniforms = CinemaUniforms()
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "CinemaCameraViewModel")
    
    public override init() {
        super.init()
        captureEngine.delegate = self
        recorder.delegate = self
        
        loadDefaultBundles()
        setupThermalObserver()
        updateUniforms()
    }
    
    public func startCamera() {
        captureEngine.startEngine { [weak self] result in
            switch result {
            case .success:
                self?.logger.info("Camera started successfully.")
            case .failure(let err):
                self?.logger.error("Camera startup error: \(err.localizedDescription)")
            }
        }
    }
    
    public func stopCamera() {
        captureEngine.stopEngine()
    }
    
    // MARK: - Sensor Mutation Dispatch
    
    public func updateLens(_ lens: LensChoice) {
        selectedLens = lens
        captureEngine.switchLens(to: lens)
    }
    
    public func updateFPS(_ fps: Double) {
        currentFPS = fps
        captureEngine.setFPS(fps)
    }
    
    public func updateShutterAngle(_ angle: Double) {
        shutterAngle = angle
        captureEngine.setShutterAngle(angle)
    }
    
    public func updateISO(_ iso: Float) {
        targetISO = iso
        captureEngine.setISO(iso)
    }
    
    public func updateWhiteBalance(kelvin: Float, tint: Float) {
        self.kelvin = kelvin
        self.tint = tint
        captureEngine.setWhiteBalance(kelvin: kelvin, tint: tint)
    }
    
    public func updateFocus(distance: Float) {
        self.focusDistance = distance
        captureEngine.setManualFocus(lensPosition: distance)
    }
    
    public func toggleRecording() {
        if isRecording {
            recorder.stopRecording { [weak self] url in
                DispatchQueue.main.async {
                    self?.isRecording = false
                    self?.timecodeString = "00:00:00:00"
                }
            }
        } else {
            let res = selectedAspectRatio.resolution4K
            do {
                try recorder.startRecording(
                    outputDirectory: storageManager.activeDrive?.url,
                    width: res.width,
                    height: res.height,
                    fps: currentFPS,
                    codec: selectedCodec,
                    mode: recordingMode,
                    activeBundle: activeBundle
                )
                isRecording = true
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
    
    public func selectLUTBundle(_ bundle: CinemaLUTBundle) {
        self.activeBundle = bundle
        self.glowIntensity = bundle.manifest.glowIntensity
        self.glowThreshold = bundle.manifest.glowThreshold
        self.anamorphicStretch = bundle.manifest.anamorphicStretch
        self.halationStrength = bundle.manifest.halationStrength
        
        if let aspect = CinemaAspectRatio(rawValue: bundle.manifest.defaultAspectRatio) {
            self.selectedAspectRatio = aspect
        }
        updateUniforms()
    }
    
    public func updateUniforms() {
        uniforms.glowIntensity = glowIntensity
        uniforms.glowThreshold = glowThreshold
        uniforms.anamorphicStretch = anamorphicStretch
        uniforms.halationStrength = halationStrength
        uniforms.activeCropBounds = selectedAspectRatio.normalizedBounds
        uniforms.anamorphicDesqueeze = anamorphicDesqueeze
        uniforms.isLetterboxMode = isLetterboxMode ? 1 : 0
        uniforms.enableFalseColor = isFalseColorEnabled ? 1 : 0
        uniforms.enableFocusPeaking = isFocusPeakingEnabled ? 1 : 0
        uniforms.enableZebra = isZebraEnabled ? 1 : 0
        
        // Colors
        if let bundle = activeBundle, bundle.manifest.anamorphicTintRGB.count >= 3 {
            uniforms.anamorphicTint = (bundle.manifest.anamorphicTintRGB[0], bundle.manifest.anamorphicTintRGB[1], bundle.manifest.anamorphicTintRGB[2])
        } else {
            uniforms.anamorphicTint = (0.18, 0.58, 1.0) // Classic blue anamorphic streak
        }
        
        switch peakingColorIndex {
        case 1: uniforms.peakingColor = (1.0, 0.05, 0.1) // Red
        case 2: uniforms.peakingColor = (0.1, 0.5, 1.0)  // Blue
        default: uniforms.peakingColor = (0.0, 1.0, 0.2) // Green
        }
    }
    
    // MARK: - Viewfinder Render Loop (120Hz ProMotion)
    
    public func renderFrame(to currentDrawable: CAMetalDrawable, sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textures = metalContext.createTextures(from: pixelBuffer),
              let lutTexture = activeBundle?.lutTexture ?? metalContext.device.makeDefaultLibrary().flatMap({ _ in nil }) else {
            return
        }
        
        let startTimestamp = CACurrentMediaTime()
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else { return }
        
        // Render target is the ProMotion CAMetalDrawable texture
        let targetTexture = currentDrawable.texture
        
        updateUniforms()
        opticsPipeline.encode(
            commandBuffer: commandBuffer,
            luma: textures.luma,
            chroma: textures.chroma,
            lut3D: lutTexture,
            outputTexture: targetTexture,
            uniforms: &uniforms
        )
        
        // If recording Direct Baked mode, simultaneously write to pre-allocated CVPixelBuffer
        if isRecording && recordingMode == .directBaked, let recorderBuffer = recorder.acquirePoolBuffer() {
            if let recordTex = metalContext.createRenderTargetTexture(from: recorderBuffer) {
                // Encode to recorder texture
                opticsPipeline.encode(
                    commandBuffer: commandBuffer,
                    luma: textures.luma,
                    chroma: textures.chroma,
                    lut3D: lutTexture,
                    outputTexture: recordTex,
                    uniforms: &uniforms
                )
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                commandBuffer.addCompletedHandler { [weak self] _ in
                    self?.recorder.appendPixelBuffer(recorderBuffer, presentationTime: pts)
                }
            }
        } else if isRecording && recordingMode == .cleanLogWithSidecar {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recorder.appendPixelBuffer(pixelBuffer, presentationTime: pts)
        }
        
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
        
        let elapsedMs = (CACurrentMediaTime() - startTimestamp) * 1000.0
        DispatchQueue.main.async { [weak self] in
            self?.computeLatencyMs = elapsedMs
        }
    }
    
    private func setupThermalObserver() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.thermalState = ProcessInfo.processInfo.thermalState
                }
            }
            .store(in: &cancellables)
    }
    
    private func loadDefaultBundles() {
        let clean = CinemaLUTBundle.cleanAppleLog(device: metalContext.device)
        self.availableBundles = [clean]
        self.activeBundle = clean
    }
}

// MARK: - CoreCaptureEngineDelegate
extension CinemaCameraViewModel: CoreCaptureEngineDelegate {
    public func captureEngine(_ engine: CoreCaptureEngine, didOutput sampleBuffer: CMSampleBuffer) {
        // Frame processing routed via MTKView render delegate
    }
    
    public func captureEngine(_ engine: CoreCaptureEngine, didChangeLens device: AVCaptureDevice) {
        logger.info("Engine switched device to \(device.localizedName)")
    }
    
    public func captureEngine(_ engine: CoreCaptureEngine, didEncounterError error: Error) {
        logger.error("Capture engine error: \(error.localizedDescription)")
    }
}

// MARK: - ZeroCopyRecorderDelegate
extension CinemaCameraViewModel: ZeroCopyRecorderDelegate {
    public func recorderDidStart(_ recorder: ZeroCopyRecorder) {
        DispatchQueue.main.async { self.isRecording = true }
    }
    
    public func recorderDidUpdateProgress(_ recorder: ZeroCopyRecorder, duration: CMTime, framesWritten: Int64, bytesWritten: Int64) {
        let seconds = Int(CMTimeGetSeconds(duration))
        let hh = seconds / 3600
        let mm = (seconds % 3600) / 60
        let ss = seconds % 60
        let ff = Int(framesWritten % Int64(self.currentFPS))
        let tc = String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
        
        DispatchQueue.main.async {
            self.timecodeString = tc
        }
    }
    
    public func recorderDidFinish(_ recorder: ZeroCopyRecorder, fileURL: URL) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.timecodeString = "00:00:00:00"
        }
    }
    
    public func recorderDidEncounterError(_ recorder: ZeroCopyRecorder, error: Error) {
        logger.error("Recorder error: \(error.localizedDescription)")
    }
}
