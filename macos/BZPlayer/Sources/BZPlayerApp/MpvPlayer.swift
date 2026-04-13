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
    private var renderContext: OpaquePointer?
    private weak var attachedView: MpvRenderView?
    private var pendingResumeTime: Double?
    private var configuredSpeed: Double = 1.0
    private var isRenderScheduled = false
    private var needsAnotherRender = false
    private var lastRenderAt: CFTimeInterval = 0

    override init() {
        super.init()
        setlocale(LC_NUMERIC, "C")
    }

    deinit {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
        }
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    func attach(to view: MpvRenderView) {
        attachedView = view
        if handle == nil {
            createPlayer()
        }
        requestRender()
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
        applyPlaybackProfile(for: speed)
        setDoubleProperty("speed", speed)
    }

    private func createPlayer() {
        guard let handle = mpv_create() else {
            onStatusChanged?("播放引擎：mpv 创建失败")
            return
        }

        self.handle = handle
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "terminal", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "idle", "yes")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "force-window", "no")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "framedrop", "vo")
        mpv_set_option_string(handle, "video-latency-hacks", "yes")
        mpv_set_option_string(handle, "audio-pitch-correction", "yes")

        let result = mpv_initialize(handle)
        guard result >= 0 else {
            onStatusChanged?("播放引擎：mpv 初始化失败")
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }

        mpv_set_wakeup_callback(handle, mpvWakeupCallback, Unmanaged.passUnretained(self).toOpaque())
        observeProperties(on: handle)
        createRenderContextIfNeeded()
        applyPlaybackProfile(for: configuredSpeed)
        onStatusChanged?("播放引擎：mpv/libmpv")
    }

    private func createRenderContextIfNeeded() {
        guard let handle, renderContext == nil else { return }

        let apiType = strdup(MPV_RENDER_API_TYPE_SW)
        defer { free(apiType) }

        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]

        var context: OpaquePointer?
        let result = params.withUnsafeMutableBufferPointer { buffer -> Int32 in
            mpv_render_context_create(&context, handle, buffer.baseAddress)
        }

        guard result >= 0, let context else {
            onStatusChanged?("播放引擎：mpv render 初始化失败")
            return
        }

        renderContext = context
        mpv_render_context_set_update_callback(context, mpvRenderUpdateCallback, Unmanaged.passUnretained(self).toOpaque())
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
                requestRender()
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

    func renderCurrentFrame() {
        guard let renderContext, let attachedView else { return }
        isRenderScheduled = false
        lastRenderAt = CACurrentMediaTime()

        attachedView.renderFrame { size, stride, pointer in
            var sizeStorage = [Int32(size.x), Int32(size.y)]
            var strideStorage = stride
            let format = strdup("bgr0")
            defer { free(format) }
            sizeStorage.withUnsafeMutableBytes { sizeBytes in
                withUnsafeMutablePointer(to: &strideStorage) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizeBytes.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]

                    params.withUnsafeMutableBufferPointer { buffer in
                        _ = mpv_render_context_render(renderContext, buffer.baseAddress)
                    }
                }
            }
        }

        if needsAnotherRender {
            needsAnotherRender = false
            requestRender()
        }
    }

    func requestRender() {
        guard renderContext != nil, attachedView != nil else { return }
        if isRenderScheduled {
            needsAnotherRender = true
            return
        }
        let now = CACurrentMediaTime()
        let minInterval = renderInterval(for: configuredSpeed)
        let elapsed = now - lastRenderAt
        isRenderScheduled = true
        let delay = max(0, minInterval - elapsed)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.renderCurrentFrame()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.renderCurrentFrame()
            }
        }
    }

    private func applyPlaybackProfile(for speed: Double) {
        setFlagProperty("mute", speed >= 12)
        if speed >= 12 {
            setFlagProperty("audio-pitch-correction", false)
        } else {
            setFlagProperty("audio-pitch-correction", true)
        }
    }

    private func renderInterval(for speed: Double) -> CFTimeInterval {
        switch speed {
        case 16...:
            return 1.0 / 12.0
        case 12...:
            return 1.0 / 18.0
        case 8...:
            return 1.0 / 24.0
        default:
            return 0
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

private let mpvRenderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    let player = Unmanaged<MpvPlayer>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        player.requestRender()
    }
}
