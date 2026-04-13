import AVFoundation
import AVKit
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    enum PlaybackBackend: String {
        case native
        case mpv
    }

    @Published var isPaused = true
    @Published var speed: Double = 1.0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var syncText = "播放链路：系统原生"
    @Published var playlist: [URL] = []
    @Published var currentIndex: Int = -1
    @Published var windowTitle = "BZPlayer"
    @Published var fileAssociationStatus = "未执行格式关联"
    @Published var playbackEngineStatus = "播放引擎：AVPlayer"
    @Published var playbackBackend: PlaybackBackend = .native

    let mpvPlayer = MpvPlayer()
    let nativePlayer = AVPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    private var currentFileURL: URL?
    private var nativeTimeObserver: Any?
    private var nativeItemStatusObserver: NSKeyValueObservation?
    private var nativeEndObserver: NSObjectProtocol?

    override init() {
        super.init()
        bindMpvCallbacks()
        bindNativePlayer()
        selectBackend(.native)
    }

    deinit {
        if let nativeTimeObserver {
            nativePlayer.removeTimeObserver(nativeTimeObserver)
        }
        if let nativeEndObserver {
            NotificationCenter.default.removeObserver(nativeEndObserver)
        }
    }

    func attachPlayerView(_ view: MpvRenderView) {
        mpvPlayer.attach(to: view)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadPlaylist(with: url)
            openFromPlaylist(url)
        }
    }

    func play() {
        switch playbackBackend {
        case .native:
            nativePlayer.play()
            nativePlayer.rate = Float(speed)
            isPaused = false
        case .mpv:
            mpvPlayer.play()
            isPaused = false
        }
    }

    func pause() {
        switch playbackBackend {
        case .native:
            nativePlayer.pause()
        case .mpv:
            mpvPlayer.pause()
        }
        isPaused = true
        saveCurrentProgress()
    }

    func togglePause() {
        isPaused ? play() : pause()
    }

    func selectPlaylistItem(_ index: Int) {
        guard playlist.indices.contains(index) else { return }
        openFromPlaylist(playlist[index])
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let target = duration * progress
        switch playbackBackend {
        case .native:
            nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        case .mpv:
            mpvPlayer.seek(seconds: target)
        }
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.25), 16)
        switch playbackBackend {
        case .native:
            nativePlayer.rate = isPaused ? 0 : Float(speed)
        case .mpv:
            mpvPlayer.setSpeed(speed)
        }
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
    }

    func toggleFullscreen(in window: NSWindow? = nil) {
        (window ?? NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    func showFileInfo() {
        guard let url = currentFileURL else {
            showAlert(title: "文件信息", message: "当前未打开媒体文件。")
            return
        }

        Task {
            let text = await buildFileInfoText(url: url)
            await MainActor.run {
                self.showAlert(title: "文件信息", message: text)
            }
        }
    }

    func associateCommonVideoFormats() {
        let bundleID = (Bundle.main.bundleIdentifier ?? "tech.sbbz.bzplayer") as CFString
        let commonExtensions = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "mpeg", "mpg"]

        var associated: [String] = []
        var failed: [String] = []

        for ext in commonExtensions {
            guard let type = UTType(filenameExtension: ext) else {
                failed.append(ext)
                continue
            }
            let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .viewer, bundleID)
            if status == noErr {
                associated.append(ext)
            } else {
                failed.append(ext)
            }
        }

        if failed.isEmpty {
            fileAssociationStatus = "已关联：\(associated.joined(separator: ", "))"
        } else if associated.isEmpty {
            fileAssociationStatus = "关联失败：\(failed.joined(separator: ", "))"
        } else {
            fileAssociationStatus = "部分成功，已关联：\(associated.joined(separator: ", "))；失败：\(failed.joined(separator: ", "))"
        }
    }

    private func bindMpvCallbacks() {
        mpvPlayer.onTimeChanged = { [weak self] time in
            guard let self, self.playbackBackend == .mpv else { return }
            self.currentTime = time.isFinite ? time : 0
            if Int(self.currentTime * 10) % 30 == 0 {
                self.saveCurrentProgress()
            }
        }
        mpvPlayer.onDurationChanged = { [weak self] duration in
            guard let self, self.playbackBackend == .mpv else { return }
            self.duration = duration.isFinite ? duration : 0
        }
        mpvPlayer.onPauseChanged = { [weak self] paused in
            guard let self, self.playbackBackend == .mpv else { return }
            self.isPaused = paused
        }
        mpvPlayer.onFileLoaded = { [weak self] in
            guard let self, self.playbackBackend == .mpv else { return }
            self.syncText = "播放链路：mpv/libmpv"
        }
        mpvPlayer.onStatusChanged = { [weak self] status in
            guard let self, self.playbackBackend == .mpv else { return }
            self.playbackEngineStatus = status
        }
    }

    private func bindNativePlayer() {
        nativeTimeObserver = nativePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, self.playbackBackend == .native else { return }
            let seconds = time.seconds
            self.currentTime = seconds.isFinite ? max(0, seconds) : 0
            if Int(self.currentTime * 10) % 30 == 0 {
                self.saveCurrentProgress()
            }
        }

        nativeEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.playbackBackend == .native else { return }
            guard notification.object as? AVPlayerItem === self.nativePlayer.currentItem else { return }
            self.isPaused = true
        }
    }

    private func selectBackend(_ backend: PlaybackBackend) {
        playbackBackend = backend
        switch backend {
        case .native:
            playbackEngineStatus = "播放引擎：AVPlayer"
            syncText = "播放链路：系统原生"
            mpvPlayer.pause()
        case .mpv:
            playbackEngineStatus = "播放引擎：mpv/libmpv"
            syncText = "播放链路：mpv/libmpv"
            nativePlayer.pause()
        }
    }

    private func openFromPlaylist(_ url: URL) {
        saveCurrentProgress()
        currentFileURL = url
        currentIndex = playlist.firstIndex(of: url) ?? -1
        currentTime = 0
        duration = 0
        updateWindowTitle(url.lastPathComponent)
        let resumeTime = loadSavedProgress(for: url)
        let backend = chooseBackend(for: url)
        selectBackend(backend)

        switch backend {
        case .native:
            openWithNative(url: url, resumeAt: resumeTime)
        case .mpv:
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: url, resumeAt: resumeTime)
        }
    }

    private func openWithNative(url: URL, resumeAt: Double?) {
        let item = AVPlayerItem(url: url)
        nativeItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self, self.playbackBackend == .native else { return }
            if item.status == .readyToPlay {
                let seconds = item.duration.seconds
                self.duration = seconds.isFinite ? max(0, seconds) : 0
                self.syncText = "播放链路：系统原生"
                self.playbackEngineStatus = "播放引擎：AVPlayer"
                self.isPaused = false
                if let resumeAt, resumeAt > 0 {
                    self.nativePlayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                }
                self.nativePlayer.play()
                self.nativePlayer.rate = Float(self.speed)
            }
        }
        nativePlayer.replaceCurrentItem(with: item)
    }

    private func chooseBackend(for url: URL) -> PlaybackBackend {
        let asset = AVURLAsset(url: url)
        let ffprobeInfo = probeMediaInfo(url: url)

        if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
            let audioTracks = asset.tracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                return .mpv
            }
        }

        return .native
    }

    private func loadPlaylist(with selectedURL: URL) {
        let fm = FileManager.default
        let folder = selectedURL.deletingLastPathComponent()
        let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "flv", "wmv", "m4v", "webm", "ts", "mpeg", "mpg"]

        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let allVideos = urls.filter { videoExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        playlist = allVideos.isEmpty ? [selectedURL] : allVideos
        currentIndex = playlist.firstIndex(of: selectedURL) ?? 0
    }

    private func updateWindowTitle(_ title: String) {
        windowTitle = title
        for window in NSApp.windows {
            window.title = title
        }
    }

    private func progressKey(for url: URL) -> String {
        "playback.progress.\(url.path)"
    }

    private func loadSavedProgress(for url: URL) -> Double? {
        let value = UserDefaults.standard.double(forKey: progressKey(for: url))
        return value > 0 ? value : nil
    }

    private func saveCurrentProgress() {
        guard let url = currentFileURL, currentTime.isFinite, currentTime > 0 else { return }
        UserDefaults.standard.set(currentTime, forKey: progressKey(for: url))
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func buildFileInfoText(url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        do {
            let durationTime = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let fileSizeBytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let ffprobeInfo = probeMediaInfo(url: url)
            let recommendedBackend = chooseBackend(for: url)

            var lines: [String] = []
            lines.append("文件：\(url.lastPathComponent)")
            lines.append("路径：\(url.path)")
            if let fileSizeBytes {
                lines.append("大小：\(formatBytes(Int64(fileSizeBytes)))")
            }

            let durationSeconds = durationTime.seconds
            if durationSeconds.isFinite, durationSeconds > 0 {
                lines.append("时长：\(formatDuration(durationSeconds)) (\(String(format: "%.2f", durationSeconds)) 秒)")
            }

            lines.append("建议播放后端：\(recommendedBackend == .native ? "系统原生" : "mpv/libmpv")")

            let videoTracks = tracks.filter { $0.mediaType == .video }
            lines.append("")
            lines.append("视频轨道：\(videoTracks.count)")
            for (index, videoTrack) in videoTracks.enumerated() {
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let fps = try await videoTrack.load(.nominalFrameRate)
                let estimatedBitRate = try await videoTrack.load(.estimatedDataRate)

                let transformed = size.applying(transform)
                let width = abs(Int(transformed.width.rounded()))
                let height = abs(Int(transformed.height.rounded()))

                lines.append("")
                lines.append("【视频 #\(index + 1)】")
                lines.append("分辨率：\(width)x\(height)")
                lines.append("帧率：\(String(format: "%.3f", fps)) fps")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                lines.append("编码：\(codecDescription(from: videoTrack.formatDescriptions.first, mediaType: "视频"))")
            }

            let audioTracks = tracks.filter { $0.mediaType == .audio }
            lines.append("")
            lines.append("音频轨道：\(audioTracks.count)")
            if audioTracks.isEmpty {
                if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
                    lines.append("提示：AVFoundation 未识别到音轨，但 ffprobe 检测到 \(ffprobeInfo.audioStreams.count) 条音轨。")
                    lines.append("这类文件会自动切到 mpv 后端播放。")
                } else {
                    lines.append("提示：AVFoundation 未检测到音轨。")
                    lines.append("若文件在其它播放器有声音，通常是当前系统媒体解析兼容性问题，而不一定是源文件无声。")
                    lines.append("当前未拿到 ffprobe 音轨结果，因此暂时无法进一步确认。")
                }
            }

            for (index, audioTrack) in audioTracks.enumerated() {
                let estimatedBitRate = try await audioTrack.load(.estimatedDataRate)
                lines.append("")
                lines.append("【音频 #\(index + 1)】")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                if let formatDesc = audioTrack.formatDescriptions.first.map({ $0 as! CMFormatDescription }),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                    lines.append("采样率：\(Int(asbd.mSampleRate)) Hz")
                    lines.append("声道数：\(asbd.mChannelsPerFrame)")
                    lines.append("位深：\(asbd.mBitsPerChannel) bit")
                }
                lines.append("编码：\(codecDescription(from: audioTrack.formatDescriptions.first, mediaType: "音频"))")
            }

            if let ffprobeInfo {
                lines.append("")
                lines.append("【ffprobe 检测】")
                lines.append("视频流：\(ffprobeInfo.videoStreams.count)")
                for (index, stream) in ffprobeInfo.videoStreams.enumerated() {
                    lines.append("视频 #\(index + 1)：\(stream.summary)")
                }
                lines.append("音频流：\(ffprobeInfo.audioStreams.count)")
                for (index, stream) in ffprobeInfo.audioStreams.enumerated() {
                    lines.append("音频 #\(index + 1)：\(stream.summary)")
                }
            }

            return lines.joined(separator: "\n")
        } catch {
            return "读取媒体信息失败：\(error.localizedDescription)"
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}

private func formatDuration(_ time: Double) -> String {
    let total = Int(time)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

private func formatBitrate(_ bitsPerSecond: Float) -> String {
    guard bitsPerSecond > 0 else { return "未知" }
    let mbps = Double(bitsPerSecond) / 1_000_000
    if mbps >= 1 {
        return String(format: "%.2f Mbps", mbps)
    }
    let kbps = Double(bitsPerSecond) / 1_000
    return String(format: "%.0f kbps", kbps)
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func fourCCString(_ code: FourCharCode) -> String {
    let n = Int(code.bigEndian)
    let c1 = Character(UnicodeScalar((n >> 24) & 255)!)
    let c2 = Character(UnicodeScalar((n >> 16) & 255)!)
    let c3 = Character(UnicodeScalar((n >> 8) & 255)!)
    let c4 = Character(UnicodeScalar(n & 255)!)
    let text = String([c1, c2, c3, c4])
    return text.trimmingCharacters(in: .controlCharacters).isEmpty ? "\(code)" : text
}

private func codecDescription(from formatDescription: Any?, mediaType: String) -> String {
    guard let formatDescription else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let subtype = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
    return "\(fourCCString(subtype)) (\(subtype))"
}

private struct FFprobeInfo {
    let videoStreams: [FFprobeStream]
    let audioStreams: [FFprobeStream]
}

private struct FFprobeStream {
    let summary: String
}

private func probeMediaInfo(url: URL) -> FFprobeInfo? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffprobe",
        "-v", "error",
        "-show_entries",
        "stream=codec_name,codec_long_name,codec_type,codec_tag_string,profile,sample_rate,channels,channel_layout,bit_rate,width,height,r_frame_rate:stream_tags=language",
        "-of", "json",
        url.path
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let streams = object["streams"] as? [[String: Any]]
        else {
            return nil
        }

        let mapped = streams.compactMap(ffprobeStreamSummary(from:))
        return FFprobeInfo(
            videoStreams: mapped.filter { $0.type == "video" }.map { FFprobeStream(summary: $0.summary) },
            audioStreams: mapped.filter { $0.type == "audio" }.map { FFprobeStream(summary: $0.summary) }
        )
    } catch {
        return nil
    }
}

private func ffprobeStreamSummary(from json: [String: Any]) -> (type: String, summary: String)? {
    guard let type = json["codec_type"] as? String else { return nil }

    var parts: [String] = []
    if let codec = json["codec_name"] as? String {
        if let longName = json["codec_long_name"] as? String, !longName.isEmpty, longName.lowercased() != codec.lowercased() {
            parts.append("编码 \(codec) (\(longName))")
        } else {
            parts.append("编码 \(codec)")
        }
    }
    if let tag = json["codec_tag_string"] as? String, !tag.isEmpty {
        parts.append("标签 \(tag)")
    }
    if let profile = json["profile"] as? String, !profile.isEmpty, profile != "unknown" {
        parts.append("Profile \(profile)")
    }

    if type == "video" {
        if let width = json["width"] as? Int, let height = json["height"] as? Int {
            parts.append("\(width)x\(height)")
        }
        if let frameRate = json["r_frame_rate"] as? String, frameRate != "0/0" {
            parts.append("帧率 \(frameRate)")
        }
    } else if type == "audio" {
        if let sampleRate = json["sample_rate"] as? String, !sampleRate.isEmpty {
            parts.append("采样率 \(sampleRate) Hz")
        }
        if let channels = json["channels"] as? Int {
            parts.append("声道 \(channels)")
        }
        if let channelLayout = json["channel_layout"] as? String, !channelLayout.isEmpty {
            parts.append(channelLayout)
        }
    }

    if let bitRate = json["bit_rate"] as? String, let value = Float(bitRate) {
        parts.append("码率 \(formatBitrate(value))")
    }

    if let tags = json["tags"] as? [String: Any], let language = tags["language"] as? String, !language.isEmpty {
        parts.append("语言 \(language)")
    }

    return (type, parts.joined(separator: "，"))
}
