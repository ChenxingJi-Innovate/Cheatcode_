// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "CheatcodeInstaller", platforms: [.macOS(.v13)], products: [
    .library(name: "InstallerCore", targets: ["InstallerCore"]),
    .executable(name: "CheatcodeInstaller", targets: ["CheatcodeInstaller"])
], targets: [
    .target(name: "InstallerCore", resources: [.copy("Resources/targets.json"), .copy("Resources/mcp_clients.json")]),
    .executableTarget(name: "CheatcodeInstaller", dependencies: ["InstallerCore"]),
    .executableTarget(name: "NativeCoreTests", dependencies: ["InstallerCore"], path: "Tests/InstallerCoreTests", exclude: ["Fixtures", "transport_fixture.py"]),
    .testTarget(name: "InstallerCoreTests", dependencies: ["InstallerCore", "NativeCoreTests"], path: "Tests/SwiftPMTests")
])
