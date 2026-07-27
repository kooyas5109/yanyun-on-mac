// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "YanyunSimulator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SimulatorCore", targets: ["SimulatorCore"]),
    ],
    targets: [
        .target(
            name: "SimulatorCore",
            path: "app/SimulatorCore"
        ),
        .testTarget(
            name: "SimulatorCoreTests",
            dependencies: ["SimulatorCore"],
            path: "Tests/SimulatorCoreTests"
        ),
    ]
)
