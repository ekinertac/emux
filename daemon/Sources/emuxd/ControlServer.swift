// ControlServer — owns the control socket (emux.sock), accepts client
// connections, runs the hello handshake, and dispatches JSON-RPC to
// MethodDispatcher.
//
// Threading model: one dispatch queue per client (`emuxd.client.<fd>`),
// serial. Reads block until a newline arrives, then a message is
// decoded, dispatched, response written. Simple and predictable.
// When workspace/pane state lands (Task 5), shared-state mutations
// serialize onto a dedicated queue so client threads don't fight.
//
// Line reading uses a small helper (LineReader) because Foundation's
// InputStream is clunky for line-oriented protocols. Max message size
// is 1 MiB per protocol.md §2 — anything larger closes the connection
// with a message_too_large error.

import Foundation
import Darwin

/// One process-wide ControlServer instance. Kept as a singleton so
/// handlers (Handlers.swift) can query it for counts like
/// `attachedClientCount`.
final class ControlServer {
    static var shared: ControlServer?

    private let listener: UnixSocketServer
    private let clientLock = NSLock()
    private var clients: [Int: ClientConnection] = [:]  // fd → connection
    private let dispatchQueue = DispatchQueue(label: "emuxd.control-server", qos: .userInitiated)

    /// Called when daemon.stop is dispatched. main.swift wires this to
    /// begin graceful shutdown.
    var onShutdownRequested: (() -> Void)?

    init(socketPath: String) {
        self.listener = UnixSocketServer(path: socketPath, handler: { _ in
            // Placeholder — replaced by the closure that captures self
            // in start(). Silences init-order requirements.
        })
    }

    /// Bind the socket and begin accepting connections.
    func start() throws {
        // Rebuild the handler with a self-capturing closure now that
        // self is fully initialized.
        let selfRef = self
        let socketPath = SocketPaths.controlSocket.path
        let boundListener = UnixSocketServer(path: socketPath) { fd in
            selfRef.acceptedConnection(fd: fd)
        }
        try boundListener.bind()
        // Swap in the properly-wired listener before starting the loop.
        // This is a little awkward because init() has to seed a listener
        // to satisfy the `let` requirement — we replace it here.
        boundListener.startAcceptLoop()
        Self.shared = self
        // Hold onto the real listener so it isn't deinit-ed. We keep
        // this in a stored property since accept-thread needs the fd.
        self.replaceListener(with: boundListener)
    }

    // MARK: - Attached-client counting (for daemon.status)

    var attachedClientCount: Int {
        clientLock.lock()
        defer { clientLock.unlock() }
        return clients.count
    }

    // MARK: - Event broadcast

    /// Push a control event to every attached client. Used by
    /// WorkspaceStore hooks for workspace.updated / (later)
    /// pane.exit / daemon.shutting_down.
    ///
    /// MVP scope note (protocol.md §8.1 refinement): we currently
    /// broadcast to ALL clients. Once client.attach lands (Task 7),
    /// workspace.updated should only fan out to clients that hold an
    /// active attach on a pane in the changed window.
    func broadcast(_ event: ControlEvent) {
        clientLock.lock()
        let snapshot = Array(clients.values)
        clientLock.unlock()
        for client in snapshot {
            client.sendEvent(event)
        }
    }

    // MARK: - Internals

    private var actualListener: UnixSocketServer?

    private func replaceListener(with new: UnixSocketServer) {
        self.actualListener = new
    }

    /// Called on the accept thread. Spins up a per-client dispatch
    /// queue and hands the fd off.
    private func acceptedConnection(fd: Int32) {
        let conn = ClientConnection(fd: fd, server: self)
        clientLock.lock()
        clients[Int(fd)] = conn
        clientLock.unlock()

        let q = DispatchQueue(label: "emuxd.client.\(fd)", qos: .userInitiated)
        q.async {
            conn.run()
            self.clientLock.lock()
            self.clients.removeValue(forKey: Int(fd))
            self.clientLock.unlock()
        }
    }

    /// Called by ClientConnection when it dispatches a daemon.stop.
    /// Fires the shutdown callback (usually main.swift's exit path).
    func requestShutdown() {
        onShutdownRequested?()
    }

    /// Stop accepting new connections and close the listener. Existing
    /// client threads run to completion (they'll see EOF on their fds
    /// when the process exits).
    func stop() {
        actualListener?.stop()
    }
}

// MARK: - ClientConnection

/// One client's read/dispatch/write state. Runs entirely on the
/// per-client dispatch queue set up by ControlServer.acceptedConnection.
final class ClientConnection {
    private let fd: Int32
    private weak var server: ControlServer?
    private let reader: LineReader
    private var didHello: Bool = false
    /// Max bytes allowed per message (protocol.md §2 = 1 MiB).
    private let maxMessageBytes = 1 * 1024 * 1024

    init(fd: Int32, server: ControlServer) {
        self.fd = fd
        self.server = server
        self.reader = LineReader(fd: fd, maxLineBytes: 1 * 1024 * 1024)
    }

    /// Main loop for the client — blocks reading lines, decodes, dispatches.
    func run() {
        Log.info("client", "fd=\(fd) connected")
        defer {
            close(fd)
            Log.info("client", "fd=\(fd) disconnected")
        }

        // Hello handshake first.
        do {
            try performHello()
            didHello = true
        } catch {
            Log.warn("client", "fd=\(fd) hello failed: \(error)")
            return
        }

        // Request/response loop until EOF or fatal error.
        while true {
            let line: Data
            do {
                guard let l = try reader.readLine() else {
                    Log.debug("client", "fd=\(fd) EOF")
                    return
                }
                line = l
            } catch LineReader.Error.lineTooLong(let len) {
                writeError(id: nil, code: ErrorCode.messageTooLarge,
                           message: "message \(len) bytes exceeds 1 MiB limit; closing")
                return
            } catch {
                Log.warn("client", "fd=\(fd) read error: \(error)")
                return
            }

            handleRequestLine(line)
        }
    }

    /// Read the first line and validate it's a compatible client hello,
    /// then reply with the daemon hello. Any invalid input closes the
    /// connection.
    private func performHello() throws {
        guard let firstLine = try reader.readLine() else {
            throw HandshakeError.eofBeforeHello
        }
        let hello: ClientHello
        do {
            hello = try JSONDecoder().decode(ClientHello.self, from: firstLine)
        } catch {
            let err = ControlError(code: ErrorCode.invalidMessage,
                                   message: "hello did not parse as ClientHello: \(error)")
            writeControlError(err)
            throw HandshakeError.invalidHello
        }

        guard hello.kind == "hello" else {
            let err = ControlError(code: ErrorCode.invalidMessage,
                                   message: "first message must be kind=hello, got '\(hello.kind)'")
            writeControlError(err)
            throw HandshakeError.invalidHello
        }

        if hello.protocolVersion < ProtocolVersion.minSupported {
            let err = ControlError(code: ErrorCode.protocolIncompatible,
                                   message: "client protocol_version \(hello.protocolVersion) is below daemon's minimum \(ProtocolVersion.minSupported); upgrade the client")
            writeControlError(err)
            throw HandshakeError.protocolIncompatible
        }

        Log.info("client", "fd=\(fd) hello ok: client=\(hello.client)/\(hello.clientVersion) proto=\(hello.protocolVersion)")

        // Send our hello.
        let reply = DaemonHello()
        writeLock.lock()
        try writeMessage(reply)
        writeLock.unlock()
    }

    /// Decode + dispatch one request line.
    private func handleRequestLine(_ line: Data) {
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: line)
        } catch {
            writeError(id: nil, code: ErrorCode.invalidMessage,
                       message: "request did not parse: \(error)")
            return
        }

        guard request.kind == "request" else {
            writeError(id: request.id, code: ErrorCode.invalidMessage,
                       message: "expected kind=request, got '\(request.kind)'")
            return
        }

        let result = MethodDispatcher.dispatch(request)
        switch result {
        case .response(let resp):
            writeLock.lock()
            try? writeMessage(resp)
            writeLock.unlock()
        case .responseAndExit(let resp):
            writeLock.lock()
            try? writeMessage(resp)
            writeLock.unlock()
            // Fire the shutdown request on a background queue so we
            // don't deadlock — main.swift's shutdown may join threads.
            DispatchQueue.global().async {
                self.server?.requestShutdown()
            }
        }
    }

    /// Send a server-initiated event on this connection. Silent-fail on
    /// write error — the accept-loop / read-loop will pick up the dead
    /// connection separately. Serialized via writeLock so events don't
    /// interleave with responses on the same fd.
    func sendEvent(_ event: ControlEvent) {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try writeMessage(event)
        } catch {
            Log.debug("client", "fd=\(fd) event send failed: \(error)")
        }
    }

    // MARK: - Writes

    private let writeLock = NSLock()

    /// Encode a Codable message as JSON + newline and write to the fd.
    private func writeMessage<T: Encodable>(_ msg: T) throws {
        var data = try JSONEncoder().encode(msg)
        data.append(0x0A)  // newline
        try writeAll(data)
    }

    private func writeError(id: String?, code: String, message: String) {
        let resolvedId = id ?? "-"
        let resp = ControlResponse(id: resolvedId, error: ControlError(code: code, message: message))
        writeLock.lock()
        try? writeMessage(resp)
        writeLock.unlock()
    }

    private func writeControlError(_ err: ControlError) {
        // Used during hello — the message doesn't have a request id
        // yet. We wrap it as a response with id="-" per protocol
        // conventions (rejected before any request landed).
        writeError(id: nil, code: err.code, message: err.message)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(errno: errno)
                }
                offset += n
            }
        }
    }
}

enum HandshakeError: Error {
    case eofBeforeHello
    case invalidHello
    case protocolIncompatible
}

enum WriteError: Error {
    case writeFailed(errno: Int32)
}

// MARK: - LineReader

/// Simple newline-delimited reader over a POSIX fd. Buffers reads
/// internally; returns one line at a time (excluding the trailing
/// newline). Returns nil on EOF. Throws lineTooLong if the accumulated
/// line exceeds maxLineBytes.
final class LineReader {
    enum Error: Swift.Error {
        case lineTooLong(len: Int)
        case readFailed(errno: Int32)
    }

    private let fd: Int32
    private let maxLineBytes: Int
    private var buffer = Data()
    private let readChunkSize = 4096

    init(fd: Int32, maxLineBytes: Int) {
        self.fd = fd
        self.maxLineBytes = maxLineBytes
    }

    func readLine() throws -> Data? {
        while true {
            // Check for a complete line in the buffer.
            if let nlIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIndex)
                let after = buffer.index(after: nlIndex)
                buffer = buffer.subdata(in: after..<buffer.endIndex)
                return lineData
            }
            if buffer.count > maxLineBytes {
                throw Error.lineTooLong(len: buffer.count)
            }
            // Need more bytes.
            var chunk = Data(count: readChunkSize)
            let n = chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                let result = Darwin.read(fd, base, raw.count)
                return result
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw Error.readFailed(errno: errno)
            }
            if n == 0 {
                // EOF. If there's a partial line without newline, drop it
                // (protocol requires every message terminated by \n).
                return nil
            }
            buffer.append(chunk.prefix(n))
        }
    }
}
