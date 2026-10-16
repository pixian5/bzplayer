# AV 内核播放 MP3-in-MP4 文件"找不到音轨"根因分析

- 时间：2026-10-16 22:10
- 模型：DeepSeek-V4.1-Flash
- 样本：`/Users/x/Downloads/Nagram Desktop/ezgif.com-video-merger.mp4`（15.68 MB，1920x1080 H.264 + MP3 立体声 48 kHz 128 kbps，时长 71.73 s，编码器 `ezgif.com`）
- 性质：**纯分析，未修改任何源码**（VERSION 保持 240）

---

## 一、结论（一句话）

该文件的音频是 **MP3（MPEG-1 Layer III）被封装在 MP4 容器里**。macOS 的 AVFoundation / CoreMedia **不支持 MP4 容器内的 MP3**，解析音频轨时无法构造 `CMFormatDescription`，于是**整条音频轨被静默丢弃**；而 VLC 走 FFmpeg(libavformat) + MP3 解码器，直接按 `esds` 里的 `objectTypeIndication = 0x6B` 识别并解码，所以有声音。

**不是文件损坏，也不是本项目的解析代码写错**，而是系统媒体框架的能力边界 + 本项目路由白名单过宽共同导致。

---

## 二、证据链

### 1. ffprobe 看到的流

| 序号 | 类型 | 编码 | codec_tag | mime | 说明 |
|---|---|---|---|---|---|
| 0 | video | h264 (High, level 4.0) | `avc1` | avc1.640028 | 1920x1080, 30fps, 1.61 Mbps |
| 1 | audio | **mp3** | **`mp4a`** | **mp4a.40.34** | 48000 Hz, stereo, 128 kbps, `initial_padding=1105` |

关键：**编码是 mp3，但容器采样条目是 `mp4a`** —— 这正是"MP3 装进 MP4"的典型特征（FFmpeg 用 `mp4a` + `esds` 来描述 MP3，而不是 QuickTime 的 `.mp3` 采样描述）。

### 2. 文件内部盒（box）结构：音频采样条目是 `mp4a` + esds OTI 0x6B

`moov`（文件尾部，offset 15617222，size 63712）里的音频轨 `stsd`：

```
mp4a 采样条目（size=100）:
  6d703461                                  "mp4a"
  ... dataRefIndex=1, version=0
  channelcount = 0002  (2 声道)
  samplesize   = 0010  (16 bit)
  samplerate   = bb80 0000  (48000 Hz, 16.16 定点)
  esds (size=44):
    03 808080 1b  ES_Descriptor (len=27), ES_ID=0x0002
      04 808080 0d  DecoderConfigDescriptor (len=13)
        6b          <-- objectTypeIndication = 0x6B = MPEG-1 Audio Layer III (MP3)
        15          streamType=Audio, upstream=0
        bufferSizeDB = 000000
        maxBitrate   = 01f401 (128001)
        avgBitrate   = 01f401 (128001)
      05 808080 01 02   DecoderSpecificInfo = 0x02
      06 808080 01 02   SLConfigDescriptor = 0x02
  btrt (size=20)
```

音频轨 `edts/elst`：`seg_dur=71736, media_time=1105, rate=65536`（去掉编码器延迟 1105 个采样，属正常写法，不是问题原因）。
音频轨 `mdhd`：`timescale=48000, duration=3444433`（≈71.759 s），`hdlr=SoundHandler`，`minf/smhd` 齐备。
→ **音频轨在文件结构上完全合法、完整**，只是编码标识是 MP4 体系外的 MP3。

### 3. AVFoundation 实测：音频轨被丢弃

用 `AVURLAsset.load(.tracks)` 实测：

```
全部轨道 = 1   视频轨 = 1   音频轨 = 0   asset.isPlayable = true
  - vide  subtype=avc1  decodable=true
```

`asset.isPlayable` 依然是 **true**，`AVPlayerItem.status` 也能走到 `.readyToPlay` —— **没有任何错误抛出，只是声音消失**。这一点很重要：项目里基于"播放失败"的自动回退逻辑因此永远不会触发。

### 4. 对照实验（决定性证据）

用 ffmpeg 只改封装/编码，其余全部 `-c copy`：

| 文件 | 音频编码 | 容器采样条目 | AVFoundation 音频轨数 | 结论 |
|---|---|---|---|---|
| 原始 `ezgif.com-video-merger.mp4` | mp3 | `mp4a` (esds OTI 0x6B) | **0** | 原始问题 |
| `mp3_in_mp4.mp4`（纯 remux） | mp3 | `mp4a` (esds OTI 0x6B) | **0** | 与"文件损坏"无关，是 **MP3+MP4 组合**不被支持 |
| `mp3_in_mov.mov`（remux 到 MOV） | mp3 | **`.mp3`** | **1**（subtype=`.mp3`, decodable=true） | 同样的 MP3 数据，换成 MOV 的 `.mp3` 采样描述就能识别 |
| `aac_test.mp4`（音轨转 AAC） | aac | `mp4a` (OTI 0x40) | **1**（subtype=`aac `） | 证明 MP4 容器本身没问题，问题在 OTI |
| `audio_only.mp3`（提取为 .mp3） | mp3 | `.mp3` | **1** | AVFoundation 支持 MP3 文件，但不支持 MP3-in-MP4 |

**同一份 MP3 码流，放在 MP4 里 = 0 轨，放在 MOV 里 = 1 轨。** 这就是根因的直接证明。

---

## 三、为什么 AVFoundation 会丢轨

CoreMedia 的 ISO-BMFF（MP4/MOV）解析器只接受它认识的一批音频对象类型（OTI）：

- `0x40` MPEG-4 AAC、`0x66/0x67/0x68` AAC LC/MAIN/SSR（MPEG-2）
- ALAC、AC-3 / E-AC-3、LPCM、FLAC、Opus 等

`0x6B`（MPEG-1 Layer III）与 `0x69`（MPEG-2 Layer III）**不在支持列表内**。当解析器遇到不认识的 OTI 时：

1. 无法为该轨生成 `CMFormatDescription`；
2. 轨道对象被**静默剔除**，不出现在 `asset.tracks` / `loadTracks(withMediaType: .audio)` 中；
3. 也不报错 —— 视频轨正常，`isPlayable` 仍为 true。

AVFoundation 对 MP3 的支持只覆盖 **MPEG 音频裸流容器**（`.mp3`，采样描述 `.mp3`）以及 **QuickTime MOV 的 `.mp3` 采样描述**。QuickTime 自己的音频编码 ID 与 ISO-BMFF 的 `mp4a` 是两套体系，`.mp3` 属于前者。

VLC 之所以能播：libavformat 的 mov demuxer 解析 `esds` 拿到 OTI 0x6B 后直接映射到 `AV_CODEC_ID_MP3`，交给 libmpg123 解码，与系统框架能力无关。

---

## 四、本项目为什么会"踩中"这个坑

### 1. 路由白名单把 `mp3` 当成了"原生安全"

`macos/BZPlayer/Sources/BZPlayerApp/PlayerViewModel.swift` `shouldPreferVLC(ffprobeInfo:)`：

```swift
let nativeSafeAudioCodecs: Set<String> = [
    "aac", "ac3", "eac3", "alac", "mp3", "opus", "flac", ...   // 第 2385 行
]
if ffprobeInfo.audioStreams.contains(where: { !nativeSafeAudioCodecs.contains($0.codecName) }) {
    return true   // 走 VLC
}
```

判定只看 `codec_name`，不看容器。`mp3` 被判为安全 → 返回 false → `chooseBackend` 落到 `.native`。

**"mp3 是否原生安全"必须和容器联合判断**：
- `.mp3` 文件 / MOV 里的 `.mp3` 采样描述 → 安全
- **MP4/M4V 里的 `mp4a`+OTI 0x6B → 不安全，必须走 VLC**

同理，基于 asset 的另一条 `shouldPreferVLC(asset:)` 里把 `".mp3"` 和 `"mp4a"` 都列为安全 subtype（第 2402-2406 行）。`".mp3"` 是对的；`"mp4a"` 过宽 —— 不过这条路天然看不到 MP3-in-MP4（因为系统已经把该轨丢了），所以它反而"看起来正常"。

### 2. 自动回退到 VLC 的逻辑抓不到这种情况

`checkAndHandlePlaybackFailure` 的失败判据是：

```swift
let hasFailed = duration == 0 && (isPaused || currentTime < 0.5)
```

本文件视频轨解码正常、`duration = 71.73`，`AVPlayerItem.status` 是 `.readyToPlay`，因此：

- 不会触发 `.failed` 分支（第 2280 行）
- 不会触发 5 秒失败计时器
- **结果：原生后端静默无声地播放完整个视频**

### 3. 文件信息面板的提示与实际行为不一致

`PlayerViewModel.swift` 第 2942-2945 行：

```swift
if audioTracks.isEmpty {
    if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
        lines.append("提示：AVFoundation 未识别到音轨，但 ffprobe 检测到 \(ffprobeInfo.audioStreams.count) 条音轨。")
        lines.append("这类文件会自动切到 VLC 后端播放。")   // ← 这句话目前并没有对应实现
    }
```

文案承诺"会自动切到 VLC"，但代码里**没有任何** "ffprobe 有音轨 && AVFoundation 无音轨 → 切 VLC" 的判断（全局搜索 `audioStreams` 只有此处的展示用途）。

### 4. 音轨菜单在原生后端恒为空

`audioTrackMenuEntries()`（第 3349-3351 行）第一句就是 `guard playbackBackend == .vlc else { return [] }`，原生后端永远返回空 → 右键菜单显示"无可用音轨"（`PlayerContainerView.swift:630`）。这正是用户看到的"找不到音轨"。

---

## 五、可选修复方向（待决策，本次未实施）

按"改动量从小到大"排列：

1. **补路由规则（最小改动）**：在 `shouldPreferVLC(ffprobeInfo:)` 中增加联合判断 —— 当 `codecName == "mp3"` 且容器为 mp4/m4v/mov-`mp4a` 时返回 true。ffprobe 已经给出 `codec_tag`（本文件是 `mp4a`），可直接用于判定，**无需新增探测成本**。
   - 判据建议：`audioStreams.contains { $0.codecName == "mp3" && $0.codecTag == "mp4a" }` → 走 VLC。
   - 注意别误伤 MOV（MOV 里是 `.mp3`，`codec_tag` 会不同），需实测确认 ffprobe 对 MOV 的 `codec_tag_string` 输出。
2. **加"音轨缺失"兜底**：原生后端 `readyToPlay` 后做一次 `loadTracks(withMediaType: .audio)` 检查，若为空而 ffprobe 报告有音频流，则主动切到 VLC（这样第 2945 行的文案才成立）。
3. **原生后端补齐音轨菜单**：把菜单数据源从"仅 VLC"改为"VLC + AVFoundation 轨道"，至少让信息面板与菜单一致。
4. **不推荐**：自己用 AudioToolbox 手写 MP3 解复用（`mp4a`/OTI 0x6B 解析 + AudioConverter），成本高、收益低，VLC 后端已能覆盖。

---

## 六、给用户的临时绕过方案（不改代码）

- 直接把这个文件（或同类文件）**交给 VLC 内核播放**：在应用里手动切换后端到 VLC。
- 或者用 ffmpeg 转封装/转码后播放：
  - 只改封装（快，秒级，无损）：`ffmpeg -i in.mp4 -c copy out.mov`
  - 音轨转 AAC（兼容性最好）：`ffmpeg -i in.mp4 -c:v copy -c:a aac -b:a 128k out.mp4`

---

## 七、经验沉淀（避坑）

1. **"编码名 + 容器"才是能力判定单位。** 单看 `codec_name` 判断系统框架能否解码，一定会漏掉 MP3-in-MP4、MP3-in-MOV、PCM 各类变体等边界情况。
2. **AVFoundation 丢轨是静默的。** `isPlayable=true`、`status=.readyToPlay` 都不代表音轨被识别；必须显式 `loadTracks(withMediaType:)` 计数。
3. **`ezgif.com` 这类在线工具的产物是高危样本来源**，常出现 MP3-in-MP4、非标准 edit list、`moov` 置尾等组合，适合做回归测试素材。
4. **文案不要承诺未实现的回退行为**，否则会把"框架能力问题"误导成"项目逻辑问题"，浪费排查时间。
5. 排查此类问题的标准动作：`ffprobe -show_streams` 看编码 → 解析 `stsd`/`esds` 看 OTI → 用 `AVURLAsset.load(.tracks)` 实测 → 做"只改封装"的对照实验。
