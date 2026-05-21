# emux — Design Spec

**Date:** 2026-05-21
**Status:** Approved, ready for implementation planning
**Target user:** Ekin (primary author and sole user for v1)

---

## Overview

**emux** is a project-scoped terminal emulator for macOS. Each project owns its own tabs, splits, file tree, and editor files, so switching between concurrent projects is one click instead of mental context recovery across a flat list of iTerm2 tabs.

The renderer and terminal core come from **Ghostty** (consumed as a pinned `libghostty` library). The macOS app shell is a **detached fork** of Ghostty's existing Swift/SwiftUI app, restructured around a four-column project-first layout.

### Why this exists

The user runs 5–6 projects concurrently in iTerm2. The flat tab list does not encode "which project does this tab belong to," and context recovery across switches is expensive. emux makes the project the primary unit of organization: a tab cannot exist outside a project, and tabs / splits / file-tree / editor state are all scoped to the active project.

### What emux is not

- Not a full IDE. Editor is "IDE-lite" — syntax highlighting, multi-file tabs, save — no LSP, no autocomplete, no diagnostics in v1.
- Not a tmux replacement. Shells restart fresh on relaunch; visual state (cwd, scrollback) is restored but processes are not preserved.
- Not a Ghostty replacement. Terminal core remains Ghostty's; we change the app shell around it.

---

## Strategic Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Terminal core | `libghostty` as pinned library | Ghostty's renderer is fast, correct, and embeddable. Avoid re-deriving terminal work. |
| App shell | **Detached fork** of Ghostty's `macos/` Swift app | Ships fastest. No upstream merge cost. Acceptable: we own all bugs/features in the shell from day one. |
| Language stack | Swift / SwiftUI on macOS, AppKit where needed | Ghostty's shell is already Swift. Native macOS feel. |
| libghostty updates | Manual version bumps via vendored `GhosttyKit.xcframework` | No tagged-release binary exists; we build from a Ghostty tag, vendor the binary, bump deliberately. |
| Min macOS target | **14.0 (Sonoma)** | Modern SwiftUI APIs (`@Observable`, `NavigationSplitView`) without locking out Sonoma users. Ghostty's 13.0 baseline is more conservative than we need. |
| Editor library | **CodeEditSourceEditor** (from CodeEditApp) | Native AppKit `NSTextView` base, tree-sitter, multi-cursor, find/replace. Right grain for "IDE-lite". |
| Delivery cadence | **Phase-based** — each phase ships a runnable, visible UI/UX slice | User iterates on look-and-feel per phase. No monolithic deliveries. |

### License posture

Ghostty is MIT. The fork preserves the upstream copyright notice in retained source files and surfaces the upstream MIT text in the About sheet (under an "Acknowledgements" section that credits Ghostty + contributors). Renaming to "emux" and changing `com.mitchellh.ghostty` → `com.{owner}.emux` is permitted; no trademark concerns identified.

---

## §1 — Module / Folder Layout

emux is a single Xcode project, single scheme. The directory layout mirrors what we inherit from `Ghostty/macos/`, plus three new feature folders and a vendored framework.

```
emux/
├── emux.xcodeproj                     # renamed from Ghostty.xcodeproj
├── Frameworks/
│   └── GhosttyKit.xcframework         # vendored binary, built from a pinned Ghostty tag
├── scripts/
│   └── build-libghostty.sh            # one-shot xcframework builder (see §3)
├── docs/                              # spec, design notes, contributor docs
└── Sources/
    ├── App/macOS/                     [inherited, light edits]
    │   ├── main.swift                 # entry point; light edits for renaming + ProjectsModel init
    │   ├── AppDelegate.swift          # owns ProjectsModel singleton alongside Ghostty.App
    │   └── ghostty-bridging-header.h  # untouched
    ├── Ghostty/                       [inherited, UNTOUCHED]
    │   # The libghostty wrapper. Treat as a black box owned by upstream.
    │   # Includes Ghostty.App, SurfaceView, Input, Config.
    ├── Helpers/                       [inherited, mostly untouched]
    └── Features/
        ├── Projects/                  [NEW]
        │   ├── ProjectsModel.swift            # observable project list, persistence
        │   ├── ProjectsSidebarView.swift      # SwiftUI sidebar
        │   ├── ScrollbackTee.swift            # PTY data interceptor (arch TBD by Phase 6 PoC)
        │   └── PaneLifecycle.swift            # create/destroy orchestration
        ├── Editor/                    [NEW]
        │   ├── EditorColumnView.swift         # tab strip + active editor
        │   ├── EditorFileModel.swift          # buffer state, scroll/cursor
        │   └── EditorView.swift               # CodeEditSourceEditor wrapper
        ├── FileTree/                  [NEW]
        │   ├── FileTreeView.swift             # SwiftUI tree
        │   ├── FileTreeModel.swift            # directory model + FSEvents watcher
        │   └── FileTreeContextMenu.swift
        ├── Terminal/                  [INHERITED, MODIFIED]
        │   ├── TerminalController.swift       # add projectId; remove native NSWindow tabbing
        │   ├── BaseTerminalController.swift   # hooks for scrollback tee
        │   └── TerminalView.swift             # wrap in NSSplitViewController contentView
        ├── Splits/                    [INHERITED, light edits]
        │   # Generic SplitTree<ViewType>; binding stays SplitTree<Ghostty.SurfaceView>
        │   # (Editor lives in its own column, NOT inside splits.)
        ├── Settings/                  [INHERITED, light edits]
        │   # Add Projects + Editor settings tabs
        ├── Command Palette/           [INHERITED, EXTENDED in Phase 7]
        │   # Becomes ⌘⇧P: file fuzzy-finder in v1; command-palette mode in v2
        ├── Global Keybinds/           [INHERITED]
        ├── Secure Input/              [INHERITED]
        ├── Services/                  [INHERITED]
        ├── ClipboardConfirmation/     [INHERITED]
        ├── About/                     [REBRAND]
        │   # Credit Ghostty + bundle MIT acknowledgements
        ├── QuickTerminal/             [REMOVED]   # doesn't fit project-scoped model
        ├── Custom App Icon/           [REMOVED]   # not v1
        ├── Update/ (Sparkle)          [REMOVED]   # replace later if/when we ship publicly
        ├── AppleScript/               [REMOVED]   # Ghostty-branded .sdef; revisit if scripting needed
        └── App Intents/               [DEFERRED]  # rebrand later
```

### Inheritance rules

- **Untouched** (don't read except to debug): `Sources/Ghostty/`. This is the libghostty bridge. All terminal-core questions stay there.
- **Modified surgically**: `Sources/Features/Terminal/`, `Sources/Features/Splits/` (light), `Sources/App/macOS/AppDelegate.swift`. Targeted edits only.
- **New**: `Projects/`, `Editor/`, `FileTree/`. These are emux-original code.
- **Removed**: `QuickTerminal/`, `Custom App Icon/`, `Update/`, `AppleScript/`. Deleted on initial fork import.

### Bundle identity

`com.mitchellh.ghostty` → `com.{owner}.emux` everywhere it appears (`Info.plist`, `project.pbxproj`, `GhosttyPackage.swift` notification category, etc.). One-time grep-and-replace at fork time.

---

## §2 — Data Model & Persistence

### Storage tiers

```
~/Library/Application Support/emux/
├── state.json                            # structured app state (atomic write, debounced)
└── scrollback/
    └── {paneId}.bin                      # raw PTY bytes per pane, capped circular

~/Library/Preferences/com.{owner}.emux.plist  # UserDefaults — emux preferences
```

- **state.json** — projects, tabs, splits, editor files, window frame. Small volume (KBs), JSON for debuggability.
- **scrollback/{paneId}.bin** — raw PTY tee per pane. Per-file rotation, ~25 MB cap, drop first 2 MB on truncation.
- **UserDefaults** — emux app config (themes, editor defaults). Separate from `Ghostty.Config` (terminal-level config flows through Ghostty's existing `~/.config/ghostty/config`).

### Schema (Swift)

```swift
struct AppState: Codable {
    var schemaVersion: Int            // currently 1; bump on incompatible changes
    var projects: [Project]
    var lastActiveProjectId: UUID?
    var windowFrame: NSRect?
}

struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var path: URL
    var sortOrder: Int
    var createdAt: Date
    var lastOpenedAt: Date

    var tabs: [Tab]
    var activeTabId: UUID?

    var openEditorFiles: [EditorFile]
    var activeEditorFileId: UUID?

    var sidebarCollapsed: Bool
    var fileTreeCollapsed: Bool
    // Editor column auto-shows when openEditorFiles is non-empty; no explicit collapsed flag.
}

struct Tab: Identifiable, Codable {
    let id: UUID
    var title: String                 // defaults to active pane's cwd basename
    var layout: SplitNode
    var activePaneId: UUID
    var sortOrder: Int
}

indirect enum SplitNode: Codable {
    case leaf(Pane)
    case split(orientation: SplitOrientation, children: [SplitNode], ratios: [Double])
}

enum SplitOrientation: String, Codable { case horizontal, vertical }

struct Pane: Identifiable, Codable {
    let id: UUID
    var cwd: URL
    var shellOverride: String?        // nil → system default
    var scrollbackFileName: String    // "{id}.bin", relative to scrollback dir
}

struct EditorFile: Identifiable, Codable {
    let id: UUID
    var path: URL
    var scrollOffset: Double
    var cursorLine: Int
    var cursorColumn: Int
    var sortOrder: Int
}
```

### Save strategy

- Any model mutation triggers a **250 ms debounced** atomic write of `state.json`.
- Atomic write = write to `state.json.tmp`, fsync, `rename(2)` to `state.json`. Crashes never produce partial files.
- On launch, if `state.json` is missing → start empty. If corrupt → rename to `state.json.corrupt-{timestamp}` and start empty. Never crash on startup over persistence.

### Scrollback specifics

- Per-pane file at `scrollback/{paneId}.bin`, opened `O_APPEND | O_CREAT` at pane creation.
- All PTY output bytes tee'd to file as they arrive (raw, no parsing).
- Cap: **25 MB per pane**. On overflow, truncate from head: rewrite file with last 23 MB. Performed in a background queue, infrequently triggered.
- On pane close: delete the file.
- On project delete: delete all pane files for that project.

### Restore flow

1. Read `state.json` → present projects in sidebar.
2. Select `lastActiveProjectId` (or empty state).
3. For the active project: create one NSWindow, instantiate tabs from `Tab[]`, reconstruct each tab's split tree, spawn shells in each pane's `cwd`, replay scrollback bytes into surface, attach live PTY.
4. If `openEditorFiles` is non-empty: show editor column, open files in tab order, restore scroll/cursor on active file.

### Project switching: hide+show

When the user selects a different project in the sidebar:
1. Active project's NSWindow → `orderOut(_:)` (kept alive, just hidden).
2. Target project's NSWindow → `orderFront(_:)` (or created from state if first visit this session).
3. No process teardown; switching is instant.
4. State.json save reflects new `lastActiveProjectId`.

Memory cost: a shell + Ghostty surface per pane across all visited projects. Acceptable on modern hardware; auto-eviction of inactive projects deferred to a later phase if needed.

---

## §3 — libghostty Integration & Pane Lifecycle

### Build & vendor pipeline

`scripts/build-libghostty.sh` (committed to repo):

```bash
#!/usr/bin/env bash
set -euo pipefail
GHOSTTY_TAG="${GHOSTTY_TAG:-v1.3.1}"  # pinned; edit + re-run to bump
WORKDIR="$(mktemp -d)"
git clone --depth=1 --branch="$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty "$WORKDIR/ghostty"
cd "$WORKDIR/ghostty"
# Requires Zig 0.15.2 — operator installs via Homebrew or zigup.
zig build -Demit-macos-app=false
EMUX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$EMUX_ROOT/Frameworks/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$EMUX_ROOT/Frameworks/"
echo "$GHOSTTY_TAG" > "$EMUX_ROOT/Frameworks/LIBGHOSTTY_VERSION"
```

- The xcframework (~50–100 MB universal arm64+x86_64) is committed to the emux repo. Sealed binary, no merge conflicts.
- Version bumps are a deliberate operator action: edit `GHOSTTY_TAG`, re-run script, commit. Never automatic.
- Zig 0.15.2 install is operator's responsibility; documented in README.

### Pane lifecycle — creation

```
1. Generate Pane.id (UUID)
2. Open scrollback file (O_APPEND | O_CREAT) → ~/Library/.../scrollback/{id}.bin
3. Build Ghostty surface config:
     • cwd = pane.cwd  (defaults to project.path on user-initiated creates)
     • shell = pane.shellOverride ?? user default
4. Install PTY data tee (see "Scrollback tee" below)
5. If restoring an existing pane: replay scrollback bytes into surface
6. Create Ghostty.SurfaceView with config
7. Insert into Tab.layout at the requested position; set as active
8. Trigger debounced state.json save
```

### Pane lifecycle — destruction

```
1. Ghostty surface teardown (shell/PTY cleanup is owned by Ghostty.App)
2. Close scrollback file handle
3. Delete scrollback file
4. Remove leaf from SplitNode tree; promote sibling
5. If tab is now empty: close tab. If project has zero tabs: open one in project.path.
6. Trigger debounced state.json save
```

### Scrollback tee — architecture validated in Phase 6

The clean tee point in `libghostty`'s public C API is not yet validated. Three possible architectures, preference order:

1. **PTY-level tee.** libghostty exposes a callback on raw PTY bytes pre-parser. We copy to file, pass through. Lossless and replayable.
2. **Surface output hook.** Some "on surface output" callback. Snapshot bytes there. Similar fidelity.
3. **Grid dump fallback.** Periodically dump visible grid + scrollback ring via a `ghostty_surface_*` query, serialize as a textual replay file. **Lossy** — loses ANSI styling on history that scrolled off — but always works.

**Decision (locked):** if Phase 6 PoC discovers only #3 is available, **accept the lossy restore**. Visible screen comes back perfectly; deep history is approximate. The user's primary workflow is "restore visible context per project," not literal byte-for-byte replay.

### File touch list (Terminal + App)

| File | Change |
|---|---|
| `Frameworks/GhosttyKit.xcframework` | NEW — vendored binary |
| `scripts/build-libghostty.sh` | NEW |
| `Sources/App/macOS/AppDelegate.swift` | own `ProjectsModel` singleton; route window creation through project |
| `Sources/Features/Terminal/BaseTerminalController.swift` | add `projectId: UUID`; expose pane create/destroy hooks |
| `Sources/Features/Terminal/TerminalController.swift` | remove native NSWindow tab routing; propagate projectId; hide/show methods |
| `Sources/Features/Splits/TerminalRestorable.swift` | replaced by emux's `state.json` persistence layer |

---

## §4 — UI Shell

### Window structure

One **NSWindow per project**, hidden/shown via `orderOut(_:)` / `orderFront(_:)` on project switch. No native NSWindow tabbing — emux uses custom in-content tabs (consistent with the design mockup).

```
NSWindow (per project)
└── contentView: NSSplitViewController
    │
    ├── Item 1: Projects sidebar          [collapsible — no shortcut, drag divider to collapse]
    │   ProjectsSidebarView (SwiftUI)
    │     • project list, drag-to-reorder
    │     • "+" / new-project button (⌘0)
    │     • settings gear (bottom)
    │   Min 150 pt, max 400 pt
    │
    ├── Item 2: Terminal column           [NON-collapsible, holding priority HIGH]
    │   VStack:
    │     ├── Custom tab strip
    │     │     • Tab[] for active project, ⌘1..9 to switch
    │     │     • + button (⌘T), close (⌘W), drag-reorder, double-click rename
    │     └── TerminalSplitTreeView (inherited — hosts SplitTree<Ghostty.SurfaceView>)
    │   Min 200 pt, no max — grows freely with window
    │
    ├── Item 3: Editor column             [auto-shown when openEditorFiles non-empty — ⌘E toggles]
    │   VStack:
    │     ├── Editor file tab strip
    │     │     • each tab = open file, ⌘W to close
    │     └── EditorView (CodeEditSourceEditor)
    │   Min 250 pt, no max — grows freely with window
    │
    └── Item 4: File tree                 [collapsible — ⌘⇧E]
        FileTreeView
          • tree of project.path, FSEvents watcher
          • click text-y file → opens in editor column
          • right-click → context menu (see below)
        Min 150 pt, max 400 pt
```

### Keybindings (v1)

Inheriting Ghostty's terminal-level bindings (clear, copy, paste, font size, etc.) untouched. New emux-level bindings:

| Shortcut | Action |
|---|---|
| ⌘0 | New project (folder picker) |
| ⌘N | New window |
| ⌘E | Toggle editor column (hides without closing files) |
| ⌘⇧E | Toggle file tree |
| ⌘T | New terminal tab (in active project) |
| ⌘W | Close active tab / pane / editor file (whichever is focused) |
| ⌘D | Split right (Ghostty default, inherited) |
| ⌘⇧D | Split down (Ghostty default, inherited) |
| ⌘1..⌘9 | Switch to tab N within active project |
| ⌃1..⌃9 | Switch to project N |
| ⌘[ / ⌘] | Cycle projects backward / forward in sidebar |
| ⌘⇧[ / ⌘⇧] | Cycle tabs backward / forward in active project |
| ⌘⇧P | Quick-open file in project (fuzzy finder). Future: command palette mode. |
| ⌘S | Save active editor file |
| ⌘, | Settings |

No keyboard shortcut for Projects sidebar toggle in v1 — divider-drag only. Easy to add later.

### Modifier-key shortcut hint overlay

Holding **⌘ alone** reveals chips next to every clickable target that has a ⌘-prefixed shortcut: tab strip shows `⌘1` `⌘2` …, "new tab" button shows `⌘T`, "new project" button shows `⌘0`, etc.

Holding **⌃ alone** reveals `^`-prefixed chips on project sidebar items (`^1` `^2` …).

Release → chips fade out (~150 ms).

Implementation:
- One `ModifierKeyMonitor` ObservableObject, driven by `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`.
- Each labeled target declares its shortcut metadata once (string + modifier set).
- Overlays render conditionally via a `.shortcutHint(...)` view modifier subscribed to the monitor.

### File tree → other columns

- **Click** file (text-y extension list configurable): opens in editor column. Editor auto-shows if hidden.
- **Right-click file**: Open in editor / Open terminal here (new tab, cwd = file's directory) / Reveal in Finder / Rename / Delete (with confirm; uses `FileManager.trashItem(at:)`).
- **Right-click folder**: Open terminal here / New File / New Folder / Rename / Delete.
- **(Future)** Files / Diff toggle in file-tree column header — stubbed-out only in v1.

### Collapse persistence

Sidebar and File-tree collapsed states are stored per-project in `Project.sidebarCollapsed` / `Project.fileTreeCollapsed`. Switching projects can present different layouts.

---

## §5 — Implementation Choices

### Editor

**CodeEditSourceEditor** (Swift package from CodeEditApp), wrapping `CodeEditTextView` (an `NSTextView` subclass). Vendored as a SwiftPM dependency in the Xcode project.

Features used in v1:
- Tree-sitter syntax highlighting (~20 languages bundled via `CodeEditLanguages`)
- Line numbers gutter
- Multi-cursor + rectangular selection (inherited from `NSTextView`)
- Find / find-and-replace panel
- Indent guides
- Themable (we'll match editor theme to user's terminal theme over time)

Features explicitly NOT in v1: LSP, autocomplete, inline diagnostics, git gutter, vim mode. Deferred.

Before final integration (during Phase 5 implementation), re-verify the package's current API and pin a known-good version.

### Deployment target

**macOS 14.0 (Sonoma)**. Buys `@Observable`, mature `NavigationSplitView`, `inspector` modifier. The user runs macOS 15; 14 retains headroom without locking out Sonoma machines if we ever distribute.

### Testing

Pragmatic, not exhaustive:

- **Unit tests** (the ones that pay back):
  - `state.json` round-trip — encode then decode equals input
  - `SplitNode` tree operations — split, close, promote sibling
  - Scrollback rotation — write past 25 MB cap, verify head truncation
  - `ProjectsModel` mutations — add / delete / reorder / switch
- **No tests for `Sources/Ghostty/` code** — it's inherited and not ours to maintain.
- **One XCUITest smoke test**:
  - Launch → create project → open tab → type text → quit → relaunch → verify visual state restored.
  - Covers the riskiest user-visible regression class (persistence).
- **Manual verification** for libghostty rendering output (pixel-asserting against a Metal-rendered surface is not worth the effort for this team size).

### Build & logging

- Single Xcode project, single scheme `emux`, two configs (Debug, Release).
- No CI for v1. Manual `xcodebuild` / Archive when needed.
- Codesigning + notarization deferred until first public release (then invoke the `macos-notarize` skill).
- Logging via `OSLog`. Subsystems: `persistence`, `projects`, `panes`, `scrollback`, `editor`, `ui`. `info` in Release, `debug` in Debug. Filterable via Console.app with `subsystem:com.{owner}.emux`.

### Non-goals for v1 (explicit)

So the spec stays honest:

- LSP, autocomplete, go-to-definition, inline diagnostics
- Git diff UI (right column's Diff tab — stub only)
- Command-palette mode in ⌘⇧P (file finder only for v1)
- Sparkle / auto-update / public distribution
- iCloud / cross-machine sync
- Custom themes editor (terminal themes via Ghostty config; editor uses CodeEditSourceEditor defaults)
- Restoring running processes (no tmux daemon)
- In-titlebar tabs (`macosTitlebarStyle = .native`)
- QuickTerminal / Custom App Icon / AppleScript (removed at fork time)

The user retains the right to promote items from non-goals into v1 phase-by-phase as the UI takes shape.

---

## Phase outline (preliminary — refined in writing-plans)

Phase-based delivery is a working principle (captured in the `emux-development-style` project memory). Each phase ships a runnable, visually testable slice. The user reviews before the next phase starts.

Tentative phases (writing-plans will produce the authoritative sequence with steps + verification per phase):

1. **Boot the renamed fork.** Clone Ghostty at pinned tag, strip git remote, build xcframework, rename project/bundle id, app launches as "emux" with default Ghostty UX intact. *This is the embedding PoC.*
2. **Projects sidebar shell.** Sidebar UI + persistence + "+" button. No project scoping yet — sidebar is decorative.
3. **Project scoping wired through tabs.** Active project drives window content; switching projects hides/shows windows. Per-project tab list replaces NSWindow tab groups.
4. **File tree column.** SwiftUI tree + FSEvents watcher + context menu actions.
5. **Editor column.** CodeEditSourceEditor wrapper, file-tab strip, click-to-open from file tree.
6. **Scrollback tee + replay.** Validate libghostty tee architecture (#1/#2/#3 from §3); implement the chosen one; verify restore.
7. **⌘⇧P quick-open palette.** Fuzzy file finder.
8. **Modifier-key shortcut hint overlay.** ModifierKeyMonitor + per-target hint chips.
9. **Polish.** Defaults, animations, theme matching, settings UI.

---

## Open questions (resolved by implementation, not by design)

- Which scrollback tee architecture (§3, options 1/2/3) does libghostty's current C API expose? Answered in Phase 6.
- Does `ghostty_surface_text` (or equivalent) accept arbitrary bytes for replay? Answered in Phase 6.
- Does removing NSWindow tab routing (§4) interact oddly with any inherited Ghostty code paths beyond `TerminalController.newWindow`? Answered in Phase 3.
- Exact CodeEditSourceEditor API surface as of integration date. Re-verified in Phase 5.

---

## References

- Ghostty repo: <https://github.com/ghostty-org/ghostty>
- CodeEditTextView / CodeEditSourceEditor: <https://github.com/CodeEditApp/CodeEditTextView>
- Project memory files (in the Claude Code memory store, not the project tree): `emux-fork-decision`, `emux-development-style`
