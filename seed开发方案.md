# BZPlayer 完整项目分析与开发方案

> 生成时间：2026-08-09
> 分析范围：macOS/BZPlayer 全量代码、构建脚本、CI/CD、依赖管理、测试体系
> 当前版本：Git tag v99，VLCKit 4.0.0-alpha.21

---

## 一、项目概述

BZPlayer 是一款 macOS 原生视频播放器，定位为高性能、高兼容性的本地媒体播放工具。核心特色是双播放后端架构——系统原生 AVPlayer 与 VLC/libvlc 并存，按媒体容器和编码格式智能路由，并在播放失败时自动回退。

### 1.1 技术栈

| 层面 | 技术选型 |
|------|----------|
| 语言 | Swift 5.9+ |
| UI 框架 | SwiftUI + AppKit 混合（SwiftUI 为主，播放层用 AppKit） |
| 播放后端 | AVPlayer（AVFoundation）+ VLCKit 4.0.0-alpha.21（libvlc 4.0.0-dev） |
| 视频渲染 | AVPlayerLayer（原生）/ AVSampleBufferDisplayLayer（VLC samplebufferdisplay vout） |
| 构建系统 | Swift Package Manager（无 Xcode 工程文件） |
| 最低系统 | macOS 13.0（Ventura） |
| 外部工具 | ffprobe（媒体分析）、ffmpeg（解码诊断，可选） |
| CI/CD | GitHub Actions（macOS runner，构建→签名→公证→DMG→Release） |
| 包标识 | tech.sbbz.bzplayer |

### 1.2 核心功能清单

- 最高 16x 倍速播放（0.25x–16x，含数字键快捷倍速）
- 双后端自动选择 + 手动切换 + 失败自动回退
- 外挂字幕（SRT/VTT/ASS/SSA）解析与原生渲染，支持拖拽定位
- 内置字幕/音轨切换
- 音频延迟调节（每文件独立记忆）
- 播放列表管理（正序/倒序、单文件/列表/不循环）
- 播放进度记忆、倍速记忆、最近文件
- 可配置快捷键（跳转、帧步进、文件切换、音频延迟、倍速切换）
- 多窗口支持（可配置单窗口模式）
- 7 语言界面（中/英/日/德/法/西/俄）
- 文件信息面板（AVFoundation + ffprobe 双源）
- 最小化音频-only 模式（实验性节能）
- 常见视频格式关联（LaunchServices）
- VP9 解码器预热、原生卡顿检测与自动切换 VLC
- 性能基准测试框架（benchmark mode）

---

## 二、项目结构分析

### 2.1 目录结构

```
bzplayer-main/
├── .github/workflows/build-and-release.yml   # CI/CD 流水线
├── docs/
│   └── VLC4_MAINTENANCE.md                   # VLC 4 升级维护手册
├── macos/
│   ├── BZPlayer/
│   │   ├── Package.swift                     # SPM 包定义
│   │   ├── Resources/AppIcon.icns
│   │   ├── Sources/
│   │   │   ├── BZPlayerApp/                  # 主应用 target（executable）
│   │   │   │   ├── BZPlayerApp.swift         # @main 入口 + AppDelegate（417行）
│   │   │   │   ├── PlayerViewModel.swift     # 核心 ViewModel（~2630行）
│   │   │   │   ├── PlayerRootView.swift      # 根视图 + 控制栏/播放列表/Toast（302行）
│   │   │   │   ├── PlayerContainerView.swift # NSViewRepresentable + 3个AppKit类（793行）
│   │   │   │   ├── VLCPlayer.swift           # VLC 后端封装（550行）
│   │   │   │   ├── BenchmarkConfiguration.swift
│   │   │   │   ├── Views/
│   │   │   │   │   ├── ControlBarView.swift
│   │   │   │   │   ├── PlaylistPanelView.swift
│   │   │   │   │   ├── SettingsView.swift
│   │   │   │   │   ├── RecentFilesView.swift
│   │   │   │   │   ├── FileInfoPanelView.swift
│   │   │   │   │   └── LongPressButton.swift
│   │   │   │   └── Utils/
│   │   │   │       ├── AppLogger.swift
│   │   │   │       ├── ExternalSubtitleRenderer.swift
│   │   │   │       ├── InputDispatcher.swift
│   │   │   │       ├── JSONWriteQueue.swift
│   │   │   │       ├── Localization.swift
│   │   │   │       ├── MediaAnalyzer.swift
│   │   │   │       └── WindowAccessor.swift
│   │   │   └── BZPlayerCore/                 # 核心库 target（library）
│   │   │       └── MediaAnalysisCore.swift
│   │   └── Tests/BZPlayerTests/
│   │       └── MediaAnalyzerTests.swift
│   └── Vendor/vlckit-spm/                    # 本地 SPM 包装（gitignore 二进制）
├── scripts/
│   ├── fetch_vlckit.sh                       # 下载校验 VLCKit 861MB
│   ├── build_macos_app.sh                    # 打包 .app
│   ├── install_macos_app.sh                  # 本地构建+安装+启动
│   └── measure_audio_only.sh                 # 节能基准测试
├── readme.md
├── deep-research-report.md
└── deploy.sh
```

### 2.2 Target 划分

| Target | 类型 | 职责 |
|--------|------|------|
| BZPlayerCore | library | 纯逻辑：ffprobe 数据结构、字幕解析工具、格式化函数 |
| BZPlayerApp | executable | 全部 UI、播放控制、VLC 集成、持久化 |
| BZPlayerTests | testTarget | 仅依赖 BZPlayerCore，3 个测试用例 |

**问题**：BZPlayerApp 是单一巨型 target，没有按功能进一步模块化。所有 UI、播放逻辑、后端封装、工具类都在一个编译单元内，增量编译效率低，且无法独立测试。

---

## 三、架构深度分析

### 3.1 双后端路由机制

`PlayerViewModel.chooseBackend(for:ffprobeInfo:)` 是后端选择的核心决策点：

```
输入 URL
  │
  ├─ 容器在非原生集合 {mkv,avi,flv,wmv,webm,rmvb,ts,mpeg,mpg,ogg,oga,opus,wma,ape,mka}
  │     → VLC
  ├─ audioDelayMs != 0
  │     → VLC（AVPlayer 不支持运行时音频延迟）
  ├─ 视频编码为 AV1（在原生容器 mp4/mov/m4v 中）
  │     → Native（走系统硬件解码，降低功耗）
  ├─ ffprobe 检测到非安全编码/标签
  │     → VLC
  ├─ H.264 且 ffmpeg 前20秒解码报错
  │     → VLC
  └─ 默认 → Native
```

**容错机制**：
- `schedulePlaybackFailureCheck`：5秒后检查 `duration == 0 && currentTime < 0.5`，判定为失败
- 原生卡顿检测：0.5秒 tick 中时间不动连续 6 次（~3秒），自动切 VLC
- AVPlayerItem.status == .failed 立即触发回退
- 两个后端都失败时显示错误面板，AV1 有专属错误提示

**评估**：路由策略务实且经过实战打磨，但决策逻辑全部硬编码在 ViewModel 中，无法单独测试，也不易扩展（如新增 mpv 后端）。

### 3.2 播放状态管理

ViewModel 使用多层 generation UUID 防止竞态：

- `mediaOpenGeneration`：每次打开新媒体递增，丢弃旧回调
- `nativePlaybackRefreshGeneration`：原生速率刷新/seek 操作代次
- `activeSeekGeneration`：seek 操作代次
- `attemptedBackendSwitch`：防止循环回退

VLCPlayer 内部也有独立的 `mediaGeneration`。

**问题**：
1. 四层 generation + 多个 Bool 标志（`isTransitioning`、`shouldPlay`、`resumeAfterSeek`、`nativePlaybackRefreshInFlight`）交织，状态机隐式且难以推理。
2. VLCPlayer 每次 load 都重建 VLCMediaPlayer 实例（注释说明是为了规避 VLCKit 4 stop/load 竞态），这是较重的 workaround。
3. seek 后用 1.5 秒硬编码定时器兜底 `isSeeking` 状态，属于启发式修补。

### 3.3 视频渲染层

`PlayerContainerView` 是 NSViewRepresentable，内部 `PlayerHostView` 管理：

- `AVPlayerLayer`（zPosition 0）：原生渲染
- `VLCVideoView`（zPosition 0，默认 hidden）：VLC 渲染
- `ClickCaptureView`（zPosition 50）：点击/右键菜单/键盘
- `DraggableSubtitleView`（zPosition 200）：可拖拽字幕气泡

**设计亮点**：用 AVPlayerLayer 而非 AVPlayerView，避免 AVPlayerView 私有图层层级遮挡字幕 overlay。

**问题**：一个文件包含 4 个类（PlayerContainerView、PlayerHostView、DraggableSubtitleView、ClickCaptureView），职责混杂，应拆分。

### 3.4 字幕系统

| 能力 | 原生后端 | VLC 后端 |
|------|----------|----------|
| 内置字幕 | 不支持（AVPlayer 可显示但本项目未用） | VLC 原生渲染 |
| 外挂 SRT/VTT/ASS | ExternalSubtitleParser 解析 + AppKit label overlay | VLC addPlaybackSlave |
| 字幕拖拽定位 | 支持（DraggableSubtitleView） | 不支持 |
| 字体/背景/位置 | 支持 | 通过 VLC freetype 选项（需 reload） |

外挂字幕解析器实现了二分查找 active cue，支持 UTF-8/GB18030/ISO Latin-1 编码回退。ASS 仅提取 Dialogue 行并剥离样式标签（不渲染 ASS 特效）。

### 3.5 持久化层

数据存储在 `~/Library/Application Support/BZPlayer/`：

| 文件 | 内容 | 写入方式 |
|------|------|----------|
| settings.json | 全局设置（~25字段） | JSONWriteQueue 串行异步原子写 |
| fileSettings.json | [路径: {progress, speed, audioDelayMs}] | 同上 |
| recentFiles.json | 最近10个文件路径 | 同上 |
| openedFiles.json | 已打开未完成集合 | 同上 |
| completedFiles.json | 已完整播放集合 | 同上 |

**问题**：
1. `settingsCache` 和 `fileSettingsCache` 是静态变量，多窗口（多 ViewModel）场景下存在线程安全隐患。
2. `saveSettings()` 每次都全量序列化写入，频繁设置变更（如拖动音量）虽有 150ms debounce，但仍可优化。
3. 没有数据迁移机制，字段增减依赖 Codable 的 `decodeIfPresent` 默认值。

### 3.6 多窗口架构

AppDelegate 维护 `registeredWindows: [ObjectIdentifier: WeakWindowBinding]`，通过 `singleWindowTargetBinding` 决定文件打开目标。`allowMultipleWindows=false` 时，新文件在已有窗口播放并关闭多余窗口。

**问题**：多窗口共享静态设置缓存，但每个窗口有独立 ViewModel 和独立播放器实例，窗口间偏好同步通过 `NotificationCenter` 广播（`preferencesDidChangeNotification`），机制较脆弱。

---

## 四、代码质量评估

### 4.1 文件规模与复杂度

| 文件 | 行数 | 问题 |
|------|------|------|
| PlayerViewModel.swift | ~2630 | God Object，40+ @Published，12+ 职责 |
| PlayerContainerView.swift | 793 | 4个类混放 |
| VLCPlayer.swift | 550 | 状态管理复杂 |
| BZPlayerApp.swift | 417 | App 入口 + 完整 AppDelegate |
| PlayerRootView.swift | 302 | 控件可见性状态机偏复杂 |
| Localization.swift | 648 | 字典硬编码，无占位符校验 |

PlayerViewModel 的 @Published 属性超过 40 个，任何一个变化都会触发 SwiftUI  body 重算，虽然 SwiftUI 有内部 diff，但粒度仍偏粗。

### 4.2 具体代码问题

#### 4.2.1 强制解包与强制转换

```swift
// MediaAnalysisCore.swift:126-131
let c1 = Character(UnicodeScalar((code >> 24) & 255)!)
// ... 4个强制解包
return text.trimmingCharacters(in: .controlCharacters).isEmpty ? "\(code)" : text
```

`fourCCString` 中 4 个 `!` 在理论上 FourCharCode 字节均可打印时安全，但控制字符场景未处理。

#### 4.2.2 错误吞没

```swift
guard let data = try? Data(contentsOf: settingsURL),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
    return AppSettings()  // 配置文件损坏时静默重置，无日志无备份
}
```

全项目大量使用 `try?`，配置损坏、磁盘写入失败等场景用户无感知。

#### 4.2.3 线程安全

- `JSONWriteQueue` 用串行 DispatchQueue 保证写入顺序，设计合理。
- `settingsCache`/`fileSettingsCache` 为 `static var` 无锁访问，虽然 ViewModel 标记 `@MainActor`，但 `BZPlayerApp` 中创建了一个 `loadPlaybackInfrastructure: false` 的 settingsViewModel，与播放 ViewModel 可能并发读写。
- `AsyncProcessRunner` 用 NSLock 保护进程状态，实现正确。

#### 4.2.4 硬编码魔法值

```swift
let nonNativeContainers: Set<String> = ["mkv", "avi", ...]  // 散落在 chooseBackend
let nativeSafeVideoCodecs: Set<String> = ["h264", "hevc", ...]  // shouldPreferVLC
let nativeSafeVideoSubtypes: Set<String> = ["avc1", "hvc1", ...]  // 另一个 shouldPreferVLC
let errorMarkers = ["invalid nal", ...]  // hasVideoDecodeErrors
```

兼容性规则分散在多处，codec name 和 fourCC tag 两套白名单维护成本高且易不一致。

#### 4.2.5 重复代码

- `seek(to:)` 和 `seekBy(seconds:)` 的原生/VLC 分支逻辑高度重复。
- `chooseBackend` 中 ffprobe 路径和 AVAsset 路径的白名单判断逻辑重复。
- `format(_:)` 时间格式化在 ControlBarView 和 MediaAnalyzer 中各有一份。

---

## 五、构建与依赖分析

### 5.1 VLCKit 依赖管理

采用本地 path package + 脚本下载方案：

- `fetch_vlckit.sh` 从 GitHub Release 下载 861MB zip，校验 SHA256 + 文件大小
- 解压后 2.6GB XCFramework，gitignore
- `VLCKIT.lock` 记录版本/URL/SHA，防止版本漂移
- 本地缓存 `.cache/` 避免重复下载

**优点**：避免 SwiftPM 远程 binaryTarget 解析大文件超时；版本锁定可靠。
**风险**：
1. VLCKit 4.0.0-alpha.21 是 alpha 版本，API 不稳定，已知 OpenGL vout 崩溃（已用 samplebufferdisplay 规避）。
2. 首次构建需下载 861MB，对网络环境要求高；CI 每次都重新下载（无缓存配置）。
3. VLCKit 4 未来 API 变更可能导致大面积编译错误。

### 5.2 .app 打包

`build_macos_app.sh` 手动组装 .app bundle：
- 手写 Info.plist（含文档类型声明）
- 复制 VLCKit.framework 到 Contents/Frameworks
- 用 `install_name_tool` 添加 `@executable_path/../Frameworks` rpath
- 复制资源 bundle

**问题**：
1. 手写 Info.plist 无法利用 Xcode 的自动配置（如权限、entitlements）。
2. 没有代码签名 entitlements 文件（sandbox、hardened runtime 配置缺失）。
3. `install_name_tool -add_rpath` 重复执行用 `2>/dev/null || true` 吞错误，不够健壮。

### 5.3 CI/CD

GitHub Actions 流水线步骤：checkout → Node.js → Xcode → 计算版本 → fetch VLCKit → swift build → swift test → 打包 .app → 签名/公证 → DMG → 上传 artifact → GitHub Release。

**问题**：
1. **无 VLCKit 缓存**：每次 CI 运行都下载 861MB，耗时且不稳定。应配置 `actions/cache` 缓存 `.cache/` 目录和已解压 framework。
2. **版本号用 GITHUB_RUN_NUMBER-1**：与本地 `install_macos_app.sh` 从 git tag 取版本的逻辑不一致，可能导致本地和 CI 版本号错位。
3. **测试在构建后执行**：应先测试再打包，测试失败不应产出 .app。
4. **无 SwiftLint**：没有静态检查。
5. **签名条件判断**：未配置签名密钥时静默产出 unsigned app，应有 warning 或手动确认。

### 5.4 缺少 Xcode 工程

纯 SPM 项目无法使用 Xcode 的 Interface Builder、Instruments 模板、Scheme 管理、Core Data 模型编辑器等。对于需要大量 AppKit 互操作的项目，建议生成或维护一个 `.xcodeproj`（可用 xcodegen 或 tuist）。

---

## 六、测试体系评估

### 6.1 现状

- 仅 3 个单元测试，全部在 `MediaAnalyzerTests` 中，仅覆盖 BZPlayerCore。
- 测试内容：ffprobe 摘要解析、FPS 解析、码率格式化。
- 无 ViewModel 测试、无 VLCPlayer 测试、无字幕解析测试、无 UI 测试。
- CI 执行 `swift test`，但测试不依赖 VLCKit，不涉及播放。

### 6.2 测试盲区

| 模块 | 风险 | 建议测试类型 |
|------|------|-------------|
| PlayerViewModel 后端选择 | 路由错误导致播放失败或功耗高 | 单元测试（mock 后端） |
| ExternalSubtitleParser | 字幕时间轴错位、编码识别失败 | 参数化单元测试 |
| VLCPlayer 状态机 | 竞态导致永久暂停/无法切换 | 集成测试（需真实 VLCKit） |
| 设置持久化 | 升级后配置丢失或损坏 | 单元测试 + 迁移测试 |
| InputDispatcher | 快捷键冲突/无响应 | 单元测试 |
| 播放列表逻辑 | 循环/切换/排序错误 | 单元测试 |
| UI 交互 | 控制栏/播放列表/字幕拖拽 | XCUITest |

---

## 七、问题与风险清单

### 7.1 高优先级（影响稳定性/可维护性）

| # | 问题 | 影响 | 位置 |
|---|------|------|------|
| H1 | PlayerViewModel 2630行 God Object | 难以维护、测试、扩展；修改易引入回归 | PlayerViewModel.swift |
| H2 | 播放后端无协议抽象 | 无法添加第三后端（如 mpv），无法 mock 测试 | PlayerViewModel + VLCPlayer |
| H3 | VLCKit 4 alpha 依赖 | 未来升级风险高，已知崩溃需 workaround | Package.swift + VLCPlayer |
| H4 | 测试覆盖率接近零 | 重构无安全网，回归靠人工 | Tests/ |
| H5 | 状态机用 generation+Bool 隐式实现 | 竞态问题反复出现（seek卡住、暂停后不恢复） | VLCPlayer + PlayerViewModel |
| H6 | CI 每次下载 861MB VLCKit | CI 慢且易失败 | build-and-release.yml |

### 7.2 中优先级（影响开发效率/用户体验）

| # | 问题 | 影响 |
|---|------|------|
| M1 | 40+ @Published 粗粒度更新 | SwiftUI 性能浪费 |
| M2 | 静态设置缓存无线程安全 | 多窗口潜在数据竞争 |
| M3 | 编解码白名单分散重复 | 维护困难，易漏判 |
| M4 | 无 SwiftLint/格式强制 | 代码风格不统一 |
| M5 | 配置损坏静默重置 | 用户设置丢失无感知 |
| M6 | 原生倍速变更用 seek+play 刷新 | 变速瞬间卡顿 |
| M7 | 字幕 ASS 样式完全丢失 | 特效字幕体验差 |
| M8 | 无网络流媒体播放 | 功能局限于本地文件 |
| M9 | 版本号本地/CI 不一致 | 版本追踪混乱 |
| M10 | 无 Xcode 工程 | 调试和 Instruments 不便 |

### 7.3 低优先级（改进项）

| # | 问题 |
|---|------|
| L1 | Localization 字典硬编码，缺占位符格式校验，新增语言易漏译 |
| L2 | 无 Picture-in-Picture 支持 |
| L3 | 无 AirPlay 支持 |
| L4 | 无视频截图功能 |
| L5 | 无 A-B 循环 |
| L6 | 无章节（chapter）支持 |
| L7 | 无 Touch Bar 支持 |
| L8 | 播放列表无搜索/过滤 |
| L9 | 无媒体库/收藏管理 |
| L10 | 日志仅 os.log，无文件轮转和用户上报 |

---

## 八、开发建议与路线图

### 阶段一：架构解耦与安全网（建议 2–3 周）

#### 1.1 抽取播放后端协议

定义统一的播放后端协议，让 ViewModel 依赖抽象而非具体实现：

```swift
// Sources/BZPlayerCore/Playback/PlaybackBackend.swift
@MainActor
protocol PlaybackBackend: AnyObject {
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var rate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var audioTracks: [TrackInfo] { get }
    var subtitleTracks: [TrackInfo] { get }
    var currentAudioTrack: Int32 { get set }
    var currentSubtitleTrack: Int32 { get set }

    var onTimeUpdate: ((Double) -> Void)? { get set }
    var onDurationUpdate: ((Double) -> Void)? { get set }
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    var onEndReached: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func load(url: URL, resumeAt: Double?, options: PlaybackOptions)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
    func setExternalSubtitle(url: URL)
    func setAudioDelay(_ ms: Double)
}

enum PlaybackState { case idle, loading, ready, playing, paused, stalled, ended, failed(Error) }
struct PlaybackOptions { var audioDelayMs: Double; var subtitleFontSize: Int; var noVideo: Bool }
struct TrackInfo: Identifiable { let id: Int32; let name: String; let isSelected: Bool }
```

将 AVPlayer 和 VLCPlayer 分别实现该协议。ViewModel 通过 `BackendRouter` 决策后持有 `any PlaybackBackend`。

**收益**：可 mock 后端做单元测试；未来可接入 mpv/IINA 内核；切换逻辑集中。

#### 1.2 拆分 PlayerViewModel

按职责拆分为独立的 Manager/Service，均为 `@MainActor`：

```
PlayerViewModel (协调者，仅持有各 Manager 和 UI 状态)
├── PlaybackManager         # 持有 backend、播放/暂停/seek/倍速、状态同步
├── BackendRouter           # chooseBackend、编解码白名单、ffprobe 决策
├── PlaylistManager         # 列表加载、排序、循环、导航
├── SettingsStore           # 全局/文件设置加载、保存、缓存、迁移
├── SubtitleManager         # 外挂字幕发现、解析、选择、原生 overlay 调度
├── WindowManager           # 窗口行为、全屏、多窗口协调（移到 AppDelegate 侧）
├── MediaAnalysisService    # ffprobe/ffmpeg 调用（协议化，可替换）
└── ProgressTracker         # 进度保存、已打开/已完成集合
```

每个 Manager 独立可测试。ViewModel 通过组合持有，`@Published` 属性按功能分组或用 `@Observable`（macOS 14+）细化更新。

#### 1.3 建立测试基础

优先级排序：
1. **ExternalSubtitleParser 测试**（纯函数，最容易）：SRT/VTT/ASS 正常解析、边界时间戳、编码识别、畸形输入。
2. **BackendRouter 测试**：用 mock FFprobeInfo 和 URL 扩展名验证路由决策。
3. **SettingsStore 测试**：加载/保存/默认值/损坏恢复/迁移。
4. **PlaylistManager 测试**：循环模式、边界导航、排序。
5. **InputDispatcher 测试**：快捷键映射、修饰键过滤。

目标：BZPlayerCore 测试覆盖率 >80%，BZPlayerApp 核心逻辑 >50%。

#### 1.4 引入 SwiftLint

添加 `.swiftlint.yml`，CI 中执行 `swiftlint lint --strict`。规则建议：
- 行长度 120
- 文件长度 400（警告）/ 600（错误）
- 函数体长度 80
- 禁用强制解包（`force_unwrapping`）
- 禁用隐式解析（`implicitly_unwrapped_optional`）

### 阶段二：构建与 CI 改进（建议 1 周）

#### 2.1 缓存 VLCKit

在 CI 中添加：

```yaml
- name: Cache VLCKit
  uses: actions/cache@v4
  with:
    path: |
      macos/Vendor/vlckit-spm/.cache
      macos/Vendor/vlckit-spm/VLCKit.xcframework
      macos/Vendor/vlckit-spm/VLCKIT.lock
    key: vlckit-${{ hashFiles('macos/Vendor/vlckit-spm/VLCKIT.lock') }}
```

#### 2.2 统一版本号来源

在仓库根目录维护 `VERSION` 文件，本地脚本和 CI 都读取它。每次发布（本地 `--commit` 或 CI tag）自动递增。消除 git tag 与 GITHUB_RUN_NUMBER 双轨制。

#### 2.3 调整 CI 步骤顺序

`swift test` 移到 `swift build` 之后、打包之前，测试失败立即终止。

#### 2.4 添加 entitlements 与 sandbox

创建 `BZPlayer.entitlements`：
- 开启 Hardened Runtime
- 视情况启用 App Sandbox（需处理用户文件选择的 security-scoped bookmark）
- 如需网络播放，添加 `com.apple.security.network.client`

### 阶段三：播放体验增强（建议 2–3 周）

#### 3.1 网络流媒体支持

- AVPlayer 原生支持 HTTP(HLS)/HTTPS，URL 打开逻辑基本可用。
- VLC 支持几乎所有网络协议。
- 需添加 URL 打开入口（菜单/快捷键 Cmd+U）。
- 注意 App Sandbox 下的网络权限。

#### 3.2 原生字幕渲染改进

- 当前 ASS 仅提取纯文本，丢失样式、位置、动画。
- 短期：解析 ASS 的 `Style` 行，应用字体/颜色/描边/位置到原生 label。
- 长期：考虑用 Core Text + CAShapeLayer 自行渲染 ASS，或使用 libass。

#### 3.3 倍速切换平滑化

当前原生后端变速时执行 pause → seek(zero tolerance) → playImmediately(atRate:)，会造成可见卡顿。研究方案：
- 直接设置 `player.rate = newValue`（AVPlayer 支持运行时改速率，当前注释说会音视频不同步，需复现验证）。
- 若必须 refresh，用 `AVPlayerItem.seek(to:completionHandler:)` 的非 zero tolerance 版本减少卡顿。

#### 3.4 Picture-in-Picture

利用 `AVPictureInPictureController`（仅 AVPlayer 后端）。VLC 后端需通过 samplebufferdisplay 的 AVSampleBufferDisplayLayer 接入 PiP，较复杂。

#### 3.5 视频截图

- AVPlayer：`AVPlayerItemVideoOutput.copyPixelBuffer`
- VLC：`VLCMediaPlayer.videoSnapshot`（VLCKit 提供）
- 保存到 Pictures 目录或剪贴板。

### 阶段四：功能扩展（按需）

- A-B 循环：在 ProgressTracker/PlaybackManager 中添加 A/B 点，到达 B 点 seek 回 A。
- 章节支持：ffprobe `-show_chapters` 解析，AVPlayerItem.navigationMarkerChapterGroups。
- 播放列表搜索/过滤：PlaylistPanelView 添加搜索框。
- Touch Bar：NSTouchBar 提供播放/暂停/seek/倍速。
- 音频可视化：可用 AVAssetReader 或 AVAudioEngine 做简单频谱。
- 媒体库：SQLite.swift 或 Core Data 管理观看历史、收藏，但需评估是否超出播放器定位。

### 阶段五：代码质量持续改进

- 将 `PlayerContainerView.swift` 拆分为 `PlayerHostView.swift`、`ClickCaptureView.swift`、`DraggableSubtitleView.swift`。
- 编解码白名单统一到一个 `CodecCompatibility.swift`，同时支持 ffprobe name 和 fourCC tag 查询。
- 时间格式化工具移到 BZPlayerCore，消除重复。
- 配置损坏时备份原文件并记录日志，而非静默重置。
- Localization 改为 `.strings`/`.xcstrings` 文件，利用 Xcode 本地化工具和格式校验。
- 考虑升级到 `@Observable` 宏（macOS 14+，需提高最低系统或做 availability 适配）。

---

## 九、重构注意事项

1. **VLCKit 4 的特殊性**：VLCPlayer 中大量注释记录了 VLCKit 4 alpha 的 bug 和 workaround（重建 player、samplebufferdisplay vout、stop 等待、rate 需 play 后重设）。重构时**必须保留这些 workaround**，并在新协议实现中标注来源注释。每次重构后用 `scripts/measure_audio_only.sh` 和手动测试覆盖：mkv+h264、mp4+av1、mp4+vp9、带音频延迟、外挂字幕、后端切换、seek 后继续播放。

2. **不要破坏生成机制**：`mediaOpenGeneration` 等代次机制虽然复杂，但它是防止异步回调错乱的关键。重构为协议时，代次管理应留在 PlaybackManager 层，后端内部只负责单次 load/play/stop。

3. **数据备份**：按用户规则，重构前备份 `~/Library/Application Support/BZPlayer/` 整个目录。

4. **版本号递增**：每次修改版本号 +0.0.1（当前 tag v99，可考虑语义化版本如 1.0.0）。

5. **macOS 26 / Apple Silicon 兼容**：VLCKit xcframework 需包含 arm64 slice；所有 shell 脚本在 zsh 下测试；不使用 iOS-only API。

---

## 十、关键技术决策建议

| 决策点 | 现状 | 建议 | 理由 |
|--------|------|------|------|
| 最低系统 | macOS 13 | 保持 macOS 13 | @Observable 需 14，暂缓；覆盖更多用户 |
| 第三后端 | 仅 AVPlayer+VLC | 暂不接入 mpv | 双后端已覆盖绝大多数格式；mpv 增加包体积和维护成本 |
| 网络播放 | 不支持 | 优先添加 | AVPlayer 原生支持，工作量小 |
| 字幕渲染 | 原生 label + VLC freetype | 保留双轨 | 原生可拖拽但无 ASS 特效；VLC 有特效但不可拖拽 |
| 构建系统 | 纯 SPM | 引入 xcodegen 生成 .xcodeproj | 改善调试体验，保留 SPM 作为 CI 构建入口 |
| 设置存储 | JSON 文件 | 保持 JSON | 简单可读；不引入 Core Data 过度设计 |
| UI 框架 | SwiftUI+AppKit | 保持混合 | 播放层必须用 AppKit；SwiftUI 版本兼容性限制了纯 SwiftUI 方案 |
| 依赖管理 | SPM | 保持 SPM | VLCKit 本地包方案已稳定，无需引入 CocoaPods |

---

## 附录 A：关键文件索引

| 文件 | 关注点 |
|------|--------|
| [PlayerViewModel.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Sources/BZPlayerApp/PlayerViewModel.swift) | chooseBackend (L2248)、openFromPlaylist (L1948)、selectBackend (L1707)、bindVLCCallbacks (L1576) |
| [VLCPlayer.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Sources/BZPlayerApp/VLCPlayer.swift) | load (L86)、makeMediaPlayer (L269)、handleStateChanged (L495) |
| [PlayerContainerView.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Sources/BZPlayerApp/PlayerContainerView.swift) | PlayerHostView.updateBackend (L267)、字幕拖拽 (L357) |
| [ExternalSubtitleRenderer.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Sources/BZPlayerApp/Utils/ExternalSubtitleRenderer.swift) | 三种格式解析、二分查找 cue (L181) |
| [MediaAnalyzer.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Sources/BZPlayerApp/Utils/MediaAnalyzer.swift) | AsyncProcessRunner 超时取消 (L14)、probeMediaInfo (L167) |
| [Package.swift](file:///Users/x/code/bzplayer-main/macos/BZPlayer/Package.swift) | VLCKit path dependency (L20) |
| [build-and-release.yml](file:///Users/x/code/bzplayer-main/.github/workflows/build-and-release.yml) | CI 全流程 |
| [VLC4_MAINTENANCE.md](file:///Users/x/code/bzplayer-main/docs/VLC4_MAINTENANCE.md) | VLC 升级必读 |

## 附录 B：快捷键默认值

| 功能 | 键位 | 可配置 |
|------|------|--------|
| 播放/暂停 | Space | 否 |
| 全屏 | F | 否 |
| 后退/前进 | ← / → | 秒数可配 |
| 帧后退/前进 | ↑ / ↓ | 帧数可配 |
| 上一/下一文件 | [ / ] | 键位可配 |
| 音频延迟减/增 | , / . | 键位可配 |
| 倍速切换 | = | 键位可配 |
| 倍速微调 | ; / '（长按） | 否 |
| 数字键倍速 | 1–9 | 每键倍速可配 |
| 删除当前文件 | Backspace/Delete | 否 |
| 打开文件 | Cmd+O | 否 |
| 关闭文件 | Cmd+W | 否 |
| 复制路径 | Cmd+C | 否 |
