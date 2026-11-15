// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MXControl",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "HIDPP",
            path: "Sources/HIDPP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MXControl",
            dependencies: ["HIDPP"],
            path: "Sources/MXControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
