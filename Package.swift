// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nanoframe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nanoframe",
            path: "Sources/Nanoframe"
        ),
        .executableTarget(
            name: "ProtocolTests",
            path: "Sources/ProtocolTests"
        )
    ]
)
