import AVFoundation
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    @Published var isPaused = true
    @Published var speed: Double = 1.0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var syncText = "播放链路：mpv/libmpv"
    @Published var playlist: [URL] = []
    @Published var currentIndex: Int = -1
    @Published var windowTitle = "BZPlayer"
    @Published var fileAssociationStatus = "未执行格式关联"
    @Published var playbackEngineStatus = "播放引擎：mpv/libmpv"

    let player = MpvPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    private var currentFileURL: URL?

    override init() {
        super.init()
        bindPlayerCallbacks()
    }

    func attachPlayerView(_ view: MpvRenderView) {
        player.attach(to: view)
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
        player.play()
        isPaused = false
    }

    func pause() {
        player.pause()
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
        player.seek(seconds: duration * progress)
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.25), 16)
        player.setSpeed(speed)
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
        let commonExtensions = [
            "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "mpeg", "mpg"
        ]

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

    private func bindPlayerCallbacks() {
        player.onTimeChanged = { [weak self] time in
            guard let self else { return }
            self.currentTime = time.isFinite ? time : 0
            if Int(self.currentTime * 10) % 30 == 0 {
                self.saveCurrentProgress()
            }
        }
        player.onDurationChanged = { [weak self] duration in
            guard let self else { return }
            self.duration = duration.isFinite ? duration : 0
        }
        player.onPauseChanged = { [weak self] paused in
            self?.isPaused = paused
        }
        player.onFileLoaded = { [weak self] in
            self?.syncText = "播放链路：mpv/libmpv"
        }
        player.onStatusChanged = { [weak self] status in
            self?.playbackEngineStatus = status
        }
    }

    private func openFromPlaylist(_ url: URL) {
        saveCurrentProgress()
        currentFileURL = url
        currentIndex = playlist.firstIndex(of: url) ?? -1
        currentTime = 0
        duration = 0
        updateWindowTitle(url.lastPathComponent)
        syncText = "播放链路：mpv/libmpv"
        let resumeTime = loadSavedProgress(for: url)
        player.setSpeed(speed)
        player.load(url: url, resumeAt: resumeTime)
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

        let allVideos = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return videoExts.contains(ext)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

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
                let extendedLanguage = try await videoTrack.load(.extendedLanguageTag)
                if let extendedLanguage, !extendedLanguage.isEmpty {
                    lines.append("语言：\(extendedLanguage)")
                }
            }

            let audioTracks = tracks.filter { $0.mediaType == .audio }
            lines.append("")
            lines.append("音频轨道：\(audioTracks.count)")
            if audioTracks.isEmpty {
                if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
                    lines.append("提示：AVFoundation 未识别到音轨，但 ffprobe 检测到 \(ffprobeInfo.audioStreams.count) 条音轨。")
                    lines.append("实际播放已切换为 mpv/libmpv，兼容性以 mpv 结果为准。")
                } else {
                    lines.append("提示：未检测到音频轨道，这个视频本身可能就是无声的。")
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
                let extendedLanguage = try await audioTrack.load(.extendedLanguageTag)
                if let extendedLanguage, !extendedLanguage.isEmpty {
                    lines.append("语言：\(extendedLanguage)")
                }
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
        if let longName = json["codec_long_name"] as? String, longName.isEmpty == false, longName.lowercased() != codec.lowercased() {
            parts.append("编码 \(codec) (\(longName))")
        } else {
            parts.append("编码 \(codec)")
        }
    }
    if let tag = json["codec_tag_string"] as? String, tag.isEmpty == false {
        parts.append("标签 \(tag)")
    }
    if let profile = json["profile"] as? String, profile.isEmpty == false, profile != "unknown" {
        parts.append("Profile \(profile)")
    }
    if type == "video" {
        if let width = json["width"] as? Int, let height = json["height"] as? Int {
            parts.append("\(width)x\(height)")
        }
        if let fps = json["r_frame_rate"] as? String, fps != "0/0" {
            parts.append("帧率 \(fps)")
        }
    }
    if type == "audio" {
        if let sampleRate = json["sample_rate"] as? String, sampleRate.isEmpty == false {
            parts.append("采样率 \(sampleRate) Hz")
        }
        if let channels = json["channels"] as? Int {
            parts.append("声道 \(channels)")
        }
        if let layout = json["channel_layout"] as? String, layout.isEmpty == false {
            parts.append(layout)
        }
    }
    if let bitRate = json["bit_rate"] as? String, let value = Double(bitRate), value > 0 {
        parts.append("码率 \(formatBitrate(Float(value)))")
    }
    if let tags = json["tags"] as? [String: Any], let language = tags["language"] as? String, language.isEmpty == false {
        parts.append("语言 \(language)")
    }

    return (type: type, summary: parts.joined(separator: "，"))
}
