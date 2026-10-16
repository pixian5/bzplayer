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
}
