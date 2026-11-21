// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HermesIsland",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "IslandCore"),
        .package(path: "Vendor/FluidAudio", traits: ["TTS"]),
    ],
    targets: [
        .executableTarget(
            name: "HermesIsland",
            dependencies: ["CatchException", "IslandCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .target(name: "CatchException"),
    ]
)
