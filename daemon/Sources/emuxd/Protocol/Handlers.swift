// Handlers — dispatch table for control-socket JSON-RPC methods.
//
// Task 3 lands two methods: daemon.status and daemon.stop. Every
// subsequent task adds handlers here as new methods come online:
//   Task 5: workspace.* and pane.write, pane.spawn, pane.close
//   Task 7: client.attach / client.detach
//   Task 11: (persistence hooks visible in daemon.status output)
//
// Handlers run on the per-client thread that received the request —
// each connection is single-threaded on the reader side. If a handler
// needs to touch shared state, it must serialize with a lock or a
// serial dispatch queue owned by the shared resource.

import Foundation

/// Dispatch a decoded request to its handler. Returns the response to
/// send back on the same connection. `MethodDispatcher` is stateless
/// today; when workspace/pane state lands, it holds references to the
/// shared state stores.
enum MethodDispatcher {
    /// Result of a method dispatch. `.response` gets serialized and
    /// written; `.responseAndExit` writes the response then closes
    /// the connection AND signals daemon shutdown.
    enum DispatchResult {
        case response(ControlResponse)
        case responseAndExit(ControlResponse)
    }

    static func dispatch(_ request: ControlRequest) -> DispatchResult {
        Log.debug("dispatch", "id=\(request.id) method=\(request.method)")

        switch request.method {
        case "daemon.status":
            return .response(handleDaemonStatus(request))
        case "daemon.stop":
            let resp = ControlResponse(
                id: request.id,
                result: AnyCodable(["stopping": true])
            )
            return .responseAndExit(resp)
        default:
            let err = ControlError(
                code: ErrorCode.unknownMethod,
                message: "no handler for method '\(request.method)' at protocol version \(ProtocolVersion.current)"
            )
            return .response(ControlResponse(id: request.id, error: err))
        }
    }

    // MARK: - daemon.status

    private static func handleDaemonStatus(_ request: ControlRequest) -> ControlResponse {
        let uptime = Int(ProcessInfo.processInfo.systemUptime - DaemonStartTime.startedAt)
        let result: [String: Any] = [
            "version": ProtocolVersion.daemonVersion,
            "protocol_version": ProtocolVersion.current,
            "uptime_seconds": uptime,
            // Placeholder counts — Task 5 wires the real workspace/pane
            // stores in and these become live counts.
            "pane_count": 0,
            "window_count": 0,
            "attached_clients": ControlServer.shared?.attachedClientCount ?? 0
        ]
        return ControlResponse(id: request.id, result: AnyCodable(result))
    }
}

/// Uptime anchor — captured at daemon boot in main.swift so
/// daemon.status can report seconds since start.
enum DaemonStartTime {
    static var startedAt: TimeInterval = 0
}
