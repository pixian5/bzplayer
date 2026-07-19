import Foundation

struct BenchmarkConfiguration {
    enum Mode: String {
        case normal
        case audioOnly = "audio-only"
    }

    let mediaURL: URL
    let mode: Mode
    let duration: TimeInterval
    let warmup: TimeInterval
    let speed: Double
    let startFileURL: URL?

    static func parse(arguments: [String]) -> BenchmarkConfiguration? {
        let values = Array(arguments.dropFirst())
        guard values.contains("--benchmark-media") else { return nil }

        guard let mediaPath = value(after: "--benchmark-media", in: values),
              !mediaPath.isEmpty else {
            return nil
        }

        let mode = Mode(rawValue: value(after: "--benchmark-mode", in: values) ?? "normal") ?? .normal
        let duration = positiveNumber(after: "--benchmark-duration", in: values) ?? 60
        let warmup = nonNegativeNumber(after: "--benchmark-warmup", in: values) ?? 10
        let speed = positiveNumber(after: "--benchmark-speed", in: values) ?? 1
        let startFilePath = value(after: "--benchmark-start-file", in: values)

        return BenchmarkConfiguration(
            mediaURL: URL(fileURLWithPath: mediaPath).standardizedFileURL,
            mode: mode,
            duration: duration,
            warmup: warmup,
            speed: speed,
            startFileURL: startFilePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func positiveNumber(after option: String, in arguments: [String]) -> TimeInterval? {
        guard let value = value(after: option, in: arguments),
              let number = Double(value),
              number.isFinite,
              number > 0 else {
            return nil
        }
        return number
    }

    private static func nonNegativeNumber(after option: String, in arguments: [String]) -> TimeInterval? {
        guard let value = value(after: option, in: arguments),
              let number = Double(value),
              number.isFinite,
              number >= 0 else {
            return nil
        }
        return number
    }
}
