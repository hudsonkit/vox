// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DevHostClient", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "vox", path: "../..")],
    targets: [.executableTarget(name: "DevHostClient", dependencies: [.product(name: "VoxClient", package: "vox")])])
