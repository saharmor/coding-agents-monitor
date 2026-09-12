// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UsageMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "UsageMonitor", targets: ["UsageMonitor"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "UsageMonitor",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            exclude: ["Fixtures"]
        )
    ]
)
