// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LogicPluginSweeper",
    defaultLocalization: "fr",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LogicPluginSweeper", targets: ["LogicPluginSweeper"]),
        .library(name: "LogicPluginSweeperCore", targets: ["LogicPluginSweeperCore"])
    ],
    targets: [
        .executableTarget(name: "LogicPluginSweeper", dependencies: ["LogicPluginSweeperCore"], resources: [.process("Resources")]),
        .target(name: "LogicPluginSweeperCore"),
        .testTarget(name: "LogicPluginSweeperCoreTests", dependencies: ["LogicPluginSweeperCore"])
    ]
)
