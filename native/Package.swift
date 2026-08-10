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
            swiftSettings: [.swiftLanguageMode(.v5)],
            // CLI binaries have no bundle; macOS TCC aborts them on mic/speech
            // access unless usage descriptions are embedded as an __info_plist
            // linker section.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/pb-record-Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "pb-replay",
            dependencies: ["PlaybookKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
