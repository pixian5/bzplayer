import Foundation

/// 播放后端路由的纯逻辑（不依赖 AVFoundation / VLCKit），单独放在 Core 里是为了可被单元测试覆盖。
///
/// 背景：AVFoundation 对"MP3 装在 MP4 系列容器内"这种组合既不识别也不解码音轨。
/// 实测这类文件 `audioTracks == 0` 但 `isPlayable == true`——音轨被静默丢弃且不报错，
/// 因此不会触发任何"播放失败回退"，用户侧表现就是"能放、没声、不报错"。
/// 必须在路由阶段就判出来交给 VLC，而不能指望运行时失败回退。
public enum BackendRoutingCore {

    /// MP4 系列容器（ISO BMFF / M4V / 3GP 等）。这类容器里存在 AVFoundation 的音频封装兼容盲区。
    public static let mp4FamilyContainers: Set<String> = ["mp4", "m4v", "m4a", "3gp", "3g2", "f4v"]

    /// 装在 MP4 系列容器里、AVFoundation 无法解码的音频编码。
    /// - `mp3`：最常见的 MP3-in-MP4（音频 fourcc 标为 `mp4a`，真实编码是 mp3）。
    /// - `mp1` / `mp2`：同属 MPEG 音频层，在 MP4 内同样有兼容问题。
    /// 注意：纯 `.mp3` 文件（容器不是 MP4 系列）AVFoundation 可以正常播放，不受此集合影响。
    public static let mp4FamilyUnsafeAudioCodecs: Set<String> = ["mp3", "mp1", "mp2"]

    /// 容器扩展名是否属于 MP4 系列（大小写不敏感）。
    public static func isMP4FamilyContainer(_ ext: String) -> Bool {
        mp4FamilyContainers.contains(ext.lowercased())
    }

    /// 把 AVFoundation 的音频格式子类型（fourcc）映射为 ffprobe 风格的编码名。
    ///
    /// 用途：`shouldPreferVLC(asset:)` 拿到的是子类型（如 `.mp3`），而「容器 × 编码」判据
    /// `mp4FamilyAudioNeedsVLC` 用的是编码名（如 `mp3`）。集中在这里映射，保证
    /// AVAsset 路径与 ffprobe 路径走同一套规则，不再各写一份、互相矛盾。
    /// 只覆盖 MP4 系列里原生不安全的三种 MPEG 音频层，其余返回 `nil`。
    public static func audioCodecName(fromSubtype subtype: String) -> String? {
        switch subtype.lowercased() {
        case ".mp3", "mp3 ": return "mp3"
        case ".mp2", "mp2 ": return "mp2"
        case ".mp1", "mp1 ": return "mp1"
        default: return nil
        }
    }

    /// MP4 系列容器 + 原生不可解码的音频 → 必须交给 VLC。
    ///
    /// - Parameters:
    ///   - containerExtension: 容器扩展名，如 `mp4`。
    ///   - audioCodecs: ffprobe 报告的音频流编码名（大小写不敏感）。
    /// - Returns: 需要走 VLC 返回 `true`；仍可走原生返回 `false`。
    public static func mp4FamilyAudioNeedsVLC(containerExtension: String, audioCodecs: [String]) -> Bool {
        guard isMP4FamilyContainer(containerExtension) else { return false }
        return audioCodecs.contains { mp4FamilyUnsafeAudioCodecs.contains($0.lowercased()) }
    }

    // MARK: - 路由决策（把 chooseBackend 的"短路 return 顺序"变成可单测的纯函数）

    /// 路由决策结果。
    /// - `vlc` / `native`：已由前置规则确定，直接采用。
    /// - `needsFurtherProbe`：前置规则都没命中，调用方还需继续做异步探测
    ///   （h264 解码错误扫描、ffprobe 缺失时的 AVAsset 音轨探测）。
    public enum RoutingDecision: Equatable {
        case vlc
        case native
        case needsFurtherProbe
    }

    /// 按固定优先级决定后端。**顺序即语义**：先命中的规则短路返回，调整顺序会改变行为。
    ///
    /// 抽成纯函数是为了让"规则顺序"本身能被单元测试锁住。两条关键顺序：
    /// 1. 「MP4 系列 + 不安全音频」必须排在 AV1 之前，否则 **AV1 视频 + MP3-in-MP4 会被判成原生而静音**；
    /// 2. 「ffprobe 判不安全」也必须排在 AV1 之前，否则 **AV1 视频 + 非白名单音频（dts/truehd…）同样会静音**。
    ///    AV1 只在音频安全（或无法判定为不安全）时才短路走原生省电。
    ///
    /// 昂贵判据以**惰性闭包**传入（`() async -> …`）：只有真正走到对应分支才会执行，
    /// 因此"非原生容器"或"音频延迟非 0"这类廉价规则命中时，不会白跑 AVAsset 探测。
    ///
    /// - Parameters:
    ///   - isNonNativeContainer: 扩展名属于 mkv/avi/webm 等非原生容器。
    ///   - audioDelayNonZero: 用户设置了非 0 音频延迟（只有 VLC 支持）。
    ///   - mp4FamilyAudioUnavailable: MP4 系列容器里的音频原生不可用（如 MP3-in-MP4）。惰性求值。
    ///   - hasAV1: 视频是 AV1（走系统硬件解码更省电）。惰性求值。
    ///   - ffprobePrefersVLC: ffprobe 路径的判断结果；`nil` 表示 ffprobe 不可用。惰性求值。
    public static func decide(
        isNonNativeContainer: Bool,
        audioDelayNonZero: Bool,
        mp4FamilyAudioUnavailable: () async -> Bool,
        hasAV1: () async -> Bool,
        ffprobePrefersVLC: () async -> Bool?
    ) async -> RoutingDecision {
        if isNonNativeContainer { return .vlc }
        if audioDelayNonZero { return .vlc }
        // 必须排在 AV1 之前：AV1 分支会短路走原生。
        if await mp4FamilyAudioUnavailable() { return .vlc }
        let ffprobeOpinion = await ffprobePrefersVLC()
        // 同样必须排在 AV1 之前：否则"AV1 + ffprobe 判不安全（非白名单音频）"会被 AV1 短路成原生而静音。
        if ffprobeOpinion == true { return .vlc }
        // AV1 走原生硬件解码更省电；音频安全时短路线原生。
        if await hasAV1() { return .native }
        // ffprobe 认为音频安全（false）或 ffprobe 不可用（nil）：交给调用方继续探测。
        return .needsFurtherProbe
    }
}
