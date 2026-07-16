# BZPlayer (macOS)

本仓库包含 `macos/BZPlayer` 的 SwiftUI + AppKit macOS 播放器实现。

## 关键功能

- 最高 `16x` 倍速播放（含 0.25x、0.5x、1x、1.5x、2x、4x、8x、16x 按钮）
- 点击画面暂停/播放
- 双击画面全屏，或按 `f` 切换全屏
- 速度微调（`±0.25x`）
- 使用 AVPlayer 和 VLCKit 双播放后端，按媒体格式自动选择
- 文件信息可同时显示 AVFoundation 与 `ffprobe` 的媒体流识别结果

## 运行方式（macOS）

```bash
# ffmpeg/ffprobe 仅用于可选的媒体分析和解码诊断
brew install ffmpeg
cd macos/BZPlayer
swift run
```

## 重大说明

- 该播放器使用 `SwiftUI + AppKit + VLCKit`，**无法在 Ubuntu 直接运行**。
- 如需在 Ubuntu 验证，只能做静态代码检查，实际功能需在 macOS 13+ 上运行确认。
- `VLCKit.framework` 会随 `.app` 一起打包；未安装 `ffmpeg`/`ffprobe` 时仍可播放，但文件信息和部分兼容性诊断会跳过外部分析。

## 自动构建与发布（GitHub Actions）

- 工作流文件：`.github/workflows/build-and-release.yml`
- 触发条件：
  - push 到 `main`
  - 手动 `workflow_dispatch`
- 产物：
  - `BZPlayer.app`
  - `BZPlayer-v<版本>.dmg`
- 版本规则：`version = GITHUB_RUN_NUMBER - 1`（首次为 `0`，之后每次 +1）

> 注意：Release 发布需要仓库具备 `contents: write` 权限（工作流已声明）。
