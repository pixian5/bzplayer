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
    targets: [
        .executableTarget(
            name: "BZPlayerApp",
            path: "Sources/BZPlayerApp"
        )
    ]
)
