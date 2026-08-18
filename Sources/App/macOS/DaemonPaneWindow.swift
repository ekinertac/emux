// DaemonPaneWindow — proof-of-concept window that renders a real
// daemon-owned PTY inside the app. Task 8 deliverable.
//
// Flow when opened:
//   1. Call pane.spawn on DaemonConnection.shared to create a pane
//      in the daemon (cwd=$HOME by default).
//   2. Call client.attach → get a stream_id.
//   3. Open TransportClient with that stream_id.
//   4. Route incoming SCREEN_UPDATE/RESET → text view content.
//   5. Route TITLE_CHANGED → window title.
//   6. Route BELL → NSSound beep.
//   7. Keystrokes typed in the text view → INPUT frames.
//   8. On close: pane.close on the daemon, close TransportClient.
//
// Not integrated with the emux tab strip yet — this is a standalone
// window to prove the daemon flow works end-to-end from the app's
// perspective. Real integration lands in Task 10.
//
// Rendering: a plain NSTextView showing the current screen text.
// No ANSI parsing, no colors, no cursor rendering. Full-viewport
// dump replaces the text view content on each SCREEN_UPDATE. Ugly
// but functional. Real terminal-quality rendering (via a
// client-side libghostty surface fed the daemon's bytes) is Task 9.

import AppKit
import Foundation

final class DaemonPaneWindowController: NSWindowController {
    private var transport: TransportClient?
    private var paneId: UUID?

    private var textView: NSTextView!
    /// Latest screen text without any injected cursor marker. We
    /// re-render (with-or-without cursor) from this on each blink
    /// tick, so successive frames don't accumulate cursor glyphs.
    private var latestScreenText: String = ""
    /// Toggles every ~500ms — appends a block glyph as the last
    /// character when true, nothing when false. Fake cursor, but
    /// it makes the window feel like a terminal.
    private var cursorVisible: Bool = false
    private var cursorTimer: Timer?

    convenience init() {
        // Plain resizable window with a scrollable text view inside.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daemon Pane (attaching…)"
        window.center()

        let scrollView = NSTextView.scrollableTextView()
        let tv = scrollView.documentView as! NSTextView
        tv.isEditable = false          // input is captured via key events, not typed
        tv.isSelectable = false        // no selection at all — it's a terminal, not a doc
        tv.isRichText = false
        tv.font = NSFont(name: "IosevkaTerm Nerd Font Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor(white: 0.87, alpha: 1.0)  // #dedede — softer than pure white
        tv.backgroundColor = NSColor(white: 0.07, alpha: 1.0)  // #121212 — softer than pure black
        // Layout: no wrapping, tight leading, edge-to-edge padding.
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.autoresizingMask = [.width, .height]
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        window.contentView = scrollView

        self.init(window: window)
        self.textView = tv

        // Intercept keystrokes at the window level so we can forward
        // them to the daemon as INPUT frames instead of NSTextView
        // consuming them.
        installKeyMonitor(window: window)

        // 500ms blink cadence — matches most terminals' default.
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorVisible.toggle()
            self.renderTextView()
        }

        // Kick off spawn + attach async so init returns quickly.
        DispatchQueue.main.async { [weak self] in
            self?.spawnAndAttach()
        }
    }

    private func installKeyMonitor(window: NSWindow) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window,
                  event.window === window else { return event }
            self.handleKeyDown(event)
            return nil  // consume — don't let NSTextView see it
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // MVP encoder: turn NSEvent into raw bytes for the shell.
        // Handle plain characters + a small set of control keys.
        // Real production encoder is a full copy of Ghostty's key
        // encoding — a job for later.

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        // Control-key shortcut: Ctrl+A .. Ctrl+Z + a few extras.
        if modifiers.contains(.control), chars.count == 1,
           let c = chars.first, c.isASCII {
            let ascii = c.asciiValue!
            let ctrl: UInt8?
            switch ascii {
            case 0x40...0x7E:  // @, A-Z, [, \, ], ^, _, backtick, a-z
                ctrl = ascii & 0x1F
            default:
                ctrl = nil
            }
            if let ctrl {
                transport?.sendInput(Data([ctrl]))
                return
            }
        }

        // Special keys via keyCode. Values from HIToolbox/Events.h.
        switch event.keyCode {
        case 51:  // delete/backspace → 0x7f
            transport?.sendInput(Data([0x7F])); return
        case 36:  // return → \n
            transport?.sendInput(Data([0x0D])); return
        case 48:  // tab
            transport?.sendInput(Data([0x09])); return
        case 53:  // esc
            transport?.sendInput(Data([0x1B])); return
        case 123: // left arrow → ESC [ D
            transport?.sendInput(Data([0x1B, 0x5B, 0x44])); return
        case 124: // right arrow → ESC [ C
            transport?.sendInput(Data([0x1B, 0x5B, 0x43])); return
        case 125: // down arrow → ESC [ B
            transport?.sendInput(Data([0x1B, 0x5B, 0x42])); return
        case 126: // up arrow → ESC [ A
            transport?.sendInput(Data([0x1B, 0x5B, 0x41])); return
        default: break
        }

        // Plain characters (including shifted ones from characters,
        // which respects modifier state).
        if let s = event.characters, !s.isEmpty {
            transport?.sendInput(Data(s.utf8))
        }
    }

    // MARK: - Spawn + attach flow

    private func spawnAndAttach() {
        guard let daemon = DaemonConnection.shared else {
            self.window?.title = "Daemon Pane — no daemon connection"
            return
        }
        // For MVP: use any existing window's id from the daemon, or
        // just spawn against a well-known id. We need SOMETHING; use
        // the first snapshot's window_id.
        let windowId: String
        do {
            let listResult = try daemon.request(method: "workspace.list", params: [:])
            let windows = listResult["windows"] as? [[String: Any]] ?? []
            guard let first = windows.first, let wid = first["id"] as? String else {
                self.window?.title = "Daemon Pane — no windows in daemon"
                return
            }
            windowId = wid
        } catch {
            self.window?.title = "Daemon Pane — workspace.list failed: \(error)"
            return
        }

        do {
            // Fresh UUID for the tab binding on each open. Debug
            // window isn't tied to any real emux tab yet; this just
            // has to be a syntactically valid UUID for the daemon
            // to decode.
            let fakeTabId = UUID().uuidString
            let spawnResult = try daemon.request(method: "pane.spawn", params: [
                "window_id": windowId,
                "tab_id": fakeTabId,
                "cwd": "file://" + NSHomeDirectory() + "/"
            ])
            guard let pane = spawnResult["pane"] as? [String: Any],
                  let pidStr = pane["pane_id"] as? String,
                  let pid = UUID(uuidString: pidStr) else {
                self.window?.title = "Daemon Pane — spawn returned no pane_id"
                return
            }
            self.paneId = pid
            NSLog("[DaemonPaneWindow] spawned pane \(pidStr.prefix(8))")

            let attachResult = try daemon.request(method: "client.attach", params: ["pane_id": pidStr])
            guard let sidStr = attachResult["stream_id"] as? String,
                  let sid = UUID(uuidString: sidStr) else {
                self.window?.title = "Daemon Pane — attach returned no stream_id"
                return
            }
            NSLog("[DaemonPaneWindow] reserved stream \(sidStr.prefix(8))")

            let client = try TransportClient(streamId: sid, paneId: pid)
            client.onScreen = { [weak self] text in
                DispatchQueue.main.async { self?.renderScreen(text) }
            }
            client.onTitle = { [weak self] title in
                DispatchQueue.main.async { self?.window?.title = "Daemon: \(title)" }
            }
            client.onBell = {
                DispatchQueue.main.async { NSSound.beep() }
            }
            client.onDisconnect = { [weak self] in
                DispatchQueue.main.async {
                    self?.window?.title = "Daemon Pane — disconnected"
                    self?.transport = nil
                }
            }
            self.transport = client
            self.window?.title = "Daemon Pane — pid \(pidStr.prefix(8))"
        } catch {
            self.window?.title = "Daemon Pane — spawn/attach failed: \(error)"
        }
    }

    private func renderScreen(_ text: String) {
        latestScreenText = text
        renderTextView()
    }

    /// Redraw the text view from `latestScreenText`, optionally
    /// appending a block glyph to represent the (fake) cursor.
    /// Called on screen updates AND on every cursor-blink tick.
    private func renderTextView() {
        // Trim trailing whitespace lines so the cursor lands right
        // after the last visible character, not at the bottom of an
        // empty viewport. libghostty's read_text includes trailing
        // blanks up to the grid size, which for us is 19 rows —
        // without trimming, the cursor would sit at row 19 forever.
        var text = latestScreenText
        while text.hasSuffix("\n") { text.removeLast() }

        if cursorVisible {
            text.append("▊")
        }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Cleanup

    override func close() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        // Send pane.close before tearing down — leaks a daemon-side
        // pane otherwise.
        if let pid = paneId,
           let daemon = DaemonConnection.shared {
            do {
                _ = try daemon.request(method: "pane.close", params: ["pane_id": pid.uuidString])
            } catch {
                NSLog("[DaemonPaneWindow] pane.close failed: \(error)")
            }
        }
        transport?.close()
        transport = nil
        super.close()
    }
}
