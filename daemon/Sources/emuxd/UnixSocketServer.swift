// UnixSocketServer — thin wrapper around POSIX AF_UNIX socket ops.
//
// Network.framework's NWListener is TCP/UDP-centric and doesn't clean
// up nicely for Unix sockets on macOS — POSIX is simpler and better
// documented. We handle bind + listen + accept-loop here; per-client
// I/O happens on the caller's thread (ControlServer runs each client
// on its own dispatch queue).
//
// Lifecycle:
//   let server = UnixSocketServer(path: "/tmp/foo.sock")
//   try server.bind()          // unlinks stale + binds + listens
//   server.startAcceptLoop { fd in ... }   // accept fires on server thread
//   server.stop()              // closes listen fd, signals loop to exit

import Foundation
import Darwin

final class UnixSocketServer {
    private let path: String
    private var listenFd: Int32 = -1
    private var acceptThread: Thread?
    private var running: Bool = false
    private let handler: (Int32) -> Void

    /// Initialize with the socket path and a per-connection handler.
    /// Handler is called with an accepted file descriptor; the handler
    /// owns the fd from that point (must close when done).
    init(path: String, handler: @escaping (Int32) -> Void) {
        self.path = path
        self.handler = handler
    }

    /// Create the socket, unlink any stale file at the path, bind, listen.
    /// Sets mode to 0600 so only the current user can connect.
    func bind() throws {
        // Remove any stale socket file. `unlink` returns -1 with
        // ENOENT if the file doesn't exist — that's fine, ignore.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.socketFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // sun_path is a fixed-size C char array. macOS limit is 104
        // bytes including the null terminator. Enforce that here so we
        // fail with a clear error instead of silent truncation.
        let pathBytes = Array(path.utf8) + [0]  // null-terminate
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw SocketError.pathTooLong(len: pathBytes.count, max: maxLen)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { charPtr in
                for (i, b) in pathBytes.enumerated() {
                    charPtr[i] = CChar(bitPattern: b)
                }
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrSize)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.bindFailed(errno: err, path: path)
        }

        chmod(path, 0o600)

        // Backlog 32 — plenty of headroom for our expected concurrency
        // (few clients per user, no burst spikes).
        guard Darwin.listen(fd, 32) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw SocketError.listenFailed(errno: err)
        }

        self.listenFd = fd
        Log.info("socket", "bound \(path) fd=\(fd)")
    }

    /// Start the accept loop on a dedicated background thread. Each
    /// accepted connection triggers `handler(fd)` on that same thread —
    /// the handler is expected to hand the fd off to a per-client
    /// dispatch queue or thread and return quickly.
    func startAcceptLoop() {
        guard listenFd >= 0 else {
            Log.error("socket", "startAcceptLoop called before bind()")
            return
        }
        running = true
        let thread = Thread {
            self.acceptLoop()
        }
        thread.name = "emuxd.accept-\(path)"
        thread.start()
        self.acceptThread = thread
    }

    private func acceptLoop() {
        Log.debug("socket", "accept loop started for \(path)")
        while running {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                // Capture errno immediately — later logging/Swift-runtime
                // work can clobber it before we read it.
                let capturedErrno = errno
                if capturedErrno == EINTR { continue }
                if !running {
                    // stop() was called; whatever errno accept saw here
                    // (EBADF, ECONNABORTED, others depending on OS
                    // scheduling), we're intentionally shutting down.
                    break
                }
                Log.error("socket", "accept() failed errno=\(capturedErrno) (\(String(cString: strerror(capturedErrno))))")
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            Log.debug("socket", "accepted fd=\(clientFd)")
            handler(clientFd)
        }
        Log.debug("socket", "accept loop exited for \(path)")
    }

    /// Signal the accept loop to exit, close the listen fd, unlink
    /// the socket file. Safe to call multiple times.
    func stop() {
        running = false
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(path)
        Log.info("socket", "stopped \(path)")
    }
}

enum SocketError: Error, CustomStringConvertible {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32, path: String)
    case listenFailed(errno: Int32)
    case pathTooLong(len: Int, max: Int)

    var description: String {
        switch self {
        case .socketFailed(let e):
            return "socket() failed: errno=\(e) (\(String(cString: strerror(e))))"
        case .bindFailed(let e, let p):
            return "bind(\(p)) failed: errno=\(e) (\(String(cString: strerror(e))))"
        case .listenFailed(let e):
            return "listen() failed: errno=\(e) (\(String(cString: strerror(e))))"
        case .pathTooLong(let len, let max):
            return "socket path is \(len) bytes; sun_path limit is \(max) on macOS"
        }
    }
}
