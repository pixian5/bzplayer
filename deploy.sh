#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# 保持根目录部署入口与 macOS .app 打包逻辑一致。
COMMIT_MSG="${1:-$(date '+%Y%m%d%H%M')}"
exec zsh scripts/install_macos_app.sh "${COMMIT_MSG}"
