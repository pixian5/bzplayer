#!/bin/zsh
set -euo pipefail

# 用法: zsh scripts/install_macos_app.sh ["commit 消息"]
# 示例: zsh scripts/install_macos_app.sh "修复播放卡顿"   # 带 commit
# 示例: zsh scripts/install_macos_app.sh                 # 仅构建部署
COMMIT_MSG="${1:-}"

APP_NAME="BZPlayer.app"
APP_DIR="/Applications/${APP_NAME}"
BIN_SOURCE="/Users/x/code/bzplayer-main/macos/BZPlayer/.build/arm64-apple-macosx/release/BZPlayer"
PROJECT_DIR="/Users/x/code/bzplayer-main/macos/BZPlayer"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
VERSION_FILE="/Users/x/code/bzplayer-main/macos/BZPlayer/.deploy_version"

if [[ -f "${VERSION_FILE}" ]]; then
    CURRENT_VERSION=$(tr -cd '0-9' < "${VERSION_FILE}")
else
    CURRENT_VERSION=""
fi

if [[ -z "${CURRENT_VERSION}" ]]; then
    CURRENT_VERSION=0
fi

NEXT_VERSION=$((CURRENT_VERSION + 1))
echo "${NEXT_VERSION}" > "${VERSION_FILE}"
echo "[deploy] BZPlayer version: ${NEXT_VERSION}"

echo "[deploy] Removing old app..."
rm -rf "${APP_DIR}"

echo "[deploy] Building release binary..."
cd "${PROJECT_DIR}"
swift build -c release

echo "[deploy] Stopping old process..."
pkill -x BZPlayer || true
sleep 0.5
pkill -9 -x BZPlayer || true
mkdir -p "${APP_DIR}/Contents/MacOS"

/bin/cat > "${APP_DIR}/Contents/Info.plist" <<EOF
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
    <string>${NEXT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${NEXT_VERSION}</string>
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

echo "[deploy] Copying resources..."
mkdir -p "${APP_DIR}/Contents/Resources"
if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cp "${BIN_SOURCE}" "${APP_DIR}/Contents/MacOS/BZPlayer"
chmod +x "${APP_DIR}/Contents/MacOS/BZPlayer"

echo "[deploy] Copying VLCKit.framework..."
mkdir -p "${APP_DIR}/Contents/Frameworks"
cp -R "${PROJECT_DIR}/.build/arm64-apple-macosx/release/VLCKit.framework" "${APP_DIR}/Contents/Frameworks/"

"${LSREGISTER}" -f "${APP_DIR}" >/dev/null
killall cfprefsd >/dev/null 2>&1 || true
killall lsd >/dev/null 2>&1 || true
open -a "${APP_DIR}"

if [[ -n "${COMMIT_MSG}" ]]; then
    echo "[deploy] Committing and pushing..."
    cd /Users/x/code/bzplayer-main
    git add -A
    git commit -m "${COMMIT_MSG}"
    git push origin main
fi

echo "[deploy] Done!"
