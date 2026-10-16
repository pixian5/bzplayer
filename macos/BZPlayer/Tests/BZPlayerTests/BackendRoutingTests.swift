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
}
