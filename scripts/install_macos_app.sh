#!/bin/zsh
set -euo pipefail

APP_NAME="BZPlayer.app"
APP_DIR="/Applications/${APP_NAME}"
BIN_SOURCE="/Users/x/code/bzplayer-main/macos/BZPlayer/.build/arm64-apple-macosx/release/BZPlayer"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

pkill -x BZPlayer || true
sleep 1
pkill -9 -x BZPlayer || true

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"

/bin/cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>视频文件</string>
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
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cp "${BIN_SOURCE}" "${APP_DIR}/Contents/MacOS/BZPlayer"
chmod +x "${APP_DIR}/Contents/MacOS/BZPlayer"

"${LSREGISTER}" -f "${APP_DIR}" >/dev/null
killall cfprefsd >/dev/null 2>&1 || true
killall lsd >/dev/null 2>&1 || true
open -a "${APP_DIR}"
