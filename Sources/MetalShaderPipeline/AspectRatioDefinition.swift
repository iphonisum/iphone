//
//  AspectRatioDefinition.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Cinematic Aspect Ratio specifications for True-Crop and Letterboxed Mattes.
//

import Foundation
import simd

public enum CinemaAspectRatio: String, CaseIterable, Identifiable {
    case scope239 = "2.39:1"
    case univisium200 = "2.00:1"
    case theatricalFlat185 = "1.85:1"
    case native169 = "16:9"
    case imax43 = "4:3"
    case vertical916 = "9:16"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .scope239: return "2.39:1 Anamorphic Scope"
        case .univisium200: return "2.00:1 Univisium"
        case .theatricalFlat185: return "1.85:1 Theatrical Flat"
        case .native169: return "16:9 Native UHD"
        case .imax43: return "4:3 IMAX Classic"
        case .vertical916: return "9:16 Vertical Cinema"
        }
    }
    
    /// Normalized bounds for letterbox bars [min, max]
    public var normalizedBounds: SIMD2<Float> {
        switch self {
        case .scope239: return SIMD2<Float>(0.1282, 0.8718)
        case .univisium200: return SIMD2<Float>(0.0556, 0.9444)
        case .theatricalFlat185: return SIMD2<Float>(0.0194, 0.9806)
        case .native169: return SIMD2<Float>(0.0, 1.0)
        case .imax43: return SIMD2<Float>(0.1250, 0.8750) // Applied to X-axis
        case .vertical916: return SIMD2<Float>(0.0, 1.0)
        }
    }
    
    /// True-Crop target pixel dimensions in 4K
    public var resolution4K: (width: Int, height: Int) {
        switch self {
        case .scope239: return (3840, 1606)
        case .univisium200: return (3840, 1920)
        case .theatricalFlat185: return (3840, 2076)
        case .native169: return (3840, 2160)
        case .imax43: return (2880, 2160)
        case .vertical916: return (2160, 3840)
        }
    }
    
    /// True-Crop target pixel dimensions in 1080p
    public var resolution1080p: (width: Int, height: Int) {
        switch self {
        case .scope239: return (1920, 804)
        case .univisium200: return (1920, 960)
        case .theatricalFlat185: return (1920, 1038)
        case .native169: return (1920, 1080)
        case .imax43: return (1440, 1080)
        case .vertical916: return (1080, 1920)
        }
    }
}

public struct CinemaUniforms {
    public var glowIntensity: Float = 0.45
    public var glowThreshold: Float = 0.78
    public var anamorphicStretch: Float = 3.5
    public var anamorphicTint: (Float, Float, Float) = (0.18, 0.58, 1.0)
    public var halationStrength: Float = 0.30
    public var activeCropBounds: SIMD2<Float> = SIMD2<Float>(0.1282, 0.8718)
    public var anamorphicDesqueeze: Float = 1.0
    public var isLetterboxMode: UInt32 = 1
    public var enableFalseColor: UInt32 = 0
    public var enableFocusPeaking: UInt32 = 0
    public var peakingColor: (Float, Float, Float) = (0.0, 1.0, 0.2)
    public var peakingThreshold: Float = 0.12
    public var enableZebra: UInt32 = 0
    public var zebraThreshold: Float = 0.95
    public var zebraFrequency: Float = 0.15
    
    public init() {}
}
