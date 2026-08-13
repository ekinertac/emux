// SocketPaths — resolve where emuxd puts its sockets. Standard macOS
// location is ~/Library/Application Support/emux/. Override with
// EMUX_SOCKET_DIR env var (mainly for tests / non-standard installs).
//
// Two sockets per protocol.md §1:
//   emux.sock         — JSON-RPC control channel
//   emux-client.sock  — length-prefixed binary transport
//
// Also owns the state.json + scrollback dir paths since they live
// alongside the sockets.

import Foundation

enum SocketPaths {
    /// Root dir for emux daemon state. Created on demand.
    static var rootDir: URL {
        if let override = ProcessInfo.processInfo.environment["EMUX_SOCKET_DIR"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("emux", isDirectory: true)
    }

    static var controlSocket: URL {
        rootDir.appendingPathComponent("emux.sock")
    }

    static var clientTransportSocket: URL {
        rootDir.appendingPathComponent("emux-client.sock")
    }

    static var stateFile: URL {
        rootDir.appendingPathComponent("state.json")
    }

    static var scrollbackDir: URL {
        rootDir.appendingPathComponent("scrollback", isDirectory: true)
    }

    /// Ensure rootDir exists. Idempotent.
    static func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true
        )
    }
}
