// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppleReadoutExample",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AppleReadoutExample", targets: ["AppleReadoutExample"])],
    dependencies: [.package(name: "Vox", path: "../..")],
    targets: [.target(name: "AppleReadoutExample", dependencies: [
        .product(name: "VoxCore", package: "Vox"),
        .product(name: "VoxEngine", package: "Vox"),
        .product(name: "VoxAppleSpeech", package: "Vox"),
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)
