#!/bin/zsh
set -euo pipefail

# Download and extract VLCKit 4.0.0-alpha.20 into macos/Vendor/vlckit-spm.
# Remote binary is ~821MB; SwiftPM remote binaryTarget often times out, so BZPlayer
# depends on a local path package instead.

REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
VENDOR_DIR="${REPO_DIR}/macos/Vendor/vlckit-spm"
ZIP_URL="https://github.com/virtualox/vlckit-spm/releases/download/4.0.0-alpha.20/VLCKit.xcframework.zip"
EXPECTED_SHA="c94b6f556f58a471a3c2edacb242506587d6c01cc4874f96d7665bcfa0666ecc"
CACHE_ZIP="${TMPDIR:-/tmp}/VLCKit-4.0.0-alpha.20.xcframework.zip"

if [[ -d "${VENDOR_DIR}/VLCKit.xcframework" ]]; then
    echo "[fetch_vlckit] Already present: ${VENDOR_DIR}/VLCKit.xcframework"
    exit 0
fi

mkdir -p "${VENDOR_DIR}/Sources/VLCKitSPM"

if [[ ! -f "${VENDOR_DIR}/Package.swift" ]]; then
    cat > "${VENDOR_DIR}/Package.swift" <<'EOF'
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
EOF
fi

if [[ ! -f "${VENDOR_DIR}/Sources/VLCKitSPM/VLCKitSPM.swift" ]]; then
    cat > "${VENDOR_DIR}/Sources/VLCKitSPM/VLCKitSPM.swift" <<'EOF'
// Re-exports VLCKit for Swift Package Manager usage
@_exported import VLCKit
EOF
fi

if [[ -f /tmp/vlckit4-binary/VLCKit.xcframework.zip ]]; then
    CACHE_ZIP="/tmp/vlckit4-binary/VLCKit.xcframework.zip"
fi

need_download=1
if [[ -f "${CACHE_ZIP}" ]]; then
    actual="$(shasum -a 256 "${CACHE_ZIP}" | awk '{print $1}')"
    if [[ "${actual}" == "${EXPECTED_SHA}" ]]; then
        need_download=0
        echo "[fetch_vlckit] Using cached zip: ${CACHE_ZIP}"
    else
        echo "[fetch_vlckit] Cached zip checksum mismatch, re-downloading"
    fi
fi

if [[ "${need_download}" -eq 1 ]]; then
    echo "[fetch_vlckit] Downloading ${ZIP_URL}"
    curl -L --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 60 -C - \
        -o "${CACHE_ZIP}" "${ZIP_URL}"
    actual="$(shasum -a 256 "${CACHE_ZIP}" | awk '{print $1}')"
    if [[ "${actual}" != "${EXPECTED_SHA}" ]]; then
        echo "[fetch_vlckit] Checksum mismatch: expected ${EXPECTED_SHA}, got ${actual}" >&2
        exit 1
    fi
fi

echo "[fetch_vlckit] Extracting to ${VENDOR_DIR}"
ditto -x -k "${CACHE_ZIP}" "${VENDOR_DIR}"
# Strip accidental AppleDouble metadata if present
rm -rf "${VENDOR_DIR}/__MACOSX"

if [[ ! -d "${VENDOR_DIR}/VLCKit.xcframework" ]]; then
    echo "[fetch_vlckit] Extraction failed: VLCKit.xcframework missing" >&2
    exit 1
fi

echo "[fetch_vlckit] Done."
