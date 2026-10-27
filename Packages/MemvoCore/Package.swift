// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemvoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MemvoCore", targets: ["MemvoCore"])
    ],
    targets: [
        // The Argon2 reference implementation, unchanged (Sources/CArgon2/README.md): Argon2id for the passphrase.
        .target(name: "CArgon2", exclude: ["LICENSE", "README.md"],
                cSettings: [.define("ARGON2_NO_THREADS"), .headerSearchPath(".")]),
        .target(name: "MemvoCore", dependencies: ["CArgon2"]),
        .testTarget(name: "MemvoCoreTests", dependencies: ["MemvoCore"])
    ]
)
