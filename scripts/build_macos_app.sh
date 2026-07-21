#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法: $0 <输出.app路径> <版本号> <SwiftPM构建目录>" >&2
    exit 2
fi

APP_DIR="$1"
VERSION="$2"
BUILD_DIR="$3"
REPO_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_DIR="${REPO_DIR}/macos/BZPlayer"

BIN_SOURCE="${BUILD_DIR}/BZPlayer"
[[ -x "${BIN_SOURCE}" ]]
[[ -d "${BUILD_DIR}/VLCKit.framework" ]]
[[ -d "${BUILD_DIR}/BZPlayer_BZPlayerApp.bundle" ]]

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>BZPlayer</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>媒体文件</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.audio</string>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>com.apple.m4v-video</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>org.webmproject.webm</string>
                <string>public.mpeg</string>
                <string>public.mpeg-2-transport-stream</string>
                <string>com.microsoft.windows-media-wmv</string>
                <string>com.adobe.flash.video</string>
            </array>
        </dict>
    </array>
    <key>CFBundleExecutable</key>
    <string>BZPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>tech.sbbz.bzplayer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BZPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
</dict>
</plist>
EOF

cp "${BIN_SOURCE}" "${APP_DIR}/Contents/MacOS/BZPlayer"
chmod +x "${APP_DIR}/Contents/MacOS/BZPlayer"
cp -R "${BUILD_DIR}/VLCKit.framework" "${APP_DIR}/Contents/Frameworks/"
cp -R "${BUILD_DIR}/BZPlayer_BZPlayerApp.bundle" "${APP_DIR}/"
if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# SPM links VLCKit as @rpath; the binary only has @loader_path by default, so
# dyld looks next to MacOS/ not Contents/Frameworks/. Add the app-bundle rpath.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_DIR}/Contents/MacOS/BZPlayer" 2>/dev/null || true
# If rpath already exists (re-packaging), -add_rpath fails; ensure presence:
if ! otool -l "${APP_DIR}/Contents/MacOS/BZPlayer" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${APP_DIR}/Contents/MacOS/BZPlayer"
fi

plutil -lint "${APP_DIR}/Contents/Info.plist"
