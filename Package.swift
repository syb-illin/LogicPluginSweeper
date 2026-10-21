// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LogicPluginSweeper",
    defaultLocalization: "fr",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LogicPluginSweeper", targets: ["LogicPluginSweeper"]),
        .executable(name: "LogicPluginSweeperUninstaller", targets: ["LogicPluginSweeperUninstaller"]),
        .library(name: "LogicPluginSweeperCore", targets: ["LogicPluginSweeperCore"])
    ],
    targets: [
        .executableTarget(name: "LogicPluginSweeper", dependencies: ["LogicPluginSweeperCore"], resources: [.process("Resources")]),
        .executableTarget(name: "LogicPluginSweeperUninstaller", dependencies: ["LogicPluginSweeperCore"]),
        .target(name: "LogicPluginSweeperCore"),
        .testTarget(name: "LogicPluginSweeperCoreTests", dependencies: ["LogicPluginSweeperCore"])
    ]
)
