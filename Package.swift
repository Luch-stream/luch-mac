// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Luch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "luch", targets: ["luch"]),
        .executable(name: "LuchApp", targets: ["LuchApp"]),
        .executable(name: "luchctl", targets: ["luchctl"]),
        .library(name: "LuchEngine", targets: ["LuchEngine"]),
    ],
    targets: [
        .systemLibrary(name: "COpus", path: "Sources/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .target(name: "LuchProto", path: "Sources/LuchProto"),
        .target(name: "LuchNet", dependencies: ["LuchProto"], path: "Sources/LuchNet"),
        .target(name: "LuchMedia", dependencies: ["LuchProto", "COpus"], path: "Sources/LuchMedia"),
        .target(name: "LuchEngine", dependencies: ["LuchProto", "LuchNet", "LuchMedia"], path: "Sources/LuchEngine"),
        .target(name: "LuchLocal", dependencies: ["LuchProto"], path: "Sources/LuchLocal"),
        .executableTarget(name: "luch", dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine"], path: "Sources/luch"),
        .executableTarget(name: "LuchApp", dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine", "LuchLocal"], path: "Sources/LuchApp"),
        .executableTarget(name: "luchctl", dependencies: ["LuchLocal"], path: "Sources/luchctl"),
        .testTarget(name: "LuchTests", dependencies: ["LuchProto", "LuchNet", "LuchMedia", "LuchEngine"], path: "Tests/LuchTests"),
    ]
)
