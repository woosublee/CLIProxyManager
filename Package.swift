// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CLIProxyManager",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "CLIProxyManager", targets: ["CLIProxyManagerApp"]),
        .executable(name: "cliproxy-manager", targets: ["CLIProxyManagerCLI"]),
        .executable(name: "cpm", targets: ["CPMCLI"]),
        .library(name: "CLIProxyManagerCore", targets: ["CLIProxyManagerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
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
            dependencies: [
                "CLIProxyManagerCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CLIProxyManagerApp",
            resources: [
                .copy("Resources/cliproxyapi"),
                .copy("Resources/Licenses"),
                .copy("Resources/ProviderImages")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerCLI",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerCLI"
        ),
        .executableTarget(
            name: "CPMCLI",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CPMCLI"
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
