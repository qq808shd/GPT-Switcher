// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPTSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GPTSwitcherCore", targets: ["GPTSwitcherCore"]),
        .executable(name: "GPTSwitcher", targets: ["GPTSwitcherApp"]),
        .executable(name: "gpt-switcher", targets: ["GPTSwitcherCLI"]),
    ],
    targets: [
        .target(name: "GPTSwitcherCore"),
        .executableTarget(
            name: "GPTSwitcherApp",
            dependencies: ["GPTSwitcherCore"]
        ),
        .executableTarget(
            name: "GPTSwitcherCLI",
            dependencies: ["GPTSwitcherCore"]
        ),
        .testTarget(
            name: "GPTSwitcherCoreTests",
            dependencies: ["GPTSwitcherCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
