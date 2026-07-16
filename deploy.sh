#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# 保持根目录部署入口与 macOS .app 打包逻辑一致。
COMMIT_MSG="${1:-$(date '+%Y%m%d%H%M')}"
exec zsh scripts/install_macos_app.sh "${COMMIT_MSG}"
