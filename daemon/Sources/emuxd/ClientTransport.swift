// ClientTransport — listener on emux-client.sock for per-pane binary
// screen streams. See docs/protocol.md §9.
//
// Flow:
//   1. Client calls control socket's `client.attach(pane_id)` and
//      gets back a stream_id (opaque UUID).
//   2. Client connects to emux-client.sock, writes one line of JSON
//      hello: {"kind":"hello","protocol_version":1,"stream_id":"..."}
//      terminated by \n.
//   3. Daemon replies with a single byte: 0x00 accepted, 0x01 unknown
//      stream. If unknown, daemon closes the socket.
//   4. From here on the connection carries binary frames only:
//        [4-byte BE length][1-byte type][payload...]
//      Total payload length = len - 1 (length INCLUDES the type byte).
//   5. Daemon → client: SCREEN_RESET (0x02) frame with the pane's
//      current screen bytes as the first payload. Subsequent frames
//      (SCREEN_UPDATE, CURSOR, TITLE_CHANGED, BELL) land in Task 7b+.
//
// Task 7a scope: this file plus client.attach handler in
// Protocol/Handlers.swift. Streams stay open indefinitely but no
// live updates yet — SCREEN_RESET fires once at attach and that's it.
// Task 7b adds the update loop.

import Foundation
import Darwin

/// Frame type bytes per protocol.md §9.1.
enum TransportFrameType: UInt8 {
    // Server → client
    case screenUpdate  = 0x01
    case screenReset   = 0x02
    case cursor        = 0x03
    case titleChanged  = 0x04
    case bell          = 0x05
    // Client → server
    case input         = 0x10  // raw bytes → PTY (keystrokes/paste)
    case resize        = 0x11  // JSON {cols,rows}
}

final class ClientTransport {
    static var shared: ClientTransport?

    private let listener: UnixSocketServer
    private var actualListener: UnixSocketServer?
    private let streamsLock = NSLock()
    /// Active transport connections keyed by stream_id.
    private var streams: [UUID: TransportConnection] = [:]
    /// Reverse index: paneId → set of stream_ids attached. Lets
    /// pushScreenUpdate(paneId:) fan out to just the relevant
    /// streams without scanning every open transport connection.
    private var streamsByPane: [UUID: Set<UUID>] = [:]
    /// Pending attach reservations from client.attach. Client has
    /// 5 seconds to connect + hello with the stream_id, or the
    /// reservation is dropped.
    private var pendingAttachments: [UUID: PendingAttach] = [:]

    private struct PendingAttach {
        let paneId: UUID
        let deadline: Date
    }

    init(socketPath: String) {
        self.listener = UnixSocketServer(path: socketPath, handler: { _ in })
    }

    func start() throws {
        let self_ = self
        let path = SocketPaths.clientTransportSocket.path
        let l = UnixSocketServer(path: path) { fd in
            self_.acceptedConnection(fd: fd)
        }
        try l.bind()
        l.startAcceptLoop()
        self.actualListener = l
        Self.shared = self
        Log.info("transport", "client transport listening at \(path)")

        // Start the SCREEN_UPDATE poll loop. Every 100ms, for each
        // pane that has attached streams, capture the current screen
        // text and — if it differs from the last snapshot — push a
        // SCREEN_UPDATE frame to every attached stream.
        //
        // MVP-simple. Doesn't matter which libghostty action fires;
        // we just observe the result. Delta encoding + tighter
        // trigger points are optimizations for later.
        //
        // Runs on the ghostty main queue because it calls
        // readPane → ghostty_surface_read_text which is a libghostty
        // API and must be on main.
        pollForUpdates()
    }

    /// Per-pane last-sent screen snapshot for diff detection. Keyed
    /// by paneId so multiple panes are polled independently.
    private var lastSentByPane: [UUID: String] = [:]

    private func pollForUpdates() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.tickPoll()
        }
    }

    private func tickPoll() {
        streamsLock.lock()
        let paneIds = Array(streamsByPane.keys)
        streamsLock.unlock()

        for paneId in paneIds {
            let current = WorkspaceStore.shared.readPane(paneId)
            let last = lastSentByPane[paneId]
            if current != last {
                lastSentByPane[paneId] = current
                streamsLock.lock()
                let sids = streamsByPane[paneId] ?? []
                let conns = sids.compactMap { streams[$0] }
                streamsLock.unlock()
                let payload = Data(current.utf8)
                for conn in conns {
                    conn.sendFrame(type: .screenUpdate, payload: payload)
                }
            }
        }
        pollForUpdates()  // reschedule
    }

    func stop() {
        actualListener?.stop()
        streamsLock.lock()
        let conns = Array(streams.values)
        streams.removeAll()
        streamsLock.unlock()
        for c in conns { c.close() }
    }

    // MARK: - Attach reservations

    /// Called from control-socket client.attach handler. Allocates a
    /// stream_id, records the pending pane binding, returns the id.
    /// If the client doesn't connect within 5 seconds, the reservation
    /// is dropped by the next cleanup pass (or lazily on connect).
    func reserveAttach(paneId: UUID) -> UUID {
        let streamId = UUID()
        streamsLock.lock()
        pendingAttachments[streamId] = PendingAttach(
            paneId: paneId,
            deadline: Date().addingTimeInterval(5))
        streamsLock.unlock()
        Log.debug("transport", "reserved stream=\(streamId.uuidString.prefix(8)) for pane=\(paneId.uuidString.prefix(8))")
        return streamId
    }

    // MARK: - Accept + hello

    private func acceptedConnection(fd: Int32) {
        Log.debug("transport", "transport connection fd=\(fd)")
        let q = DispatchQueue(label: "emuxd.transport.\(fd)", qos: .userInitiated)
        q.async { [weak self] in
            self?.handleConnection(fd: fd)
        }
    }

    private func handleConnection(fd: Int32) {
        // Read one JSON line = the hello.
        var buffer = Data()
        let helloBytes = readUntilNewline(fd: fd, buffer: &buffer, maxBytes: 4096)
        guard let helloData = helloBytes else {
            Log.debug("transport", "fd=\(fd) EOF/error before hello")
            close(fd); return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: helloData) as? [String: Any],
              obj["kind"] as? String == "hello",
              let streamIdStr = obj["stream_id"] as? String,
              let streamId = UUID(uuidString: streamIdStr) else {
            Log.warn("transport", "fd=\(fd) bad hello, closing")
            _ = writeByte(fd: fd, 0x01)
            close(fd); return
        }

        streamsLock.lock()
        let pending = pendingAttachments.removeValue(forKey: streamId)
        streamsLock.unlock()
        guard let pending, pending.deadline >= Date() else {
            Log.warn("transport", "fd=\(fd) unknown/expired stream_id \(streamId.uuidString.prefix(8))")
            _ = writeByte(fd: fd, 0x01)
            close(fd); return
        }

        // Accepted.
        _ = writeByte(fd: fd, 0x00)
        Log.info("transport", "attached stream=\(streamId.uuidString.prefix(8)) → pane=\(pending.paneId.uuidString.prefix(8))")

        let conn = TransportConnection(fd: fd, streamId: streamId, paneId: pending.paneId)
        streamsLock.lock()
        streams[streamId] = conn
        streamsByPane[pending.paneId, default: []].insert(streamId)
        streamsLock.unlock()

        // Send initial SCREEN_RESET with the pane's current text.
        // Task 7a keeps it plain text (no ANSI encoding) — that
        // shows up correctly if the client just prints the bytes;
        // full-fidelity replay lands in Task 7b when we hook screen
        // callbacks and start sending the actual ANSI byte stream.
        let text = WorkspaceStore.shared.readPane(pending.paneId)
        conn.sendFrame(type: .screenReset, payload: Data(text.utf8))

        // Read binary frames from the client (INPUT / RESIZE per
        // protocol.md §9). Frame format:
        //   [4-byte BE length][1-byte type][payload of len-1 bytes]
        // Bad frames or EOF end the connection.
        var readBuf = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            // Ensure we have at least the 5-byte header.
            while readBuf.count < 5 {
                let n = scratch.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n <= 0 { break }
                readBuf.append(contentsOf: scratch.prefix(n))
            }
            if readBuf.count < 5 { break }  // EOF or error
            let totalLen = UInt32(readBuf[0]) << 24
                         | UInt32(readBuf[1]) << 16
                         | UInt32(readBuf[2]) << 8
                         | UInt32(readBuf[3])
            let type = readBuf[4]
            let payloadLen = Int(totalLen) - 1
            if payloadLen < 0 || payloadLen > 4 * 1024 * 1024 {
                Log.warn("transport", "stream=\(streamId.uuidString.prefix(8)) bad frame len \(totalLen), closing")
                break
            }
            // Ensure the full payload is in the buffer.
            while readBuf.count < 5 + payloadLen {
                let n = scratch.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n <= 0 { break }
                readBuf.append(contentsOf: scratch.prefix(n))
            }
            if readBuf.count < 5 + payloadLen { break }
            let payload = readBuf.subdata(in: 5..<5 + payloadLen)
            readBuf = readBuf.subdata(in: 5 + payloadLen..<readBuf.count)

            switch type {
            case TransportFrameType.input.rawValue:
                // Raw bytes → PTY. Hop to main (libghostty rule).
                DispatchQueue.main.sync {
                    _ = WorkspaceStore.shared.writePane(pending.paneId, bytes: payload)
                }
            case TransportFrameType.resize.rawValue:
                // Payload = JSON {cols, rows}.
                if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                   let cols = obj["cols"] as? Int,
                   let rows = obj["rows"] as? Int {
                    DispatchQueue.main.sync {
                        _ = WorkspaceStore.shared.resizePane(pending.paneId,
                                                             cols: UInt16(cols),
                                                             rows: UInt16(rows))
                    }
                } else {
                    Log.warn("transport", "stream=\(streamId.uuidString.prefix(8)) bad RESIZE payload")
                }
            default:
                // Unknown frame type — protocol.md says receivers MUST
                // skip and continue, not close. Already consumed via
                // the payload slice above.
                Log.debug("transport", "stream=\(streamId.uuidString.prefix(8)) unknown frame type 0x\(String(type, radix: 16))")
            }
        }
        Log.info("transport", "detached stream=\(streamId.uuidString.prefix(8))")
        streamsLock.lock()
        streams.removeValue(forKey: streamId)
        streamsByPane[pending.paneId]?.remove(streamId)
        if streamsByPane[pending.paneId]?.isEmpty == true {
            streamsByPane.removeValue(forKey: pending.paneId)
        }
        streamsLock.unlock()
        conn.close()
    }

    /// Push a SCREEN_UPDATE frame with the pane's current text to
    /// every attached stream. Called by GhosttyRuntime.action when
    /// libghostty fires GHOSTTY_ACTION_RENDER for this surface.
    /// MVP sends the full plain-text screen every time — no diffing.
    /// Delta encoding + ANSI-fidelity encoding land later.
    func pushScreenUpdate(paneId: UUID) {
        streamsLock.lock()
        let sids = streamsByPane[paneId] ?? []
        let conns = sids.compactMap { streams[$0] }
        streamsLock.unlock()
        guard !conns.isEmpty else { return }
        let text = WorkspaceStore.shared.readPane(paneId)
        let payload = Data(text.utf8)
        for conn in conns {
            conn.sendFrame(type: .screenUpdate, payload: payload)
        }
    }

    // MARK: - Frame helpers

    private func writeByte(fd: Int32, _ byte: UInt8) -> Bool {
        var b = byte
        let n = Darwin.write(fd, &b, 1)
        return n == 1
    }

    private func readUntilNewline(fd: Int32, buffer: inout Data, maxBytes: Int) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
                return line
            }
            if buffer.count > maxBytes { return nil }
            let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }
}

// MARK: - TransportConnection

/// One attached client's binary channel. Owns the fd, writes frames.
final class TransportConnection {
    let fd: Int32
    let streamId: UUID
    let paneId: UUID
    private let writeLock = NSLock()
    private var closed: Bool = false

    init(fd: Int32, streamId: UUID, paneId: UUID) {
        self.fd = fd
        self.streamId = streamId
        self.paneId = paneId
    }

    /// Send one framed message: [4-byte BE length][1-byte type][payload].
    /// length includes the type byte (= 1 + payload.count).
    func sendFrame(type: TransportFrameType, payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return }
        let totalLen = UInt32(1 + payload.count)
        var header = [UInt8](repeating: 0, count: 5)
        header[0] = UInt8((totalLen >> 24) & 0xFF)
        header[1] = UInt8((totalLen >> 16) & 0xFF)
        header[2] = UInt8((totalLen >> 8) & 0xFF)
        header[3] = UInt8(totalLen & 0xFF)
        header[4] = type.rawValue
        var buffer = Data(header)
        buffer.append(payload)
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    Log.warn("transport", "stream=\(streamId.uuidString.prefix(8)) write err \(errno)")
                    return
                }
                offset += n
            }
        }
    }

    func close() {
        writeLock.lock()
        if closed { writeLock.unlock(); return }
        closed = true
        writeLock.unlock()
        Darwin.close(fd)
    }
}
