//
//  CoreCaptureEngine.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Hardware-Level AVFoundation Capture Engine:
//  Dedicated serial queue (com.cinema.captureQueue), 10-Bit Apple Log format negotiation,
//  zero-lag 4K 120 FPS capture, multi-lens hot swapping, and deterministic manual sensor locks.
//

import Foundation
import AVFoundation
import CoreVideo
import os.log

public protocol CoreCaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CoreCaptureEngine, didOutput sampleBuffer: CMSampleBuffer)
    func captureEngine(_ engine: CoreCaptureEngine, didChangeLens device: AVCaptureDevice)
    func captureEngine(_ engine: CoreCaptureEngine, didEncounterError error: Error)
}

public enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide13mm = "13mm (0.5x)"
    case mainWide24mm = "24mm (1.0x)"
    case mainWide28mm = "28mm (1.2x)"
    case mainWide35mm = "35mm (1.5x)"
    case telephoto120mm = "120mm (5.0x)"
    case frontTrueDepth = "Front (23mm)"
    
    public var id: String { rawValue }
    
    public var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide13mm: return .builtInUltraWideCamera
        case .mainWide24mm, .mainWide28mm, .mainWide35mm: return .builtInWideAngleCamera
        case .telephoto120mm: return .builtInTelephotoCamera
        case .frontTrueDepth: return .builtInTrueDepthCamera
        }
    }
    
    public var position: AVCaptureDevice.Position {
        return self == .frontTrueDepth ? .front : .back
    }
    
    public var sensorCropZoomFactor: CGFloat {
        switch self {
        case .mainWide28mm: return 1.2
        case .mainWide35mm: return 1.5
        default: return 1.0
        }
    }
}

public final class CoreCaptureEngine: NSObject {
    public weak var delegate: CoreCaptureEngineDelegate?
    
    // Dedicated Serial Queue for deterministic hardware operations
    public let captureQueue = DispatchQueue(label: "com.cinema.captureQueue", qos: .userInteractive)
    
    public private(set) var captureSession = AVCaptureSession()
    public private(set) var activeDevice: AVCaptureDevice?
    public private(set) var activeInput: AVCaptureDeviceInput?
    public private(set) var videoOutput = AVCaptureVideoDataOutput()
    public private(set) var audioOutput = AVCaptureAudioDataOutput()
    
    // Active State Persistence across lens hot-swaps
    public private(set) var currentLens: LensChoice = .mainWide24mm
    public private(set) var currentFPS: Double = 24.0
    public private(set) var targetResolution: (width: Int32, height: Int32) = (3840, 2160)
    public private(set) var shutterAngle: Double = 180.0 // Standard 180-degree cinema shutter
    public private(set) var targetISO: Float = 800.0     // Native sweet spot for Apple Log
    public private(set) var kelvin: Float = 5600.0       // Daylight standard
    public private(set) var tint: Float = 0.0
    public private(set) var lensPosition: Float = 0.5
    public private(set) var isISOPriorityEnabled: Bool = true
    
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "CoreCaptureEngine")
    
    public override init() {
        super.init()
    }
    
    // MARK: - Lifecycle & Configuration
    
    public func startEngine(completion: @escaping (Result<Void, Error>) -> Void) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setupCaptureSession()
                self.captureSession.startRunning()
                self.logger.info("AVCaptureSession started running.")
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.logger.error("Capture session failed to start: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    public func stopEngine() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
                self.logger.info("AVCaptureSession stopped.")
            }
        }
    }
    
    private func setupCaptureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .inputPriority
        captureSession.automaticallyConfiguresCaptureDeviceForWideColor = false
        
        // 1. Discover and attach default physical device (Main 24mm Wide)
        let device = try selectPhysicalDevice(for: currentLens)
        let input = try AVCaptureDeviceInput(device: device)
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            self.activeInput = input
            self.activeDevice = device
        } else {
            throw NSError(domain: "CinemaCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input."])
        }
        
        // 2. Setup 10-bit Video Output
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        // Disable extended stabilization to eliminate frame lag
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }
        
        captureSession.commitConfiguration()
        
        // 3. Negotiate 4K120 / Apple Log hardware format
        try configureHardwareFormat(device: device, fps: currentFPS, resolution: targetResolution)
        
        // 4. Apply initial deterministic manual locks
        try applyManualLocks(device: device)
    }
    
    // MARK: - Hardware Format Negotiation (4K120 & Apple Log)
    
    public func configureHardwareFormat(device: AVCaptureDevice, fps: Double, resolution: (width: Int32, height: Int32)) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        // Discover matching 10-bit format
        let matchingFormats = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let isMatchingRes = dims.width == resolution.width && dims.height == resolution.height
            let is10Bit = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let supportsAppleLog = format.supportedColorSpaces.contains(.appleLog)
            let supportsFPS = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= fps && fps <= range.maxFrameRate
            }
            return isMatchingRes && is10Bit && supportsAppleLog && supportsFPS
        }
        
        guard let bestFormat = matchingFormats.first ?? device.formats.first(where: { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == resolution.width && dims.height == resolution.height
        }) else {
            logger.warning("No exact matching Apple Log 10-bit format found; retaining current format.")
            return
        }
        
        device.activeFormat = bestFormat
        
        // Explicitly assign Apple Log Color Space
        if bestFormat.supportedColorSpaces.contains(.appleLog) {
            device.activeColorSpace = .appleLog
            logger.info("Active color space locked to: .appleLog")
        } else if bestFormat.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
            logger.info("Active color space locked to fallback: .HLG_BT2020")
        }
        
        // Exact Frame Duration Lock (e.g. 1/24, 1/30, 1/60, 1/120)
        let exactDuration = CMTimeMake(value: 1, timescale: Int32(fps))
        device.activeVideoMinFrameDuration = exactDuration
        device.activeVideoMaxFrameDuration = exactDuration
        
        logger.info("Locked frame duration to \(fps) FPS (\(exactDuration.value)/\(exactDuration.timescale)s).")
    }
    
    // MARK: - Multi-Lens Hot Swapping Without Interruption
    
    public func switchLens(to targetLens: LensChoice) {
        captureQueue.async { [weak self] in
            guard let self = self, self.currentLens != targetLens else { return }
            
            do {
                self.captureSession.beginConfiguration()
                
                // If switching between 24mm, 28mm, and 35mm, we utilize optical 48MP sensor crop zoom
                if (self.currentLens == .mainWide24mm || self.currentLens == .mainWide28mm || self.currentLens == .mainWide35mm) &&
                   (targetLens == .mainWide24mm || targetLens == .mainWide28mm || targetLens == .mainWide35mm) {
                    
                    if let device = self.activeDevice {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = targetLens.sensorCropZoomFactor
                        device.unlockForConfiguration()
                        self.currentLens = targetLens
                        self.captureSession.commitConfiguration()
                        self.logger.info("Executed optical sensor-crop zoom: \(targetLens.rawValue)")
                        DispatchQueue.main.async { self.delegate?.captureEngine(self, didChangeLens: device) }
                        return
                    }
                }
                
                // Physical lens change: 13mm <-> 24mm <-> 120mm <-> Front
                let newDevice = try self.selectPhysicalDevice(for: targetLens)
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                
                if let oldInput = self.activeInput {
                    self.captureSession.removeInput(oldInput)
                }
                
                if self.captureSession.canAddInput(newInput) {
                    self.captureSession.addInput(newInput)
                    self.activeInput = newInput
                    self.activeDevice = newDevice
                    self.currentLens = targetLens
                }
                
                // Configure video stabilization to off for zero lag
                if let connection = self.videoOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .off
                    }
                }
                
                self.captureSession.commitConfiguration()
                
                // Negotiate format and restore cached state
                try self.configureHardwareFormat(device: newDevice, fps: self.currentFPS, resolution: self.targetResolution)
                try self.applyManualLocks(device: newDevice)
                
                self.logger.info("Hot-swapped lens to: \(targetLens.rawValue)")
                DispatchQueue.main.async { self.delegate?.captureEngine(self, didChangeLens: newDevice) }
            } catch {
                self.logger.error("Lens switch failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.delegate?.captureEngine(self, didEncounterError: error) }
            }
        }
    }
    
    private func selectPhysicalDevice(for lens: LensChoice) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [lens.deviceType],
            mediaType: .video,
            position: lens.position
        )
        guard let device = discovery.devices.first else {
            throw NSError(
                domain: "CinemaCamera",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Physical camera module for \(lens.rawValue) not found."]
            )
        }
        return device
    }
    
    // MARK: - Manual Sensor Controls (ISO, Shutter Angle, WB, Focus)
    
    public func setFPS(_ newFPS: Double) {
        captureQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.currentFPS = newFPS
            do {
                try self.configureHardwareFormat(device: device, fps: newFPS, resolution: self.targetResolution)
                try self.applyCinemaExposure(device: device)
            } catch {
                self.logger.error("Failed to update FPS: \(error.localizedDescription)")
            }
        }
    }
    
    public func setShutterAngle(_ angle: Double) {
        captureQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.shutterAngle = angle
            do {
                try self.applyCinemaExposure(device: device)
            } catch {
                self.logger.error("Failed to set shutter angle: \(error.localizedDescription)")
            }
        }
    }
    
    public func setISO(_ iso: Float) {
        captureQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.targetISO = iso
            do {
                try self.applyCinemaExposure(device: device)
            } catch {
                self.logger.error("Failed to set ISO: \(error.localizedDescription)")
            }
        }
    }
    
    public func setWhiteBalance(kelvin: Float, tint: Float) {
        captureQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.kelvin = kelvin
            self.tint = tint
            do {
                try self.applyWhiteBalance(device: device)
            } catch {
                self.logger.error("Failed to set White Balance: \(error.localizedDescription)")
            }
        }
    }
    
    public func setManualFocus(lensPosition: Float) {
        captureQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.lensPosition = max(0.0, min(lensPosition, 1.0))
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: self.lensPosition, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                self.logger.error("Failed to set manual focus: \(error.localizedDescription)")
            }
        }
    }
    
    private func applyManualLocks(device: AVCaptureDevice) throws {
        try applyCinemaExposure(device: device)
        try applyWhiteBalance(device: device)
        try device.lockForConfiguration()
        device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
        device.unlockForConfiguration()
    }
    
    private func applyCinemaExposure(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        // Calculate exact exposure duration from Shutter Angle: Duration = (Angle / 360.0) / FPS
        let exposureSeconds = (shutterAngle / 360.0) / currentFPS
        let rawDuration = CMTimeMakeWithSeconds(exposureSeconds, preferredTimescale: 1_000_000)
        let clampedDuration = max(device.activeFormat.minExposureDuration, min(rawDuration, device.activeFormat.maxExposureDuration))
        
        // Clamp ISO to active sensor format limits
        let clampedISO = max(device.activeFormat.minISO, min(targetISO, device.activeFormat.maxISO))
        
        device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO, completionHandler: nil)
        logger.info("Exposure locked: \(clampedDuration.seconds)s (Angle \(self.shutterAngle)°), ISO \(clampedISO)")
    }
    
    private func applyWhiteBalance(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: kelvin,
            tint: tint
        )
        var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
        let maxG = device.maxWhiteBalanceGain
        
        gains.redGain = max(1.0, min(gains.redGain, maxG))
        gains.greenGain = max(1.0, min(gains.greenGain, maxG))
        gains.blueGain = max(1.0, min(gains.blueGain, maxG))
        
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        logger.info("White balance locked: \(self.kelvin)K, Tint \(self.tint)")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CoreCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.captureEngine(self, didOutput: sampleBuffer)
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        logger.warning("Dropped frame in capture session.")
    }
}
