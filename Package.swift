// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "minutes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "minutes", targets: ["Minutes"]),
        .executable(name: "minutes-cli", targets: ["MinutesCLI"]),
        .executable(name: "minutes-checks", targets: ["MinutesChecks"]),
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "Minutes",
            dependencies: ["MinutesCore"]
        ),
        .executableTarget(
            name: "MinutesCLI",
            dependencies: ["MinutesCore"]
        ),
        // The checks are an executable rather than an XCTest target on
        // purpose: XCTest ships with Xcode, and this project has to build and
        // verify with the Command Line Tools alone.
        .executableTarget(
            name: "MinutesChecks",
            dependencies: ["MinutesCore"]
        ),
    ]
)
