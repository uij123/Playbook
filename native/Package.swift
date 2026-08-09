// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "playbooks-native",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PlaybookKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pb-record",
            dependencies: ["PlaybookKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pb-replay",
            dependencies: ["PlaybookKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
