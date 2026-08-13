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

## Herdr-parity roadmap (PROMOTED 2026-08-13 to primary track)

Reordered and elevated after a full architecture read of `herdrdev/herdr`
(see the research subagent report — kept in session, not persisted). Old
Phases 4-9 (file tree, editor, scrollback replay, quick-open, hint
overlay, polish) are **deferred behind this track** — user does not need
them right now; the vacation-workflow story (remote attach a daemon
running on the Mac Mini from a laptop) is the goal.

Constraint: **Claude-only** for the agent hook installer. Multi-agent
socket API (agent-to-agent primitives) is **skipped** — Claude Code has
native subagents, so the socket only needs one method
(`pane.report_agent_session`).

Execution order: **G → A → B → C → D → E → H → I → J → F**

### Track 1 — Daemon story (matches wezterm mux workflow)

- **Phase G — `emuxd` daemon split.** Split emux app into a headless
  mux daemon (owns PTYs, screen state, workspaces, persistence) and a
  UI client that attaches over a local socket. Sessions survive
  closing the GUI window. Reference: `herdr/src/server/headless.rs`,
  `src/server/autodetect.rs`, `src/persist/`. Biggest single change on
  this roadmap.

- **Phase H — Local reattach polish.** Multi-window reattach: closing
  the emux window auto-detaches (does NOT kill sessions). Reopening
  emux reattaches to the same daemon and restores the visible state.
  Reference: herdr's client attach flow.

- **Phase I — Remote attach.** `emux connect mini` opens a client
  window whose sessions live on the daemon running on the Mac Mini.
  SSH transport (uses `~/.ssh/config` — Tailscale hostnames like
  `mini-m4` work directly). Both ends must be macOS emux; no
  cross-platform binary bootstrap needed. Reference:
  `herdr/src/remote/attach.rs`.

- **Phase J — Instance switcher UI.** Dropdown in the titlebar next to
  the traffic-light buttons. Items = local + remote emux instances.
  Select → GUI swaps to that instance's workspaces. Companion button:
  "New window in this instance." This is a pure UI layer on top of I.

### Track 2 — Agent state story (screen-detected, no socket needed)

- **Phase A — State hierarchy split.** Refactor emux's `Pane` to be
  the tab-tree identity only; peer `TerminalState` holds cwd, title,
  agent metadata, and the future agent-state fields. Enables state to
  survive pane moves and makes testing easier. Reference:
  `herdr/src/pane/state.rs:6-13`, `herdr/src/terminal/state.rs:120-150`.

- **Phase B — Agent state model.** Add `AgentState { Idle, Working,
  Blocked, Unknown }` + `seen: Bool` to `TerminalState`. Wire
  `@Published` propagation to sidebar/tab badges (visual only, no
  detector yet). Reference: `herdr/src/detect/mod.rs:9-20`,
  `herdr/src/pane/state.rs:8-10`. **"Done" = `Idle && !seen`** — not a
  fifth state.

- **Phase C — Screen manifest engine + Claude manifest.** Port
  herdr's TOML rule engine (regions: `osc_title`, `osc_progress`,
  `bottom_non_empty_lines(N)`, `after_last_horizontal_rule`,
  `whole_recent`, `prompt_box_body`; priority + skip_state_update
  semantics). Copy `src/detect/manifests/claude.toml` verbatim as the
  starting rules. Feed from libghostty's screen buffer. This ALONE
  gives working Claude state detection with no shim.

- **Phase D — Source arbitration + timing debounce.**
  `recomputeEffectiveState` with priority: (1) visible-blocker
  overrides, (2) hook if authoritative, (3) screen fallback. Copy
  herdr's timing constants: 500/300/50 ms polling, 100 ms × 3
  confirmations + 700 ms cap for working→idle debounce, 800 ms
  visible-blocker refresh, 3 s startup grace. Reference:
  `herdr/src/terminal/state.rs:2120-2161`,
  `herdr/src/pane/agent_detection.rs`.

- **Phase E — Aggregation cascade.** Workspace-level badge is a
  priority-min over pane states (Blocked > Working > Done > Idle >
  Unknown). Sidebar rows and tab strip show the worst-in-subtree
  state. This is the "never hunt for the stuck agent" UX win.
  Reference: `herdr/src/workspace/aggregate.rs`.

### Late track — Session-identity for future resume

- **Phase F — Claude integration installer + shim + minimal socket.**
  `emux integration install claude` writes a shim to
  `~/.claude/hooks/emux-agent-state.sh` and edits
  `~/.claude/settings.json` (JSONC-preserving parser required — don't
  destroy user comments). Env vars: `EMUX_ENV=1`,
  `EMUX_SOCKET_PATH`, `EMUX_PANE_ID`, `EMUX_TAB_ID`,
  `EMUX_WORKSPACE_ID`. Socket handles ONE method:
  `pane.report_agent_session` — records Claude session_id +
  transcript_path so future features (`claude --resume`) work after
  daemon restart. **NOT required for state detection** (C handles
  that from screen alone). Reference:
  `herdr/src/integration/claude_settings.rs`,
  `herdr/src/integration/assets/claude/herdr-agent-state.sh`.

### Deferred (behind this track, may or may not ever ship)

- Phase 4 — File tree column (was next per spec; parked)
- Phase 5 — Editor column
- Phase 6 — Scrollback tee + replay (partially subsumed by Phase G —
  daemon-owned PTY means PTY bytes are naturally available server-side
  for tee)
- Phase 7 — ⌘⇧P quick-open palette
- Phase 8 — Modifier-key shortcut hint overlay
- Phase 9 — Polish (keyboard-first audit, scheme rename, etc.)

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
