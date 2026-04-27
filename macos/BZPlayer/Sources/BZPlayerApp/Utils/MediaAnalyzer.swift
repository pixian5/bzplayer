import Foundation
import CoreMedia
import AVFoundation

struct FFprobeInfo {
    let videoStreams: [FFprobeStream]
    let audioStreams: [FFprobeStream]
}

struct FFprobeStream {
    let codecName: String
    let codecTag: String
    let profile: String
    let summary: String
}

func probeMediaInfo(url: URL) -> FFprobeInfo? {
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

func ffprobeStreamSummary(from json: [String: Any]) -> (type: String, codecName: String, codecTag: String, profile: String, summary: String)? {
    guard let type = json["codec_type"] as? String else { return nil }
    let codecName = (json["codec_name"] as? String)?.lowercased() ?? ""
    let codecTag = (json["codec_tag_string"] as? String)?.lowercased() ?? ""
    let profile = (json["profile"] as? String) ?? ""

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

    return (type, codecName, codecTag, profile, parts.joined(separator: "，"))
}

func codecHeadline(from streams: [FFprobeStream]) -> String {
    let parts = streams.map { stream in
        var items: [String] = []
        items.append(stream.codecName.isEmpty ? "未知" : stream.codecName)
        if !stream.codecTag.isEmpty {
            items.append("标签 \(stream.codecTag)")
        }
        if !stream.profile.isEmpty, stream.profile != "unknown" {
            items.append("Profile \(stream.profile)")
        }
        return items.joined(separator: "，")
    }
    return parts.joined(separator: "；")
}

func parseFPS(fromFFprobeSummary summary: String) -> Double? {
    guard let range = summary.range(of: "帧率 ") else { return nil }
    let suffix = summary[range.upperBound...]
    let token = suffix.split(separator: "，", maxSplits: 1).first.map(String.init) ?? ""
    if token.contains("/") {
        let parts = token.split(separator: "/", maxSplits: 1).compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 {
            let fps = parts[0] / parts[1]
            return fps.isFinite && fps > 0 ? fps : nil
        }
    }
    if let value = Double(token), value.isFinite, value > 0 {
        return value
    }
    return nil
}

func formatBitrate(_ bitsPerSecond: Float) -> String {
    guard bitsPerSecond > 0 else { return "未知" }
    let mbps = Double(bitsPerSecond) / 1_000_000
    if mbps >= 1 {
        return String(format: "%.2f Mbps", mbps)
    }
    let kbps = Double(bitsPerSecond) / 1_000
    return String(format: "%.0f kbps", kbps)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fourCCString(_ code: FourCharCode) -> String {
    let n = Int(code.bigEndian)
    let c1 = Character(UnicodeScalar((n >> 24) & 255)!)
    let c2 = Character(UnicodeScalar((n >> 16) & 255)!)
    let c3 = Character(UnicodeScalar((n >> 8) & 255)!)
    let c4 = Character(UnicodeScalar(n & 255)!)
    let text = String([c1, c2, c3, c4])
    return text.trimmingCharacters(in: .controlCharacters).isEmpty ? "\(code)" : text
}

func codecDescription(from formatDescription: Any?, mediaType: String) -> String {
    guard let formatDescription else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let subtype = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
    return "\(fourCCString(subtype)) (\(subtype))"
}
