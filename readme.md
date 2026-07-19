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

验证与安装：

```bash
swift test --package-path macos/BZPlayer
swift build -c release --package-path macos/BZPlayer
zsh scripts/install_macos_app.sh
```

安装脚本会结束旧的 BZPlayer 进程、重建 `/Applications/BZPlayer.app` 并启动新版本。它默认不会提交 Git；只有明确执行 `zsh scripts/install_macos_app.sh --commit "中文提交说明"` 或 `./deploy.sh --commit "中文提交说明"` 才会提交并推送。

音频模式 A/B 测量：

```bash
# 建议使用至少 1080p、时长足够长的本地媒体；每种模式运行 3 次。
bash scripts/measure_audio_only.sh "/path/to/media.mp4" \
  --runs 3 --warmup 120 --duration 600
```

脚本会自动运行 normal 和 audio-only 两组，应用在媒体从头播放、倍速固定为 `1x` 且状态稳定后写入测量开始标记，再自动退出。每个 run 会保存 BZPlayer 进程 CPU、`top`、`pmset`、`ioreg` 和可用时的 `powermetrics` 原始数据。两组测试必须保持相同的电源、屏幕亮度、外接显示器、网络和后台负载；短媒体或短时长只能验证流程，不能据此宣称节能。

## 重大说明

- 该播放器使用 `SwiftUI + AppKit + VLCKit`，**无法在 Ubuntu 直接运行**。
- 如需在 Ubuntu 验证，只能做静态代码检查，实际功能需在 macOS 13+ 上运行确认。
- `VLCKit.framework` 会随 `.app` 一起打包；未安装 `ffmpeg`/`ffprobe` 时仍可播放，但文件信息和部分兼容性诊断会跳过外部分析。
- `ffprobe` 分析最多等待 8 秒，`ffmpeg` 解码诊断最多等待 20 秒；超时会终止子进程，不应阻塞播放启动。
- AV1 视频优先使用系统 AVPlayer；为避免 macOS 26 上随 VLCKit 一起打包的 dav1d 解码器崩溃，AV1 不再回退到 VLC。AV1 容器或音频轨道不受系统支持时会提示无法播放。
- “最小化到 Dock 时仅播放音频”默认关闭，是实验功能。开启后会在最小化时禁用 AVPlayer 视频轨道，或让 VLC 以 `:no-video` 重新加载；恢复窗口时会再次加载视频。该功能可能产生短暂切换，节能效果必须在目标机器上用 Activity Monitor、`powermetrics` 等工具实测，不能仅凭配置推断。
- 当前本地安装与 GitHub Actions 生成的应用包均未自动签名或公证，首次运行可能需要在系统安全提示中允许。生产分发前应增加 Developer ID 签名、公证和 staple 流程。

## 自动构建与发布（GitHub Actions）

- 工作流文件：`.github/workflows/build-and-release.yml`
- 触发条件：
  - push 到 `main`
  - 手动 `workflow_dispatch`
- 产物：
  - `BZPlayer.app`
  - `BZPlayer-v<版本>.dmg`
- 版本规则：`version = GITHUB_RUN_NUMBER - 1`（首次为 `0`，之后每次 +1）
- CI 会先执行 `swift test --package-path macos/BZPlayer`，再使用 `scripts/build_macos_app.sh` 生成与本地一致的 `.app` 和 DMG。
- CI 只有在配置 `MACOS_CERTIFICATE_BASE64`、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_SIGNING_IDENTITY` 后才签名；再配置 `APPLE_API_KEY_BASE64`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER` 才会公证并 staple，否则产物保持 unsigned。

> 注意：Release 发布需要仓库具备 `contents: write` 权限（工作流已声明）。
