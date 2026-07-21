// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VLCKitSPM",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "VLCKitSPM", targets: ["VLCKitSPM"])
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: "VLCKit.xcframework"
        ),
        .target(
            name: "VLCKitSPM",
            dependencies: [.target(name: "VLCKit")],
            linkerSettings: [
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("CoreText", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("Security", .when(platforms: [.iOS])),
                .linkedFramework("CFNetwork", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("OpenGLES", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.iOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.iOS, .tvOS])),
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedLibrary("c++", .when(platforms: [.iOS, .tvOS, .macOS])),
                .linkedLibrary("xml2", .when(platforms: [.iOS, .tvOS, .macOS])),
                .linkedLibrary("z", .when(platforms: [.iOS, .tvOS, .macOS])),
                .linkedLibrary("bz2", .when(platforms: [.iOS, .tvOS, .macOS])),
                .linkedLibrary("iconv")
            ]
        )
    ]
)
