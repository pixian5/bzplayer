// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BZPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BZPlayerCore", targets: ["BZPlayerCore"]),
        .executable(name: "BZPlayer", targets: ["BZPlayerApp"])
    ],
    dependencies: [
        // VLCKit 4.0.0-alpha.20 (VideoLAN 4.0.0a20). Remote SPM zip is ~821MB and often
        // times out; use a local path package. Run scripts/fetch_vlckit.sh if missing.
        .package(path: "../Vendor/vlckit-spm")
    ],
    targets: [
        .target(
            name: "BZPlayerCore",
            path: "Sources/BZPlayerCore"
        ),
        .executableTarget(
            name: "BZPlayerApp",
            dependencies: [
                "BZPlayerCore",
                .product(name: "VLCKitSPM", package: "vlckit-spm")
            ],
            path: "Sources/BZPlayerApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "BZPlayerTests",
            dependencies: ["BZPlayerCore"],
            path: "Tests/BZPlayerTests"
        )
    ]
)
