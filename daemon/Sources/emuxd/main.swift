// emuxd — the emux mux daemon entry point.
//
// Owns libghostty (Task 6), all PTYs, and the workspace/tab/pane tree.
// Client (emux.app) attaches over local Unix sockets. See
// docs/protocol.md for the wire protocol and
// docs/superpowers/plans/2026-08-13-phase-g-daemon-split.md for the
// Phase G plan.
//
// Task 3: control socket + JSON-RPC dispatch. Two methods live now:
//   daemon.status → returns version + uptime + counts
//   daemon.stop   → responds then triggers clean shutdown
// Try it: `nc -U ~/Library/Application\ Support/emux/emux.sock` then
// send a hello line followed by request lines.

import Foundation
import Darwin

// Capture start time so daemon.status can report uptime.
DaemonStartTime.startedAt = ProcessInfo.processInfo.systemUptime

Log.info("emuxd", "starting (version=\(ProtocolVersion.daemonVersion) proto=\(ProtocolVersion.current) pid=\(ProcessInfo.processInfo.processIdentifier))")

// Make sure ~/Library/Application Support/emux exists before binding.
do {
    try SocketPaths.ensureRootExists()
} catch {
    Log.error("emuxd", "cannot create root dir at \(SocketPaths.rootDir.path): \(error)")
    exit(1)
}

// Load persisted workspace state from state.json.
WorkspaceStore.shared.loadFromDisk()

// Start the control server on emux.sock.
let controlServer = ControlServer(socketPath: SocketPaths.controlSocket.path)

// Wire WorkspaceStore change callbacks to broadcast workspace.updated
// events on the control socket. Every attached client sees these.
// MVP scope note: refinement (only clients with attached panes in the
// changed window) lands after Task 7's client.attach flow.
WorkspaceStore.shared.onWindowChanged = { snapshot in
    do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapData = try encoder.encode(snapshot)
        let snapObj = try JSONSerialization.jsonObject(with: snapData, options: [.fragmentsAllowed])
        let payload: [String: Any] = [
            "window_id": snapshot.id.uuidString,
            "snapshot": snapObj
        ]
        controlServer.broadcast(ControlEvent(name: "workspace.updated", payload: AnyCodable(payload)))
    } catch {
        Log.error("workspace", "failed to encode workspace.updated payload: \(error)")
    }
}
WorkspaceStore.shared.onWindowDeleted = { windowId in
    let payload: [String: Any] = ["window_id": windowId.uuidString]
    controlServer.broadcast(ControlEvent(name: "workspace.deleted", payload: AnyCodable(payload)))
}
controlServer.onShutdownRequested = {
    Log.info("emuxd", "shutdown requested via daemon.stop")
    controlServer.stop()
    exit(0)
}
do {
    try controlServer.start()
    Log.info("emuxd", "control server listening at \(SocketPaths.controlSocket.path)")
} catch {
    Log.error("emuxd", "control server failed to start: \(error)")
    exit(1)
}

// Trap SIGINT/SIGTERM so Ctrl-C during dev doesn't leave a stale
// socket file behind. Use DispatchSourceSignal because raw
// signal(SIGINT, ...) doesn't play well with Swift runtime.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    Log.info("emuxd", "SIGINT received; shutting down")
    controlServer.stop()
    exit(0)
}
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    Log.info("emuxd", "SIGTERM received; shutting down")
    controlServer.stop()
    exit(0)
}
sigtermSource.resume()

// Block forever. The control server runs its accept loop on its own
// thread; per-client dispatch queues handle I/O. main just needs to
// keep the process alive.
dispatchMain()
