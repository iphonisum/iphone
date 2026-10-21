//
//  CinemaMetalContext.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Zero-Copy GPU Context: Shared MTLDevice, High-Priority Metal CommandQueue,
//  and CVMetalTextureCache mapping for IOSurface Luma/Chroma DMA transfers.
//

import Foundation
import Metal
import CoreVideo
import os.log

public final class CinemaMetalContext {
    public static let shared = CinemaMetalContext()
    
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public private(set) var textureCache: CVMetalTextureCache?
    
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "CinemaMetalContext")
    
    private init() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Apple A17 Pro Metal device could not be initialized.")
        }
        self.device = defaultDevice
        
        guard let queue = defaultDevice.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue on A17 Pro.")
        }
        self.commandQueue = queue
        
        setupTextureCache()
        logger.info("Metal Context initialized successfully on: \(self.device.name)")
    }
    
    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let validCache = cache else {
            fatalError("Unable to create CVMetalTextureCacheRef: OSStatus \(status)")
        }
        self.textureCache = validCache
    }
    
    /// Flushes transient texture references from the CVMetalTextureCache
    public func flushCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    
    /// Maps a Bi-Planar 10-bit YUV CVPixelBuffer (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    /// into Luma (Plane 0) and Chroma (Plane 1) MTLTexture instances with zero CPU memory copy.
    public func createTextures(from pixelBuffer: CVPixelBuffer) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let cache = textureCache else { return nil }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Plane 0: Luma (Y) - 10-bit stored in 16-bit unorm or 8-bit unorm depending on capture format
        // kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange uses r16Unorm
        var lumaCVTexture: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r16Unorm,
            width,
            height,
            0,
            &lumaCVTexture
        )
        
        // Plane 1: Chroma (CbCr) - half width, half height, 2 channels (rg16Unorm)
        var chromaCVTexture: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            width / 2,
            height / 2,
            1,
            &chromaCVTexture
        )
        
        guard lumaStatus == kCVReturnSuccess, let lumaCV = lumaCVTexture,
              let lumaMTL = CVMetalTextureGetTexture(lumaCV),
              chromaStatus == kCVReturnSuccess, let chromaCV = chromaCVTexture,
              let chromaMTL = CVMetalTextureGetTexture(chromaCV) else {
            logger.error("Failed to map CVPixelBuffer planes to Metal textures. Status Luma: \(lumaStatus), Chroma: \(chromaStatus)")
            return nil
        }
        
        return (luma: lumaMTL, chroma: chromaMTL)
    }
    
    /// Maps an RGBA or BGRA destination CVPixelBuffer (for AVAssetWriter recording) zero-copy to an MTLTexture
    public func createRenderTargetTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var renderCVTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &renderCVTexture
        )
        
        guard status == kCVReturnSuccess, let cvTex = renderCVTexture,
              let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            logger.error("Failed to map output CVPixelBuffer to Metal texture: \(status)")
            return nil
        }
        
        return mtlTex
    }
}
