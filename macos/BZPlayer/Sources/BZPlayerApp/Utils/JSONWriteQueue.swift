import Foundation

final class JSONWriteQueue: @unchecked Sendable {
    static let shared = JSONWriteQueue()

    private let queue = DispatchQueue(label: "tech.sbbz.bzplayer.json-writes", qos: .utility)

    private init() {}

    func enqueue(_ data: Data, to url: URL) {
        queue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                BZLogger.error("Failed to write JSON file \(url.path): \(error.localizedDescription)")
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}
