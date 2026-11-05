// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "Sfera", path: "..")],
    targets: [
        // Sfera 0.9, extracted from git by run.sh.
        .target(name: "LegacyCore", path: ".legacy/Sources/SpatialCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Sfera 1.0 "Classic", frozen at CLASSIC_COMMIT in run.sh. The reference sound.
        .target(name: "ClassicCore", path: ".classic/Sources/SferaCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Bench",
            dependencies: ["LegacyCore", "ClassicCore", .product(name: "SferaCore", package: "Sfera")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
