# BZPlayer (macOS)

本仓库新增了 `macos/BZPlayer` 的 SwiftUI + AVFoundation macOS 播放器实现。

## 关键功能

- 最高 `16x` 倍速播放（含 0.25x、0.5x、1x、1.5x、2x、4x、8x、16x 按钮）
- 点击画面暂停/播放
- 双击画面全屏，或按 `f` 切换全屏
- 速度微调（`±0.25x`）
- 基础音画同步状态提示

## 运行方式（macOS）

```bash
cd macos/BZPlayer
swift run
```

## 重大说明

- 该播放器使用 `SwiftUI + AppKit + AVKit`，**无法在 Ubuntu 直接运行**。
- 如需在 Ubuntu 验证，只能做静态代码检查，实际功能需在 macOS 13+ 上运行确认。

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
