// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "Sfera", path: "..")],
    targets: [
        .target(name: "LegacyCore", path: ".legacy/Sources/SpatialCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Bench",
            dependencies: ["LegacyCore", .product(name: "SferaCore", package: "Sfera")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
