// swift-tools-version:6.0
import PackageDescription

// Everything is Swift 6 now: the core modules check data crossing threads, and the AppKit layer
// reaches the main actor explicitly instead of relying on a language mode that does not check it.
let uiMode: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Luch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "luch", targets: ["luch"]),
        .executable(name: "LuchApp", targets: ["LuchApp"]),
        .executable(name: "luchctl", targets: ["luchctl"]),
        .executable(name: "LuchViewer", targets: ["LuchViewer"]),
        .library(name: "LuchEngine", targets: ["LuchEngine"]),
        .library(name: "LuchReceive", targets: ["LuchReceive"]),
        .library(name: "LuchAudio", targets: ["LuchAudio"]),
    ],
    targets: [
        .systemLibrary(name: "COpus", path: "Sources/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .target(name: "LuchProto", path: "Sources/LuchProto"),
        .target(name: "LuchNet", dependencies: ["LuchProto"], path: "Sources/LuchNet"),
        .target(name: "LuchMedia", dependencies: ["LuchProto", "COpus"], path: "Sources/LuchMedia"),
        .target(
            name: "LuchEngine", dependencies: ["LuchProto", "LuchNet", "LuchMedia"],
            path: "Sources/LuchEngine"),
        .target(name: "LuchLocal", dependencies: ["LuchProto"], path: "Sources/LuchLocal"),
        .target(name: "LuchReceive", dependencies: ["LuchProto"], path: "Sources/LuchReceive"),
        .target(
            name: "LuchAudio", dependencies: ["LuchProto", "LuchReceive", "COpus"], path: "Sources/LuchAudio"),
        .executableTarget(
            name: "luch", dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine"],
            path: "Sources/luch",
            swiftSettings: uiMode),
        .executableTarget(
            name: "LuchApp",
            dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine", "LuchLocal"],
            path: "Sources/LuchApp",
            swiftSettings: uiMode),
        .executableTarget(
            name: "luchctl", dependencies: ["LuchLocal"], path: "Sources/luchctl", swiftSettings: uiMode),
        .executableTarget(
            name: "LuchViewer", dependencies: ["LuchProto", "LuchReceive", "LuchAudio"],
            path: "Sources/LuchViewer",
            swiftSettings: uiMode),
        .testTarget(
            name: "LuchTests", dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine"],
            path: "Tests/LuchTests"),
    ]
)
