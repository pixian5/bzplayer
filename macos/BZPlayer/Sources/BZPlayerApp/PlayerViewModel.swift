import AVFoundation
import AppKit
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var isPaused = true
    @Published var speed: Double = 1.0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var syncText = "音画同步：稳定"

    let player = AVPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        attachPeriodicObserver()
    }

    deinit {
        if let observer {
            player.removeTimeObserver(observer)
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            observeCurrentItem(item)
            play()
        }
    }

    func play() {
        player.playImmediately(atRate: Float(speed))
        isPaused = false
    }

    func pause() {
        player.pause()
        isPaused = true
    }

    func togglePause() {
        isPaused ? play() : pause()
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

    private func attachPeriodicObserver() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.updateSyncStatus()
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem) {
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            }
        }

        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.isPaused = self?.player.timeControlStatus != .playing
            }
        }
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
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
