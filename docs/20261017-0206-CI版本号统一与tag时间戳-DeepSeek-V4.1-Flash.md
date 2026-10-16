# CI 版本号统一并给 tag 加时间戳

- 时间：2026-10-17 02:06
- 模型：DeepSeek-V4.1-Flash
- 性质：**CI 配置修改 + 文档更新**（无 app 源码改动，故 `VERSION` 不递增，保持 `244`）
- 前置文档：[后端路由六项审查修复](20261017-0146-后端路由六项审查修复-DeepSeek-V4.1-Flash.md)

---

## 一、动机

上一轮已把**本机安装脚本**的版本源从 git tag 改为根目录 `VERSION`，但 CI 仍用 `GITHUB_RUN_NUMBER - 1`，于是出现两套版本机制：

| 来源 | 旧机制 | 结果 |
|---|---|---|
| 根 `VERSION` 文件 | 手工递增 | `244` |
| 本机 `/Applications/BZPlayer.app` | 读 `VERSION` | `244` |
| CI 构建产物 / Release tag | `GITHUB_RUN_NUMBER - 1` | `v240`（独立计数） |

**症结**：若直接把 CI 的 tag 也改成 `v${VERSION}`（不含时间），则"仅改文档、不递增 VERSION"的提交会与上一个提交**撞同名 tag** —— `softprops/action-gh-release` 指向已存在的 tag/release 会报错，CI 变红。

## 二、方案：tag 追加「年月日-时分」

按使用者指示，tag 追加当前时间，从根上保证唯一：

```yaml
- name: Compute version
  run: |
    VERSION="$(tr -d '[:space:]' < VERSION)"
    STAMP="$(TZ='Asia/Singapore' date +%Y%m%d-%H%M)"
    echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
    echo "tag=v${VERSION}-${STAMP}" >> "$GITHUB_OUTPUT"
```

- **`version`（app 版本串）**：仍是纯数字 `VERSION`（`244`）。**必须纯数字** —— Apple 要求 `CFBundleShortVersionString` 为 1–3 个点分整数，带连字符的时间戳写进去会不合法。所以**时间戳只加在 tag 上**。
- **`tag`（Release 标识 / DMG 文件名 / artifact 名）**：`v244-20261017-0206`。
- **时区取东八区 `Asia/Singapore`**：与使用者本地时钟一致；若用 runner 默认 UTC，会出现"明明今天提交却记为昨天"的错觉（实测 UTC 为 `20261016-1806`，SGT 为 `20261017-0206`）。

修改后三条路径**同源**：`VERSION=244` → 本机 app 版本串 `244` → CI app 版本串 `244`，仅 Release tag 多一个时间戳后缀。

## 三、为什么这样能避免冲突

`GITHUB_RUN_NUMBER` 天然唯一但**与语义版本脱节、且会跳号**（统计所有 workflow 运行，含失败/重跑）。改为「`VERSION` + 时间戳」后：

- 改源码的提交：`VERSION` 递增 → tag `v245-...`；
- 只改文档的提交：`VERSION` 不变 → tag 靠**不同的时间戳**区分，不撞名；
- 因此 CI 的 Release 步骤不会再因同名 tag 失败，`VERSION` 也无需为"仅文档提交"而被迫递增（符合"只改文档不递增"的既定规则）。

## 四、验证

- 本地实跑同一段 shell，输出 `version=244`、`tag=v244-20261017-0206`；`git check-ref-format refs/tags/v244-20261017-0206` 通过（tag 名合法）。
- 时区核对：`date -u` = `20261016-1806`，`TZ='Asia/Singapore' date` = `20261017-0206`，确认 `TZ` 生效。
- 未改任何 app 源码，故未重跑构建；未推送 tag（由 CI 自动创建），本轮只提交 CI 配置与文档。

## 五、残留与建议

- **同一分钟内连续两次 push 仍可能撞名**（时间精度到分钟）。若要彻底消除，可再追加 run number，例如 `v244-20261017-0206-123`。当前未加，按使用者指定的"年月日、时分"实现。
- CI 的 `swift test` 仍是构建前回归；建议后续加 `concurrency` 取消旧构建（分析文档 P1-4 建议，仍未实施）。
- 只改文档的提交**也会发一次 Release**（与旧行为一致，未改）。

## 六、版本与提交

- `VERSION`：**保持 244**（本轮无 app 源码改动；遵循"只改文档/配置不递增"）。
- 本轮改动文件：`.github/workflows/build-and-release.yml`、`readme.md`、`文档索引.md`、`经验/构建发布与版本号.md`、本文件。
