//
//  CubeLUTParser.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  High-Performance .cube 3D LUT Parser & MTLTextureType3D Generator.
//  Converts standard Adobe / DaVinci Resolve .cube files into hardware-interpolated 3D Metal textures.
//

import Foundation
import Metal
import os.log

public final class CubeLUTParser {
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "CubeLUTParser")
    
    public enum LUTError: Error {
        case fileNotFound
        case invalidFormat(String)
        case unsupportedDimension
        case deviceAllocationFailed
    }
    
    public init() {}
    
    /// Parses a .cube file at the given URL into a 3D Metal Texture (MTLTextureType3D).
    public func loadLUT(from url: URL, device: MTLDevice) throws -> MTLTexture {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content: content, device: device)
    }
    
    /// Parses string content formatted in standard Adobe .cube specification.
    public func parse(content: String, device: MTLDevice) throws -> MTLTexture {
        var size: Int = 0
        var domainMin = SIMD3<Float>(0.0, 0.0, 0.0)
        var domainMax = SIMD3<Float>(1.0, 1.0, 1.0)
        
        let lines = content.components(separatedBy: .newlines)
        var dataValues: [SIMD4<Float16>] = []
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let firstToken = tokens.first else { continue }
            
            if firstToken == "LUT_3D_SIZE" {
                if tokens.count >= 2, let parsedSize = Int(tokens[1]) {
                    size = parsedSize
                    dataValues.reserveCapacity(size * size * size)
                }
            } else if firstToken == "DOMAIN_MIN" {
                if tokens.count >= 4,
                   let minR = Float(tokens[1]),
                   let minG = Float(tokens[2]),
                   let minB = Float(tokens[3]) {
                    domainMin = SIMD3<Float>(minR, minG, minB)
                }
            } else if firstToken == "DOMAIN_MAX" {
                if tokens.count >= 4,
                   let maxR = Float(tokens[1]),
                   let maxG = Float(tokens[2]),
                   let maxB = Float(tokens[3]) {
                    domainMax = SIMD3<Float>(maxR, maxG, maxB)
                }
            } else if tokens.count >= 3 {
                // Parse RGB triplet
                if let r = Float(tokens[0]),
                   let g = Float(tokens[1]),
                   let b = Float(tokens[2]) {
                    
                    // Normalize across domain range if specified
                    let normR = (r - domainMin.x) / (domainMax.x - domainMin.x)
                    let normG = (g - domainMin.y) / (domainMax.y - domainMin.y)
                    let normB = (b - domainMin.z) / (domainMax.z - domainMin.z)
                    
                    dataValues.append(
                        SIMD4<Float16>(
                            Float16(normR),
                            Float16(normG),
                            Float16(normB),
                            Float16(1.0)
                        )
                    )
                }
            }
        }
        
        guard size > 0 else {
            throw LUTError.invalidFormat("Missing LUT_3D_SIZE header.")
        }
        
        let expectedCount = size * size * size
        guard dataValues.count == expectedCount else {
            throw LUTError.invalidFormat("Expected \(expectedCount) table elements, found \(dataValues.count).")
        }
        
        // Allocate 3D Metal Texture
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LUTError.deviceAllocationFailed
        }
        
        // Resolve .cube ordering: Red changes fastest, then Green, then Blue
        let bytesPerPixel = MemoryLayout<SIMD4<Float16>>.stride
        let bytesPerRow = size * bytesPerPixel
        let bytesPerImage = bytesPerRow * size
        
        dataValues.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: size, height: size, depth: size)
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }
        
        logger.info("Successfully loaded 3D LUT (size: \(size)x\(size)x\(size), 16-bit Float).")
        return texture
    }
    
    /// Generates an identity 3D LUT texture in memory for clean un-graded pass-through.
    public func createIdentityLUT(size: Int = 33, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        
        var values = [SIMD4<Float16>]()
        values.reserveCapacity(size * size * size)
        
        let inv = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(
                        SIMD4<Float16>(
                            Float16(Float(r) / inv),
                            Float16(Float(g) / inv),
                            Float16(Float(b) / inv),
                            Float16(1.0)
                        )
                    )
                }
            }
        }
        
        let bytesPerPixel = MemoryLayout<SIMD4<Float16>>.stride
        let bytesPerRow = size * bytesPerPixel
        let bytesPerImage = bytesPerRow * size
        
        values.withUnsafeBytes { raw in
            if let addr = raw.baseAddress {
                texture.replace(
                    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: size, height: size, depth: size)),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: addr,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            }
        }
        
        return texture
    }
}
