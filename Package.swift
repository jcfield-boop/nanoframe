// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nanoframe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Nanoframe",
            path: "Sources/Nanoframe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProtocolTests",
            path: "Sources/ProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
