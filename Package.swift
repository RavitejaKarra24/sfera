// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sfera",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sfera", targets: ["Sfera"]),
        .library(name: "SferaCore", targets: ["SferaCore"]),
    ],
    targets: [
        .target(name: "SferaCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Sfera",
            dependencies: ["SferaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
