// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keybridge",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "HIDPP",
            path: "Sources/HIDPP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Keybridge",
            dependencies: ["HIDPP"],
            path: "Sources/Keybridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
