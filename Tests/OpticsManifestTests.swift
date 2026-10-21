//
//  OpticsManifestTests.swift
//  iPhoneCinemaCameraTests
//

import XCTest
@testable import iPhoneCinemaCamera

final class OpticsManifestTests: XCTestCase {
    
    func testManifestDecoding() throws {
        let json = """
        {
          "lutFile": "grade.cube",
          "inputColorSpace": "AppleLog",
          "glowIntensity": 0.45,
          "glowThreshold": 0.78,
          "anamorphicStretch": 3.5,
          "anamorphicTintRGB": [0.18, 0.58, 1.0],
          "halationStrength": 0.30,
          "defaultAspectRatio": "2.39:1"
        }
        """.data(using: .utf8)!
        
        let manifest = try JSONDecoder().decode(OpticsManifest.self, from: json)
        XCTAssertEqual(manifest.lutFile, "grade.cube")
        XCTAssertEqual(manifest.inputColorSpace, "AppleLog")
        XCTAssertEqual(manifest.glowIntensity, 0.45, accuracy: 0.001)
        XCTAssertEqual(manifest.glowThreshold, 0.78, accuracy: 0.001)
        XCTAssertEqual(manifest.anamorphicStretch, 3.5, accuracy: 0.001)
        XCTAssertEqual(manifest.anamorphicTintRGB, [0.18, 0.58, 1.0])
        XCTAssertEqual(manifest.halationStrength, 0.30, accuracy: 0.001)
        XCTAssertEqual(manifest.defaultAspectRatio, "2.39:1")
    }
    
    func testAspectRatioBounds() {
        let scope = CinemaAspectRatio.scope239
        XCTAssertEqual(scope.normalizedBounds.x, 0.1282, accuracy: 0.0001)
        XCTAssertEqual(scope.normalizedBounds.y, 0.8718, accuracy: 0.0001)
        XCTAssertEqual(scope.resolution4K.width, 3840)
        XCTAssertEqual(scope.resolution4K.height, 1606)
        
        let univisium = CinemaAspectRatio.univisium200
        XCTAssertEqual(univisium.normalizedBounds.x, 0.0556, accuracy: 0.0001)
        XCTAssertEqual(univisium.normalizedBounds.y, 0.9444, accuracy: 0.0001)
        XCTAssertEqual(univisium.resolution4K.width, 3840)
        XCTAssertEqual(univisium.resolution4K.height, 1920)
        
        let native = CinemaAspectRatio.native169
        XCTAssertEqual(native.normalizedBounds.x, 0.0)
        XCTAssertEqual(native.normalizedBounds.y, 1.0)
    }
}
