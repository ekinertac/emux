// Handlers — dispatch table for control-socket JSON-RPC methods.
//
// Adds workspace.* methods on top of daemon.status/daemon.stop that
// Task 3 landed. See docs/protocol.md §7 for the full method surface.
//
// Handlers run on the per-client thread that received the request —
// each connection is single-threaded on the reader side. Shared state
// (WorkspaceStore) is thread-safe internally via its NSLock.

import Foundation

enum MethodDispatcher {
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

        case "workspace.list":
            return .response(handleWorkspaceList(request))
        case "workspace.snapshot":
            return .response(handleWorkspaceSnapshot(request))
        case "workspace.create":
            return .response(handleWorkspaceCreate(request))
        case "workspace.delete":
            return .response(handleWorkspaceDelete(request))
        case "workspace.mutate":
            return .response(handleWorkspaceMutate(request))

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
            "pane_count": 0,  // Task 6+ will fill this in from PTYRuntime
            "window_count": WorkspaceStore.shared.windowCount,
            "attached_clients": ControlServer.shared?.attachedClientCount ?? 0
        ]
        return ControlResponse(id: request.id, result: AnyCodable(result))
    }

    // MARK: - workspace.*

    private static func handleWorkspaceList(_ request: ControlRequest) -> ControlResponse {
        let windows = WorkspaceStore.shared.listOrdered()
        // Encode via JSONEncoder → decode via JSONSerialization to
        // convert into AnyCodable-friendly dictionaries. This keeps
        // Date/URL formatting consistent with the rest of the wire.
        do {
            let encoded = try snapshotEncoder.encode(windows)
            let obj = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
            return ControlResponse(id: request.id, result: AnyCodable(["windows": obj]))
        } catch {
            let err = ControlError(code: ErrorCode.internalError,
                                   message: "encode workspace list failed: \(error)")
            return ControlResponse(id: request.id, error: err)
        }
    }

    private static func handleWorkspaceSnapshot(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable { let window_id: UUID }
        do {
            let p = try request.params.decodeAs(Params.self)
            guard let snap = WorkspaceStore.shared.snapshot(windowId: p.window_id) else {
                let err = ControlError(code: ErrorCode.notFound,
                                       message: "no window with id \(p.window_id)")
                return ControlResponse(id: request.id, error: err)
            }
            return okResponse(id: request.id, encoding: ["snapshot": snap])
        } catch {
            return badParams(request.id, error: error)
        }
    }

    private static func handleWorkspaceCreate(_ request: ControlRequest) -> ControlResponse {
        let snap = WorkspaceStore.shared.createWindow()
        do {
            let snapData = try snapshotEncoder.encode(snap)
            let snapObj = try JSONSerialization.jsonObject(with: snapData, options: [.fragmentsAllowed])
            let result: [String: Any] = [
                "window_id": snap.id.uuidString,
                "snapshot": snapObj
            ]
            return ControlResponse(id: request.id, result: AnyCodable(result))
        } catch {
            let err = ControlError(code: ErrorCode.internalError,
                                   message: "encode workspace.create result failed: \(error)")
            return ControlResponse(id: request.id, error: err)
        }
    }

    private static func handleWorkspaceDelete(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable { let window_id: UUID }
        do {
            let p = try request.params.decodeAs(Params.self)
            let existed = WorkspaceStore.shared.deleteWindow(p.window_id)
            guard existed else {
                let err = ControlError(code: ErrorCode.notFound,
                                       message: "no window with id \(p.window_id)")
                return ControlResponse(id: request.id, error: err)
            }
            return ControlResponse(id: request.id, result: AnyCodable(["deleted": true]))
        } catch {
            return badParams(request.id, error: error)
        }
    }

    private static func handleWorkspaceMutate(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable {
            let window_id: UUID
            let mutation: WorkspaceMutation
        }
        do {
            let p = try request.params.decodeAs(Params.self)
            let snap = try WorkspaceStore.shared.apply(p.mutation, toWindow: p.window_id)
            return okResponse(id: request.id, encoding: ["snapshot": snap])
        } catch let e as WorkspaceStore.MutationError {
            let code: String
            switch e {
            case .windowNotFound, .projectNotFound, .tabNotFound:
                code = ErrorCode.notFound
            case .invalidReorder:
                code = ErrorCode.invalidParams
            }
            return ControlResponse(
                id: request.id,
                error: ControlError(code: code, message: "\(e)")
            )
        } catch {
            return badParams(request.id, error: error)
        }
    }

    // MARK: - Encoding helpers

    /// Shared encoder configured with ISO8601 dates. Matches
    /// Persistence's encoder so wire and disk formats agree.
    private static let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Build a response result from a [String: any Encodable] where
    /// the values may be Codable structs. Encodes each value via
    /// snapshotEncoder, decodes back to Any, wraps in AnyCodable.
    private static func okResponse<V: Encodable>(id: String, encoding dict: [String: V]) -> ControlResponse {
        do {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                let data = try snapshotEncoder.encode(v)
                out[k] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            }
            return ControlResponse(id: id, result: AnyCodable(out))
        } catch {
            let err = ControlError(code: ErrorCode.internalError,
                                   message: "encode result failed: \(error)")
            return ControlResponse(id: id, error: err)
        }
    }

    private static func badParams(_ id: String, error: Error) -> ControlResponse {
        return ControlResponse(
            id: id,
            error: ControlError(code: ErrorCode.invalidParams,
                                message: "params decoding failed: \(error)")
        )
    }
}

/// Uptime anchor — captured at daemon boot in main.swift.
enum DaemonStartTime {
    static var startedAt: TimeInterval = 0
}
