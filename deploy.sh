#!/bin/bash
set -e

cd "$(dirname "$0")"

# commit 消息：传参或默认当前时间
COMMIT_MSG="${1:-$(date '+%Y%m%d%H%M')}"

echo "🔨 构建项目..."
cd macos/BZPlayer
swift build
echo "✅ 构建成功"

echo "📦 复制编译产物到 .app 包..."
cp .build/arm64-apple-macosx/debug/BZPlayer dist/BZPlayer.app/Contents/MacOS/BZPlayer

echo "📦 复制应用图标到 .app 包..."
mkdir -p dist/BZPlayer.app/Contents/Resources
cp Resources/AppIcon.icns dist/BZPlayer.app/Contents/Resources/AppIcon.icns

echo "📦 复制 VLCKit.framework 到 .app 包..."
VLCKIT_SRC=".build/artifacts/vlckit-spm/VLCKit-all/VLCKit-all.xcframework/macos-arm64_x86_64/VLCKit.framework"
mkdir -p dist/BZPlayer.app/Contents/Frameworks
rm -rf dist/BZPlayer.app/Contents/Frameworks/VLCKit.framework
cp -R "$VLCKIT_SRC" dist/BZPlayer.app/Contents/Frameworks/VLCKit.framework

echo "🛑 关闭旧应用..."
osascript -e 'quit app "BZPlayer"' 2>/dev/null || true
sleep 1

echo "🗑️  删除旧应用..."
rm -rf /Applications/BZPlayer.app

echo "📋 复制到应用程序文件夹..."
cp -R dist/BZPlayer.app /Applications/BZPlayer.app

echo "🚀 启动应用..."
open /Applications/BZPlayer.app

cd ../..

echo "📤 推送 git..."
git add -A
git commit -m "$COMMIT_MSG"
git push

echo "✅ 全部完成"
