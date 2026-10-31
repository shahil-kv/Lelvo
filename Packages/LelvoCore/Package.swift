// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LelvoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LelvoCore", targets: ["LelvoCore"])
    ],
    targets: [
        // The Argon2 reference implementation, unchanged (Sources/CArgon2/README.md): Argon2id for the passphrase.
        .target(name: "CArgon2", exclude: ["LICENSE", "README.md"],
                cSettings: [.define("ARGON2_NO_THREADS"), .headerSearchPath(".")]),
        .target(name: "LelvoCore", dependencies: ["CArgon2"]),
        .testTarget(name: "LelvoCoreTests", dependencies: ["LelvoCore"])
    ]
)
