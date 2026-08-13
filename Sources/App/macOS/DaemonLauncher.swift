// DaemonLauncher — app-side lifecycle for emuxd.
//
// Called early in AppDelegate.applicationWillFinishLaunching. Ensures
// an emuxd is alive and speaks a compatible protocol version before
// any window opens. Sequence:
//
//   1. Try to connect to ~/Library/Application Support/emux/emux.sock.
//   2. If success: do the hello + daemon.status handshake. Version
//      compatible → return, app proceeds normally. Incompatible →
//      show a modal alert explaining what to do; the user can quit.
//   3. If ECONNREFUSED / missing file: find the emuxd binary
//      (bundle first, dev fallback second), posix_spawn it with
//      SETSID so it survives app quit, redirect stdio to a log file.
//   4. Poll the socket every 50ms up to 15s. Time-out → alert.
//
// Bundle path (production): emux.app/Contents/MacOS/emuxd — copied in
// by a build phase on the app target (build-phase wiring is a
// follow-up polish item; for now, developers run
// `cd daemon && swift build` and either set the EMUX_DAEMON_PATH env
// var in their Xcode scheme or rely on the ~/Code/emux dev fallback
// below).

import AppKit
import Foundation
import Darwin

enum DaemonLauncher {
    // MARK: - Public API

    /// Ensure a compatible emuxd is running. Blocks up to ~15s in the
    /// worst case (spawn + wait-for-ready). Called synchronously from
    /// AppDelegate; if it returns, the daemon is ready.
    /// On failure, presents a modal alert and returns false.
    @MainActor
    static func ensureRunning() -> Bool {
        // Fast path: daemon already up + compatible.
        if let status = pingDaemon() {
            if isCompatible(status: status) {
                NSLog("[DaemonLauncher] existing daemon ok — proto=\(status.protocolVersion) uptime=\(status.uptimeSeconds)s pid=\(status.daemonPid)")
                return true
            }
            presentIncompatibleAlert(status: status)
            return false
        }

        // Daemon not running — spawn one.
        NSLog("[DaemonLauncher] no daemon; spawning emuxd")
        guard let binary = locateEmuxdBinary() else {
            presentMissingBinaryAlert()
            return false
        }

        do {
            let pid = try spawnDaemon(binary: binary)
            NSLog("[DaemonLauncher] emuxd spawned pid=\(pid)")
        } catch {
            presentSpawnFailedAlert(error: error)
            return false
        }

        // Poll socket for readiness up to 15s.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let status = pingDaemon() {
                if isCompatible(status: status) {
                    NSLog("[DaemonLauncher] freshly-spawned daemon ready — proto=\(status.protocolVersion)")
                    return true
                }
                presentIncompatibleAlert(status: status)
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        presentTimeoutAlert()
        return false
    }

    // MARK: - Ping (short-lived connect + hello + daemon.status)

    private struct DaemonStatus {
        let version: String
        let protocolVersion: Int
        let daemonPid: Int
        let uptimeSeconds: Int
    }

    private static func pingDaemon() -> DaemonStatus? {
        let socketPath = defaultSocketPath()
        guard let (fd, _) = connectUnixSocket(path: socketPath) else {
            return nil
        }
        defer { close(fd) }

        do {
            // Send client hello.
            let hello: [String: Any] = [
                "kind": "hello",
                "protocol_version": clientProtocolVersion,
                "client": "emux.app",
                "client_version": appVersionString(),
            ]
            try writeLine(fd: fd, jsonObject: hello)

            // Read daemon hello. Protocol version + daemon version come
            // from this single reply — we intentionally do NOT chain a
            // daemon.status call here because two back-to-back reads
            // over a kernel-coalesced write can lose the second reply
            // (same shape as the DaemonConnection.readLine bug fixed
            // in 89b9f1a). pingDaemon only needs enough info to decide
            // "alive and compatible?"; one round-trip is enough.
            guard let helloReply = try readLine(fd: fd, timeout: 5.0),
                  let dict = helloReply.parseAsJSONObject() else {
                return nil
            }
            // If the daemon returned an error (protocol_incompatible),
            // parse it and short-circuit — treat as incompatible so the
            // caller shows the "stop the old daemon" alert.
            if dict["kind"] as? String == "response",
               let errObj = dict["error"] as? [String: Any],
               (errObj["code"] as? String) == "protocol_incompatible" {
                NSLog("[DaemonLauncher] daemon rejected our hello: \(errObj["message"] ?? "?")")
                return DaemonStatus(version: "unknown", protocolVersion: -1, daemonPid: 0, uptimeSeconds: 0)
            }
            guard let daemonProto = dict["protocol_version"] as? Int else {
                return nil
            }
            return DaemonStatus(
                version: (dict["daemon_version"] as? String) ?? "?",
                protocolVersion: daemonProto,
                daemonPid: (dict["daemon_pid"] as? Int) ?? 0,
                uptimeSeconds: 0
            )
        } catch {
            NSLog("[DaemonLauncher] ping failed: \(error)")
            return nil
        }
    }

    private static func isCompatible(status: DaemonStatus) -> Bool {
        // Client accepts daemon protocol_version == our clientProtocolVersion
        // for MVP. Later we'll accept a range.
        return status.protocolVersion == clientProtocolVersion
    }

    // MARK: - Binary discovery

    /// Find the emuxd binary. Priority:
    ///   1. EMUX_DAEMON_PATH env var (dev override)
    ///   2. Bundle: emux.app/Contents/MacOS/emuxd
    ///   3. Dev fallback: ~/Code/emux/daemon/.build/debug/emuxd
    ///   4. Dev fallback: ~/Code/emux/daemon/.build/release/emuxd
    private static func locateEmuxdBinary() -> String? {
        let fm = FileManager.default

        if let overridePath = ProcessInfo.processInfo.environment["EMUX_DAEMON_PATH"],
           fm.isExecutableFile(atPath: overridePath) {
            return overridePath
        }

        let bundlePath = Bundle.main.bundlePath + "/Contents/MacOS/emuxd"
        if fm.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        let home = NSHomeDirectory()
        let devPaths = [
            "\(home)/Code/emux/daemon/.build/debug/emuxd",
            "\(home)/Code/emux/daemon/.build/release/emuxd",
        ]
        for path in devPaths where fm.isExecutableFile(atPath: path) {
            NSLog("[DaemonLauncher] using dev binary at \(path)")
            return path
        }

        NSLog("[DaemonLauncher] no emuxd binary found in any known location")
        return nil
    }

    // MARK: - Spawn (posix_spawn with SETSID)

    private static func spawnDaemon(binary: String) throws -> pid_t {
        // Prepare log file. Path: ~/Library/Logs/emux/emuxd.log
        let logsDir = NSHomeDirectory() + "/Library/Logs/emux"
        try? FileManager.default.createDirectory(
            atPath: logsDir, withIntermediateDirectories: true)
        let logPath = "\(logsDir)/emuxd.log"

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // POSIX_SPAWN_SETSID: run the child in a new session, detached
        // from our controlling terminal + process group. Survives our
        // exit.
        var flags: Int16 = 0
        flags |= Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&attr, flags)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin ← /dev/null (daemon reads nothing)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // stdout + stderr → log file (append)
        let logMode: mode_t = 0o644
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, logMode)
        posix_spawn_file_actions_addopen(&fileActions, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, logMode)

        // argv — must include argv[0] and be null-terminated.
        let argv0 = strdup(binary)
        defer { free(argv0) }
        var argv: [UnsafeMutablePointer<CChar>?] = [argv0, nil]

        // envp — pass NULL to inherit our environment.
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &fileActions, &attr, argv, nil)
        if rc != 0 {
            throw NSError(domain: "DaemonLauncher", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(rc)))"
            ])
        }
        return pid
    }

    // MARK: - Socket helpers

    private static func defaultSocketPath() -> String {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return (appSupport?.appendingPathComponent("emux/emux.sock").path)
            ?? (NSHomeDirectory() + "/Library/Application Support/emux/emux.sock")
    }

    private static func connectUnixSocket(path: String) -> (fd: Int32, addrLen: socklen_t)? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { cp in
                for (i, b) in pathBytes.enumerated() {
                    cp[i] = CChar(bitPattern: b)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        if rc != 0 {
            close(fd)
            return nil
        }
        return (fd, addrLen)
    }

    private static func writeLine(fd: Int32, jsonObject: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        data.append(0x0A)  // newline
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: "DaemonLauncher", code: Int(errno))
                }
                offset += n
            }
        }
    }

    private static func readLine(fd: Int32, timeout: TimeInterval) throws -> Data? {
        // Set socket recv timeout so a hung daemon doesn't block us.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: "DaemonLauncher", code: Int(errno))
            }
            if n == 0 { return nil }
            for i in 0..<n {
                let byte = chunk[i]
                if byte == 0x0A {
                    // ignore anything after the newline in this read —
                    // we only expect one message at a time from the daemon
                    return buffer
                }
                buffer.append(byte)
                if buffer.count > 1_000_000 {
                    throw NSError(domain: "DaemonLauncher", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "response too large"
                    ])
                }
            }
        }
    }

    // MARK: - Version + constants

    /// Must stay in sync with daemon's ProtocolVersion.current
    /// (daemon/Sources/emuxd/Protocol/Messages.swift). Any change
    /// requires a coordinated update on both sides.
    private static let clientProtocolVersion = 1

    private static func appVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - Alerts

    @MainActor
    private static func presentIncompatibleAlert(status: DaemonStatus) {
        let alert = NSAlert()
        alert.messageText = "emux daemon version mismatch"
        alert.informativeText = """
            The running emuxd speaks protocol version \(status.protocolVersion), but this app expects version \(clientProtocolVersion).

            Stop the old daemon so a compatible one can start:
                emux daemon stop

            Then reopen emux.
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    @MainActor
    private static func presentMissingBinaryAlert() {
        let alert = NSAlert()
        alert.messageText = "emux daemon binary not found"
        alert.informativeText = """
            emux couldn't find the emuxd binary. This is a dev-mode issue — the daemon isn't yet copied into the app bundle by the build system.

            To fix:
                cd ~/Code/emux/daemon
                swift build

            Then reopen emux. (Or set EMUX_DAEMON_PATH in your Xcode scheme to point at a specific binary.)
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    @MainActor
    private static func presentSpawnFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "emux daemon failed to start"
        alert.informativeText = "\(error.localizedDescription)\n\nCheck ~/Library/Logs/emux/emuxd.log for details."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    @MainActor
    private static func presentTimeoutAlert() {
        let alert = NSAlert()
        alert.messageText = "emux daemon didn't come up"
        alert.informativeText = """
            The emuxd process was spawned but didn't respond within 15 seconds.

            Check ~/Library/Logs/emux/emuxd.log for details.
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}

// MARK: - Data helpers

private extension Data {
    func parseAsJSONObject() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self, options: [])) as? [String: Any]
    }
}
