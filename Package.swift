// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsaWallpaper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OsaWallpaper",
            path: "Sources/OsaWallpaper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
