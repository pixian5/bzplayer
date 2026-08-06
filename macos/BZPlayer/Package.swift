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
        // SwiftPM packages the macOS slice of VLCKit through this local wrapper rather than
        // a remote binaryTarget. The locked archive is about 821 MB and repeatedly times out
        // in both local and CI resolution. The directory name (vlckit-spm) is the package
        // identity used below; run scripts/fetch_vlckit.sh before the first build.
        // The active binary version and upgrade procedure are documented in
        // docs/VLC4_MAINTENANCE.md.
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
