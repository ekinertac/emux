# Phase G — `emuxd` Daemon Split

*Drafted 2026-08-13. First phase of the promoted herdr-parity roadmap
(see STATUS.md § "Herdr-parity roadmap"). This is the foundational
change — every subsequent phase in Track 1 (H local reattach, I remote
attach, J instance switcher) and Track 2 (A-F agent-state stack) is
easier if this land first, and Track 1 is impossible without it.*

---

## Goal

Split the emux macOS app into two processes:

- **`emuxd`** — a headless mux daemon that owns libghostty, all PTYs,
  workspaces, tabs, panes, screen state, and `state.json` persistence.
  Survives app-quit; runs until the user reboots or explicitly stops
  it. One instance per user.
- **`emux.app`** — the AppKit GUI, now a thin renderer/input-forwarder
  that attaches to the daemon over a local Unix socket. Multiple
  emux.app windows can attach to the same daemon simultaneously.

After Phase G, closing the emux window leaves the terminals running.
Reopening a window reattaches. Multiple windows can each show
different or overlapping views into the daemon's state.

## Scope (in vs. out)

**In scope**

- Daemon binary bundled inside `emux.app/Contents/MacOS/`, spawned by
  the app on first-open if not already running.
- Client-daemon wire protocol (JSON control + binary screen frames).
- libghostty ownership moves to daemon.
- Existing per-window `ProjectsModel` state moves to daemon as
  workspace snapshots. Existing `state.json` (schema v3) continues to
  load; daemon becomes the sole reader/writer.
- Close-window = detach (sessions keep running). Reopen = reattach.
- Single-instance daemon per user (no `--session <name>` support in
  MVP).
- `emux daemon status | start | stop` CLI subcommands.
- Screen state (grid + scrollback) replay on daemon restart, so a
  daemon crash + restart brings back the visible screen.

**Out of scope for Phase G** (deferred to their own phases)

- Named sessions (`--session <name>`). Add in a follow-up if needed.
- LaunchAgent plist for the daemon. Follow-up if approach A shows
  problems.
- Agent-state detection (Phases A-E) — Phase G exposes the surfaces
  those phases will read, but doesn't implement detection.
- Claude integration hook installer (Phase F).
- Remote attach over SSH (Phase I).
- Instance switcher UI (Phase J).
- Live daemon-to-daemon PTY handoff during upgrade (herdr's
  `handoff.rs`). Users close emux to upgrade; acceptable.

## Prerequisites

- Xcode 16+, macOS 14.6+.
- libghostty xcframework built (`scripts/build-libghostty.sh` — the
  daemon target links the same xcframework as the app target).
- Understanding of the herdr reference impl. Re-clone if needed:
  `git clone --depth 1 https://github.com/herdrdev/herdr /tmp/herdr-src`
  Key files to have open when working on tasks:
  - `src/server/headless.rs` — the whole runtime loop
  - `src/server/autodetect.rs` — spawn/attach handshake
  - `src/server/socket_paths.rs` — path derivation
  - `src/persist/` — atomic writes, snapshot format
  - `src/pane/state.rs`, `src/terminal/state.rs` — state split
  - `src/session.rs` — save debounce
  - `src/protocol/` — wire format shape

## Architecture notes

### Read before starting

**One daemon owns libghostty; clients render pre-parsed screen
frames.** This is Q1=A from the design questions. Consequences:

- The daemon links `GhosttyKit.xcframework`, spawns `Ghostty.App`,
  creates `Ghostty.SurfaceView`s. The app target still links
  GhosttyKit **at first** (Task 5 removes it from the app target).
- Client sends input events (key, mouse, resize) as JSON. Daemon
  applies them to the surface. Daemon serializes the resulting screen
  state and sends binary frames back.
- A single Ghostty surface can have multiple clients attached — the
  daemon fans out screen frames to every attached client for that
  surface.

**Two sockets, JSON control + binary streaming.** Q2=Hybrid. Herdr
splits the same way and it works. Concrete:

- **Control socket**: `~/Library/Application Support/emux/emux.sock`.
  Line-delimited JSON-RPC. Methods: `pane.spawn`, `pane.list`,
  `pane.close`, `pane.resize`, `pane.write` (send input),
  `workspace.list`, `workspace.snapshot`, `daemon.status`,
  `daemon.stop`, `client.attach {pane_id}` (opens a screen-frame
  stream on the client socket for that pane).
- **Client transport socket**: `~/Library/Application
  Support/emux/emux-client.sock`. Binary framed. One connection per
  attached pane view — daemon pushes screen updates, client pushes
  input events.

**Single-instance daemon.** Q4=A. Simplifies bootstrapping. Add
named-session support later if wanted; the current codepaths don't
lock us out of it.

**Auto-launch by the app.** Q3=A. On app start:
1. Try connecting to `emux.sock`. If success → daemon is alive,
   handshake for compat.
2. If `ECONNREFUSED` or file missing → spawn `emuxd` via
   `Process.launch` with `setsid`, stdout/stderr → log file at
   `~/Library/Logs/emux/emuxd.log`.
3. Poll socket every 50ms up to 15s. Time-out → error banner in the
   first window ("daemon failed to start, see log").

**State ownership moves to daemon.** The app's current per-window
`ProjectsModel` becomes a `WindowSnapshot` in the daemon. When an
`emux.app` window attaches, it says "give me window N's state" or
"create a new window for me" and gets back the workspace/tab/pane
tree. Every mutation (add project, spawn tab, resize split) goes to
the daemon via JSON-RPC. The app's SwiftUI views observe cached local
copies that the client refreshes on state-change pushes from the
daemon.

**Screen state survives daemon restart.** Q5=B. Daemon periodically
snapshots each pane's Ghostty screen buffer to
`~/Library/Application Support/emux/scrollback/<pane_id>.ansi` (an
ANSI byte log). On daemon start, if a pane is being restored from
state.json, the corresponding scrollback file (if present) is written
to the new PTY's slave before the shell is unfrozen, so the shell
sees a fully-scrolled-back terminal. This is the same trick herdr's
`PaneHistorySnapshot` uses.

### Process topology after Phase G

```
launchd session
├── emux.app                        (GUI, N windows attached)
│   ├── window 1 → attached to pane P1 in daemon
│   ├── window 2 → attached to pane P2 in daemon
│   └── ...
└── emuxd                           (headless, persistent, setsid detached)
    ├── libghostty (Ghostty.App)
    ├── PTYs: shell in P1, shell in P2, ...
    ├── workspace/tab/pane tree
    ├── state.json read/write
    └── control socket + client sockets
```

### Non-obvious constraints

- **libghostty in a headless process**: verify Ghostty.App can
  initialize without an active NSApp / event loop. Herdr's daemon
  runs a tokio loop, not an AppKit runloop. In Swift, this likely
  means a `Foundation.RunLoop.main` or `DispatchSourceRead` on the
  sockets. Check `Ghostty.App.init()` for any AppKit dependencies
  before committing to this design — if it hard-requires NSApp, we
  either patch Ghostty or run a headless `NSApplication` (accessory
  policy, no dock icon).
- **State transfer at reattach**: the app's SwiftUI views expect
  `@Published` mutation streams. The client needs to translate
  daemon push-updates into ObservableObject changes so existing
  views keep working. Consider a per-window `ProjectsModel` shim
  that internally forwards mutations over the socket and applies
  daemon-pushed changes to its `@Published` fields — the sidebar
  and content views don't need to change.
- **Daemon crash mid-session**: if daemon dies, all clients see
  socket close. The app should NOT auto-respawn silently — surface
  a banner "daemon lost, click to reconnect." Users will want to
  know.
- **Version compat**: bundle a `PROTOCOL_VERSION: Int` constant.
  Daemon exposes it via `daemon.status`. App refuses to attach if
  versions mismatch; message directs user to reopen after the daemon
  is stopped. Same pattern as herdr.

## File map for this phase

### New files

```
emuxd/                                       [NEW TARGET]
├── main.swift                               # daemon entry point
├── Server.swift                             # control-socket JSON-RPC dispatch
├── ClientTransport.swift                    # binary framed screen-frame streaming
├── PTYRuntime.swift                         # Ghostty surface lifecycle per pane
├── WorkspaceStore.swift                     # in-memory workspace/tab/pane tree
├── Persistence.swift                        # state.json + scrollback replay
├── Protocol/
│   ├── ControlMessages.swift                # Codable JSON-RPC request/response types
│   ├── ScreenFrame.swift                    # binary frame encoder/decoder
│   └── ProtocolVersion.swift
└── Logging.swift

Sources/App/macOS/DaemonLauncher.swift       [NEW]  auto-spawn + liveness check
Sources/App/macOS/DaemonConnection.swift     [NEW]  the app-side client of the daemon
Sources/Features/Terminal/RemotePaneView.swift  [NEW]  renders daemon screen frames

docs/superpowers/plans/2026-08-13-phase-g-daemon-split.md   this file
```

### Modified files

```
emux.xcodeproj/project.pbxproj               new emuxd target, GhosttyKit linked
Sources/App/macOS/AppDelegate.swift          app boot flow: launch daemon, connect
Sources/App/macOS/main.swift                 stays for the app; emuxd has its own
Sources/Features/Projects/ProjectsModel.swift  becomes a client-side shim
Sources/Features/Terminal/TerminalController.swift  no longer owns Ghostty surfaces
Sources/Features/Terminal/BaseTerminalController.swift  same
```

### Removed / relocated files

- `Sources/Ghostty/*` — stays in the app target for now (types are
  shared between app and daemon; move to a shared package in a
  cleanup after G is stable).
- No files are deleted in Phase G. All existing surface-view rendering
  code stays because we'll want to inspect / diff during migration.

---

## Task 1: Design the wire protocol

**Goal.** Nail down the JSON-RPC schema for the control socket and
the binary format for the screen-frame streaming socket, before any
code touches sockets.

**Deliverable.** A markdown reference at `docs/protocol.md` (new)
containing every request/response type with field descriptions, the
binary frame layout, error semantics, and version handshake. This is
what both the client and daemon read from.

**Details to nail down**

- JSON-RPC style: request `{id, method, params}`, response `{id,
  result | error}`. Line-delimited (newline terminator per message).
- Control methods (minimum for Phase G):
  - `daemon.status` → `{version, protocol_version, uptime, pane_count}`
  - `daemon.stop` — daemon shuts down cleanly
  - `workspace.list` → `[WindowSnapshot]`
  - `workspace.snapshot(window_id) → WindowSnapshot`
  - `workspace.create() → window_id`
  - `workspace.delete(window_id)`
  - `workspace.mutate(window_id, mutation)` — add project, rename,
    delete, switch active. Mutations mirror the current
    `ProjectsModel` API.
  - `pane.spawn(window_id, project_id, cwd)` → `pane_id`
  - `pane.close(pane_id)`
  - `pane.resize(pane_id, cols, rows)`
  - `pane.write(pane_id, bytes_base64)` — send raw input
  - `client.attach(pane_id)` → returns a `stream_id` on the client
    transport socket; opens screen-frame push for that pane
  - `client.detach(stream_id)`
- Push events (server → client over control socket):
  - `workspace.updated(window_id, snapshot)` — after any mutation
  - `pane.exit(pane_id, exit_code)`
- Binary frame layout (client transport):
  ```
  frame = [4-byte BE length][1-byte type][payload]
  types:
    0x01 SCREEN_UPDATE  payload = zstd-compressed ANSI byte diff since last frame
    0x02 SCREEN_RESET   payload = zstd-compressed ANSI full screen
    0x03 CURSOR         payload = {row, col, visible, style}
    0x04 TITLE_CHANGED  payload = utf8 string
    0x05 BELL           payload = empty
  ```
- Version handshake: first message on any socket connection is a
  `hello {protocol_version}` from the client; daemon replies `hello
  {protocol_version, min_supported_version}`. Mismatch → daemon
  closes the socket after sending an `error` with a clear message.

**Acceptance criteria**

- `docs/protocol.md` exists and covers all of the above.
- Every method has an example request + response JSON block.
- Ambiguities called out as TODOs in the doc (e.g. mouse events —
  deferred? included?).

## Task 2: New `emuxd` Xcode target

**Goal.** Add a new Xcode target that produces the daemon binary,
links `GhosttyKit.xcframework`, has its own bundle id + entitlements
matching the app's (sandbox-off since the daemon needs unrestricted
socket + fs access).

**Steps.**
- New target: type "Command Line Tool" (macOS), name `emuxd`.
- Bundle id: `com.ekinertac.emuxd`. Same signing style as the app.
- Link `GhosttyKit.xcframework`, `libghostty.a` transitively as
  today.
- Skeleton `emuxd/main.swift`: prints "emuxd starting" to stderr and
  exits. Nothing else yet.
- Xcode scheme "emuxd" that builds and runs the binary standalone.

**Acceptance criteria**

- `xcodebuild -scheme emuxd build` succeeds.
- Running the built binary prints "emuxd starting" and exits 0.
- App target build unaffected.

## Task 3: Control socket server + JSON-RPC dispatch

**Goal.** `emuxd` listens on `~/Library/Application
Support/emux/emux.sock`, accepts multiple concurrent connections,
routes JSON-RPC methods to handler functions. Only two methods work
initially: `daemon.status` and `daemon.stop`.

**Steps.**
- `emuxd/Server.swift`: `NWListener(using: .tcp, on: .unix(path:))`.
- Frame per line (newline-delimited JSON).
- Decode into `ControlRequest` (Task 1's `ControlMessages.swift`),
  dispatch by `method`, encode `ControlResponse`, send back.
- `daemon.status` returns hard-coded version + zero uptime.
- `daemon.stop` calls `exit(0)`.
- `Logging.swift` writes to `~/Library/Logs/emux/emuxd.log`,
  auto-rotate at 10MB, keep last 3.

**Acceptance criteria**

- Manually: `emuxd &` then `echo '{"id":"1","method":"daemon.status","params":{}}' | nc -U ~/Library/Application\ Support/emux/emux.sock` returns a JSON response.
- `nc -U emux.sock` and send `daemon.stop` — daemon exits cleanly.
- Second connection while the first is idle also works (multiple
  clients).

## Task 4: DaemonLauncher — app-side auto-spawn

**Goal.** On `AppDelegate.applicationDidFinishLaunching`, the app
checks daemon liveness via a socket ping. If dead, spawns `emuxd`
from the bundle (`Bundle.main.bundlePath +
"/Contents/MacOS/emuxd"`), detaches, polls for readiness. If already
alive, verifies protocol compat via `daemon.status`.

**Steps.**
- `Sources/App/macOS/DaemonLauncher.swift`: `Process()` with
  `standardOutput`, `standardError` piped to log file.
- `setsid` detach via `Process.qualityOfService = .background` +
  spawn a helper — or use `posix_spawn` with
  `posix_spawnattr_setflags(POSIX_SPAWN_SETSID)` for a cleaner detach
  that doesn't die on app quit.
- Poll socket every 50ms up to 15s.
- On mismatch: show `NSAlert` "daemon version mismatch — quit and
  reopen after stopping the daemon."
- On successful attach: proceed with normal launch (existing
  `applicationDidFinishLaunching` continues after).

**Acceptance criteria**

- Fresh state (no daemon running, no socket file): app launches,
  daemon starts, socket appears within 1s.
- Existing daemon: app launches, uses existing daemon (no second
  daemon spawned).
- Kill daemon while app is running: app shows a banner in every
  window (Task 12).
- Quit app: daemon still running (verify via `pgrep emuxd`).

## Task 5: Move `ProjectsModel` state to daemon

**Goal.** Daemon owns the workspace state. App's `ProjectsModel`
becomes a shim that forwards mutations to the daemon and updates its
`@Published` fields from daemon push notifications.

**Steps.**
- `emuxd/WorkspaceStore.swift`: holds `[UUID: WindowSnapshot]`
  in-memory, keyed by window id. Same schema as current
  `WindowSnapshot`.
- Daemon handles `workspace.*` and stateful `pane.*` methods against
  this store.
- `emuxd/Persistence.swift`: moves the current
  `StatePersistence.swift` logic. Loads on daemon start, saves
  debounced on mutation.
- App: `Sources/Features/Projects/ProjectsModel.swift` refactored.
  Its `init` takes a `DaemonConnection` + window id. Every existing
  mutator (`addProject`, `deleteProject`, `renameTab`, etc.) becomes
  a JSON-RPC call. Push notifications from daemon update the
  `@Published` properties.
- `DaemonConnection.swift`: manages the control-socket connection,
  request/response correlation via request ids, subscribes to
  `workspace.updated` pushes and routes them to the right
  `ProjectsModel`.

**Acceptance criteria**

- App launches. Existing state.json (schema v3) still loads — now via
  the daemon. Sidebar shows existing projects.
- Adding a project via `+`: JSON-RPC call reaches daemon, daemon
  persists, daemon pushes `workspace.updated`, sidebar re-renders.
- Two app windows attached to the same daemon: adding a project in
  window 1's sidebar makes window 1's sidebar reflect it (window 2's
  sidebar is a DIFFERENT window in the daemon, still unaffected —
  this preserves the per-window model from the multi-window rewrite).
- Quit app: state.json intact on disk.

## Task 6: Move libghostty ownership to daemon

**Goal.** `emuxd` initializes `Ghostty.App`, spawns
`Ghostty.SurfaceView` per pane. Verify this works without an active
NSApp / AppKit runloop. If it doesn't, patch or accept a headless
NSApp workaround.

**Steps.**
- Investigate first: read `Sources/Ghostty/Ghostty.App.swift`
  init path. Note any AppKit assumptions (main runloop, NSApp,
  NSScreen, etc.).
- If Ghostty.App requires AppKit runloop: `emuxd`'s main.swift wraps
  the whole thing in a headless `NSApplication.shared` with
  `.setActivationPolicy(.prohibited)` so no dock icon, no menu bar.
- `emuxd/PTYRuntime.swift`: per-pane object holding a Ghostty
  surface. `spawn(cwd)` creates surface with `SurfaceConfiguration`.
- Subscribe to surface events: `titleChanged`, `bell`,
  `screenUpdated` (hook into libghostty's screen callback).

**Acceptance criteria**

- Daemon starts a PTY spawning `zsh` in `$HOME`, PTY output flows
  into the surface (verify with a print inside the screen callback).
- No AppKit dock icon appears when daemon runs.
- Daemon can spawn 5 PTYs concurrently without issue.

**Known risk.** Ghostty may have hard AppKit assumptions we can't
easily route around. If this task blocks: fallback is to have the
daemon be a background-only `NSApplication` with accessory policy;
much less ideal but still headless-ish. Document whatever we discover
here in `emuxd/PTYRuntime.swift` as a file-header comment for future
context.

## Task 7: Screen-frame serialization + client transport

**Goal.** Daemon serializes screen state as ANSI byte streams,
streams to attached clients over the client transport socket.

**Steps.**
- `emuxd/ClientTransport.swift`: listens on
  `emux-client.sock`. Each connection is one attached pane view.
- `client.attach(pane_id)` on the control socket allocates a
  `stream_id`, and the client is expected to `connect` to the
  transport socket and send `{stream_id}` as its first frame.
- Daemon captures the pane's current screen (full ANSI dump via
  `ghostty_surface_read_text` or the equivalent — verify what
  libghostty exposes) as a `SCREEN_RESET` frame on attach.
- Subsequently: on each libghostty screen-update callback, capture
  new bytes since last snapshot, encode as `SCREEN_UPDATE` frame,
  push to all streams attached to that pane.
- zstd-compress payloads over a small threshold (e.g. > 256 bytes).

**Acceptance criteria**

- Manual: attach via `nc -U emux-client.sock`, send stream_id
  ("subscribe" hack), see raw framed bytes flowing.
- Multiple clients attached to the same pane both receive updates.

## Task 8: Input event forwarding

**Goal.** Client sends keystrokes / mouse events to daemon; daemon
applies them to the surface.

**Steps.**
- Two paths, decide which:
  - **JSON `pane.write` per event** — simple, higher latency.
  - **Dedicated input channel on the transport socket** — faster.
- Recommendation: `pane.write` for MVP (over the control socket).
  Latency should be fine for keyboard.
- App-side: intercept surface key events in `SurfaceView` (or the new
  `RemotePaneView`), forward via `pane.write`.
- Mouse events deferred — decide in Task 1 whether to include mouse
  in Phase G or push to a follow-up.

**Acceptance criteria**

- Typing in the emux window reaches the daemon PTY and its output
  echoes back via screen frames.

## Task 9: RemotePaneView — client-side rendering

**Goal.** New SwiftUI view that connects to a daemon pane, replays
its screen-frame stream into a client-side terminal renderer, and
displays it.

**Steps.**
- `Sources/Features/Terminal/RemotePaneView.swift`.
- The client-side renderer: two options —
  - **Reuse libghostty in the app** — link GhosttyKit in the app,
    create a local `Ghostty.SurfaceView` that eats the ANSI bytes we
    receive. Simple; matches what we render today.
  - **Custom text renderer** — write our own from scratch.
    Discouraged; libghostty already does this.
- Recommendation: keep GhosttyKit linked in the app (both app and
  daemon link it). Daemon uses it for PTY parsing; app uses it for
  visual rendering only, fed by ANSI bytes from the daemon.
- `RemotePaneView` initializes a local surface, wires up input →
  `pane.write`, reads from a `DaemonConnection` stream.

**Acceptance criteria**

- One `RemotePaneView` visually matches the terminal output as
  though it were direct (compare with the pre-Phase-G version).
- Scrolling, resize, cursor placement all correct.

## Task 10: TerminalController becomes attach coordinator

**Goal.** Refactor `TerminalController` to no longer directly own
Ghostty surfaces. Instead it owns a list of `RemotePaneView`s each
attached to a daemon pane.

**Steps.**
- `TerminalController` reads its window's snapshot from daemon.
- For each pane in the snapshot, allocates a `RemotePaneView` and
  attaches via `client.attach`.
- When the daemon pushes `workspace.updated`, controller diffs the
  new snapshot vs. current view state, adds/removes
  `RemotePaneView`s as needed.
- Window close: sends `client.detach` for all streams. Daemon keeps
  the panes alive.

**Acceptance criteria**

- App launches, shows a window with a working terminal. Kill the
  app. Daemon shows the pane still running (verify via
  `daemon.status`). Reopen the app: a new window attaches to the
  same pane, screen shows the current terminal state.

## Task 11: Persistence in daemon + scrollback replay

**Goal.** Daemon writes state.json debounced on any mutation.
Additionally captures per-pane ANSI scrollback to `scrollback/<pane_id>.ansi`
periodically (every 5s or on graceful shutdown, whichever). On
daemon start, if state.json references panes and their scrollback
files exist, respawn the shell but pre-fill the surface with the
saved ANSI bytes before unfreezing.

**Steps.**
- Move `StatePersistence.swift` logic into
  `emuxd/Persistence.swift`.
- Add scrollback capture on a timer per pane.
- On daemon start with restored state: for each restored pane,
  respawn shell, `ghostty_surface_write` the saved ANSI, then attach
  the new PTY.
- On daemon `daemon.stop`: capture final scrollback for every pane
  before exit.
- On pane close: delete the scrollback file.

**Acceptance criteria**

- Kill daemon while a pane has output in its scrollback. Restart
  daemon. New pane's initial screen shows the previous session's
  scrollback (may look slightly different because the shell
  restarts fresh, but the history is there).

## Task 12: Daemon lifecycle CLI + disconnect banner

**Goal.** `emux` CLI understands `emux daemon status | start | stop`
subcommands. App shows a banner in every window if daemon
disconnects.

**Steps.**
- `emux` CLI is currently the app binary; add a subcommand dispatcher
  in `main.swift` that detects `daemon` as the first arg and shells
  out to the appropriate action instead of launching the GUI.
- `emux daemon status`: connects to socket, calls `daemon.status`,
  prints JSON.
- `emux daemon start`: launches daemon (fails if already running).
- `emux daemon stop`: connects, sends `daemon.stop`, waits for
  socket to close.
- Client: on socket disconnect, all `TerminalController`s show a
  banner "daemon disconnected — click to reconnect." Reconnect
  re-invokes DaemonLauncher path.

**Acceptance criteria**

- `emux daemon status` after fresh install shows daemon uptime.
- `emux daemon stop` in one terminal → GUI shows banner in every
  window within ~500ms.
- Click banner → daemon starts, attach succeeds, banner disappears.

## Task 13: Migration + smoke test

**Goal.** Existing state.json (schema v3) loads correctly. Full
end-to-end flow: quit-app-daemon-alive-reopen-attach.

**Steps.**
- Verify existing state.json loads unchanged.
- Manual smoke:
  1. Launch fresh install: daemon starts, one window opens.
  2. Add two projects, ⌘N second window, add different projects.
  3. Spawn tabs in each project. Type something in each.
  4. Close both windows.
  5. `pgrep emuxd` — verify daemon alive.
  6. Reopen `emux.app` — both windows come back with their terminal
     state visible.
  7. `emux daemon stop`.
  8. Reopen `emux.app` — daemon restarts, windows come back but
     shells are fresh (only scrollback replay, not live processes).
  9. `emux daemon stop && sleep 5 && emux daemon start && open
     emux.app` — verify the restart+attach flow.
- Write a doc entry in STATUS.md noting Phase G shipped.

**Acceptance criteria**

- All manual smoke steps pass.
- No regressions in existing keybindings, sidebar, tab strip,
  multi-window model.

## Task 14: Push Phase G

**Steps.**
- Update STATUS.md — mark Phase G shipped, list H as next.
- `git add`, commit with a clear message explaining WHY (foundation
  for remote attach + agent state + session persistence).
- `git push origin main`.

---

## Phase G verification summary

Before declaring Phase G complete:

- [ ] `xcodebuild` succeeds for both `emux` and `emuxd` targets in
      Debug + Release.
- [ ] Daemon auto-launches on app first-open. Second app-open reuses
      existing daemon.
- [ ] Multiple app windows can attach to the same daemon
      simultaneously.
- [ ] Closing the app leaves the daemon running with PTYs live
      (verify via `pgrep emuxd` and `emux daemon status`).
- [ ] Reopening the app reattaches to running panes; screen state
      visible.
- [ ] `emux daemon stop` cleanly shuts down; app windows show
      reconnect banner.
- [ ] After daemon stop + start, scrollback replay brings back the
      visible screen (shells respawn fresh — Phase 6 territory, not
      Phase G).
- [ ] state.json schema v3 loads unchanged from a v3 file. No new
      schema bump.
- [ ] Two windows with independent per-window project lists (from
      the multi-window rewrite) still work identically.
- [ ] `emux daemon status | start | stop` CLI subcommands work.
- [ ] Protocol version handshake refuses to attach if versions
      mismatch (test by editing PROTOCOL_VERSION on one side).
- [ ] `docs/protocol.md` exists and is accurate.
- [ ] All commits pushed to `origin/main`.

## Known limitations (deliberate, deferred)

- **Named sessions (`--session <name>`).** Not in MVP. Add if there
  becomes a real need for isolated user sessions or per-project
  daemons.
- **LaunchAgent plist.** Approach A (app auto-spawn) chosen for MVP.
  If daemon reliability suffers or users want it launchd-managed,
  add a plist in a follow-up. Pivot is small (drop the auto-spawn,
  add an install step).
- **Live daemon-upgrade handoff.** Users close the app to upgrade.
  Herdr's fd-passing handoff is out of scope.
- **Cross-user daemon.** One daemon per user. No multi-user support.
- **Live process persistence across daemon restart.** Only scrollback
  is preserved; shells restart fresh. Phase 6 (scrollback + PTY
  process preservation via forking) is a separate topic.
- **Mouse event forwarding.** Deferred pending decision in Task 1.
  Text mode is fine for MVP; TUIs with mouse support (btop, k9s)
  won't work fully until we plumb mouse through.
- **Agent-state detection.** Phase G exposes the surfaces Phase A-E
  need (daemon-side terminal state, screen buffer access) but
  doesn't implement detection.
- **Remote attach.** Phase I. Phase G's socket is Unix-local only;
  SSH forwarding comes in I.
