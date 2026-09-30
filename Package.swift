// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AISecretaryAlarm",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SecretaryApp", targets: ["SecretaryApp"]),
        .library(name: "SecretaryCore", targets: ["SecretaryCore"]),
    ],
    targets: [
        // Pure domain logic: no AppKit, all I/O behind protocols.
        .target(name: "SecretaryCore"),
        // Menu bar app and macOS service adapters.
        .executableTarget(
            name: "SecretaryApp",
            dependencies: ["SecretaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SecretaryCoreTests", dependencies: ["SecretaryCore"]),
    ]
)
