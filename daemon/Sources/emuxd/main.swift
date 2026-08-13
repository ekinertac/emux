// emuxd — the emux mux daemon entry point.
//
// Owns libghostty, all PTYs, and the workspace/tab/pane tree. Client
// (emux.app) attaches over local Unix sockets. See docs/protocol.md
// for the wire protocol and docs/superpowers/plans/2026-08-13-phase-g-
// daemon-split.md for the Phase G plan.
//
// Task 2 stub: prints "emuxd starting" to stderr and exits 0. Real
// initialization lands in later tasks:
//   Task 3 — control socket + JSON-RPC dispatch
//   Task 6 — Ghostty.App init in headless NSApp (verified by Task 0
//            spike; works with .setActivationPolicy(.accessory))
//   Task 7 — screen-frame serialization on the client transport socket
//   Task 11 — persistence + scrollback replay

import Foundation

FileHandle.standardError.write("emuxd starting\n".data(using: .utf8)!)
exit(0)
