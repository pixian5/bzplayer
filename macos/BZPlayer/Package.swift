// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BZPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BZPlayer", targets: ["BZPlayerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/tylerjonesio/vlckit-spm/", .upToNextMajor(from: "3.5.1"))
    ],
    targets: [
        .executableTarget(
            name: "BZPlayerApp",
            dependencies: [
                .product(name: "VLCKitSPM", package: "vlckit-spm")
            ],
            path: "Sources/BZPlayerApp",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
