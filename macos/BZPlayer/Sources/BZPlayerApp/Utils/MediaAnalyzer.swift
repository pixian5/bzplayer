import Foundation
import CoreMedia
import AVFoundation
import Dispatch
import Darwin
import BZPlayerCore

private struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

private final class AsyncProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<ProcessResult, Never>?
    private var didFinish = false
    private var cancelRequested = false
    private var timeoutWorkItem: DispatchWorkItem?

    func start(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        continuation: CheckedContinuation<ProcessResult, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        let shouldCancel = cancelRequested
        lock.unlock()

        guard !shouldCancel else {
            finish(ProcessResult(terminationStatus: -1, standardOutput: Data(), standardError: Data()))
            return
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            let output = try? outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let error = try? errorPipe.fileHandleForReading.readToEnd() ?? Data()
            self?.finish(ProcessResult(
                terminationStatus: terminatedProcess.terminationStatus,
                standardOutput: output ?? Data(),
                standardError: error ?? Data()
            ))
            process?.terminationHandler = nil
        }

        lock.lock()
        self.process = process
        let shouldCancelAfterInstall = cancelRequested
        lock.unlock()

        do {
            try process.run()
        } catch {
            finish(ProcessResult(
                terminationStatus: -1,
                standardOutput: Data(),
                standardError: Data(error.localizedDescription.utf8)
            ))
            return
        }

        if shouldCancelAfterInstall {
            cancel()
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            self.clearTimeoutWorkItem()
        }
        lock.lock()
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(timeout, 0.1),
            execute: timeoutWorkItem
        )
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func clearTimeoutWorkItem() {
        lock.lock()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()
    }

    private func finish(_ result: ProcessResult) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        self.process = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private func runExternalProcess(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval
) async -> ProcessResult {
    let runner = AsyncProcessRunner()
    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { continuation in
            runner.start(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                continuation: continuation
            )
        }
    }, onCancel: {
        runner.cancel()
    })
}

private func toolInvocation(_ name: String, arguments: [String]) -> (executableURL: URL, arguments: [String]) {
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)"
    ]
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        return (URL(fileURLWithPath: path), arguments)
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), [name] + arguments)
}

func probeMediaInfo(url: URL) async -> FFprobeInfo? {
    let invocation = toolInvocation("ffprobe", arguments: [
        "-v", "error",
        "-show_entries",
        "stream=codec_name,codec_long_name,codec_type,codec_tag_string,profile,sample_rate,channels,channel_layout,bit_rate,width,height,r_frame_rate:stream_tags=language",
        "-of", "json",
        url.path
    ])
    let result = await runExternalProcess(
        executableURL: invocation.executableURL,
        arguments: invocation.arguments,
        timeout: 8
    )
    guard result.terminationStatus == 0 else {
        return nil
    }
    guard
        let object = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
        let streams = object["streams"] as? [[String: Any]]
    else {
        return nil
    }

    let mapped = streams.compactMap(ffprobeStreamSummary(from:))
    return FFprobeInfo(
        videoStreams: mapped.filter { $0.type == "video" }.map {
            FFprobeStream(codecName: $0.codecName, codecTag: $0.codecTag, profile: $0.profile, summary: $0.summary)
        },
        audioStreams: mapped.filter { $0.type == "audio" }.map {
            FFprobeStream(codecName: $0.codecName, codecTag: $0.codecTag, profile: $0.profile, summary: $0.summary)
        }
    )
}

func hasVideoDecodeErrors(url: URL, scanSeconds: Int) async -> Bool {
    guard url.isFileURL, scanSeconds > 0 else { return false }
    let invocation = toolInvocation("ffmpeg", arguments: [
        "-hide_banner",
        "-v", "warning",
        "-i", url.path,
        "-map", "0:v:0",
        "-t", "\(scanSeconds)",
        "-f", "null",
        "-"
    ])
    let result = await runExternalProcess(
        executableURL: invocation.executableURL,
        arguments: invocation.arguments,
        timeout: min(max(Double(scanSeconds), 8), 20)
    )
    guard result.terminationStatus == 0 || !result.standardError.isEmpty else {
        return false
    }
    guard let output = String(data: result.standardError, encoding: .utf8)?.lowercased(), !output.isEmpty else {
        return false
    }
    let errorMarkers = [
        "invalid nal",
        "error splitting the input into nal units",
        "invalid data found when processing input",
        "error submitting packet to decoder",
        "failed to parse header of nalu",
        "slice type"
    ]
    return errorMarkers.contains { output.contains($0) }
}

func codecDescription(from formatDescription: Any?, mediaType: String) -> String {
    guard let formatDescription else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let cfDescription = formatDescription as CFTypeRef
    guard CFGetTypeID(cfDescription) == CMFormatDescriptionGetTypeID() else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let subtype = CMFormatDescriptionGetMediaSubType(cfDescription as! CMFormatDescription)
    return "\(fourCCString(subtype)) (\(subtype))"
}
func formatSeconds(_ time: Double) -> String {
    guard time.isFinite, time >= 0 else { return "00:00" }
    let total = Int(time)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
