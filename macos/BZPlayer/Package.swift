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
        .package(url: "https://github.com/tylerjonesio/vlckit-spm/", .upToNextMajor(from: "3.5.1"))
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
