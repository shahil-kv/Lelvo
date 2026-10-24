// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemvoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MemvoCore", targets: ["MemvoCore"])
    ],
    targets: [
        .target(name: "MemvoCore"),
        .testTarget(name: "MemvoCoreTests", dependencies: ["MemvoCore"])
    ]
)
