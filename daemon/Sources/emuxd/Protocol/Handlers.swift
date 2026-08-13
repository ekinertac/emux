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

        // Task 6c pane.* handlers are implemented below but NOT wired
        // to the dispatch table yet. libghostty's threading model
        // needs another look:
        //   • Calling ghostty_surface_new from the client dispatch
        //     queue (off-main) crashes libghostty during setup.
        //   • Hopping to main via DispatchQueue.main.sync from the
        //     client thread deadlocks — main is being drained by
        //     dispatchMain() and something in the surface init flow
        //     re-enters the client queue or takes a lock main also
        //     wants.
        // Fix requires: dedicated ghostty operations serial queue,
        // OR async response pattern (semaphore-signaled from a
        // main-queue block), OR restructuring how the daemon owns
        // main. Punting until next session.

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
            "pane_count": WorkspaceStore.shared.paneCount,
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

    // MARK: - pane.* (Task 6c)

    /// pane.spawn — create a real PTY in the daemon. Client passes
    /// window_id + tab_id + cwd; returns pane_id + initial size.
    /// Runs on the client dispatch queue — libghostty surface init
    /// doesn't strictly require main; the earlier main-queue dispatch
    /// deadlocked because the client thread was serial + main was
    /// being drained by dispatchMain. Off-main is fine.
    private static func handlePaneSpawn(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable {
            let window_id: UUID
            let tab_id: UUID
            let cwd: URL
        }
        do {
            let p = try request.params.decodeAs(Params.self)
            let paneId: UUID
            do {
                paneId = try WorkspaceStore.shared.spawnPane(
                    windowId: p.window_id, tabId: p.tab_id, cwd: p.cwd)
            } catch {
                return ControlResponse(
                    id: request.id,
                    error: ControlError(code: ErrorCode.internalError,
                                        message: "spawn failed: \(error)"))
            }
            guard let info = WorkspaceStore.shared.paneInfo(paneId) else {
                return ControlResponse(
                    id: request.id,
                    error: ControlError(code: ErrorCode.internalError,
                                        message: "pane created but info lookup failed"))
            }
            let result: [String: Any] = [
                "pane": [
                    "pane_id": paneId.uuidString,
                    "window_id": info.windowId.uuidString,
                    "tab_id": info.tabId.uuidString,
                    "cwd": p.cwd.path,
                    "cols": Int(info.cols),
                    "rows": Int(info.rows),
                    "exited": false
                ]
            ]
            return ControlResponse(id: request.id, result: AnyCodable(result))
        } catch {
            return badParams(request.id, error: error)
        }
    }

    /// pane.close — terminate the pane's PTY.
    private static func handlePaneClose(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable { let pane_id: UUID }
        do {
            let p = try request.params.decodeAs(Params.self)
            let closed = WorkspaceStore.shared.closePane(p.pane_id)
            if !closed {
                return ControlResponse(
                    id: request.id,
                    error: ControlError(code: ErrorCode.notFound,
                                        message: "no pane with id \(p.pane_id)"))
            }
            return ControlResponse(id: request.id, result: AnyCodable(["closed": true]))
        } catch {
            return badParams(request.id, error: error)
        }
    }

    /// pane.write — send input bytes (base64) to a pane's PTY.
    private static func handlePaneWrite(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable {
            let pane_id: UUID
            let bytes: String  // base64
        }
        do {
            let p = try request.params.decodeAs(Params.self)
            guard let data = Data(base64Encoded: p.bytes) else {
                return ControlResponse(
                    id: request.id,
                    error: ControlError(code: ErrorCode.invalidParams,
                                        message: "bytes must be base64"))
            }
            let written = WorkspaceStore.shared.writePane(p.pane_id, bytes: data)
            if !written {
                return ControlResponse(
                    id: request.id,
                    error: ControlError(code: ErrorCode.notFound,
                                        message: "no pane with id \(p.pane_id)"))
            }
            return ControlResponse(id: request.id, result: AnyCodable(["written": data.count]))
        } catch {
            return badParams(request.id, error: error)
        }
    }

    /// pane.read — dump the pane's current viewport as text. Debug
    /// helper for now; production reads should go through the binary
    /// transport socket (Task 7). Useful for smoke tests via nc.
    private static func handlePaneRead(_ request: ControlRequest) -> ControlResponse {
        struct Params: Codable { let pane_id: UUID }
        do {
            let p = try request.params.decodeAs(Params.self)
            let text = WorkspaceStore.shared.readPane(p.pane_id)
            return ControlResponse(id: request.id, result: AnyCodable(["text": text]))
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
