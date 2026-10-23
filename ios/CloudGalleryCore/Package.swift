// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudGalleryCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CloudGalleryCore", targets: ["CloudGalleryCore"])
    ],
    targets: [
        .target(name: "CloudGalleryCore"),
        .testTarget(name: "CloudGalleryCoreTests", dependencies: ["CloudGalleryCore"])
    ]
)
