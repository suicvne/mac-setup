// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSetup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacSetupApp", targets: ["MacSetupApp"])
    ],
    targets: [
        .executableTarget(
            name: "MacSetupApp",
            path: "Sources/MacSetupApp",
            resources: [
                .copy("Resources/catalog.json"),
                .process("Resources/Assets.xcassets")
            ]
        )
    ]
)
