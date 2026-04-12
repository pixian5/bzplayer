import AppKit
import CMpv
import Darwin
import Foundation

@MainActor
final class MpvPlayer: NSObject {
    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private var handle: OpaquePointer?
    private weak var attachedView: NSView?
    private var pendingResumeTime: Double?
    private var configuredSpeed: Double = 1.0
    private var isInitialized = false

    override init() {
        super.init()
        setlocale(LC_NUMERIC, "C")
    }

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    func attach(to view: NSView) {
        attachedView = view
        if handle == nil {
            createPlayer(attachedTo: view)
        } else {
            setWindowID(for: view, asOption: false)
        }
    }

    func load(url: URL, resumeAt: Double?) {
        guard let handle else {
            onStatusChanged?("播放引擎：mpv 尚未初始化")
            return
        }

        pendingResumeTime = resumeAt
        configuredSpeed = max(0.25, configuredSpeed)
        onStatusChanged?("播放引擎：mpv/libmpv")
        command(["loadfile", url.path, "replace"], on: handle)
    }

    func play() {
        setFlagProperty("pause", false)
    }

    func pause() {
        setFlagProperty("pause", true)
    }

    func seek(seconds: Double) {
        guard seconds.isFinite else { return }
        setDoubleProperty("time-pos", seconds)
    }

    func setSpeed(_ speed: Double) {
        configuredSpeed = speed
        setDoubleProperty("speed", speed)
    }

    private func createPlayer(attachedTo view: NSView) {
        guard let handle = mpv_create() else {
            onStatusChanged?("播放引擎：mpv 创建失败")
            return
        }

        self.handle = handle
        setWindowID(for: view, asOption: true)
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "terminal", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "idle", "yes")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        mpv_set_option_string(handle, "vo", "gpu-next")

        let result = mpv_initialize(handle)
        guard result >= 0 else {
            onStatusChanged?("播放引擎：mpv 初始化失败")
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }

        isInitialized = true
        mpv_set_wakeup_callback(handle, mpvWakeupCallback, Unmanaged.passUnretained(self).toOpaque())
        observeProperties(on: handle)
        onStatusChanged?("播放引擎：mpv/libmpv")
    }

    private func setWindowID(for view: NSView, asOption: Bool) {
        guard let handle else { return }
        var wid = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())))
        if asOption {
            withUnsafeMutablePointer(to: &wid) {
                _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, $0)
            }
        } else if isInitialized {
            withUnsafeMutablePointer(to: &wid) {
                _ = mpv_set_property(handle, "wid", MPV_FORMAT_INT64, $0)
            }
        }
    }

    private func observeProperties(on handle: OpaquePointer) {
        _ = mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
    }

    func processEvents() {
        guard let handle else { return }

        while true {
            guard let event = mpv_wait_event(handle, 0) else { break }
            let eventID = event.pointee.event_id
            if eventID == MPV_EVENT_NONE {
                break
            }

            switch eventID {
            case MPV_EVENT_FILE_LOADED:
                setDoubleProperty("speed", configuredSpeed)
                if let pendingResumeTime, pendingResumeTime > 0 {
                    setDoubleProperty("time-pos", pendingResumeTime)
                }
                pendingResumeTime = nil
                onPauseChanged?(false)
                onFileLoaded?()
            case MPV_EVENT_END_FILE:
                onPauseChanged?(true)
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self) else {
                    continue
                }
                handlePropertyChange(data.pointee)
            default:
                continue
            }
        }
    }

    private func handlePropertyChange(_ property: mpv_event_property) {
        guard let cName = property.name else { return }
        let name = String(cString: cName)

        switch name {
        case "time-pos":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            onTimeChanged?(max(0, data.pointee))
        case "duration":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            onDurationChanged?(max(0, data.pointee))
        case "pause":
            guard property.format == MPV_FORMAT_FLAG, let data = property.data?.assumingMemoryBound(to: Int32.self) else { return }
            onPauseChanged?(data.pointee != 0)
        default:
            return
        }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        withUnsafeMutablePointer(to: &flag) {
            _ = mpv_set_property(handle, name, MPV_FORMAT_FLAG, $0)
        }
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        guard let handle else { return }
        var number = value
        withUnsafeMutablePointer(to: &number) {
            _ = mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, $0)
        }
    }

    private func command(_ args: [String], on handle: OpaquePointer) {
        let cStrings = args.map { strdup($0) }
        defer {
            for item in cStrings {
                free(item)
            }
        }

        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        pointers.append(nil)
        pointers.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }
}

private let mpvWakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    let player = Unmanaged<MpvPlayer>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        player.processEvents()
    }
}
