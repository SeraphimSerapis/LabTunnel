// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LabTunnel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LabTunnel", targets: ["LabTunnel"]),
        // Not named "labtunnel": that differs from "LabTunnel" only by case, and the two
        // binaries would overwrite each other on a case-insensitive volume. The build script
        // installs it as Contents/Helpers/labtunnel inside the app bundle.
        .executable(name: "labtunnel-cli", targets: ["LabTunnelCLI"]),
    ],
    targets: [
        /// Wire protocol, socket helpers and agent setup shared by the app and the CLI.
        .target(name: "LabTunnelControl"),
        .executableTarget(name: "LabTunnel", dependencies: ["LabTunnelControl"]),
        .executableTarget(name: "LabTunnelCLI", dependencies: ["LabTunnelControl"]),
        .testTarget(name: "LabTunnelTests", dependencies: ["LabTunnel", "LabTunnelCLI", "LabTunnelControl"]),
    ]
)
