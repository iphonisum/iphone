//
//  CinemaLUTBundle.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Spatial LUT Package (.cinemalut) Loader.
//  Binds standard 3D LUT color grading with optics.json spatial parameters
//  (Pro-Mist Bloom, Anamorphic Flare Streaks, Red Halation, and Target Framing).
//

import Foundation
import Metal
import os.log

public struct OpticsManifest: Codable, Equatable {
    public var lutFile: String
    public var inputColorSpace: String
    public var glowIntensity: Float
    public var glowThreshold: Float
    public var anamorphicStretch: Float
    public var anamorphicTintRGB: [Float] // [R, G, B]
    public var halationStrength: Float
    public var defaultAspectRatio: String
    
    public init(
        lutFile: String = "grade.cube",
        inputColorSpace: String = "AppleLog",
        glowIntensity: Float = 0.45,
        glowThreshold: Float = 0.78,
        anamorphicStretch: Float = 3.5,
        anamorphicTintRGB: [Float] = [0.18, 0.58, 1.0],
        halationStrength: Float = 0.30,
        defaultAspectRatio: String = "2.39:1"
    ) {
        self.lutFile = lutFile
        self.inputColorSpace = inputColorSpace
        self.glowIntensity = glowIntensity
        self.glowThreshold = glowThreshold
        self.anamorphicStretch = anamorphicStretch
        self.anamorphicTintRGB = anamorphicTintRGB
        self.halationStrength = halationStrength
        self.defaultAspectRatio = defaultAspectRatio
    }
}

public final class CinemaLUTBundle {
    public let name: String
    public let bundleURL: URL
    public var manifest: OpticsManifest
    public var lutTexture: MTLTexture?
    
    private let logger = Logger(subsystem: "com.antigravity.CinemaCamera", category: "CinemaLUTBundle")
    
    public init(name: String, bundleURL: URL, manifest: OpticsManifest, lutTexture: MTLTexture?) {
        self.name = name
        self.bundleURL = bundleURL
        self.manifest = manifest
        self.lutTexture = lutTexture
    }
    
    /// Loads a .cinemalut bundle directory
    public static func load(from directoryURL: URL, device: MTLDevice) throws -> CinemaLUTBundle {
        let manifestURL = directoryURL.appendingPathComponent("optics.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(OpticsManifest.self, from: manifestData)
        
        let cubeURL = directoryURL.appendingPathComponent(manifest.lutFile)
        let parser = CubeLUTParser()
        let lutTexture = try parser.loadLUT(from: cubeURL, device: device)
        
        let bundleName = directoryURL.deletingPathExtension().lastPathComponent
        return CinemaLUTBundle(
            name: bundleName,
            bundleURL: directoryURL,
            manifest: manifest,
            lutTexture: lutTexture
        )
    }
    
    /// Fallback default clean Apple Log pass-through bundle
    public static func cleanAppleLog(device: MTLDevice) -> CinemaLUTBundle {
        let parser = CubeLUTParser()
        let texture = parser.createIdentityLUT(size: 33, device: device)
        let manifest = OpticsManifest(
            lutFile: "identity.cube",
            inputColorSpace: "AppleLog",
            glowIntensity: 0.0,
            glowThreshold: 0.90,
            anamorphicStretch: 1.0,
            anamorphicTintRGB: [1.0, 1.0, 1.0],
            halationStrength: 0.0,
            defaultAspectRatio: "16:9"
        )
        return CinemaLUTBundle(
            name: "Clean Apple Log",
            bundleURL: URL(fileURLWithPath: "/dev/null"),
            manifest: manifest,
            lutTexture: texture
        )
    }
}
