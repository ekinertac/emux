// Logging — minimal stderr logger for emuxd. Timestamped, level-tagged.
// Written to stderr so it flows to the log file that DaemonLauncher
// (Task 4) sets up when it spawns emuxd via posix_spawn with redirected
// stdio. Never call print() from daemon code; use these helpers.

import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// Global logger — writes to stderr. Runtime-configurable level via
/// EMUX_LOG_LEVEL env var (default: info).
enum Log {
    static let minLevel: LogLevel = {
        switch ProcessInfo.processInfo.environment["EMUX_LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "warn": return .warn
        case "error": return .error
        default: return .info
        }
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        write(.debug, tag: tag, message: message())
    }
    static func info(_ tag: String, _ message: @autoclosure () -> String) {
        write(.info, tag: tag, message: message())
    }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) {
        write(.warn, tag: tag, message: message())
    }
    static func error(_ tag: String, _ message: @autoclosure () -> String) {
        write(.error, tag: tag, message: message())
    }

    private static func write(_ level: LogLevel, tag: String, message: String) {
        guard shouldLog(level) else { return }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(tag): \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    private static func shouldLog(_ level: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warn, .error]
        guard let cur = order.firstIndex(of: minLevel),
              let want = order.firstIndex(of: level) else { return true }
        return want >= cur
    }
}
