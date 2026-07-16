import Foundation
import CoreMedia
import AVFoundation
import Dispatch
import BZPlayerCore

func probeMediaInfo(url: URL) async -> FFprobeInfo? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: probeMediaInfoSynchronously(url: url))
        }
    }
}

private func probeMediaInfoSynchronously(url: URL) -> FFprobeInfo? {
    let process = Process()
    // Try common homebrew/standard paths if just "ffprobe" in env fails
    let ffprobePath: String = {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "ffprobe" // fallback to env search
    }()
    
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        ffprobePath,
        "-v", "error",
        "-show_entries",
        "stream=codec_name,codec_long_name,codec_type,codec_tag_string,profile,sample_rate,channels,channel_layout,bit_rate,width,height,r_frame_rate:stream_tags=language",
        "-of", "json",
        url.path
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
    } catch {
        return nil
    }
}

func hasVideoDecodeErrors(url: URL, scanSeconds: Int) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: hasVideoDecodeErrorsSynchronously(url: url, scanSeconds: scanSeconds))
        }
    }
}

private func hasVideoDecodeErrorsSynchronously(url: URL, scanSeconds: Int) -> Bool {
    guard url.isFileURL, scanSeconds > 0 else { return false }
    let ffmpegPath: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "ffmpeg"
    }()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        ffmpegPath,
        "-hide_banner",
        "-v", "warning",
        "-i", url.path,
        "-map", "0:v:0",
        "-t", "\(scanSeconds)",
        "-f", "null",
        "-"
    ]

    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr

    do {
        try process.run()
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8)?.lowercased(), !output.isEmpty else {
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
    } catch {
        return false
    }
}

func codecDescription(from formatDescription: Any?, mediaType: String) -> String {
    guard let formatDescription else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let subtype = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
    return "\(fourCCString(subtype)) (\(subtype))"
}
func formatSeconds(_ time: Double) -> String {
    let total = Int(time)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
