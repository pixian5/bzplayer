import Foundation

/// 随机访问的字节源。抽象出来是为了让 MP4 结构解析能用内存数据在单元测试里驱动，
/// 而不必依赖真实文件，也不必把整个文件读进内存。
public protocol MP4ByteSource {
    /// 总字节数。
    var byteCount: Int { get }

    /// 从 `offset` 起读取 `count` 字节。
    /// 约定：返回的 Data 下标从 0 开始；越界或读取失败返回 `nil`。
    func read(at offset: Int, count: Int) -> Data?
}

/// 基于 `FileHandle` 的真实文件实现：按需 seek + 读，不把整个文件读进内存。
/// 只读 box 头部与少量 payload，因此对几百 MB / 几 GB 的文件也几乎是常数开销。
public final class FileMP4ByteSource: MP4ByteSource {

    private let handle: FileHandle
    public let byteCount: Int

    public init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size <= UInt64(Int.max) else { return nil }
        self.handle = handle
        self.byteCount = Int(size)
    }

    public func read(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset + count <= byteCount else { return nil }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    deinit {
        try? handle.close()
    }
}

/// 轻量解析 ISO BMFF（MP4 系列）容器的 box 结构，判断容器是否**声明**了音频轨。
///
/// 为什么需要它：AVFoundation 对「MP3 装在 MP4 容器内」这类组合会**静默丢弃**音轨
/// （实测 `audioTracks` 为空、`isPlayable` 仍为 `true`，不报错、不触发失败回退）。
/// 于是只看 AVFoundation 无法区分两种情况：
/// - 文件本来就没有音轨（如无声录屏）——应保持原生，享受硬件解码、省电；
/// - 文件有音轨但被丢弃——必须交给 VLC，否则用户侧表现为"能放、没声、不报错"。
///
/// 直接读容器字节里 `moov/trak/mdia/hdlr` 的处理器类型即可精确区分：
/// handler_type 为 `soun` 表示该轨道是音频轨。
public enum MP4ContainerInspector {

    /// 容器对音频轨的声明情况。
    public enum AudioTrackPresence: Equatable {
        /// 至少发现一个 handler_type 为 `soun` 的轨道（容器声明有音频）。
        case declared
        /// 遍历完整、结构正常，但没有任何 `soun`（容器本来就没有音频轨）。
        case none
        /// 结构异常 / 解析失败，无法判定。
        case unknown
    }

    /// 需要向下递归的容器 box（音频轨位于 `moov → trak → mdia → hdlr`）。
    private static let nestedBoxes: Set<String> = ["moov", "trak", "mdia"]

    /// 允许的最大递归深度，防止异常文件造成无限递归。
    private static let maxDepth = 6

    /// 判断容器是否声明了音频轨。解析失败返回 `.unknown`，由调用方决定策略。
    public static func audioTrackPresence(in source: MP4ByteSource) -> AudioTrackPresence {
        var state = WalkState()
        walk(source: source, start: 0, end: source.byteCount, depth: 0, state: &state)
        if state.foundSoun { return .declared }
        return state.malformed ? .unknown : .none
    }

    // MARK: - 内部实现

    /// 遍历过程中的状态（用结构体承载，避免多层返回值）。
    private struct WalkState {
        var foundSoun = false
        var malformed = false
    }

    /// 一个 box 头：类型、含头部的总大小、头部长度。
    private struct BoxHeader {
        let type: String
        let size: Int
        let headerLength: Int
    }

    /// 在 `[start, end)` 范围内顺序遍历 box，必要时递归进容器 box。
    private static func walk(source: MP4ByteSource, start: Int, end: Int, depth: Int, state: inout WalkState) {
        if state.foundSoun { return }
        guard depth <= maxDepth else {
            state.malformed = true
            return
        }

        var cursor = start
        while cursor + 8 <= end {
            guard let header = readBoxHeader(source: source, at: cursor) else {
                state.malformed = true
                return
            }
            // size == 0 表示该 box 一直延伸到文件末尾。
            // ⚠️ 必须先判边界再相加：64 位 largesize 可能接近 Int.max，
            // `cursor + size` 会整数溢出并让整个进程崩溃（Swift 溢出即 trap）。
            let boxEnd: Int
            if header.size == 0 {
                boxEnd = end
            } else {
                guard header.size <= end - cursor else {
                    state.malformed = true
                    return
                }
                boxEnd = cursor + header.size
            }
            guard header.headerLength <= end - cursor else {
                state.malformed = true
                return
            }
            let bodyStart = cursor + header.headerLength
            guard bodyStart <= boxEnd else {
                state.malformed = true
                return
            }

            if header.type == "hdlr" {
                // hdlr payload 起始：version(1) + flags(3) + predefined(4) + handler_type(4)。
                // handler_type 位于 bodyStart + 8，音频轨为 "soun"。
                // 先确认 box 内确实还有 12 字节，避免截断的 hdlr 读到下一个 box 的字节而误匹配。
                if boxEnd - bodyStart >= 12,
                   let data = source.read(at: bodyStart, count: 12),
                   data.count == 12,
                   data[data.startIndex + 8 ..< data.startIndex + 12] == Data("soun".utf8) {
                    state.foundSoun = true
                    return
                }
            } else if nestedBoxes.contains(header.type) {
                walk(source: source, start: bodyStart, end: boxEnd, depth: depth + 1, state: &state)
                if state.foundSoun { return }
            }

            cursor = boxEnd
            if header.size == 0 { return }
        }
    }

    private static func readBoxHeader(source: MP4ByteSource, at offset: Int) -> BoxHeader? {
        // 先只读 8 字节基础头。若一次性读 16 字节，文件末尾那种 8 字节的小 box
        // （如 free/skip 填充）会读取越界返回 nil，被误判成"结构异常"→ 保守走 VLC，
        // 反而误伤本就无音轨的静音 MP4（正是本解析器要避免的）。
        guard let base = source.read(at: offset, count: 8), base.count == 8 else { return nil }
        let typeRange = base.startIndex + 4 ..< base.startIndex + 8
        guard let type = String(data: base[typeRange], encoding: .ascii) else { return nil }

        var size = Int(readUInt32(base, at: 0))
        var headerLength = 8
        if size == 1 {
            // size == 1：真正的 64 位大小（largesize）紧跟其后 8 字节。
            guard let extra = source.read(at: offset + 8, count: 8), extra.count == 8 else { return nil }
            let large = readUInt64(extra, at: 0)
            guard large <= UInt64(Int.max) else { return nil }
            size = Int(large)
            headerLength = 16
        }
        return BoxHeader(type: type, size: size, headerLength: headerLength)
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        let base = data.startIndex + index
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    private static func readUInt64(_ data: Data, at index: Int) -> UInt64 {
        (UInt64(readUInt32(data, at: index)) << 32) | UInt64(readUInt32(data, at: index + 4))
    }
}
