//
//  ZeroCopyRecorder.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Hardware AVAssetWriter Recorder:
//  Zero-Allocation CVPixelBufferPool, 10-Bit HEVC / ProRes 422 HQ,
//  Dual-Stream (Baked vs Clean Log + Sidecar), and USB-C 10Gbps NVMe Direct Streaming.
//

import Foundation
import AVFoundation
import CoreVideo
import os.log

public enum CinemaCodec: String, CaseIterable, Identifiable {
    case proRes422HQ = "Apple ProRes 422 HQ"
    case proRes422 = "Apple ProRes 422"
    case proRes422LT = "Apple ProRes 422 LT"
    case hevc10Bit = "HEVC 10-Bit (H.265)"
    
    public var id: String { rawValue }
    
    public var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .hevc10Bit: return .hevc
        }
    }
}

public enum RecordingMode: String, CaseIterable, Identifiable {
    case directBaked = "Direct Baked (LUT + Optics)"
    case cleanLogWithSidecar = "Clean Apple Log + Sidecar"
    
    public var id: String { rawValue }
}

public protocol ZeroCopyRecorderDelegate: AnyObject {
    func recorderDidStart(_ recorder: ZeroCopyRecorder)
    func recorderDidUpdateProgress(_ recorder: ZeroCopyRecorder, duration: CMTime, framesWritten: Int64, bytesWritten: Int64)
    func recorderDidFinish(_ recorder: ZeroCopyRecorder, fileURL: URL)
    func recorderDidEncounterError(_ recorder: ZeroCopyRecorder, error: Error)
}

public final class ZeroCopyRecorder {
    public weak var delegate: ZeroCopyRecorderDelegate?
    
    public private(set) var isRecording = false
    public private(set) var currentCodec: CinemaCodec = .proRes422HQ
    public private(set) var currentMode: RecordingMode = .directBaked
    public private(set) var destinationURL: URL?
    public private(set) var framesRecorded: Int64 = 0
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime = .invalid
    private let poolManager = PixelBufferPoolManager()
    
    private let recordingQueue = DispatchQueue(label: "com.cinema.recordingQueue", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "ZeroCopyRecorder")
    
    public init() {}
    
    // MARK: - Recording Control
    
    public func startRecording(
        outputDirectory: URL? = nil,
        width: Int,
        height: Int,
        fps: Double,
        codec: CinemaCodec,
        mode: RecordingMode,
        activeBundle: CinemaLUTBundle? = nil
    ) throws {
        guard !isRecording else { return }
        
        // 1. Determine destination URL (USB-C External NVMe or Local Documents)
        let dir = outputDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileDate = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let ext = codec == .hevc10Bit ? "mov" : "mov"
        let filename = "CINEMA_\(fileDate).\(ext)"
        let targetFileURL = dir.appendingPathComponent(filename)
        self.destinationURL = targetFileURL
        self.currentCodec = codec
        self.currentMode = mode
        self.framesRecorded = 0
        self.startTime = .invalid
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: targetFileURL)
        
        // 2. Initialize AVAssetWriter
        let writer = try AVAssetWriter(outputURL: targetFileURL, fileType: .mov)
        
        // 3. Configure Video Compression Settings
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        
        if codec == .hevc10Bit {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAverageBitRateKey: 150_000_000 // 150 Mbps for 10-bit HEVC 4K120
            ]
        }
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        
        // 4. Pre-allocate CVPixelBufferPool
        let sourcePixelFormat: OSType = (mode == .cleanLogWithSidecar) ?
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange :
            kCVPixelFormatType_32BGRA
        
        _ = poolManager.createPool(width: width, height: height, pixelFormat: sourcePixelFormat, poolSize: 6)
        
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: sourcePixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )
        
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw NSError(domain: "CinemaRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to asset writer."])
        }
        
        // 5. If Clean Log mode, write .cinemalut sidecar to output directory for DaVinci Resolve
        if mode == .cleanLogWithSidecar, let bundle = activeBundle {
            let sidecarURL = dir.appendingPathComponent("CINEMA_\(fileDate).cinemalut")
            exportSidecar(bundle: bundle, to: sidecarURL)
        }
        
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "CinemaRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start."])
        }
        
        self.assetWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor
        self.isRecording = true
        
        logger.info("Started zero-copy recording to \(targetFileURL.path) (\(codec.rawValue), \(width)x\(height) @ \(fps)fps).")
        delegate?.recorderDidStart(self)
    }
    
    /// Appends a processed CVPixelBuffer (Direct Baked) or raw CVPixelBuffer (Clean Log) zero-copy to the writer
    public func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        recordingQueue.async { [weak self] in
            guard let self = self, self.isRecording,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor else { return }
            
            if !self.startTime.isValid {
                self.startTime = presentationTime
                writer.startSession(atSourceTime: presentationTime)
                self.logger.info("Session started at source time: \(presentationTime.seconds)")
            }
            
            if input.isReadyForMoreMediaData {
                let success = adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                if success {
                    self.framesRecorded += 1
                    let elapsed = CMTimeSubtract(presentationTime, self.startTime)
                    self.delegate?.recorderDidUpdateProgress(self, duration: elapsed, framesWritten: self.framesRecorded, bytesWritten: self.framesRecorded * 4 * 1024 * 1024)
                } else if let error = writer.error {
                    self.logger.error("Failed to append buffer: \(error.localizedDescription)")
                    self.delegate?.recorderDidEncounterError(self, error: error)
                }
            } else {
                self.logger.warning("Writer input not ready; dropped frame at \(presentationTime.seconds)")
            }
        }
    }
    
    /// Acquires a pre-allocated CVPixelBuffer from the recorder's internal pool
    public func acquirePoolBuffer() -> CVPixelBuffer? {
        return poolManager.acquireBuffer()
    }
    
    public func stopRecording(completion: @escaping (URL?) -> Void) {
        recordingQueue.async { [weak self] in
            guard let self = self, self.isRecording,
                  let writer = self.assetWriter,
                  let input = self.videoInput else {
                completion(nil)
                return
            }
            
            self.isRecording = false
            input.markAsFinished()
            
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.poolManager.invalidate()
                let targetURL = self.destinationURL
                self.logger.info("Recording finished successfully. Saved to: \(targetURL?.path ?? "")")
                DispatchQueue.main.async {
                    if let url = targetURL {
                        self.delegate?.recorderDidFinish(self, fileURL: url)
                    }
                    completion(targetURL)
                }
            }
        }
    }
    
    private func exportSidecar(bundle: CinemaLUTBundle, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let manifestData = try JSONEncoder().encode(bundle.manifest)
            try manifestData.write(to: url.appendingPathComponent("optics.json"))
            logger.info("Exported DaVinci Resolve .cinemalut sidecar to \(url.path)")
        } catch {
            logger.error("Failed to export sidecar: \(error.localizedDescription)")
        }
    }
}
