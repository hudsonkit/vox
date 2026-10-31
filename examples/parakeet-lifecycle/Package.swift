// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParakeetLifecycleExample",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ParakeetLifecycleExample", targets: ["ParakeetLifecycleExample"])],
    dependencies: [.package(name: "Vox", path: "../..")],
    targets: [.target(name: "ParakeetLifecycleExample", dependencies: [
        .product(name: "VoxCore", package: "Vox"),
        .product(name: "VoxEngine", package: "Vox"),
    ])]
)
