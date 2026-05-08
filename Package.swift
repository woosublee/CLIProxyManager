// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CLIProxyManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CLIProxyManager", targets: ["CLIProxyManagerApp"]),
        .executable(name: "cliproxy-manager", targets: ["CLIProxyManagerCLI"]),
        .library(name: "CLIProxyManagerCore", targets: ["CLIProxyManagerCore"])
    ],
    targets: [
        .target(
            name: "CLIProxyManagerCore",
            dependencies: [],
            path: "Sources/CLIProxyManagerCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerApp",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerApp",
            resources: [
                .copy("Resources/cliproxyapi"),
                .copy("Resources/Licenses")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerCLI",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerCLI"
        ),
        .testTarget(
            name: "CLIProxyManagerCoreTests",
            dependencies: ["CLIProxyManagerCore"],
            path: "Tests/CLIProxyManagerCoreTests"
        ),
        .testTarget(
            name: "CLIProxyManagerAppTests",
            dependencies: ["CLIProxyManagerApp"],
            path: "Tests/CLIProxyManagerAppTests"
        )
    ]
)
