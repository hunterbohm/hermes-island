// swift-tools-version: 6.2
import PackageDescription

// Rules and seams that need no hardware and no models. FluidAudio is not a dependency, so importing it here
// fails the build, and scripts/test.sh never compiles it.
let package = Package(
    name: "IslandCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "IslandCore", targets: ["IslandCore"])],
    targets: [
        .target(name: "IslandCore"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
