// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sfera",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sfera", targets: ["Sfera"]),
        .library(name: "SpatialCore", targets: ["SpatialCore"]),
    ],
    targets: [
        .target(
            name: "SpatialCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Sfera",
            dependencies: ["SpatialCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpatialCoreTests",
            dependencies: ["SpatialCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
