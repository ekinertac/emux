# emux — Development Status

A project-scoped macOS terminal, forked from Ghostty's macOS Swift app shell.
libghostty is consumed as a vendored xcframework. Swift / SwiftUI / AppKit.

---

## Current state

**Phase 3 shipped (2026-05-22 → 2026-05-24).** Then significantly rewritten
2026-08-12 → 2026-08-13 to the **per-window workspace** model: each window has
its own independent project list, its own sidebar, its own persistence entry.
See "Multi-window rewrite (2026-08)" below.

Builds clean, runs locally. **Uncommitted at time of writing** — the
multi-window rewrite has not yet been pushed to origin.

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
- Each project gets its own window (original design: hide-others switching;
  see multi-window rewrite below for the current model).
- `NSSplitViewController` layout replaces `NavigationSplitView` — sidebar
  width persists across launches.
- Native macOS NSWindow tabbing disabled. Replaced with a custom in-content
  tab strip drawn at the top of the terminal pane. Active tab has a dark-gray
  background; inactive tabs are black.
- Per-project tab list persists (titles + cwds) across relaunch. Shells respawn
  fresh in each tab's cwd.
- Keyboard nav:
  - `⌘T` new tab, `⌘W` close active tab (window stays open)
  - `⌘1..⌘9` switch to Nth tab in key window's active project
  - `⌘⇧[` / `⌘⇧]` cycle tabs backward/forward in key window
  - `⌃1..⌃9` switch key window to Nth project (in its own sidebar order)
  - `⌘[` / `⌘]` cycle key window's project backward/forward
  - `⌘0` new project (folder picker) in key window
  - `⌘N` opens a new empty-sidebar window (its own workspace)
  - `⌘+` / `⌘-` terminal font size (independent of UI scale)
  - `⌘⇧+` / `⌘⇧-` / `⌘⇧0` scale key window's UI chrome (sidebar + tab strip)
  - `⌃⌘0` reset terminal font size

**Multi-window rewrite (2026-08-12 → 2026-08-13)** — uncommitted
- **Per-window workspace model.** Each window owns its own `ProjectsModel`
  (independent project list, active project, sidebar collapse, UI scale, frame).
  Two windows are fully independent — adding a project in window A does NOT
  show up in window B's sidebar.
- **Schema v3 persistence.** `state.json` is now
  `{ schemaVersion: 3, windows: [WindowSnapshot] }`. Automatic v2→v3
  migration wraps the old flat state as a single-window entry (v2 backup at
  `state.json.v2-backup`).
- **Close semantics.** Closing a window with the red dot deletes its
  persisted snapshot — that window doesn't come back. Quitting the app with
  windows open preserves all of them; relaunch restores exactly what was open
  (tracked via `AppDelegate.isTerminating` flag).
- **Per-window frame persistence.** `TerminalController.windowDidResize/Move`
  writes into that window's `WindowSnapshot.windowFrame`. Was per-project in
  the interim design; now per-window (cleaner: switching projects within a
  window doesn't jump the frame).
- **Ghostty-level window restoration disabled.** `TerminalWindowRestoration`
  returns `(nil, nil)`. emux's state.json owns "which windows, which
  projects, which frames." Ghostty restoration was creating ghost windows
  with no `projectId` and empty tabs → crash on interaction.
- **Removed concepts:** "scratch window" (isScratchWindow flag), "plain
  terminal window" (isPlainTerminal flag), global `projectsModel` on
  AppDelegate, `projectWindows` registry, `activateProject`'s hide-others
  behavior, adoptable-window branch.
- **New concept:** `openProject(_ project:, in controller:)` — swaps the
  content of exactly one window. Never touches other windows.

---

## Known issues

All four Phase 3 known issues are resolved. No open bugs at time of writing.

Resolved this session:
1. ~~⌘N scratch window empty-state~~ — the whole scratch concept is gone.
2. ~~Delete-all → black screen~~ — restoration disabled + multi-window
   rewrite killed the ghost-window class of bug.
3. ~~Per-window frame size does not persist~~ — now persisted per-window in
   the `WindowSnapshot`.
4. ~~Reset Font Size has no keystroke~~ — `⌃⌘0` via
   `~/.config/ghostty/config`.

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
- **Phase 9 — Polish.** Defaults, animations, theme matching, settings UI.
  (Original Phase 3 known issues are all resolved as of the multi-window
  rewrite.)

Not-yet-scheduled polish threads noted this session:
- **Keyboard-first audit.** Rename via keyboard, reveal in Finder via
  keyboard, delete via keyboard, sidebar reorder via keyboard, settings
  shortcut, close-window shortcut. The full "works with no mouse
  connected" audit.
- **Scheme rename** (`Ghostty` → `emux`) — cosmetic but overdue.

---

## Backlog — herdr-inspired (parked, not scheduled)

Approved 2026-08-12 as future direction after reading `herdrdev/herdr`
(the runtime coding agents live on). None of this is the next phase; it
sits behind Phase 4-9 unless explicitly promoted. Re-clone the reference
impl with `git clone --depth 1 https://github.com/herdrdev/herdr
/tmp/herdr-src` when picking this up — `src/integration/` is the piece to
copy from.

1. **Server model (`emuxd` daemon).** Split emux into a background daemon
   that owns PTYs, workspaces, tab/pane state, and on-disk snapshots, and
   a UI client that attaches over a local socket. Terminals survive app
   quit / logout / machine restart. This is the wezterm-mux equivalent —
   the single largest gap vs. wezterm today. Everything else in this list
   depends on it.

2. **Agent state per pane — #1 priority.** Every pane carries a state:
   `blocked / working / done / idle / unknown`. State cascades pane → tab
   → project sidebar (badge/dot), so the user never has to hunt for the
   stuck agent. Detection is a mix of foreground-process sniffing,
   screen-buffer heuristics, and optional agent-shim hints (see #4).
   Shim reports session id; server infers state.

3. **Socket API — agent-to-agent primitives.** Local `AF_UNIX` API the
   CLI and running agents both talk to. Minimum surface: `pane.list`,
   `pane.spawn`, `pane.send_input`, `pane.report_agent_session`,
   `pane.wait_state {pane_id, state, timeout}` (long-poll). Enables one
   Claude Code session in a pane to wait until another pane is `blocked`
   before jumping in.

4. **Agent hook installer.** `emux integration install claude` drops a
   shim at `~/.claude/hooks/herdr-agent-state.sh`-equivalent and edits
   `~/.claude/settings.json` to register hooks. Follow herdr's
   post-v7 model: **thin shim** (only reports session_id + transcript
   path on SessionStart), **server owns state classification** (from
   process + screen). Reference: `/tmp/herdr-src/src/integration/mod.rs`
   (per-agent version + event tables), `assets/claude/*.sh` (shim
   source), `claude_settings.rs` (safe settings.json merge),
   `targets.rs` (per-agent install/uninstall). Ship Claude Code, Codex,
   Cursor first.

5. **Instance switcher in the titlebar.** Dropdown placed next to the
   traffic-light buttons (leading-side titlebar accessory). Items = local
   + remote emux instances (one `emuxd` per host). Selecting an item swaps
   the whole GUI to that instance's workspaces. Companion button: open a
   new window against the selected instance. Remote instances reached via
   an SSH-tunneled version of the same client-server socket protocol.
   **Not** the same as herdr's `--remote host` (CLI-invoked thin client) —
   this is an in-app instance picker that changes what the UI is looking
   at without relaunching.

Order of implementation, if we come back to this after Phases 4-7 or 9:

- **1 first** (server split) — everything else depends on the daemon.
- **2 next** — agent state is the visible payoff that justifies #1.
- **3 + 4 together** — socket API and shims are the same feature from
  two sides.
- **5 last** — instance switcher is pure UI on top of an already-working
  client-server protocol.

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
