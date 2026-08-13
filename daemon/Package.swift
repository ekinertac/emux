// swift-tools-version: 5.9
//
// emuxd — the headless mux daemon that owns libghostty, all PTYs,
// workspaces, tabs, and per-window persistence. Client (emux.app)
// attaches over local Unix sockets; see docs/protocol.md.
//
// Built as a SwiftPM package rather than a second Xcode target so it's
// standalone-buildable (`cd daemon && swift build`) and testable in
// isolation. The built binary is copied into emux.app/Contents/MacOS/
// by a build phase on the app target (wired up in Task 4).
//
// GhosttyKit linkage is intentionally deferred — Task 6 adds it as a
// binary target pointing at ../Frameworks/GhosttyKit.xcframework. For
// Task 2 the daemon has no libghostty dependency yet.
//
// See docs/superpowers/plans/2026-08-13-phase-g-daemon-split.md.

import PackageDescription

let package = Package(
    name: "emuxd",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "emuxd", targets: ["emuxd"]),
    ],
    targets: [
        .executableTarget(
            name: "emuxd",
            path: "Sources/emuxd"
        ),
    ]
)
