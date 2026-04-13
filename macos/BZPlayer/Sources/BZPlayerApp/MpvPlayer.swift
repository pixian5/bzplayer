import AppKit
import CMpv
import Darwin
import Foundation
import OpenGL.GL3

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
    private var latestPlaybackTime: Double = 0
    private var lastPresentedPlaybackTime: Double?
    private var sourceFPS: Double = 30
    private var displayFPS: Double = 60

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
        view.onRendererReady = { [weak self] readyView in
            self?.prepareRenderer(for: readyView)
        }
        prepareRenderer(for: view)
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
        resetSamplingState()
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
        guard let handle, renderContext == nil, let attachedView else { return }
        attachedView.openGLContext?.makeCurrentContext()

        var glInitParams = mpv_opengl_init_params(
            get_proc_address: mpvOpenGLGetProcAddress,
            get_proc_address_ctx: nil
        )
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }

        var context: OpaquePointer?
        let result = withUnsafeMutablePointer(to: &glInitParams) { initPtr -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPtr),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                mpv_render_context_create(&context, handle, buffer.baseAddress)
            }
        }

        guard result >= 0, let context else {
            onStatusChanged?("播放引擎：mpv OpenGL render 初始化失败")
            return
        }

        renderContext = context
        mpv_render_context_set_update_callback(context, mpvRenderUpdateCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func observeProperties(on handle: OpaquePointer) {
        _ = mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        _ = mpv_observe_property(handle, 4, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 5, "container-fps", MPV_FORMAT_DOUBLE)
        _ = mpv_observe_property(handle, 6, "display-fps", MPV_FORMAT_DOUBLE)
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
                resetSamplingState()
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
        let profile = renderProfile(for: configuredSpeed)
        if let remainingDelay = remainingWallDelay(for: profile), remainingDelay > 0 {
            scheduleRender(after: remainingDelay)
            return
        }

        attachedView.renderFrame { size, fbo, flipY in
            var target = mpv_opengl_fbo(fbo: fbo, w: size.x, h: size.y, internal_format: 0)
            var flip = flipY
            withUnsafeMutablePointer(to: &target) { targetPtr in
                withUnsafeMutablePointer(to: &flip) { flipPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: targetPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]

                    params.withUnsafeMutableBufferPointer { buffer in
                        _ = mpv_render_context_render(renderContext, buffer.baseAddress)
                    }
                }
            }
        }
        lastRenderAt = CACurrentMediaTime()
        if latestPlaybackTime.isFinite {
            lastPresentedPlaybackTime = latestPlaybackTime
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
        isRenderScheduled = true
        scheduleRender(after: remainingWallDelay(for: renderProfile(for: configuredSpeed)) ?? 0)
    }

    private func applyPlaybackProfile(for speed: Double) {
        let profile = renderProfile(for: speed)
        setFlagProperty("mute", profile.muteAudio)
        setFlagProperty("audio-pitch-correction", profile.pitchCorrection)
        setStringProperty("video-sync", profile.videoSync)
        setStringProperty("framedrop", profile.framedrop)
        setStringProperty("vd-lavc-framedrop", profile.decoderFramedrop)
        setStringProperty("vd-lavc-skipframe", profile.skipFrame)
        setStringProperty("vd-lavc-skiploopfilter", profile.skipLoopFilter)
        setFlagProperty("vd-lavc-fast", profile.fastDecode)
        setFlagProperty("interpolation", false)
        resetSamplingState()
    }

    private func prepareRenderer(for view: MpvRenderView) {
        attachedView = view
        guard view.openGLContext != nil else { return }
        view.openGLContext?.makeCurrentContext()
        if handle == nil {
            createPlayer()
        } else {
            createRenderContextIfNeeded()
            requestRender()
        }
    }

    private func handlePropertyChange(_ property: mpv_event_property) {
        guard let cName = property.name else { return }
        let name = String(cString: cName)

        switch name {
        case "time-pos":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            let value = max(0, data.pointee)
            if value + 0.25 < latestPlaybackTime {
                lastPresentedPlaybackTime = nil
            }
            latestPlaybackTime = value
            onTimeChanged?(value)
        case "duration":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            onDurationChanged?(max(0, data.pointee))
        case "pause":
            guard property.format == MPV_FORMAT_FLAG, let data = property.data?.assumingMemoryBound(to: Int32.self) else { return }
            onPauseChanged?(data.pointee != 0)
        case "estimated-vf-fps", "container-fps":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            let fps = data.pointee
            if fps.isFinite, fps > 1 {
                sourceFPS = fps
            }
        case "display-fps":
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data?.assumingMemoryBound(to: Double.self) else { return }
            let fps = data.pointee
            if fps.isFinite, fps > 1 {
                displayFPS = fps
            }
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

    private func setStringProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        _ = value.withCString { stringPtr in
            mpv_set_property_string(handle, name, stringPtr)
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

private extension MpvPlayer {
    struct RenderProfile {
        let targetOutputFPS: Double
        let contentStep: Double
        let wallInterval: CFTimeInterval
        let muteAudio: Bool
        let pitchCorrection: Bool
        let videoSync: String
        let framedrop: String
        let decoderFramedrop: String
        let skipFrame: String
        let skipLoopFilter: String
        let fastDecode: Bool
    }

    func renderProfile(for speed: Double) -> RenderProfile {
        let effectiveSourceFPS = sourceFPS.isFinite && sourceFPS > 1 ? sourceFPS : 30
        let effectiveDisplayFPS = displayFPS.isFinite && displayFPS > 1 ? displayFPS : 60
        let renderBudgetFPS: Double
        switch speed {
        case 16...:
            renderBudgetFPS = min(effectiveDisplayFPS, 48)
        case 8...:
            renderBudgetFPS = min(effectiveDisplayFPS, 60)
        default:
            renderBudgetFPS = min(effectiveDisplayFPS, 60)
        }

        let contentFPS = max(effectiveSourceFPS * max(speed, 0.25), 1)
        let targetOutputFPS = max(12, min(renderBudgetFPS, contentFPS))
        let wallInterval = 1.0 / targetOutputFPS
        let contentStep = max(speed, 0.25) / targetOutputFPS

        switch speed {
        case 16...:
            return RenderProfile(
                targetOutputFPS: targetOutputFPS,
                contentStep: contentStep,
                wallInterval: wallInterval,
                muteAudio: true,
                pitchCorrection: false,
                videoSync: "display-vdrop",
                framedrop: "decoder+vo",
                decoderFramedrop: "nonref",
                skipFrame: "nonref",
                skipLoopFilter: "nonref",
                fastDecode: true
            )
        case 8...:
            return RenderProfile(
                targetOutputFPS: targetOutputFPS,
                contentStep: contentStep,
                wallInterval: wallInterval,
                muteAudio: false,
                pitchCorrection: true,
                videoSync: "audio",
                framedrop: "decoder+vo",
                decoderFramedrop: "bidir",
                skipFrame: "bidir",
                skipLoopFilter: "nonref",
                fastDecode: true
            )
        case 4...:
            return RenderProfile(
                targetOutputFPS: targetOutputFPS,
                contentStep: contentStep,
                wallInterval: wallInterval,
                muteAudio: false,
                pitchCorrection: true,
                videoSync: "audio",
                framedrop: "vo",
                decoderFramedrop: "nonref",
                skipFrame: "default",
                skipLoopFilter: "default",
                fastDecode: false
            )
        default:
            return RenderProfile(
                targetOutputFPS: targetOutputFPS,
                contentStep: contentStep,
                wallInterval: wallInterval,
                muteAudio: false,
                pitchCorrection: true,
                videoSync: "audio",
                framedrop: "vo",
                decoderFramedrop: "nonref",
                skipFrame: "default",
                skipLoopFilter: "default",
                fastDecode: false
            )
        }
    }

    func remainingWallDelay(for profile: RenderProfile) -> CFTimeInterval? {
        let now = CACurrentMediaTime()
        let wallDelay = max(0, profile.wallInterval - (now - lastRenderAt))

        guard configuredSpeed >= 8, let lastPresentedPlaybackTime else {
            return wallDelay
        }

        let advanced = max(0, latestPlaybackTime - lastPresentedPlaybackTime)
        let remainingContent = max(0, profile.contentStep - advanced)
        let contentDelay = remainingContent / max(configuredSpeed, 0.25)
        return max(wallDelay, contentDelay)
    }

    func scheduleRender(after delay: CFTimeInterval) {
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

    func resetSamplingState() {
        latestPlaybackTime = 0
        lastPresentedPlaybackTime = nil
        lastRenderAt = 0
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

private let mpvOpenGLGetProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name else { return nil }
    return mpvOpenGLLibraryHandle.withLibraryHandle { library in
        guard let library else { return nil }
        return dlsym(library, String(cString: name))
    }
}

private enum mpvOpenGLLibraryHandle {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL)
    }()

    static func withLibraryHandle<T>(_ body: (UnsafeMutableRawPointer?) -> T) -> T {
        body(handle)
    }
}
