// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftPi",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PiAI", targets: ["PiAI"]),
        .library(name: "PiAgent", targets: ["PiAgent"]),
        .library(name: "PiTools", targets: ["PiTools"]),
        .library(name: "PiJavaScript", targets: ["PiJavaScript"]),
    ],
    targets: [
        // Messages, models, the event stream, transcript helpers and provider APIs.
        .target(name: "PiAI"),
        // The agent loop and the stateful Agent.
        .target(name: "PiAgent", dependencies: ["PiAI"]),
        // Tools that work on files in a workspace directory.
        .target(name: "PiTools", dependencies: ["PiAI", "PiAgent"]),
        // The javascript tool, which runs code in WebKit.
        .target(name: "PiJavaScript", dependencies: ["PiAI", "PiAgent", "PiTools"]),
        .testTarget(name: "PiAITests", dependencies: ["PiAI"]),
        .testTarget(name: "PiAgentTests", dependencies: ["PiAI", "PiAgent"]),
        .testTarget(name: "PiToolsTests", dependencies: ["PiAI", "PiAgent", "PiTools"]),
        .testTarget(name: "PiJavaScriptTests", dependencies: ["PiAI", "PiAgent", "PiTools", "PiJavaScript"]),
    ]
)
