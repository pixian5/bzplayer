import XCTest
@testable import BZPlayerCore

/// 后端路由的回归测试。
///
/// 对应真实问题：MP3 装在 MP4 容器内时，AVFoundation 既不识别也不解码音轨
/// （实测 audioTracks=0 却 isPlayable=true，不报错、不触发失败回退），必须在路由阶段判给 VLC。
/// 这些用例锁住"容器 × 编码"的组合判断，防止再次退化成只看编码名不看容器。
final class BackendRoutingTests: XCTestCase {

    // MARK: - 必须走 VLC 的组合

    func testMP3InMP4NeedsVLC() {
        XCTAssertTrue(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: ["mp3"]),
            "MP3 装在 MP4 内必须走 VLC"
        )
    }

    func testMPEG1And2AudioInMP4NeedVLC() {
        XCTAssertTrue(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: ["mp1"]),
            "MP1 装在 MP4 内必须走 VLC"
        )
        XCTAssertTrue(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "m4v", audioCodecs: ["mp2"]),
            "MP2 装在 M4V 内必须走 VLC"
        )
    }

    func testMP3InOtherMP4FamilyContainersNeedsVLC() {
        for ext in ["m4v", "m4a", "3gp", "3g2", "f4v"] {
            XCTAssertTrue(
                BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: ext, audioCodecs: ["mp3"]),
                "MP3 装在 \(ext) 内必须走 VLC"
            )
        }
    }

    func testDetectionIsCaseInsensitive() {
        XCTAssertTrue(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "MP4", audioCodecs: ["MP3"]),
            "扩展名与编码名的大小写不应影响判断"
        )
    }

    func testUnsafeCodecAmongMultipleAudioStreamsNeedsVLC() {
        XCTAssertTrue(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: ["aac", "mp3"]),
            "多音轨中只要有一条不安全就应走 VLC"
        )
    }

    // MARK: - 不应误伤的组合（保持原生，省电）

    func testAACInMP4StaysNative() {
        XCTAssertFalse(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: ["aac"]),
            "AAC-in-MP4 应继续走原生，不能误伤"
        )
    }

    func testOtherSafeCodecsInMP4StayNative() {
        for codec in ["ac3", "eac3", "alac", "opus", "flac"] {
            XCTAssertFalse(
                BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: [codec]),
                "\(codec)-in-MP4 应继续走原生，不能误伤"
            )
        }
    }

    func testPlainMP3FileStaysNative() {
        XCTAssertFalse(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp3", audioCodecs: ["mp3"]),
            "纯 .mp3 文件容器不是 MP4 系列，AVFoundation 可播，不应被强制走 VLC"
        )
    }

    func testNonMP4ContainerIsNotHandledHere() {
        // mkv/webm 等由 chooseBackend 的容器规则统一走 VLC，不在这个"容器 × 编码"判断里处理，
        // 这里断言它不会被重复判定，避免两处规则互相掩盖。
        XCTAssertFalse(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mkv", audioCodecs: ["mp3"]),
            "mkv 由容器规则处理，此判断不应介入"
        )
    }

    func testNoAudioStreamStaysNative() {
        XCTAssertFalse(
            BackendRoutingCore.mp4FamilyAudioNeedsVLC(containerExtension: "mp4", audioCodecs: []),
            "没有音轨时不应触发该规则"
        )
    }

    // MARK: - 容器识别

    func testIsMP4FamilyContainer() {
        XCTAssertTrue(BackendRoutingCore.isMP4FamilyContainer("mp4"))
        XCTAssertTrue(BackendRoutingCore.isMP4FamilyContainer("M4V"))
        XCTAssertTrue(BackendRoutingCore.isMP4FamilyContainer("m4a"))
        XCTAssertFalse(BackendRoutingCore.isMP4FamilyContainer("mkv"))
        XCTAssertFalse(BackendRoutingCore.isMP4FamilyContainer("mp3"))
        XCTAssertFalse(BackendRoutingCore.isMP4FamilyContainer("mov"))
    }

    // MARK: - 路由决策顺序（chooseBackend 的短路顺序，锁死防回归）

    /// 核心回归点：AV1 分支会短路走原生，若把 MP4+不安全音频的判据排在它后面，
    /// "AV1 视频 + MP3 音频"就会被判成原生 —— 画面正常但静音，且不报错。
    func testAV1WithMP3InMP4RoutesToVLC() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: true,
            hasAV1: true,
            ffprobePrefersVLC: nil
        )
        XCTAssertEqual(decision, .vlc, "AV1 + MP3-in-MP4 必须走 VLC，不能因 AV1 短路成原生而静音")
    }

    func testAV1WithSafeAudioStaysNative() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: true,
            ffprobePrefersVLC: nil
        )
        XCTAssertEqual(decision, .native, "AV1 且音频安全时应走原生硬件解码省电")
    }

    /// AV1 分支短路，优先于 ffprobe 的判断（保持既有行为）。
    func testAV1ShortCircuitsBeforeFFprobeOpinion() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: true,
            ffprobePrefersVLC: true
        )
        XCTAssertEqual(decision, .native)
    }

    func testNonNativeContainerWinsOverAV1() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: true,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: true,
            ffprobePrefersVLC: nil
        )
        XCTAssertEqual(decision, .vlc)
    }

    func testAudioDelayWinsOverAV1() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: true,
            mp4FamilyAudioUnavailable: false,
            hasAV1: true,
            ffprobePrefersVLC: nil
        )
        XCTAssertEqual(decision, .vlc)
    }

    func testFFprobePrefersVLCRoutesToVLC() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: false,
            ffprobePrefersVLC: true
        )
        XCTAssertEqual(decision, .vlc)
    }

    /// ffprobe 认为安全时不能直接判原生 —— 后面还有 h264 解码错误扫描需要执行。
    func testFFprobeSaysSafeNeedsFurtherProbe() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: false,
            ffprobePrefersVLC: false
        )
        XCTAssertEqual(decision, .needsFurtherProbe)
    }

    /// ffprobe 缺失（外置可选依赖未安装）时交给调用方用 AVAsset 继续探测。
    func testFFprobeMissingNeedsFurtherProbe() {
        let decision = BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: false,
            hasAV1: false,
            ffprobePrefersVLC: nil
        )
        XCTAssertEqual(decision, .needsFurtherProbe)
    }
}
