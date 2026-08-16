// TransportClient — app-side binary transport connection to emuxd.
//
// One TransportClient per attached daemon pane. Owns the POSIX fd to
// emux-client.sock, does the JSON hello handshake, then reads binary
// frames per docs/protocol.md §9:
//   [4-byte BE length][1-byte type][payload of len-1 bytes]
//
// Frame types (subset in use for MVP):
//   0x01 SCREEN_UPDATE — UTF-8 text payload = current viewport
//   0x02 SCREEN_RESET  — same, sent once on attach
//   0x04 TITLE_CHANGED — UTF-8 title string
//   0x05 BELL          — empty payload
//   0x10 INPUT         — client → server, raw bytes to PTY
//   0x11 RESIZE        — client → server, JSON {cols, rows}
//
// Callbacks (onScreen, onTitle, onBell) fire on the reader thread —
// consumers hop to main themselves for UI updates.
//
// This lives in the app target (not the daemon) because it's the
// client side of the transport. Companion to DaemonConnection.swift
// which handles the control socket. Task 8 wires the two together
// via DaemonPaneWindowController.

import Foundation
import Darwin

final class TransportClient {
    private let fd: Int32
    private let streamId: UUID
    private let paneId: UUID

    /// Fires when the daemon sends SCREEN_RESET or SCREEN_UPDATE.
    /// Payload is the pane's current viewport as UTF-8 text.
    /// Called on the reader thread — hop to main for UI updates.
    var onScreen: ((String) -> Void)?

    /// Fires on TITLE_CHANGED. UTF-8 title string. Reader thread.
    var onTitle: ((String) -> Void)?

    /// Fires on BELL. Reader thread.
    var onBell: (() -> Void)?

    /// Fires when the transport socket closes (daemon gone, or we
    /// hit a bad frame). Reader thread.
    var onDisconnect: (() -> Void)?

    private var readerThread: Thread!
    private let writeLock = NSLock()
    private var closed: Bool = false

    /// Open the transport socket, send the JSON hello with the
    /// stream_id we got from the control socket's client.attach call.
    /// Throws on connect / handshake failure.
    init(streamId: UUID, paneId: UUID) throws {
        self.streamId = streamId
        self.paneId = paneId

        let path = NSHomeDirectory() + "/Library/Application Support/emux/emux-client.sock"
        guard let fd = Self.connect(path: path) else {
            throw ClientError.connectFailed(path)
        }
        self.fd = fd

        let hello: [String: Any] = [
            "kind": "hello",
            "protocol_version": 1,
            "stream_id": streamId.uuidString
        ]
        var helloLine = try JSONSerialization.data(withJSONObject: hello)
        helloLine.append(0x0A)
        try Self.writeAll(fd: fd, data: helloLine)

        // Read the 1-byte accept marker.
        var accept: UInt8 = 0
        let n = Darwin.read(fd, &accept, 1)
        if n != 1 || accept != 0x00 {
            Darwin.close(fd)
            throw ClientError.rejected(accept)
        }

        self.readerThread = Thread { [weak self] in
            self?.runReadLoop()
        }
        self.readerThread.name = "emux.transport-reader.\(streamId.uuidString.prefix(8))"
        self.readerThread.start()
    }

    /// Send an INPUT frame — raw bytes route to the daemon pane's
    /// PTY via ghostty_surface_text.
    func sendInput(_ bytes: Data) {
        sendFrame(type: 0x10, payload: bytes)
    }

    /// Send a RESIZE frame — daemon resizes the pane's grid.
    func sendResize(cols: Int, rows: Int) {
        let payload: [String: Any] = ["cols": cols, "rows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            sendFrame(type: 0x11, payload: data)
        }
    }

    /// Close the connection. Reader thread exits on next read.
    func close() {
        writeLock.lock()
        if closed { writeLock.unlock(); return }
        closed = true
        writeLock.unlock()
        Darwin.close(fd)
    }

    // MARK: - Read loop

    private func runReadLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            // Ensure at least the 5-byte header.
            while buffer.count < 5 {
                let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n <= 0 { onDisconnect?(); return }
                buffer.append(contentsOf: chunk.prefix(n))
            }
            let totalLen = (UInt32(buffer[0]) << 24)
                         | (UInt32(buffer[1]) << 16)
                         | (UInt32(buffer[2]) << 8)
                         | (UInt32(buffer[3]))
            let type = buffer[4]
            let payloadLen = Int(totalLen) - 1
            if payloadLen < 0 || payloadLen > 4 * 1024 * 1024 {
                NSLog("[TransportClient] bad frame len \(totalLen), closing")
                onDisconnect?(); return
            }
            // Ensure full payload.
            while buffer.count < 5 + payloadLen {
                let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n <= 0 { onDisconnect?(); return }
                buffer.append(contentsOf: chunk.prefix(n))
            }
            let payload = buffer.subdata(in: 5..<5 + payloadLen)
            buffer = buffer.subdata(in: 5 + payloadLen..<buffer.count)

            switch type {
            case 0x01, 0x02:  // SCREEN_UPDATE / SCREEN_RESET
                if let text = String(data: payload, encoding: .utf8) {
                    onScreen?(text)
                }
            case 0x04:        // TITLE_CHANGED
                if let title = String(data: payload, encoding: .utf8) {
                    onTitle?(title)
                }
            case 0x05:        // BELL
                onBell?()
            default:
                // Unknown types — protocol says skip, don't close.
                break
            }
        }
    }

    // MARK: - Frame write

    private func sendFrame(type: UInt8, payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return }
        let totalLen = UInt32(1 + payload.count)
        var header = Data(count: 5)
        header[0] = UInt8((totalLen >> 24) & 0xFF)
        header[1] = UInt8((totalLen >> 16) & 0xFF)
        header[2] = UInt8((totalLen >> 8) & 0xFF)
        header[3] = UInt8(totalLen & 0xFF)
        header[4] = type
        var frame = header
        frame.append(payload)
        try? Self.writeAll(fd: fd, data: frame)
    }

    // MARK: - POSIX helpers

    private static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count <= maxLen else { Darwin.close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { cp in
                for (i, b) in bytes.enumerated() { cp[i] = CChar(bitPattern: b) }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        if rc != 0 { Darwin.close(fd); return nil }
        return fd
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.writeFailed(errno)
                }
                offset += n
            }
        }
    }
}

enum ClientError: Error, CustomStringConvertible {
    case connectFailed(String)
    case rejected(UInt8)
    case writeFailed(Int32)

    var description: String {
        switch self {
        case .connectFailed(let p): return "connect(\(p)) failed"
        case .rejected(let b): return "transport hello rejected (code 0x\(String(b, radix: 16)))"
        case .writeFailed(let e): return "write failed errno=\(e)"
        }
    }
}
