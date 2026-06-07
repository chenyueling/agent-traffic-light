// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentTrafficLight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentTrafficLight", targets: ["AgentTrafficLight"])
    ],
    targets: [
        .executableTarget(
            name: "AgentTrafficLight",
            path: "Sources/AgentTrafficLight"
        )
    ]
)
