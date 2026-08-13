// DaemonConnection — persistent client for the emuxd control socket.
//
// One connection per app process (singleton via `.shared` after
// `bootstrap()` succeeds). Owns the read loop, request/response
// correlation by id, and event routing.
//
// Request model is SYNC-blocking with a semaphore:
//   let result = try daemon.request(method: "workspace.list", params: [:])
// This keeps ProjectsModel's API sync-compatible with the existing
// SwiftUI callers. Round-trips should be <10ms on a healthy daemon,
// so main-thread blocking is acceptable for MVP. If we start seeing
// hitches, refactor to async/await.
//
// Events (workspace.updated, workspace.deleted, later pane.exit) are
// dispatched to per-window handlers keyed by windowId. Handlers run
// on the reader thread — they should hand off to MainActor via
// DispatchQueue.main.async.

import Foundation
import Darwin

final class DaemonConnection {
    static private(set) var shared: DaemonConnection?

    /// Open a fresh connection to the daemon control socket and complete
    /// the hello handshake. Returns the connection on success.
    /// Sets `.shared` if successful.
    static func bootstrap(socketPath: String) throws -> DaemonConnection {
        let conn = try DaemonConnection(socketPath: socketPath)
        shared = conn
        return conn
    }

    private let fd: Int32
    private var readerThread: Thread!
    private let pendingLock = NSLock()
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    /// Event handlers keyed by (eventName, optional windowIdString).
    /// A nil windowIdString subscribes to the event across every window.
    private let eventLock = NSLock()
    private var eventHandlers: [String: [(String?, ([String: Any]) -> Void)]] = [:]

    private let writeLock = NSLock()

    private init(socketPath: String) throws {
        guard let sock = Self.connectUnixSocket(path: socketPath) else {
            throw ConnectionError.connectFailed(path: socketPath)
        }
        self.fd = sock

        // Hello handshake — send client hello, expect daemon hello.
        let hello: [String: Any] = [
            "kind": "hello",
            "protocol_version": ClientProtocol.version,
            "client": "emux.app",
            "client_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        ]
        try Self.writeJSONLine(fd: fd, object: hello)

        // Read one line — daemon's hello. Blocking read with a 5s
        // timeout via setsockopt.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let helloData = try Self.readLine(fd: fd),
              let helloObj = try JSONSerialization.jsonObject(with: helloData) as? [String: Any] else {
            close(fd)
            throw ConnectionError.handshakeFailed(reason: "no daemon hello")
        }
        // If daemon rejected us, helloObj will be a response with an
        // error field. Surface it clearly.
        if let err = helloObj["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "unknown"
            let msg = err["message"] as? String ?? ""
            close(fd)
            throw ConnectionError.handshakeFailed(reason: "\(code): \(msg)")
        }
        // Clear the recv timeout — reader loop below runs indefinitely.
        var tvOff = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tvOff, socklen_t(MemoryLayout<timeval>.size))

        NSLog("[DaemonConnection] handshake ok — daemon proto=\(helloObj["protocol_version"] ?? "?")")

        // Start the reader loop.
        self.readerThread = Thread { [weak self] in
            self?.runReadLoop()
        }
        self.readerThread.name = "emux.daemon-reader"
        self.readerThread.start()
    }

    // MARK: - Public API

    /// Send a request, block until response arrives, return result dict
    /// or throw the daemon's error.
    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = UUID().uuidString
        let sem = DispatchSemaphore(value: 0)
        var response: Result<[String: Any], Error>?

        pendingLock.lock()
        pending[id] = { result in
            response = result
            sem.signal()
        }
        pendingLock.unlock()

        let msg: [String: Any] = [
            "kind": "request",
            "id": id,
            "method": method,
            "params": params,
        ]
        do {
            try Self.writeJSONLine(fd: fd, object: msg, lock: writeLock)
        } catch {
            pendingLock.lock()
            pending.removeValue(forKey: id)
            pendingLock.unlock()
            throw error
        }

        // Wait for response. 30 second cap — if daemon hangs longer
        // than that, something's very wrong.
        let waited = sem.wait(timeout: .now() + 30)
        if waited == .timedOut {
            pendingLock.lock()
            pending.removeValue(forKey: id)
            pendingLock.unlock()
            throw ConnectionError.requestTimeout(method: method)
        }

        switch response! {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    /// Subscribe to a push event. Optional windowId filters to only
    /// events whose payload has a matching "window_id". Handler runs
    /// on the reader thread — hop to main if updating UI.
    func subscribe(event name: String, forWindow windowId: UUID? = nil, handler: @escaping ([String: Any]) -> Void) {
        eventLock.lock()
        eventHandlers[name, default: []].append((windowId?.uuidString, handler))
        eventLock.unlock()
    }

    // MARK: - Read loop

    private func runReadLoop() {
        while true {
            let line: Data?
            do {
                line = try Self.readLine(fd: fd)
            } catch {
                NSLog("[DaemonConnection] read error: \(error) — connection lost")
                failAllPending(with: ConnectionError.disconnected)
                return
            }
            guard let data = line else {
                NSLog("[DaemonConnection] EOF from daemon")
                failAllPending(with: ConnectionError.disconnected)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[DaemonConnection] undecodable line dropped")
                continue
            }
            switch obj["kind"] as? String {
            case "response":
                handleResponse(obj)
            case "event":
                handleEvent(obj)
            default:
                NSLog("[DaemonConnection] unexpected kind: \(obj["kind"] ?? "?")")
            }
        }
    }

    private func handleResponse(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        pendingLock.lock()
        let callback = pending.removeValue(forKey: id)
        pendingLock.unlock()
        guard let cb = callback else {
            NSLog("[DaemonConnection] response for unknown id \(id)")
            return
        }
        if let err = obj["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "unknown"
            let msg = err["message"] as? String ?? ""
            cb(.failure(ConnectionError.daemonError(code: code, message: msg)))
        } else if let result = obj["result"] as? [String: Any] {
            cb(.success(result))
        } else {
            cb(.failure(ConnectionError.malformedResponse))
        }
    }

    private func handleEvent(_ obj: [String: Any]) {
        guard let name = obj["name"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }
        let windowIdInPayload = payload["window_id"] as? String
        eventLock.lock()
        let handlers = eventHandlers[name] ?? []
        eventLock.unlock()
        for (targetWid, handler) in handlers {
            if let target = targetWid, target != windowIdInPayload { continue }
            handler(payload)
        }
    }

    private func failAllPending(with error: Error) {
        pendingLock.lock()
        let all = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, cb) in all {
            cb(.failure(error))
        }
    }

    // MARK: - Low-level socket helpers

    private static func connectUnixSocket(path: String) -> Int32? {
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
        if rc != 0 { close(fd); return nil }
        return fd
    }

    static func writeJSONLine(fd: Int32, object: [String: Any], lock: NSLock? = nil) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        lock?.lock()
        defer { lock?.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ConnectionError.writeFailed(errno: errno)
                }
                offset += n
            }
        }
    }

    static func readLine(fd: Int32) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw ConnectionError.readFailed(errno: errno)
            }
            if n == 0 { return nil }
            for i in 0..<n {
                let byte = chunk[i]
                if byte == 0x0A { return buffer }
                buffer.append(byte)
                if buffer.count > 4 * 1024 * 1024 {
                    throw ConnectionError.messageTooLarge
                }
            }
        }
    }
}

// MARK: - Errors

enum ConnectionError: Error, CustomStringConvertible {
    case connectFailed(path: String)
    case handshakeFailed(reason: String)
    case disconnected
    case requestTimeout(method: String)
    case daemonError(code: String, message: String)
    case malformedResponse
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case messageTooLarge

    var description: String {
        switch self {
        case .connectFailed(let p): return "connect(\(p)) failed"
        case .handshakeFailed(let r): return "handshake failed: \(r)"
        case .disconnected: return "daemon disconnected"
        case .requestTimeout(let m): return "request '\(m)' timed out after 30s"
        case .daemonError(let c, let m): return "\(c): \(m)"
        case .malformedResponse: return "malformed response from daemon"
        case .readFailed(let e): return "read failed errno=\(e)"
        case .writeFailed(let e): return "write failed errno=\(e)"
        case .messageTooLarge: return "message exceeds 4MiB limit"
        }
    }
}

enum ClientProtocol {
    /// Must stay in sync with daemon's ProtocolVersion.current.
    static let version = 1
}
