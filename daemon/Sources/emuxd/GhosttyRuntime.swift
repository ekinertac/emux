// GhosttyRuntime — minimal Swift wrapper around ghostty_app_t.
//
// The app-side Sources/Ghostty/Ghostty.App.swift wraps ghostty_app for
// GUI use — it hooks NSApplication notifications, routes actions to an
// AppDelegate, drives the AppKit runloop. For the daemon we skip all
// of that: no menu bar, no dock icon, no AppKit actions to route.
// Just enough to own PTYs.
//
// Callback plumbing follows the C-API pattern: pass `self` as
// `userdata` via Unmanaged, cast back inside each C callback. Callbacks
// run on the same thread that calls ghostty_app_tick.
//
// Runloop: libghostty's wakeup_cb tells us "please call ghostty_app_tick
// soon." We hop to the main-queue and tick. main.swift's dispatchMain()
// keeps the main queue alive so this works.
//
// Task 0 spike verified: with `NSApplication.shared.setActivationPolicy(
// .accessory)` set BEFORE any libghostty call, Ghostty.App init works
// without a real GUI runloop. Daemon main.swift does that setup before
// GhosttyRuntime.shared is touched.

import Foundation
import AppKit
import GhosttyKit

final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?  // typedef'd to void* in the C header
    private var config: ghostty_config_t?

    /// libghostty is pinned to main. Both spawn/free/write/read AND
    /// the periodic tick run on main. Tried a dedicated non-main
    /// serial queue — libghostty crashed off-thread. All handler
    /// code hops to main via DispatchQueue.main.sync.
    var queue: DispatchQueue { .main }

    /// Set once at boot from main.swift. Idempotent no-op if already
    /// initialized. Fails hard (exit 1) on any libghostty error — the
    /// daemon can't do its job without libghostty. Runs on main
    /// (caller invokes from main.swift's top level pre-dispatchMain).
    /// libghostty pins itself to whatever thread ghostty_app_new
    /// runs on; we honor that by always using main.
    func bootstrap() {
        _bootstrap()
    }

    private func _bootstrap() {
        guard app == nil else {
            Log.warn("ghostty", "bootstrap called twice — ignoring")
            return
        }

        // Load default config from ~/.config/ghostty/config plus any
        // XDG paths libghostty knows about.
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Build the runtime config with our callback trampolines.
        // Store self via passUnretained — the runtime lives for the
        // process lifetime, so there's nothing to release.
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        var runtimeCfg = ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: false,  // no X11-style clipboard
            wakeup_cb: { userdata in
                // Re-enabled after NSApp.run() fixed the thread model.
                // Under dispatchMain(), wakeup-triggered tick reentered
                // libghostty on the wrong thread and hung. NSApp.run()
                // binds main queue to the real main thread, and our
                // tick uses queue.async which just schedules — no
                // in-line reentrancy.
                GhosttyRuntime.wakeup(userdata)
            },
            action_cb: { app, target, action in
                return GhosttyRuntime.action(app!, target: target, action: action)
            },
            read_clipboard_cb: { _, _, _ in
                // No-op: daemon has no clipboard. Clients handle
                // clipboard themselves via the input channel. Return
                // false to tell libghostty we didn't handle it.
                return false
            },
            confirm_read_clipboard_cb: { _, _, _, _ in
                // No-op.
            },
            write_clipboard_cb: { _, _, _, _, _ in
                // No-op: no daemon-side clipboard write.
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let a = ghostty_app_new(&runtimeCfg, cfg) else {
            Log.error("ghostty", "ghostty_app_new failed")
            exit(1)
        }
        self.app = a
        Log.info("ghostty", "ghostty_app initialized")

        // Drive ticks periodically on the ghostty queue. Ticks are
        // serialized with all other libghostty operations (spawn,
        // free, write, read). Between operations, the queue drains
        // pending ticks; during an operation, ticks wait — same as
        // any other serial-queue block. This resolves the earlier
        // "surface_free waits for tick, tick blocked behind free"
        // circular dependency: they're on the SAME queue now, and
        // free happens between two ticks, not concurrently with one.
        // 16ms cadence = ~60Hz screen refresh.
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.tickAndReschedule()
        }
    }

    private func tickAndReschedule() {
        if let a = app { ghostty_app_tick(a) }
        scheduleNextTick()
    }

    /// Explicit tick — retained for external callers, but production
    /// path is the periodic scheduleNextTick chain above. Async on
    /// the ghostty queue so it queues behind whatever's currently
    /// running.
    func tick() {
        guard let a = app else { return }
        queue.async { ghostty_app_tick(a) }
    }

    // MARK: - C-callback trampolines

    /// Called by libghostty when it wants us to tick. Runs on
    /// libghostty's internal thread — hop to main.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        runtime.tick()
    }

    /// Called for every ghostty action (render, new_window, close,
    /// prompt, notification, etc). The daemon is not a GUI app, so
    /// most actions are no-ops for us. Return true = handled; false
    /// = libghostty falls back.
    ///
    /// Surface-scoped actions we care about:
    ///   • GHOSTTY_ACTION_RENDER — screen contents changed. Push a
    ///     SCREEN_UPDATE frame to attached clients.
    /// Called for every ghostty action. We route the surface-scoped
    /// ones we care about (SET_TITLE, RING_BELL) to per-pane
    /// TransportFrame emission. RENDER never fires for our off-screen
    /// surface so SCREEN_UPDATE stays poll-driven (Task 7b).
    private static func action(_ app: ghostty_app_t,
                                target: ghostty_target_s,
                                action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let paneId = WorkspaceStore.shared.paneId(forSurface: surface) else {
            return false
        }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let title = String(cString: action.action.set_title.title)
            ClientTransport.shared?.pushTitleChanged(paneId: paneId, title: title)
            return true
        case GHOSTTY_ACTION_RING_BELL:
            ClientTransport.shared?.pushBell(paneId: paneId)
            return true
        default:
            return false
        }
    }

    /// Called when a surface's underlying process exits. Task 6c wires
    /// this to WorkspaceStore + broadcast pane.exit event.
    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        Log.info("ghostty.close_surface", "processAlive=\(processAlive)")
        // TODO Task 6c: look up which PaneRuntime owns this surface,
        // notify WorkspaceStore, emit pane.exit event over control
        // socket to all subscribed clients.
    }
}
