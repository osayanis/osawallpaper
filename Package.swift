// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsaWallpaper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Place des fenêtres au-dessus de tout, écran verrouillé compris (même technique qu'OsaNotch).
        .package(url: "https://github.com/Lakr233/SkyLightWindow", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "OsaWallpaper",
            dependencies: ["SkyLightWindow"],
            path: "Sources/OsaWallpaper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
