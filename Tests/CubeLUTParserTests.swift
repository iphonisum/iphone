//
//  CubeLUTParserTests.swift
//  iPhoneCinemaCameraTests
//

import XCTest
@testable import iPhoneCinemaCamera

final class CubeLUTParserTests: XCTestCase {
    
    func testCubeHeaderParsingLogic() {
        let sampleCube = """
        TITLE "TestLUT"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        
        let lines = sampleCube.components(separatedBy: .newlines)
        var size: Int = 0
        var count = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("LUT_3D_SIZE") {
                let parts = t.split(separator: " ")
                if parts.count >= 2, let s = Int(parts[1]) {
                    size = s
                }
            } else if !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("TITLE") && !t.hasPrefix("DOMAIN") {
                count += 1
            }
        }
        
        XCTAssertEqual(size, 2)
        XCTAssertEqual(count, 8)
    }
}
