import Foundation

private let debugLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/BZPlayer.log")

func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: debugLogURL)
        }
    }
}
