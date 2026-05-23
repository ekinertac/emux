# emux — Development Status

A project-scoped macOS terminal, forked from Ghostty's macOS Swift app shell.
libghostty is consumed as a vendored xcframework. Swift / SwiftUI / AppKit.

---

## Current state

**Phase 3 shipped (2026-05-22 → 2026-05-24).** Latest commit on `main` carries
the full project-scoping + custom-tabs UX. Builds clean, runs locally.

The plan is phased; each phase ships a runnable, visually testable slice. See
`docs/superpowers/specs/2026-05-21-emux-design.md` for the approved design and
`docs/superpowers/plans/` for per-phase implementation plans.

---

## What works

**Phase 1 (boot the fork)** — `36aa47a`
- Cloned Ghostty v1.3.1, stripped non-macOS bits, renamed to `emux`.
- `Frameworks/GhosttyKit.xcframework` vendored (binary not in git — rebuilt
  via `scripts/build-libghostty.sh`; pin recorded in
  `Frameworks/LIBGHOSTTY_VERSION`).
- Bundle id `com.ekinertac.emux`, min macOS 14.6.
- About sheet credits Ghostty + MIT.

**Phase 2 (projects sidebar shell)** — `419ca79`
- Projects model with persistence at `~/Library/Application Support/emux/state.json`.
- SwiftUI sidebar: add via folder picker, in-place rename, reveal-in-Finder,
  delete (with confirm), drag-to-reorder.
- Sidebar still decorative at this stage — selecting projects doesn't yet scope
  the window.

**Phase 3 (project scoping + custom tabs)** — `eddbf18`
- Each project gets its own window. Switching projects hides the previous
  window and shows the target (with frame inherited so it feels like swapping
  content in one window).
- `NSSplitViewController` layout replaces `NavigationSplitView` — sidebar
  width persists across launches.
- Native macOS NSWindow tabbing disabled. Replaced with a custom in-content
  tab strip drawn at the top of the terminal pane. Active tab has a dark-gray
  background; inactive tabs are black.
- Per-project tab list persists (titles + cwds) across relaunch. Shells respawn
  fresh in each tab's cwd.
- Keyboard nav:
  - `⌘T` new tab, `⌘W` close active tab (closes window if last)
  - `⌘1..⌘9` switch to Nth tab in active project
  - `⌘⇧[` / `⌘⇧]` cycle tabs backward/forward
  - `⌃1..⌃9` switch to Nth project
  - `⌘[` / `⌘]` cycle projects backward/forward
  - `⌘0` new project (folder picker)
  - `⌘N` opens a sidebar-less "scratch" terminal window
  - `⌘+` / `⌘-` terminal font size (independent of UI scale)
  - `⌘⇧+` / `⌘⇧-` / `⌘⇧0` scale the UI chrome (sidebar + tab strip);
    terminal stays at its own font size

---

## Known issues (parked, scheduled for a polish phase)

1. **`⌘N` scratch window empty-state is unreliable.** Intended to show "No
   projects yet" regardless of the global model, but in some flows it still
   displays existing projects.
2. **Delete-all-projects → add-new-project can land the app in an
   unresponsive black/empty state.** Recovery is `⌘Q` + relaunch. Likely a
   race between hiding stale windows and showing the new one.
3. **Per-window frame size does not persist.** Every window opens at the
   default `1100×720`. User-resized dimensions are remembered for the
   sidebar divider only.
4. **`Reset Font Size` has no keystroke** (`⌘0` is now "New Project"; the
   menu item still exists but no shortcut).

---

## Roadmap

Per the original spec, the remaining phases are:

- **Phase 4 — File tree column.** Far-right collapsible column. FSEvents-based
  watcher. Right-click context: open in editor, open terminal here, reveal,
  rename, delete.
- **Phase 5 — Editor column.** Multi-file tabs. CodeEditSourceEditor wrapping
  `NSTextView` + tree-sitter. Click a file in the tree → opens in editor.
- **Phase 6 — Scrollback tee + replay.** Persist per-pane PTY output to disk
  and restore on relaunch (lossy via grid-dump fallback is acceptable).
- **Phase 7 — `⌘⇧P` quick-open palette.** Fuzzy file finder over the active
  project. Later: command-palette mode.
- **Phase 8 — Modifier-key shortcut hint overlay.** Hold `⌘` → reveal `⌘N`
  chips next to clickable targets that have them.
- **Phase 9 — Polish.** Defaults, animations, theme matching, settings UI,
  and the four Phase 3 known issues above.

The next phase is undecided. Options:
- **Polish first** — fix the four Phase 3 known issues before adding more
  window-shape complexity.
- **Phase 4** — start the file tree column.

---

## Build

Requires Xcode 16+, Zig 0.15.2 (for one-time `libghostty.xcframework`
rebuilds — see `scripts/build-libghostty.sh`), and macOS 14.6+ at runtime.

```bash
# First clone only: build the libghostty xcframework (~15 min)
./scripts/build-libghostty.sh

# Build the app
xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug \
  -destination 'platform=macOS' build

# Run it
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d | head -1)"
```

There is also a `Makefile` with `make build`, `make run`, etc.

The Xcode scheme is still named `Ghostty` (cosmetic — the project is `emux`).
Rename pending in a polish pass.
