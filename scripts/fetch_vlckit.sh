#!/bin/zsh
set -euo pipefail

# Download and extract the locked VLCKit 4.0.0-alpha.21 archive into the local SwiftPM
# wrapper at macos/Vendor/vlckit-spm. The extracted XCFramework is intentionally ignored by
# Git: it is about 2.6 GB, while the remote archive is about 861 MB. Using a path package
# keeps SwiftPM from downloading that archive during dependency resolution, which is prone to
# timing out on both developer machines and GitHub-hosted macOS runners.
#
# Keep VLCKIT_VERSION, ZIP_URL, EXPECTED_SHA and EXPECTED_SIZE in sync when upgrading. See
# docs/VLC4_MAINTENANCE.md for the complete upgrade and regression procedure.

REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
VENDOR_DIR="${REPO_DIR}/macos/Vendor/vlckit-spm"
VLCKIT_VERSION="4.0.0-alpha.21"
ZIP_URL="https://github.com/virtualox/vlckit-spm/releases/download/${VLCKIT_VERSION}/VLCKit.xcframework.zip"
EXPECTED_SHA="2dc35b65bb9efc4ef792737af026c33053f3ea6d89244e7e8aa46ab57a0e9b8e"
EXPECTED_SIZE="861112270"
LOCK_FILE="${VENDOR_DIR}/VLCKIT.lock"
CACHE_DIR="${VENDOR_DIR}/.cache"
CACHE_ZIP="${CACHE_DIR}/VLCKit-${VLCKIT_VERSION}.xcframework.zip"

expected_lock() {
    cat <<EOF
version=${VLCKIT_VERSION}
url=${ZIP_URL}
archive_sha256=${EXPECTED_SHA}
archive_size=${EXPECTED_SIZE}
EOF
}

if [[ -d "${VENDOR_DIR}/VLCKit.xcframework" ]]; then
    # Avoid hashing the 2.6 GB extracted framework on every normal build. The small lock file
    # records the exact archive used to create the current framework; if it differs, the caller
    # must replace the ignored binary directory before continuing.
    if [[ -f "${LOCK_FILE}" ]] && diff -q <(expected_lock) "${LOCK_FILE}" >/dev/null; then
        echo "[fetch_vlckit] Already present: ${VENDOR_DIR}/VLCKit.xcframework (${VLCKIT_VERSION})"
        exit 0
    fi
    echo "[fetch_vlckit] Existing VLCKit.xcframework does not match ${VLCKIT_VERSION}." >&2
    echo "[fetch_vlckit] Move or remove ${VENDOR_DIR}/VLCKit.xcframework, then re-run this script." >&2
    exit 1
fi

mkdir -p "${VENDOR_DIR}/Sources/VLCKitSPM" "${CACHE_DIR}"

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

need_download=1
if [[ -f "${CACHE_ZIP}" ]]; then
    actual="$(shasum -a 256 "${CACHE_ZIP}" | awk '{print $1}')"
    size="$(stat -f '%z' "${CACHE_ZIP}")"
    if [[ "${actual}" == "${EXPECTED_SHA}" && "${size}" == "${EXPECTED_SIZE}" ]]; then
        need_download=0
        echo "[fetch_vlckit] Using cached zip: ${CACHE_ZIP}"
    else
        echo "[fetch_vlckit] Cached zip mismatch, re-downloading"
    fi
fi

if [[ "${need_download}" -eq 1 ]]; then
    echo "[fetch_vlckit] Downloading ${ZIP_URL}"
    download_zip="${CACHE_ZIP}.download"
    curl -L --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 60 \
        -o "${download_zip}" "${ZIP_URL}"
    actual="$(shasum -a 256 "${download_zip}" | awk '{print $1}')"
    size="$(stat -f '%z' "${download_zip}")"
    if [[ "${actual}" != "${EXPECTED_SHA}" || "${size}" != "${EXPECTED_SIZE}" ]]; then
        echo "[fetch_vlckit] Archive mismatch: expected ${EXPECTED_SHA}/${EXPECTED_SIZE}, got ${actual}/${size}" >&2
        exit 1
    fi
    mv "${download_zip}" "${CACHE_ZIP}"
fi

echo "[fetch_vlckit] Extracting to ${VENDOR_DIR}"
ditto -x -k "${CACHE_ZIP}" "${VENDOR_DIR}"
# Strip accidental AppleDouble metadata if present
rm -rf "${VENDOR_DIR}/__MACOSX"

if [[ ! -d "${VENDOR_DIR}/VLCKit.xcframework" ]]; then
    echo "[fetch_vlckit] Extraction failed: VLCKit.xcframework missing" >&2
    exit 1
fi

expected_lock > "${LOCK_FILE}"
echo "[fetch_vlckit] Done."
