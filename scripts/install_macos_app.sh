#!/bin/zsh
set -euo pipefail

# 用法: zsh scripts/install_macos_app.sh [--commit "中文 commit 消息"]
COMMIT_MSG=""
if [[ "${1:-}" == "--commit" ]]; then
    COMMIT_MSG="${2:-}"
    if [[ -z "${COMMIT_MSG}" ]]; then
        echo "--commit 后必须提供 commit 消息" >&2
        exit 2
    fi
elif [[ $# -gt 0 ]]; then
    echo "仅支持显式的 --commit \"消息\" 参数" >&2
    exit 2
fi

APP_NAME="BZPlayer.app"
APP_DIR="/Applications/${APP_NAME}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${REPO_DIR}/macos/BZPlayer"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "${REPO_DIR}"
# 获取最新的 Git tag 并提取数字作为版本号
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0")
VERSION_NUM=${LATEST_TAG#v}
if [[ -z "$VERSION_NUM" ]]; then
    VERSION_NUM="0"
fi
NEXT_VERSION="${VERSION_NUM}"
echo "[deploy] BZPlayer version from Git: ${NEXT_VERSION}"

echo "[deploy] Ensuring VLCKit is present..."
zsh "${SCRIPT_DIR}/fetch_vlckit.sh"

echo "[deploy] Building release binary..."
cd "${PROJECT_DIR}"
BUILD_DIR=$(swift build -c release --show-bin-path)
BIN_SOURCE="${BUILD_DIR}/BZPlayer"
[[ -x "${BIN_SOURCE}" ]]
[[ -d "${BUILD_DIR}/VLCKit.framework" ]]
[[ -d "${BUILD_DIR}/BZPlayer_BZPlayerApp.bundle" ]]

echo "[deploy] Stopping old process..."
pkill -x BZPlayer || true
sleep 0.5
pkill -9 -x BZPlayer || true

echo "[deploy] Removing old app..."
rm -rf "${APP_DIR}"

echo "[deploy] Packaging app bundle..."
zsh "${SCRIPT_DIR}/build_macos_app.sh" "${APP_DIR}" "${NEXT_VERSION}" "${BUILD_DIR}"

"${LSREGISTER}" -f "${APP_DIR}" >/dev/null
# Use path form; `open -a` expects an app name, not a full .app path.
open "${APP_DIR}"

if [[ -n "${COMMIT_MSG}" ]]; then
    echo "[deploy] Committing and pushing..."
    cd "${REPO_DIR}"
    git add -A
    if git diff --cached --quiet; then
        echo "[deploy] No staged changes to commit."
    else
        git commit -m "${COMMIT_MSG}"
        git push origin main
    fi
fi

echo "[deploy] Done!"
