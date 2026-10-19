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

    /// 语义提醒：**ffprobe 路径**下 `audioCodecs` 是"文件里真实存在的音频流"，
    /// 为空表示文件本来就没有音轨 —— 此时当然不该走 VLC。
    ///
    /// 注意这与 `PlayerViewModel` 里 **ffprobe 缺失**时的兜底判据方向不同：
    /// 那条路径的输入是"AVFoundation 取不到音轨"，还要叠加"容器是否声明了音频轨"才能区分
    /// "本来无音轨" 与 "音轨被静默丢弃"，见下面的 `MP4ContainerInspector` 用例。
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

    // MARK: - 子类型 → 编码名映射（AVAsset 路径与 ffprobe 路径共用同一判据）

    func testAudioSubtypeToCodecName() {
        XCTAssertEqual(BackendRoutingCore.audioCodecName(fromSubtype: ".mp3"), "mp3")
        XCTAssertEqual(BackendRoutingCore.audioCodecName(fromSubtype: "mp3 "), "mp3")
        XCTAssertEqual(BackendRoutingCore.audioCodecName(fromSubtype: ".mp2"), "mp2")
        XCTAssertEqual(BackendRoutingCore.audioCodecName(fromSubtype: ".mp1"), "mp1")
        XCTAssertNil(BackendRoutingCore.audioCodecName(fromSubtype: "mp4a"), "AAC 不应映射为不安全编码")
        XCTAssertNil(BackendRoutingCore.audioCodecName(fromSubtype: "aac "))
    }

    // MARK: - 路由决策顺序（chooseBackend 的短路顺序，锁死防回归）

    /// 核心回归点：AV1 分支会短路走原生，若把 MP4+不安全音频的判据排在它后面，
    /// "AV1 视频 + MP3 音频"就会被判成原生 —— 画面正常但静音，且不报错。
    func testAV1WithMP3InMP4RoutesToVLC() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { true },
            hasAV1: { true },
            ffprobePrefersVLC: { nil }
        )
        XCTAssertEqual(decision, .vlc, "AV1 + MP3-in-MP4 必须走 VLC，不能因 AV1 短路成原生而静音")
    }

    func testAV1WithSafeAudioStaysNative() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { true },
            ffprobePrefersVLC: { nil }
        )
        XCTAssertEqual(decision, .native, "AV1 且音频安全时应走原生硬件解码省电")
    }

    /// ffprobe 判"不安全"（非白名单音频，如 dts/truehd）必须优先于 AV1，
    /// 否则 AV1 会短路成原生而静音。
    func testAV1WithFFprobeUnsafeAudioRoutesToVLC() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { true },
            ffprobePrefersVLC: { true }
        )
        XCTAssertEqual(decision, .vlc, "AV1 + ffprobe 判不安全必须走 VLC，不能被 AV1 短路成原生")
    }

    /// ffprobe 判音频安全时，AV1 仍走原生省电。
    func testAV1WithFFprobeSafeAudioStaysNative() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { true },
            ffprobePrefersVLC: { false }
        )
        XCTAssertEqual(decision, .native, "ffprobe 判音频安全时，AV1 应走原生硬件解码")
    }

    func testNonNativeContainerWinsOverAV1() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: true,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { true },
            ffprobePrefersVLC: { nil }
        )
        XCTAssertEqual(decision, .vlc)
    }

    func testAudioDelayWinsOverAV1() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: true,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { true },
            ffprobePrefersVLC: { nil }
        )
        XCTAssertEqual(decision, .vlc)
    }

    func testFFprobePrefersVLCRoutesToVLC() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { false },
            ffprobePrefersVLC: { true }
        )
        XCTAssertEqual(decision, .vlc)
    }

    /// ffprobe 认为安全时不能直接判原生 —— 后面还有 h264 解码错误扫描需要执行。
    func testFFprobeSaysSafeNeedsFurtherProbe() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { false },
            ffprobePrefersVLC: { false }
        )
        XCTAssertEqual(decision, .needsFurtherProbe)
    }

    /// ffprobe 缺失（外置可选依赖未安装）时交给调用方用 AVAsset 继续探测。
    func testFFprobeMissingNeedsFurtherProbe() async {
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { false },
            hasAV1: { false },
            ffprobePrefersVLC: { nil }
        )
        XCTAssertEqual(decision, .needsFurtherProbe)
    }

    // MARK: - 惰性求值：用不到的判据不应被执行（避免白跑 AVAsset 探测）

    /// 记录各判据被求值的次数。
    private final class ProbeCounter {
        var mp4Audio = 0
        var av1 = 0
        var ffprobe = 0
    }

    func testCheapRuleShortCircuitsBeforeExpensiveProbes() async {
        let counter = ProbeCounter()
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: true,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { counter.mp4Audio += 1; return false },
            hasAV1: { counter.av1 += 1; return true },
            ffprobePrefersVLC: { counter.ffprobe += 1; return true }
        )
        XCTAssertEqual(decision, .vlc)
        XCTAssertEqual(counter.mp4Audio, 0, "非原生容器命中后不应再做 MP4 音频探测")
        XCTAssertEqual(counter.av1, 0, "非原生容器命中后不应再做 AV1 探测")
        XCTAssertEqual(counter.ffprobe, 0)
    }

    func testUnsafeAudioShortCircuitsBeforeAV1Probe() async {
        let counter = ProbeCounter()
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { counter.mp4Audio += 1; return true },
            hasAV1: { counter.av1 += 1; return true },
            ffprobePrefersVLC: { counter.ffprobe += 1; return nil }
        )
        XCTAssertEqual(decision, .vlc)
        XCTAssertEqual(counter.av1, 0, "音频已判不安全并短路走 VLC，不应再做 AV1 探测")
        XCTAssertEqual(counter.ffprobe, 0)
    }

    func testFFprobeUnsafeShortCircuitsBeforeAV1Probe() async {
        let counter = ProbeCounter()
        let decision = await BackendRoutingCore.decide(
            isNonNativeContainer: false,
            audioDelayNonZero: false,
            mp4FamilyAudioUnavailable: { counter.mp4Audio += 1; return false },
            hasAV1: { counter.av1 += 1; return true },
            ffprobePrefersVLC: { counter.ffprobe += 1; return true }
        )
        XCTAssertEqual(decision, .vlc)
        XCTAssertEqual(counter.av1, 0, "ffprobe 判不安全优先于 AV1，不应再做 AV1 探测")
    }

    // MARK: - MP4 容器解析（ffprobe 缺失时的精确兜底判据）

    func testContainerDeclaresAudioWhenSounHandlerPresent() {
        let data = makeBox("moov", makeTrack(handler: "soun"))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .declared,
            "容器里有 soun 处理器时应判为声明了音频轨"
        )
    }

    func testContainerDeclaresNoAudioWhenOnlyVideoHandler() {
        let data = makeBox("moov", makeTrack(handler: "vide"))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .none,
            "只有 vide 处理器时不应误判有音频轨（静音 MP4 要保持原生）"
        )
    }

    func testContainerFindsAudioAmongMultipleTracks() {
        let data = makeBox("moov", makeTrack(handler: "vide") + makeTrack(handler: "soun"))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .declared
        )
    }

    func testContainerIgnoresNestedMetadataHandler() {
        // udta/meta 里的 hdlr 不是轨道处理器，不应被当成音频轨。
        let meta = makeBox("udta", makeBox("meta", makeBox("hdlr", makeHandlerPayload("mdir"))))
        let data = makeBox("moov", makeTrack(handler: "vide") + meta)
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .none
        )
    }

    func testContainerReportsUnknownOnMalformedData() {
        // 声明的大小(1000)超过实际缓冲区 → 结构异常，应返回 .unknown（调用方据此保守走 VLC）。
        var data = Data()
        var size = UInt32(1000).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data("junk".utf8))
        data.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .unknown
        )
    }

    // MARK: - 容器解析的边界情况（回归用）

    func testContainerHandlesTrailingHeaderOnlyBox() {
        // 文件末尾常见的 8 字节 `free` 填充（只有头、没有 payload）不应被判成结构异常，
        // 否则静音 MP4 会被误判为 .unknown → 保守走 VLC，白白丢掉原生硬解。
        let data = makeBox("moov", makeTrack(handler: "vide") + makeBox("free", Data()))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .none,
            "末尾只有 8 字节头的 box 是合法结构，应遍历到 EOF 后判为无音频"
        )
    }

    func testContainerSupports64BitLargeSizeBox() {
        // size == 1 表示真正的 64 位大小（largesize）紧跟其后 8 字节，头部共 16 字节。
        let large = makeLargeBox("free", Data(repeating: 0, count: 4))
        let data = makeBox("moov", large + makeTrack(handler: "soun"))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .declared,
            "跳过大 size 的 free box 后仍应找到 soun 轨"
        )
    }

    func testContainerTreatsZeroSizeBoxAsExtendingToEOF() {
        // size == 0 是合法写法，表示该 box 一直延伸到文件末尾。
        var data = makeBox("moov", makeTrack(handler: "vide"))
        var zero = UInt32(0).bigEndian
        withUnsafeBytes(of: &zero) { data.append(contentsOf: $0) }
        data.append(Data("free".utf8))
        data.append(Data(repeating: 0, count: 4))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .none,
            "size == 0 应吃到 EOF 并正常结束，而不是判为结构异常"
        )
    }

    func testContainerRejectsLargeSizeBeyondBuffer() {
        // largesize 本身没超过 Int.max，但远超缓冲区剩余字节。
        // 修复前 `cursor + size` 会整数溢出直接 trap（实测 exit=133），现在应先比较再相加。
        var data = Data()
        var marker = UInt32(1).bigEndian
        withUnsafeBytes(of: &marker) { data.append(contentsOf: $0) }
        data.append(Data("free".utf8))
        var huge = UInt64(Int.max).bigEndian
        withUnsafeBytes(of: &huge) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .unknown,
            "超出缓冲区的 size 应判为结构异常，且不能因整数溢出崩溃"
        )
    }

    func testContainerRejectsLargeSizeExceedingIntMax() {
        // largesize > Int.max 无法用 Int 表示 → 头部解析失败 → 结构异常（不能崩溃）。
        var data = Data()
        var marker = UInt32(1).bigEndian
        withUnsafeBytes(of: &marker) { data.append(contentsOf: $0) }
        data.append(Data("free".utf8))
        var beyond = UInt64.max.bigEndian
        withUnsafeBytes(of: &beyond) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(
            MP4ContainerInspector.audioTrackPresence(in: DataByteSource(data: data)),
            .unknown
        )
    }

    // MARK: - 测试辅助

    /// 内存字节源，用于在没有真实文件的情况下驱动容器解析。
    private struct DataByteSource: MP4ByteSource {
        let data: Data
        var byteCount: Int { data.count }
        func read(at offset: Int, count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
            return data.subdata(in: offset ..< (offset + count))
        }
    }

    /// 构造一个 ISO BMFF box：[4 字节大小][4 字节类型][payload]。
    private func makeBox(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    /// 构造一个使用 64 位 largesize 的 box：[4 字节 1][4 字节类型][8 字节大小][payload]。
    private func makeLargeBox(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        var marker = UInt32(1).bigEndian
        withUnsafeBytes(of: &marker) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        var large = UInt64(16 + payload.count).bigEndian
        withUnsafeBytes(of: &large) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// hdlr 的 payload：version+flags(4) + predefined(4) + handler_type(4)。
    private func makeHandlerPayload(_ handlerType: String) -> Data {
        var payload = Data(repeating: 0, count: 8)
        payload.append(Data(handlerType.utf8))
        return payload
    }

    /// 一个轨道：trak → mdia → hdlr。
    private func makeTrack(handler: String) -> Data {
        makeBox("trak", makeBox("mdia", makeBox("hdlr", makeHandlerPayload(handler))))
    }
}
