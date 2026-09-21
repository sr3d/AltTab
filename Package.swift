// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AltTab",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AltTabCore"),
        .executableTarget(name: "AltTab", dependencies: ["AltTabCore"]),
        .executableTarget(name: "FocusSpike", dependencies: ["AltTabCore"]),
    ]
)
