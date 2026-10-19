# BZPlayer (macOS)

本仓库包含 `macos/BZPlayer` 的 SwiftUI + AppKit macOS 播放器实现。

## 关键功能

- 最高 `16x` 倍速播放（含 0.25x、0.5x、1x、1.5x、2x、4x、8x、16x 按钮）
- 点击画面暂停/播放
- 双击画面全屏，或按 `f` 切换全屏
- 速度微调（`±0.25x`）
- 使用 AVPlayer 和 VLCKit 双播放后端，按媒体格式自动选择
- 文件信息可同时显示 AVFoundation 与 `ffprobe` 的媒体流识别结果

## 当前开发进度

截至最新发布：双后端播放、字幕、快捷键、多窗口、按文件记忆等核心能力均已在 `/Applications/BZPlayer.app` 形态下跑通；播放器源码未冻结，仍以修复型迭代为主。

最新一轮（2026-10-19 09:14）：对后端路由做**第二轮**审查后修复 6 项。其中两项是上一轮引入 `MP4ContainerInspector` 时留下的缺陷：**手写 box 遍历的整数溢出崩溃**（64 位 `largesize` 接近 `Int.max` 时 `cursor + size` 溢出，Swift 溢出即 trap，实测 `exit=133`）与**末尾 8 字节 `free` box 被误判结构异常**（会误伤本应走原生的静音 MP4）。另修：`loadTracks` 抛错时改为保守走 VLC、新增 `resolveBackend`/`BackendChoice` 消除 AV1 重复探测、`hdlr` 读取加限界。`swift test` **37 个测试全过**（新增 5 个解析器边界用例）。真实文件实测：`特斯拉.mp4` → VLC；`-an` 生成的静音 MP4 → 保持原生。详见 [后端路由第二轮审查六项修复](docs/20261019-0914-后端路由第二轮审查六项修复与边界测试-DeepSeek-V4.1-Flash.md)。

上一轮（2026-10-17 01:46）：对后端路由做代码审查后修复 6 项。重点是 **ffprobe 缺失时兜底判据精确化** —— 不再用"音轨为空"（会误伤本就无音轨的静音 MP4、丢原生硬件解码），改为解析 MP4 容器的 `moov/trak/mdia/hdlr` 看是否声明 `soun` 音频轨（新增 `MP4ContainerInspector`）；同时把「ffprobe 判不安全」提到 AV1 之前（避免 **AV1 + dts/truehd** 静音）、`decide` 改为惰性闭包避免无谓 AVAsset 探测、`.mp3` 判据统一到 Core（消除黑白名单自相矛盾）。详见 [后端路由六项审查修复](docs/20261017-0146-后端路由六项审查修复-DeepSeek-V4.1-Flash.md)。

版本号已统一（2026-10-17）：**单一版本源 = 根目录 `VERSION`**（当前 `245`），本机安装脚本与 CI 都读它；CI 的 Release tag 额外追加时间戳 `v245-<年月日>-<时分>`，以区分"仅改文档、未递增版本"的提交。详见 [CI 版本号统一与 tag 时间戳](docs/20261017-0206-CI版本号统一与tag时间戳-DeepSeek-V4.1-Flash.md)。

之前两次修复（00:10 判据下沉 Core 并补 mp1/mp2 等四项；00:35 路由顺序抽成可测纯函数 `decide()`）详见 [代码审查与四项修复补齐](docs/20261017-0010-后端路由代码审查与四项修复补齐-hy3.md)（该文数字口径已修正为：本轮合计新增 19 个用例）。

简单说明之外，详细内容见 [当前开发进度（202609292334）](docs/20260929-2334-当前开发进度-未标注.md)。

## 下一步待实现

优先方向：持久化数据治理（fileSettings 上限与清理）、版本号统一（CI 与 `VERSION` 同源，需评估 tag 冲突）、测试补齐与架构减负；功能侧待定项（网络流、截图、A-B 循环、PiP）由使用者决定优先级。

上一轮的后端路由缺口已于 2026-10-17 全部修复（① ffprobe 缺失兜底 ② 音频判据早于 AV1 ③ ffprobe 判不安全早于 AV1），2026-10-19 又修掉手写解析器的崩溃级/误判级缺陷。已用真实文件端到端实测并补足单测（`BackendRoutingTests` 34 个用例、全库 37 个通过）。仍未覆盖：`hasVideoDecodeErrors` 异步逻辑、MP3-in-MOV/ADPCM 等其它组合。详见 [后端路由第二轮审查六项修复](docs/20261019-0914-后端路由第二轮审查六项修复与边界测试-DeepSeek-V4.1-Flash.md) 与 [后端路由六项审查修复](docs/20261017-0146-后端路由六项审查修复-DeepSeek-V4.1-Flash.md)。

详细清单见 [下一步待实现（202609292334）](docs/20260929-2334-下一步待实现-未标注.md)。

## 运行方式（macOS）

```bash
# ffmpeg/ffprobe 仅用于可选的媒体分析和解码诊断
brew install ffmpeg

# VLCKit 4 二进制约 861MB，默认不进 Git；首次需拉取到 macos/Vendor/vlckit-spm
zsh scripts/fetch_vlckit.sh

cd macos/BZPlayer
swift run
```

验证与安装：

```bash
zsh scripts/fetch_vlckit.sh
swift test --package-path macos/BZPlayer
swift build -c release --package-path macos/BZPlayer
zsh scripts/install_macos_app.sh
```

安装脚本会结束旧的 BZPlayer 进程、重建 `/Applications/BZPlayer.app` 并启动新版本。它默认不会提交 Git；只有明确执行 `zsh scripts/install_macos_app.sh --commit "中文提交说明"` 或 `./deploy.sh --commit "中文提交说明"` 才会提交并推送。

VLCKit 的依赖结构、锁定版本、离线缓存、升级步骤和 AV1 回归清单见 [VLC 4 维护手册](docs/VLC4_MAINTENANCE.md)。这是维护 VLC 内核时的唯一操作入口；不要直接修改 `.build`、`artifacts` 或应用包内的 framework。

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
- 播放内核：VLC 后端使用 VLCKit **4.0.0-alpha.21**（libvlc 4.0.0-dev）。仓库通过本地 path package `macos/Vendor/vlckit-spm` 引入（远程 SPM 二进制约 861MB，易超时）。首次构建必须先运行 `zsh scripts/fetch_vlckit.sh`。
- 打包的 `.app` 依赖 `@executable_path/../Frameworks` 加载 `VLCKit.framework`；请使用 `scripts/build_macos_app.sh` / `install_macos_app.sh`，不要只拷贝 release 二进制。
- AV1 视频在 mp4/mov 等系统友好容器上默认优先使用 AVPlayer；可手动切换到 VLC（VLCKit 4 / libavcodec+dav1d 或系统硬件解码）。原生播放失败时会回退到 VLC。MKV/WebM 等非原生容器中的 AV1 直接走 VLC。
- “最小化到 Dock 时仅播放音频”默认关闭，是实验功能。开启后会在最小化时禁用 AVPlayer 视频轨道，或让 VLC 以 `:no-video` 重新加载；恢复窗口时会再次加载视频。该功能可能产生短暂切换，节能效果必须在目标机器上用 Activity Monitor、`powermetrics` 等工具实测，不能仅凭配置推断。
- 当前本地安装与 GitHub Actions 生成的应用包均未自动签名或公证，首次运行可能需要在系统安全提示中允许。生产分发前应增加 Developer ID 签名、公证和 staple 流程。

## 自动构建与发布（GitHub Actions）

- 工作流文件：`.github/workflows/build-and-release.yml`
- 触发条件：
  - push 到 `main`
  - 手动 `workflow_dispatch`
- 产物：
  - `BZPlayer.app`
  - `BZPlayer-v<版本>-<年月日>-<时分>.dmg`
- 版本规则（2026-10-17 起）：
  - app 版本串 = 读仓库根目录 `VERSION` 文件（纯数字，如 `244`）；本地安装脚本同源。
  - Release tag = `v${VERSION}-${YYYYMMDD}-${HHMM}`（**东八区 Asia/Singapore** 时间戳）。带时间戳是为了让"仅改文档、未递增 VERSION"的提交也能得到唯一 tag，避免撞名导致 Release 失败。
  - 旧规则曾是 `version = GITHUB_RUN_NUMBER - 1`（已废弃；它会跳号且与 `VERSION` 脱节）。
- CI 会先执行 `swift test --package-path macos/BZPlayer`，再使用 `scripts/build_macos_app.sh` 生成与本地一致的 `.app` 和 DMG。
- CI 只有在配置 `MACOS_CERTIFICATE_BASE64`、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_SIGNING_IDENTITY` 后才签名；再配置 `APPLE_API_KEY_BASE64`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER` 才会公证并 staple，否则产物保持 unsigned。

> 注意：Release 发布需要仓库具备 `contents: write` 权限（工作流已声明）。

## 文档索引

> 每个文档的逐条介绍见根目录 [文档索引.md](文档索引.md)；分类提炼、已核对的经验条目见 [经验/](经验/README.md)。

| 文档 | 作用 |
|------|------|
| [VLC4_MAINTENANCE.md](docs/VLC4_MAINTENANCE.md) | VLC 4 内核维护手册：依赖结构、锁定版本、离线缓存、升级步骤、AV1 回归清单；维护 VLC 的唯一操作入口 |
| [202609292334项目详细分析与开发建议.md](docs/202609292334项目详细分析与开发建议.md) | 全量代码/CI/仓库的分析结论（问题分级 P0–P2）与分阶段重构路线图 |
| [20260929-2334-当前开发进度-未标注.md](docs/20260929-2334-当前开发进度-未标注.md) | 当前版本可跑通能力、基础设施状态、已知问题状态 |
| [20260929-2334-下一步待实现-未标注.md](docs/20260929-2334-下一步待实现-未标注.md) | 按优先级排列的待办清单（P0 立即 → P4 分发准备） |
| [20261016-2210-AV内核MP3-in-MP4无音轨根因分析-DeepSeek-V4.1-Flash.md](docs/20261016-2210-AV内核MP3-in-MP4无音轨根因分析-DeepSeek-V4.1-Flash.md) | MP3-in-MP4 无音轨根因分析（AVFoundation 不支持 MP4 内 MP3，静默丢轨）；含证据链与对照实验 |
| [20261016-2247-AV内核MP3-in-MP4强制走VLC修复-hy3.md](docs/20261016-2247-AV内核MP3-in-MP4强制走VLC修复-hy3.md) | 对应修复记录：MP4 系列容器 + mp3 → 强制走 VLC；含设计取舍、验证、残留风险（**已被下面一篇补齐**） |
| [20261017-0010-后端路由代码审查与四项修复补齐-hy3.md](docs/20261017-0010-后端路由代码审查与四项修复补齐-hy3.md) | 代码审查 + 四项补齐：判据下沉 Core 可测并补 mp1/mp2、ffprobe 缺失兜底、AV1 判断顺序、消除重复加载；含实测证据与 19 个新增单测（含 8 个顺序单测） |
| [20261017-0146-后端路由六项审查修复-DeepSeek-V4.1-Flash.md](docs/20261017-0146-后端路由六项审查修复-DeepSeek-V4.1-Flash.md) | 六项审查修复：ffprobe 缺失兜底精确化（解析容器 `hdlr=soun`，新增 `MP4ContainerInspector`）、ffprobe 判不安全早于 AV1、`decide` 惰性求值、`.mp3` 判据统一到 Core、文档/版本账目修正；含真实文件端到端实测 |
| [20261017-0206-CI版本号统一与tag时间戳-DeepSeek-V4.1-Flash.md](docs/20261017-0206-CI版本号统一与tag时间戳-DeepSeek-V4.1-Flash.md) | CI 改为读根目录 `VERSION` 作为 app 版本串，Release tag 追加「年月日-时分」（东八区）保证唯一，消除"仅改文档提交撞同名 tag"问题；含本地验证 |
| [20261019-0914-后端路由第二轮审查六项修复与边界测试-DeepSeek-V4.1-Flash.md](docs/20261019-0914-后端路由第二轮审查六项修复与边界测试-DeepSeek-V4.1-Flash.md) | 第二轮审查六项修复：box 遍历整数溢出崩溃、末尾 8 字节 box 误判、`loadTracks` 抛错保守化、`resolveBackend` 消除 AV1 重复探测、`hdlr` 限界、补 5 个解析器边界单测；含真实文件实测 |
