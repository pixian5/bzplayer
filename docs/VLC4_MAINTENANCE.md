# VLC 4 维护手册

## 目的与当前状态

BZPlayer 的 VLC 播放后端使用 `VLCKit 4.0.0-alpha.21`，对应 VideoLAN `4.0.0a21` / 运行时 `libvlc 4.0.0-dev`。该版本是一个明确锁定的内测二进制，不会因为执行 `swift build` 自动升级。升级必须同时修改下载地址、SHA-256、大小、文档和回归结果，避免源码、缓存与最终 `.app` 使用不同框架。

本项目不直接把 `VLCKit.xcframework` 提交到 Git：解压后约 2.6 GB，下载包约 861 MB。框架由 `scripts/fetch_vlckit.sh` 放入 `macos/Vendor/vlckit-spm/`，后者再以 SwiftPM 本地 path package 的形式提供给 BZPlayer。当前锁定 archive 的 SHA-256 为 `2dc35b65bb9efc4ef792737af026c33053f3ea6d89244e7e8aa46ab57a0e9b8e`，大小为 `861112270` bytes。

## 依赖结构

```text
scripts/fetch_vlckit.sh
  -> macos/Vendor/vlckit-spm/VLCKit.xcframework  (忽略，不入库)
  -> macos/Vendor/vlckit-spm/Package.swift       (本地 SwiftPM 包)
  -> macos/Vendor/vlckit-spm/VLCKIT.lock         (锁定版本、URL、SHA、大小)
  -> macos/BZPlayer/Package.swift                (path: ../Vendor/vlckit-spm)
  -> SwiftPM release build
  -> .build/.../VLCKit.framework                  (构建派生产物)
  -> BZPlayer.app/Contents/Frameworks/VLCKit.framework
```

`macos/Vendor/vlckit-spm` 是一个很薄的包装包。它的二进制 target 指向本地 XCFramework，`VLCKitSPM` target 再重新导出 `VLCKit`。应用依赖 `VLCKitSPM`，因此不用在业务代码中关心 XCFramework 的目录布局。

不能将 `.build/index-build`、`.build/artifacts` 当作共享依赖目录：它们都是 SwiftPM 的派生缓存，会随 Swift 版本、架构、构建配置和依赖图变化。唯一的框架源是 Vendor 目录；构建目录和 `.app` 内的 framework 都是可删除、可重建的副本。

## 日常构建与安装

首次构建或清理 Vendor 后执行：

```zsh
zsh scripts/fetch_vlckit.sh
swift test --package-path macos/BZPlayer
cd macos/BZPlayer && swift build -c release --product BZPlayer
zsh scripts/install_macos_app.sh
```

安装脚本会停止旧进程，重新构建 release 产品，将 `VLCKit.framework` 复制到 `/Applications/BZPlayer.app/Contents/Frameworks`，为可执行文件写入 `@executable_path/../Frameworks`，再前台启动应用。只运行 `swift build --show-bin-path` 不会编译源码，不能作为发布构建命令。

可用以下命令确认最终应用真正加载的是预期框架，而不是构建缓存或系统中的其他副本：

```zsh
APP="/Applications/BZPlayer.app"
otool -l "$APP/Contents/MacOS/BZPlayer" | rg '@executable_path/../Frameworks'
shasum -a 256 \
  macos/Vendor/vlckit-spm/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit \
  "$APP/Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit"
strings "$APP/Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit" | rg 'LibVLC/4\\.0\\.0-dev'
```

两项 SHA-256 必须相同，`otool` 必须显示 app bundle rpath。最后一条仅用于确认大版本运行时标识，不替代完整测试。

## 升级到新的 VLC 4 内测版

升级前先确认网络类型。下载包很大；若 `check_network.py` 报告个人热点，必须先取得确认。

```zsh
python3 ~/.codex/skills/pixian-dev-workflow/scripts/check_network.py
```

随后按以下顺序操作：

1. 从可信发布源确认候选版本、macOS universal XCFramework、发布 SHA-256、archive 大小和最小 macOS 要求。不要以“latest”字符串或未经校验的第三方重打包替代具体版本号。
2. 在 `scripts/fetch_vlckit.sh` 同步更新 `VLCKIT_VERSION`、`ZIP_URL`、`EXPECTED_SHA`、`EXPECTED_SIZE` 和文件顶部说明；在 `macos/BZPlayer/Package.swift` 与本手册更新锁定版本。
3. 将旧二进制目录移到被忽略的备份目录，或确认不需要回滚后删除：`mv macos/Vendor/vlckit-spm/VLCKit.xcframework macos/Vendor/vlckit-spm/.cache/VLCKit.xcframework.<旧版本>.backup`。拉取脚本通过 `VLCKIT.lock` 防止目录存在时误用旧版。
4. 执行 `zsh scripts/fetch_vlckit.sh`，下载完成后重新计算 archive SHA-256，并用 `plutil -p .../Info.plist` 确认含 `macos-arm64_x86_64` slice。
5. 运行测试、release 构建和安装流程。不要复用旧 `.build` 是否成功作为升级结论。
6. 完成下方播放回归、记录实测机器与结论，再提交版本号、文档和锁定信息。

升级时不要手动替换 `.build/index-build`、`.build/artifacts`、`dist` 或 `/Applications/BZPlayer.app` 内的 framework。这些目录只能由 SwiftPM、打包脚本和安装脚本生成；手工共享会掩盖 ABI/架构或 rpath 不一致。

## VLC 4 兼容性约束

`VLCPlayer` 针对 VLCKit 4 有以下刻意保留的实现：

- 使用 `--vout=samplebufferdisplay`。macOS 26 上 OpenGL `macosx` / `caopengllayer` vout 可能在渲染线程断言并在约 15 秒后终止；`avsamplebuffer` 是音频输出模块，不能替代视频 vout。
- 不传已移除的 `--avcodec-hw`，也不强制 `:codec=videotoolbox`。VLC 应自行选择 H.264/HEVC 的硬件路径；强制 VideoToolbox 会使不少设备上的 AV1 (`av01`) 无法回退到 `dav1d` / `libavcodec`。
- 每次载入媒体会等旧 player 进入 stopped/error，再新建 `VLCMediaPlayer`。VLCKit 4 将自然结束和 stop 都表现为 `.stopped`，代码以媒体代次、通知解绑和 `shouldPlay` 区分真实 EOF 与内部切换。
- 倍速、音频延迟、字幕字体和字幕背景是不随新 player 自动保留的配置。重载和进入 playing 后会重新应用；这是防止切换文件或内核后状态丢失的必要步骤。

## AV1 路由与回归

AV1 不是“不能使用 VLC”。路由策略按容器和失败路径选择更合适的默认后端：

- `mp4`、`mov`、`m4v` 等 AVPlayer 可处理的容器，AV1 默认使用 AVPlayer，优先功耗和系统硬件解码。
- `mkv`、`webm` 等 AVPlayer 不支持的容器直接使用 VLC。
- 原生后端播放失败时自动回退 VLC；用户也能在界面中手动切换至 VLC。
- 若两个后端均失败，界面报告 AV1 播放失败，不把内部的状态切换误报为成功。

每次升级 VLCKit 4 后，至少在目标 macOS 和 Apple Silicon 机器上验证以下场景：

| 场景 | 期望结果 |
| --- | --- |
| AV1 MP4 | 默认 AVPlayer 播放；失败后可回退 VLC，音视频与字幕正常 |
| AV1 MKV / WebM | 默认 VLC，有画有声，可拖动、暂停、恢复与结束 |
| H.264 / HEVC | VLC 与 AVPlayer 均可播放；VLC 连续播放超过 15 秒不崩溃 |
| VLC 字幕与音轨 | 内嵌/外挂字幕、字幕关闭、音轨切换正确生效 |
| 倍速与延迟 | 切换文件、暂停恢复、拖动后保持设置；音频延迟切换 VLC |
| 后端切换 | 保持当前时间和暂停状态；不出现重复 EOF、黑屏或旧回调覆盖新媒体 |
| 打包应用 | 从 `/Applications/BZPlayer.app` 启动，非构建目录启动也能加载 VLCKit |

保留测试媒体的编码、封装、分辨率、时长、字幕格式、音轨信息和失败日志。只有 release build、打包验证和以上关键播放路径均通过，才可以宣称内核升级完成。

## CI 与发布注意事项

GitHub Actions 在构建前运行 `zsh scripts/fetch_vlckit.sh`，随后必须执行 `swift build -c release --product BZPlayer`，不能仅计算 `--show-bin-path`。本地安装和 CI 都调用 `scripts/build_macos_app.sh`，以保持 framework 嵌入和 rpath 修复一致。若 CI 缓存了旧 `VLCKit.xcframework`，`VLCKIT.lock` 不匹配会直接失败，避免静默发布旧内核。

目前 CI 的版本来自 `GITHUB_RUN_NUMBER - 1`，本地应用版本来自最新 Git tag；二者是两套机制。发布前应确认二者是否需要对外保持同一版本号，避免 DMG、应用 About 页面和 Git tag 出现不一致。
