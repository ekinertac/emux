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
// GhosttyKit.xcframework is linked as a binary target — the same
// framework the app links, at the same relative path. Task 6 needs
// libghostty on the daemon side to own PTYs.

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
        .binaryTarget(
            name: "GhosttyKit",
            path: "../Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "emuxd",
            dependencies: ["GhosttyKit"],
            path: "Sources/emuxd",
            linkerSettings: [
                // libghostty (Zig) depends on these Apple frameworks.
                // The app target gets them auto-linked via Xcode's
                // implicit framework detection; SPM requires explicit
                // declaration. Match what Ghostty's own macos Xcode
                // project links.
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),  // Text Input Services (kTISProperty*)
                .linkedFramework("AudioToolbox"),  // audio bell
                .linkedFramework("UserNotifications"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),  // libghostty embeds glslang / spirv-cross (C++)
                .linkedLibrary("z"),
            ]
        ),
    ]
)
