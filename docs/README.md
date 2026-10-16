# docs 索引

本目录存放项目相关的分析、方案、经验与维护文档。命名规范：`YYYYMMDD-HHMM-<标题>-<模型名>.md`。

## 分析与根因

- [AV 内核 MP3-in-MP4 无音轨根因分析（2026-10-16）](20261016-2210-AV内核MP3-in-MP4无音轨根因分析-DeepSeek-V4.1-Flash.md) — 样本 `ezgif.com-video-merger.mp4`：MP3 封装在 MP4 内，AVFoundation 无法解码音轨。

## 修复记录

- [修复：MP3-in-MP4 强制走 VLC 后端（2026-10-16）](20261016-2247-AV内核MP3-in-MP4强制走VLC修复-hy3.md) — 后端路由把 MP3 当原生安全、未结合容器判断，导致 MP3-in-MP4 误走 AVPlayer 无音轨；已改 `PlayerViewModel.shouldPreferVLC` 强制 VLC，构建安装并提交。

## 维护手册

- [VLC 4 维护手册](VLC4_MAINTENANCE.md) — VLCKit 依赖结构、锁定版本、离线缓存、升级步骤、AV1 回归清单（维护 VLC 内核唯一入口）。

## 项目早期文档（2026-09-29）

- [项目详细分析与开发建议](202609292334项目详细分析与开发建议.md)
- [当前开发进度](20260929-2334-当前开发进度-未标注.md)
- [下一步待实现](20260929-2334-下一步待实现-未标注.md)
