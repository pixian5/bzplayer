import AVFoundation
import AppKit
import Combine
import CoreServices
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    @Published var isPaused = true
    @Published var speed: Double = 1.0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var syncText = "音画同步：稳定"
    @Published var playlist: [URL] = []
    @Published var currentIndex: Int = -1
    @Published var windowTitle = "BZPlayer"
    @Published var fileAssociationStatus = "未执行格式关联"

    let player = AVPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    private var currentFileURL: URL?
    private var pendingResumeTime: Double?
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?

    init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        attachPeriodicObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
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
        player.playImmediately(atRate: Float(speed))
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
        let seconds = duration * progress
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.25), 16)
        guard !isPaused else { return }
        player.rate = Float(speed)
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
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

    private func detachPeriodicObserverIfNeeded() {
        if let observer {
            player.removeTimeObserver(observer)
            self.observer = nil
        }
    }

    @objc
    private func handleWillTerminate(_ notification: Notification) {
        saveCurrentProgress()
        detachPeriodicObserverIfNeeded()
    }

    private func attachPeriodicObserver() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            if Int(self.currentTime * 10) % 30 == 0 {
                self.saveCurrentProgress()
            }
            self.updateSyncStatus()
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem) {
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                self.resumeIfNeeded()
            }
        }

        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.isPaused = self?.player.timeControlStatus != .playing
            }
        }
    }

    private func openFromPlaylist(_ url: URL) {
        saveCurrentProgress()
        currentFileURL = url
        currentIndex = playlist.firstIndex(of: url) ?? -1
        pendingResumeTime = loadSavedProgress(for: url)
        updateWindowTitle(url.lastPathComponent)

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)
        play()
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

    private func resumeIfNeeded() {
        guard let resumeTime = pendingResumeTime,
              duration.isFinite,
              duration > 0,
              resumeTime < duration - 2 else {
            pendingResumeTime = nil
            return
        }

        pendingResumeTime = nil
        player.seek(
            to: CMTime(seconds: resumeTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func updateSyncStatus() {
        // AVPlayer 在 macOS 下原生保证 A/V 同步，这里提供状态提示，便于高倍速时诊断。
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            syncText = "音画同步：缓冲中"
            return
        }

        let drift = player.currentItem?.currentDate()?.timeIntervalSinceNow ?? 0
        if abs(drift) > 0.08 {
            syncText = String(format: "音画同步：轻微偏移 %.2fs", abs(drift))
        } else {
            syncText = "音画同步：稳定"
        }
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

            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let fps = try await videoTrack.load(.nominalFrameRate)
                let estimatedBitRate = try await videoTrack.load(.estimatedDataRate)

                let transformed = size.applying(transform)
                let width = abs(Int(transformed.width.rounded()))
                let height = abs(Int(transformed.height.rounded()))

                lines.append("")
                lines.append("【视频】")
                lines.append("分辨率：\(width)x\(height)")
                lines.append("帧率：\(String(format: "%.3f", fps)) fps")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                if let codec = videoTrack.formatDescriptions.first
                    .map({ CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) })
                    .map({ fourCCString($0) }) {
                    lines.append("编码：\(codec)")
                }
            }

            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                let estimatedBitRate = try await audioTrack.load(.estimatedDataRate)
                lines.append("")
                lines.append("【音频】")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                if let formatDesc = audioTrack.formatDescriptions.first as? CMAudioFormatDescription,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                    lines.append("采样率：\(Int(asbd.mSampleRate)) Hz")
                    lines.append("声道数：\(asbd.mChannelsPerFrame)")
                    lines.append("位深：\(asbd.mBitsPerChannel) bit")
                }
                if let codec = audioTrack.formatDescriptions.first
                    .map({ CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) })
                    .map({ fourCCString($0) }) {
                    lines.append("编码：\(codec)")
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
