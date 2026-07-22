import Foundation

/// Simple timed-text cue used by the native AVPlayer overlay.
struct ExternalSubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String

    func contains(time: Double) -> Bool {
        time >= start && time < end
    }
}

/// Parses external subtitle sidecars (SRT / VTT / basic ASS/SSA) for the native backend.
enum ExternalSubtitleParser {
    static func loadCues(from url: URL) -> [ExternalSubtitleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let content = decodeSubtitleText(data) else { return nil }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "vtt":
            return parseWebVTT(content)
        case "ass", "ssa":
            return parseASS(content)
        default:
            // srt / sub / idx-less text fall back to SRT-style parsing
            return parseSRT(content)
        }
    }

    private static func decodeSubtitleText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbEncodingRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let gbEncoding = String.Encoding(rawValue: gbEncodingRaw)
        if let gb = String(data: data, encoding: gbEncoding) {
            return gb
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - SRT

    static func parseSRT(_ content: String) -> [ExternalSubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [ExternalSubtitleCue] = []
        cues.reserveCapacity(blocks.count)

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }

            var timingLineIndex = 0
            if lines[0].range(of: #"^\d+$"#, options: .regularExpression) != nil {
                timingLineIndex = 1
            }
            guard timingLineIndex < lines.count else { continue }
            guard let range = parseTimingLine(lines[timingLineIndex]) else { continue }

            let textLines = lines.dropFirst(timingLineIndex + 1)
            let text = textLines
                .map { stripSRTTags($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, range.end > range.start else { continue }
            cues.append(ExternalSubtitleCue(start: range.start, end: range.end, text: text))
        }

        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - WebVTT

    static func parseWebVTT(_ content: String) -> [ExternalSubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var body = normalized
        if body.hasPrefix("\u{FEFF}") {
            body.removeFirst()
        }
        if body.lowercased().hasPrefix("webvtt") {
            if let firstNewline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: firstNewline)...])
            } else {
                return []
            }
        }

        let blocks = body.components(separatedBy: "\n\n")
        var cues: [ExternalSubtitleCue] = []

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            if lines[0].hasPrefix("NOTE") || lines[0].hasPrefix("STYLE") || lines[0].hasPrefix("REGION") {
                continue
            }

            var timingLineIndex = 0
            if !lines[0].contains("-->") {
                timingLineIndex = 1
            }
            guard timingLineIndex < lines.count else { continue }
            guard let range = parseTimingLine(lines[timingLineIndex]) else { continue }

            let textLines = lines.dropFirst(timingLineIndex + 1)
            let text = textLines
                .map { stripWebVTTTags($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, range.end > range.start else { continue }
            cues.append(ExternalSubtitleCue(start: range.start, end: range.end, text: text))
        }

        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - ASS / SSA (Dialogue lines only)

    static func parseASS(_ content: String) -> [ExternalSubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [ExternalSubtitleCue] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("Dialogue:") else { continue }
            let payload = String(line.dropFirst("Dialogue:".count)).trimmingCharacters(in: .whitespaces)
            // Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            // Text may contain commas, so take first 9 commas then remainder.
            var fields: [String] = []
            var remaining = payload
            for _ in 0..<9 {
                if let comma = remaining.firstIndex(of: ",") {
                    fields.append(String(remaining[..<comma]).trimmingCharacters(in: .whitespaces))
                    remaining = String(remaining[remaining.index(after: comma)...])
                } else {
                    fields = []
                    break
                }
            }
            guard fields.count == 9 else { continue }
            guard let start = parseASSTime(fields[1]),
                  let end = parseASSTime(fields[2]),
                  end > start else { continue }

            let text = stripASSTags(remaining)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(ExternalSubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - Cue lookup

    /// Binary search for the active cue at `time`.
    static func activeCue(in cues: [ExternalSubtitleCue], at time: Double) -> ExternalSubtitleCue? {
        guard !cues.isEmpty, time.isFinite else { return nil }
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start {
                high = mid - 1
            } else if time >= cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }

    // MARK: - Timing helpers

    private static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        // Accept "00:00:01,000 --> 00:00:02,000" or with dots; ignore trailing cue settings.
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let startToken = parts[0].trimmingCharacters(in: .whitespaces)
        let endToken = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        guard let start = parseTimestamp(startToken),
              let end = parseTimestamp(endToken) else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let pieces = cleaned.split(separator: ":")
        guard pieces.count == 2 || pieces.count == 3 else { return nil }

        if pieces.count == 2 {
            guard let minutes = Double(pieces[0]),
                  let seconds = Double(pieces[1]) else { return nil }
            return minutes * 60 + seconds
        }

        guard let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        // H:MM:SS.cs  (centiseconds)
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        let pieces = cleaned.split(separator: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2].replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func stripSRTTags(_ text: String) -> String {
        // Strip simple HTML-like tags: <i>, <b>, <font ...>, {\an8}
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        if let regex = try? NSRegularExpression(pattern: #"\{[^}]*\}"#, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    private static func stripWebVTTTags(_ text: String) -> String {
        stripSRTTags(text)
    }

    private static func stripASSTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{[^}]*\}"#, options: []) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}
