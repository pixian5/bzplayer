import Foundation
import os

enum BZLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "tech.sbbz.bzplayer",
        category: "player"
    )

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
