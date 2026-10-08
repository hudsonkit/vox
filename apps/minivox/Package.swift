// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Minivox",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "../../swift")
    ],
    targets: [
        .target(
            name: "MinivoxSupport"
        ),
        .executableTarget(
            name: "Minivox",
            dependencies: [
                "MinivoxSupport",
                .product(name: "VoxCore", package: "swift"),
                .product(name: "VoxEngine", package: "swift"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MinivoxCommand",
            dependencies: ["MinivoxSupport"]
        ),
        .testTarget(
            name: "MinivoxSupportTests",
            dependencies: ["MinivoxSupport"]
        )
    ]
)
