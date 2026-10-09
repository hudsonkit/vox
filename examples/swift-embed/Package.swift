// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxEmbedDemo",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // In your own app: .package(path: "../vox/swift")
        .package(path: "../../swift")
    ],
    targets: [
        .executableTarget(
            name: "vox-embed-demo",
            dependencies: [
                .product(name: "VoxCore", package: "swift"),
                .product(name: "VoxEngine", package: "swift"),
            ],
            path: "Sources/VoxEmbedDemo"
        )
    ]
)
