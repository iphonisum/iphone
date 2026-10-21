// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iPhoneCinemaCamera",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "iPhoneCinemaCamera",
            targets: ["iPhoneCinemaCamera"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "iPhoneCinemaCamera",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("MetalShaderPipeline/Shaders"),
                .copy("Bundles")
            ]
        ),
        .testTarget(
            name: "iPhoneCinemaCameraTests",
            dependencies: ["iPhoneCinemaCamera"],
            path: "Tests"
        )
    ]
)
