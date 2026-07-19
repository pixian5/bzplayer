#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# 保持根目录部署入口与 macOS .app 打包逻辑一致。
# 默认只构建、安装并启动；只有显式 --commit 才会提交和推送。
if [[ "${1:-}" == "--commit" ]]; then
    exec zsh scripts/install_macos_app.sh "$@"
fi
exec zsh scripts/install_macos_app.sh
