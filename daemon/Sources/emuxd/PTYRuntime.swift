// PTYRuntime — per-pane wrapper around ghostty_surface_t.
//
// One PTYRuntime holds one live PTY (shell process running headlessly
// in the daemon), its ghostty_surface_t, and the invisible NSView that
// libghostty requires for its Metal setup. The NSView is never
// attached to a window; wantsLayer=true is enough to keep
// ghostty_surface_new happy (validated by the Task 6c spike).
//
// Lifecycle:
//   spawn(cwd, cols, rows)     — allocates NSView + ghostty_surface_new
//   sendInput(bytes)           — ghostty_surface_text; keystrokes / paste
//   resize(cols, rows)         — resize NSView frame, libghostty picks
//                                up on next tick
//   readScreen()               — dump viewport as text (for periodic
//                                scrollback capture + client attach)
//   close()                    — ghostty_surface_free, releases PTY
//
// The daemon-owned NSApp (.accessory) keeps Metal setup from
// exploding. Rendering never happens (we never call draw), but
// libghostty's terminal PARSER + PTY reader run just fine and
// populate the grid we can query via ghostty_surface_read_text.

import Foundation
import AppKit
import GhosttyKit

final class PTYRuntime {
    /// Daemon-generated id, referenced from control protocol as pane_id.
    let paneId: UUID
    let windowId: UUID
    let tabId: UUID

    /// The invisible NSView libghostty attaches to. Kept as a strong
    /// reference so it outlives the surface — libghostty stores the
    /// underlying pointer and dereferences it during ticks.
    private let view: NSView

    /// The ghostty_surface_t. Freed on close().
    private var surface: ghostty_surface_t?

    /// Latest known grid size. Updated by ghostty_surface_size after
    /// resize.
    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24

    /// True after close(). Prevents double-free.
    private(set) var closed: Bool = false

    init(paneId: UUID, windowId: UUID, tabId: UUID) {
        self.paneId = paneId
        self.windowId = windowId
        self.tabId = tabId
        // Frame size drives the initial grid dimensions. libghostty
        // divides by cell size (~12x30 for default font) to get
        // cols/rows. We resize precisely on the first client.attach.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view.wantsLayer = true
    }

    deinit {
        // Belt-and-suspenders: if someone forgot to call close(),
        // libghostty leaks the PTY. Cover it here.
        if !closed, let surface {
            ghostty_surface_free(surface)
        }
    }

    /// Create the underlying ghostty_surface_t. Should be called on
    /// the main thread — libghostty callbacks re-enter there. We
    /// don't precondition on Thread.isMainThread because the
    /// daemon's dispatchMain() flow can execute main-queue blocks
    /// on threads that don't self-identify as "main" via NSThread.
    /// Correctness is enforced by the caller (Handlers.handlePaneSpawn
    /// wraps in DispatchQueue.main.sync).
    func spawn(cwd: URL) throws {
        Log.debug("pty", "spawn on thread \(Thread.current.description) main=\(Thread.isMainThread)")
        guard surface == nil else {
            throw SpawnError.alreadySpawned
        }
        guard let app = GhosttyRuntime.shared.app else {
            throw SpawnError.appNotReady
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
        )
        config.scale_factor = 2.0
        config.font_size = 12

        // strdup the cwd — libghostty may retain the pointer beyond
        // our call. Freed after ghostty_surface_new returns; libghostty
        // copies to its own storage before returning per the header
        // docs.
        let cwdPtr = strdup(cwd.path)
        defer { free(cwdPtr) }
        config.working_directory = UnsafePointer(cwdPtr)

        guard let s = ghostty_surface_new(app, &config) else {
            throw SpawnError.surfaceNewFailed
        }
        self.surface = s

        // Read back the grid size libghostty picked based on our
        // 800x600 view frame + default font.
        let size = ghostty_surface_size(s)
        self.cols = size.columns
        self.rows = size.rows
        Log.info("pty", "spawned pane=\(paneId.uuidString.prefix(8)) cwd=\(cwd.path) size=\(cols)x\(rows)")
    }

    /// Feed input bytes to the PTY. Handles keystrokes, paste content,
    /// etc. Bytes are UTF-8; caller responsible for encoding.
    func sendInput(_ bytes: Data) {
        guard let surface, !closed else { return }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, base, UInt(raw.count))
        }
    }

    /// Read the entire viewport as UTF-8 text. Used for client-attach
    /// SCREEN_RESET frames and periodic scrollback capture.
    /// Returns empty string if surface is closed or read fails.
    func readScreen() -> String {
        guard let surface, !closed else { return "" }
        let size = ghostty_surface_size(surface)
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(max(0, Int(size.columns) - 1)),
            y: UInt32(max(0, Int(size.rows) - 1))
        )
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text),
              let ptr = text.text else {
            return ""
        }
        let s = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)
        return s
    }

    /// Free the surface and release the PTY. Safe to call more than
    /// once (subsequent calls are no-ops).
    func close() {
        guard let s = surface, !closed else { return }
        ghostty_surface_free(s)
        surface = nil
        closed = true
        Log.info("pty", "closed pane=\(paneId.uuidString.prefix(8))")
    }
}

enum SpawnError: Error, CustomStringConvertible {
    case alreadySpawned
    case appNotReady
    case surfaceNewFailed

    var description: String {
        switch self {
        case .alreadySpawned: return "PTYRuntime.spawn called twice"
        case .appNotReady: return "GhosttyRuntime not bootstrapped"
        case .surfaceNewFailed: return "ghostty_surface_new returned nil"
        }
    }
}
