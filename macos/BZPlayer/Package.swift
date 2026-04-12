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
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv"
        ),
        .executableTarget(
            name: "BZPlayerApp",
            dependencies: ["CMpv"],
            path: "Sources/BZPlayerApp",
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib"
                ])
            ]
        )
    ]
)
