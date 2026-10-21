//
//  PixelBufferPoolManager.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Zero-Allocation CVPixelBufferPool Manager.
//  Pre-allocates an IOSurface-backed ring buffer of 6 CVPixelBuffer objects
//  to guarantee zero allocation per frame during continuous 4K 120 FPS encoding.
//

import Foundation
import CoreVideo
import os.log

public final class PixelBufferPoolManager {
    public private(set) var pool: CVPixelBufferPool?
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "PixelBufferPoolManager")
    
    public init() {}
    
    /// Creates a pre-allocated IOSurface-backed CVPixelBufferPool
    public func createPool(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA, poolSize: Int = 6) -> Bool {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: poolSize
        ]
        
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], // Zero-copy GPU IOSurface backing
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )
        
        guard status == kCVReturnSuccess, let validPool = newPool else {
            logger.error("Failed to create CVPixelBufferPool: OSStatus \(status)")
            return false
        }
        
        self.pool = validPool
        
        // Pre-warm the pool to allocate the IOSurfaces upfront
        var preAllocatedBuffers: [CVPixelBuffer] = []
        for _ in 0..<poolSize {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, validPool, &buffer) == kCVReturnSuccess,
               let buf = buffer {
                preAllocatedBuffers.append(buf)
            }
        }
        preAllocatedBuffers.removeAll() // Return back to pool
        
        logger.info("Pre-allocated CVPixelBufferPool for \(width)x\(height) with \(poolSize) buffers.")
        return true
    }
    
    /// Acquires a recycled CVPixelBuffer from the pre-allocated pool
    public func acquireBuffer() -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            logger.warning("Pixel buffer pool exhausted; frame may be dropped.")
            return nil
        }
        return buffer
    }
    
    public func invalidate() {
        pool = nil
    }
}
