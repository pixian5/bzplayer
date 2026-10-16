# VLC 内核维护

提炼自 `docs/VLC4_MAINTENANCE.md`。**维护 VLC 内核时的唯一操作入口**是这份手册，不要直接改 `.build`、`artifacts` 或应用包内 framework。

## 1. 版本与依赖结构

【结论】播放内核锁定 `VLCKit 4.0.0-alpha.21`（VideoLAN `4.0.0a21` / 运行时 `libvlc 4.0.0-dev`），是明确锁定的**内测二进制**，`swift build` **不会自动升级**。
【避坑要点】升级必须**同时**改下载地址、SHA-256、大小、文档与回归结果，否则源码/缓存/`.app` 会用不同框架。
【依据/来源】`docs/VLC4_MAINTENANCE.md`。

依赖链：

```text
scripts/fetch_vlckit.sh
  -> macos/Vendor/vlckit-spm/VLCKit.xcframework   (忽略，不入库；解压约 2.6 GB)
  -> macos/Vendor/vlckit-spm/Package.swift        (本地 SwiftPM path 包)
  -> macos/Vendor/vlckit-spm/VLCKIT.lock          (版本/URL/SHA/大小四要素)
  -> macos/BZPlayer/Package.swift                 (path: ../Vendor/vlckit-spm)
  -> .build/.../VLCKit.framework                  (构建派生产物)
  -> BZPlayer.app/Contents/Frameworks/VLCKit.framework
```

锁定信息（当前）：archive SHA-256 = `2dc35b65bb9efc4ef792737af026c33053f3ea6d89244e7e8aa46ab57a0e9b8e`，大小 = `861112270` bytes（约 861 MB）。**不把 xcframework 提交进 Git**。

【避坑要点】`.build/index-build`、`.build/artifacts` 是 SwiftPM 派生缓存，**不能当共享依赖目录**；唯一框架源是 Vendor 目录。

## 2. 日常构建与安装

```zsh
zsh scripts/fetch_vlckit.sh
swift test --package-path macos/BZPlayer
cd macos/BZPlayer && swift build -c release --product BZPlayer
zsh scripts/install_macos_app.sh
```

【避坑要点】只跑 `swift build --show-bin-path` **不会编译源码**，不能作为发布构建命令。

验证应用真正加载了预期框架：

```zsh
APP="/Applications/BZPlayer.app"
otool -l "$APP/Contents/MacOS/BZPlayer" | rg '@executable_path/../Frameworks'
shasum -a 256 \
  macos/Vendor/vlckit-spm/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit \
  "$APP/Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit"
strings "$APP/Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit" | rg 'LibVLC/4\.0\.0-dev'
```

两项 SHA-256 必须相同，`otool` 必须显示 app bundle rpath。

## 3. 升级到新 VLC 4 内测版

【避坑要点】下载包很大（约 861 MB），升级前先确认网络类型；若为个人热点须先取得确认。**不要用 "latest" 字符串或第三方重打包**替代具体版本号。

1. 从可信源确认候选版本、universal XCFramework、SHA-256、archive 大小与最低 macOS。
2. 同步更新 `scripts/fetch_vlckit.sh` 的 `VLCKIT_VERSION`/`ZIP_URL`/`EXPECTED_SHA`/`EXPECTED_SIZE`，以及 `macos/BZPlayer/Package.swift` 与本手册。
3. 旧二进制先移入被忽略的 `.cache/` 备份（或确认不需回滚后删除）。
4. 执行 `zsh scripts/fetch_vlckit.sh`，重算 SHA-256，并用 `plutil -p .../Info.plist` 确认含 `macos-arm64_x86_64` slice。
5. 跑测试、release 构建、安装。**不要复用旧 `.build` 是否成功作为结论**。
6. 完成下方回归、记录实测机器与结论，再提交版本号与锁定信息。

## 4. VLC 4 刻意保留的实现（重构必须保留）

- 使用 `--vout=samplebufferdisplay`：macOS 26 上 OpenGL `macosx`/`caopengllayer` vout 可能断言后终止。
- 不传已移除的 `--avcodec-hw`，不强制 `:codec=videotoolbox`：强制 VideoToolbox 会使部分设备 AV1 无法回退到 `dav1d`/`libavcodec`。
- 每次载入媒体先等旧 player 进入 stopped/error 再建新 `VLCMediaPlayer`；以媒体代次、通知解绑、`shouldPlay` 区分真实 EOF 与内部切换。
- 倍速、音频延迟、字幕字体/背景**不随新 player 自动保留**，重载后需重新应用。
- `VLCVideoView` 预登记 + 分配媒体前绑定 drawable，避免切 VLC 时数秒首帧卡顿。
- seek 直接写 `mediaPlayer.time`，**不得**人为"暂停→定位→延迟恢复"（VLCKit 4 异步状态通知会使恢复竞态丢失，把播放器留在暂停态）。

## 5. AV1 路由与回归要点

【结论】AV1 **不是"不能用 VLC"**：mp4/mov/m4v 默认 AVPlayer（省电、系统硬解），mkv/webm 直接 VLC，原生失败自动回退 VLC，两者都失败则明确报错。

升级 VLCKit 4 后**至少**在目标 macOS + Apple Silicon 上验证：

| 场景 | 期望结果 |
|---|---|
| AV1 MP4 | 默认 AVPlayer；失败可回退 VLC，音视频/字幕正常 |
| AV1 MKV / WebM | 默认 VLC，有画有声，可拖动/暂停/恢复/结束 |
| H.264 / HEVC | 两后端均可播；VLC 连续播放超 15 秒不崩溃 |
| VLC 字幕与音轨 | 内嵌/外挂字幕、关闭字幕、音轨切换生效 |
| 倍速与延迟 | 切文件/暂停恢复/拖动后保持设置 |
| 后端切换 | 保持当前时间与暂停状态；无重复 EOF/黑屏/旧回调覆盖 |
| 打包应用 | 从 `/Applications/BZPlayer.app` 启动也能加载 VLCKit |

只有 release build + 打包验证 + 以上关键路径全通过，才可宣称内核升级完成。

## 6. CI 注意事项

【结论】CI 构建前运行 `fetch_vlckit.sh`，随后必须 `swift build -c release --product BZPlayer`；本地与 CI 都调用 `scripts/build_macos_app.sh` 以保持一致。
【避坑要点】CI 若缓存了旧 `VLCKit.xcframework`，`VLCKIT.lock` 不匹配会直接失败，避免静默发布旧内核。

## 存疑/未验证

- "macOS 26 上 OpenGL vout 会断言"来自维护手册，**本次未独立复核**（属内核经验，升级时按回归清单再验证）。
- 升级步骤中的下载地址/大小等**具体数值会变**，请以 `VLCKIT.lock` 与 `fetch_vlckit.sh` 当前内容为准。
