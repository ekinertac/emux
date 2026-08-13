# emux client ↔ daemon wire protocol

**Status:** draft, Phase G Task 1 deliverable. Any change to methods,
frame types, or the version handshake shape is a protocol version bump.

**Protocol version:** `1` (current).

**Scope:** the wire format between `emux.app` (client) and `emuxd`
(daemon). Local Unix sockets in Phase G/H; the same protocol is
SSH-forwarded byte-for-byte in Phase I (no changes needed there).

---

## 1. Sockets

Two sockets per daemon instance, both `AF_UNIX SOCK_STREAM`, mode `0600`.

| Path | Framing | Purpose |
|---|---|---|
| `~/Library/Application Support/emux/emux.sock` | Line-delimited JSON | Control API — every JSON-RPC call and every server → client push notification. One connection per attached client. |
| `~/Library/Application Support/emux/emux-client.sock` | Length-prefixed binary | Screen-frame streaming + input events. One connection per attached pane view. |

The paths are configurable via `EMUX_SOCKET_DIR` (env var, expands `~`).
Named sessions (`--session <name>`) are out of scope for Phase G — one
daemon per user.

## 2. Encoding

- **Control socket:** UTF-8 JSON, one message per line, terminated by
  `\n` (LF, not CRLF). Messages never contain embedded newlines
  (JSON strings escape `\n`). Max message size: 1 MiB — larger
  messages (e.g. huge workspace snapshots) close the connection with
  `error: message_too_large`.
- **Client transport socket:** binary frames, network byte order
  (big-endian) for the length prefix. Payloads may be zstd-compressed
  as noted per frame type.

## 3. Version handshake

**Every connection** on both sockets starts with a `hello` exchange
before any other traffic. Client sends first, daemon replies.

### Control socket

Client → daemon (first line):
```json
{"kind":"hello","protocol_version":1,"client":"emux.app","client_version":"0.4.0"}
```

Daemon → client (first line):
```json
{"kind":"hello","protocol_version":1,"min_supported_version":1,"daemon_version":"0.4.0","daemon_pid":31415}
```

If the client's `protocol_version` is less than the daemon's
`min_supported_version`, the daemon writes:
```json
{"kind":"error","code":"protocol_incompatible","message":"client protocol 0 is below daemon's minimum 1; upgrade the client"}
```
then closes the connection. Symmetric on the client side — the client
refuses to attach if the daemon's `protocol_version` is above the
highest version it knows.

### Client transport socket

Client → daemon (first line, JSON followed by `\n` before the socket
switches to binary framing):
```json
{"kind":"hello","protocol_version":1,"stream_id":"01H..."}
```

Daemon replies with a single control byte `0x00` (accepted) or `0x01`
(unknown stream) then closes the socket for `0x01`. From this point on
the connection carries only binary frames (§8).

`stream_id` is obtained from a prior `client.attach` call on the
control socket (§7.5).

## 4. Message shape (control socket)

Every control-socket message is one of three kinds, disambiguated by
the top-level `kind` field:

- `request` — client → daemon, awaits a response.
- `response` — daemon → client, correlates to a request by `id`.
- `event` — daemon → client, server-initiated push. No response
  expected.

### 4.1 Request
```json
{"kind":"request","id":"req-42","method":"pane.spawn","params":{...}}
```
- `id` is a client-generated string. Any format; must be unique across
  in-flight requests on that connection. Recommended: UUIDv7 or an
  incrementing counter.

### 4.2 Response
```json
{"kind":"response","id":"req-42","result":{...}}
```
or
```json
{"kind":"response","id":"req-42","error":{"code":"pane_not_found","message":"no pane with id ..."}}
```
Exactly one of `result` or `error` present.

### 4.3 Event
```json
{"kind":"event","name":"workspace.updated","payload":{...}}
```
No `id` — events are fire-and-forget. Delivery is best-effort but
guaranteed in-order per connection.

## 5. Error codes

Errors on both `error` responses and `hello`-reject messages use the
same shape: `{code: string, message: string, details?: any}`.

| Code | Meaning |
|---|---|
| `protocol_incompatible` | Version handshake failed. Connection closes after this error. |
| `message_too_large` | Message exceeded 1 MiB. Connection closes. |
| `invalid_message` | Message did not parse as JSON, or `kind` was missing/unknown. Connection closes. |
| `unknown_method` | `request.method` not recognized by the daemon at this protocol version. Response only; connection stays open. |
| `invalid_params` | `request.params` was missing fields or wrong types. Response only. |
| `not_found` | Referenced entity (window/project/pane/tab) does not exist. Response only. |
| `precondition_failed` | Operation not valid in current state (e.g. spawn in a deleted window). Response only. |
| `internal_error` | Uncaught daemon-side error. `details` may include a stack trace in debug builds. Response only. |

## 6. Data types (JSON)

Reused by multiple methods. All fields required unless marked
`optional`.

### 6.1 `WindowFrame`
```json
{"x": 100.0, "y": 200.0, "width": 1100.0, "height": 748.0}
```

### 6.2 `Tab`
```json
{
  "id": "01H...",
  "title": "agamon",
  "sort_order": 0,
  "cwd": "file:///Users/ekinertac/Code/agamon/"
}
```

### 6.3 `Project`
```json
{
  "id": "01H...",
  "name": "agamon",
  "path": "file:///Users/ekinertac/Code/agamon/",
  "sort_order": 0,
  "created_at": "2026-08-12T20:04:11Z",
  "last_opened_at": "2026-08-13T09:15:00Z",
  "tabs": [/* Tab objects */],
  "active_tab_id": "01H..."   // optional
}
```

### 6.4 `WindowSnapshot`
```json
{
  "id": "01H...",
  "projects": [/* Project objects */],
  "active_project_id": "01H...",   // optional
  "sidebar_collapsed": false,
  "ui_type_size_index": 3,
  "window_frame": {/* WindowFrame */}  // optional
}
```

### 6.5 `PaneInfo`
Runtime info about a live pane, keyed by pane_id (daemon-generated
UUID). Not persisted directly — persistence is via `WindowSnapshot`.
```json
{
  "pane_id": "01H...",
  "window_id": "01H...",
  "tab_id": "01H...",
  "project_id": "01H...",
  "cwd": "/Users/ekinertac/Code/agamon",
  "title": "zsh — 80×24",
  "cols": 80,
  "rows": 24,
  "exited": false,
  "exit_code": null    // optional; set when exited=true
}
```

### 6.6 `WorkspaceMutation`
Tagged union — one of the following, keyed by `type`:

```json
{"type":"add_project", "path":"file:///Users/ekinertac/Code/agamon/"}
{"type":"rename_project", "project_id":"01H...", "name":"new-name"}
{"type":"delete_project", "project_id":"01H..."}
{"type":"reorder_projects", "from":[0], "to":2}
{"type":"add_tab", "project_id":"01H...", "cwd":"/optional/override"}
{"type":"close_tab", "project_id":"01H...", "tab_id":"01H..."}
{"type":"switch_tab", "project_id":"01H...", "tab_id":"01H..."}
{"type":"rename_tab", "project_id":"01H...", "tab_id":"01H...", "title":"new-title"}
{"type":"set_active_project", "project_id":"01H..."}
{"type":"set_sidebar_collapsed", "collapsed":true}
{"type":"set_ui_scale_index", "index":4}
{"type":"set_window_frame", "frame":{/* WindowFrame */}}
```

Mutations return the updated `WindowSnapshot` in the response's
`result`. Every successful mutation also broadcasts a
`workspace.updated` event to all attached clients that hold a
connection interested in this window (see `client.attach` semantics
in §7.5).

## 7. Control methods

### 7.1 `daemon.status`
Health check + version info.

Request:
```json
{"kind":"request","id":"1","method":"daemon.status","params":{}}
```
Response:
```json
{"kind":"response","id":"1","result":{
  "version":"0.4.0",
  "protocol_version":1,
  "uptime_seconds":3600,
  "pane_count":5,
  "window_count":2,
  "attached_clients":1
}}
```

### 7.2 `daemon.stop`
Ask the daemon to shut down cleanly. Daemon persists everything, closes
all sockets, exits.

Request:
```json
{"kind":"request","id":"2","method":"daemon.stop","params":{}}
```
Response (sent before the daemon exits):
```json
{"kind":"response","id":"2","result":{"stopping":true}}
```
The connection closes right after the response.

### 7.3 Workspace lifecycle

#### `workspace.list`
Return all persisted window snapshots, in restoration order.

```json
{"kind":"request","id":"3","method":"workspace.list","params":{}}
```
```json
{"kind":"response","id":"3","result":{"windows":[/* WindowSnapshot, WindowSnapshot ...*/]}}
```

#### `workspace.snapshot`
Return one window's full state.

```json
{"kind":"request","id":"4","method":"workspace.snapshot","params":{"window_id":"01H..."}}
```
```json
{"kind":"response","id":"4","result":{"snapshot":/* WindowSnapshot */}}
```
Error `not_found` if the window id is unknown.

#### `workspace.create`
Create a new empty window snapshot. Returns the assigned window_id.

```json
{"kind":"request","id":"5","method":"workspace.create","params":{}}
```
```json
{"kind":"response","id":"5","result":{"window_id":"01H...","snapshot":/* empty WindowSnapshot */}}
```

#### `workspace.delete`
Delete a window's snapshot from persisted state. All panes belonging
to that window are closed first (their PTYs are terminated). Attached
clients showing panes in this window receive a `pane.exit` event for
each.

```json
{"kind":"request","id":"6","method":"workspace.delete","params":{"window_id":"01H..."}}
```
```json
{"kind":"response","id":"6","result":{"deleted":true}}
```

#### `workspace.mutate`
Apply a mutation. See §6.6 for the mutation shape.

```json
{"kind":"request","id":"7","method":"workspace.mutate","params":{
  "window_id":"01H...",
  "mutation":{"type":"add_project","path":"file:///Users/ekinertac/Code/agamon/"}
}}
```
```json
{"kind":"response","id":"7","result":{"snapshot":/* updated WindowSnapshot */}}
```
On success: a `workspace.updated` event fires to every attached
client with the same window_id.

### 7.4 Pane lifecycle

#### `pane.spawn`
Create a new PTY for a project's tab. Returns the pane_id. Typically
called after `add_tab` — the mutation creates the tab record, then
`pane.spawn` creates the runtime PTY for it.

```json
{"kind":"request","id":"8","method":"pane.spawn","params":{
  "window_id":"01H...",
  "tab_id":"01H...",
  "cwd":"/Users/ekinertac/Code/agamon",
  "cols":80,
  "rows":24
}}
```
```json
{"kind":"response","id":"8","result":{"pane":/* PaneInfo */}}
```
`cols` and `rows` are optional (default 80×24 — client resizes
immediately after via `pane.resize`).

#### `pane.close`
Terminate the pane's PTY, delete the tab record from the containing
project, remove the pane. Broadcasts `pane.exit` (exit_code=null,
reason="closed_by_client").

```json
{"kind":"request","id":"9","method":"pane.close","params":{"pane_id":"01H..."}}
```
```json
{"kind":"response","id":"9","result":{"closed":true}}
```

#### `pane.resize`
Update PTY window size. Multiple attached clients viewing the same
pane may resize independently — the daemon uses the smallest cols and
smallest rows across all attached streams (matches tmux behavior for
shared sessions).

```json
{"kind":"request","id":"10","method":"pane.resize","params":{
  "pane_id":"01H...",
  "stream_id":"01H...",   // which stream is reporting; optional if only one attached
  "cols":100,
  "rows":30
}}
```
```json
{"kind":"response","id":"10","result":{"effective_cols":80,"effective_rows":24}}
```
If `effective_cols`/`effective_rows` differ from what the client
requested, another client had a smaller size and it wins.

#### `pane.write`
Send raw input bytes to the pane's PTY. Bytes are base64-encoded to
keep the JSON envelope safe from binary content (control chars,
escape sequences).

```json
{"kind":"request","id":"11","method":"pane.write","params":{
  "pane_id":"01H...",
  "bytes":"bHM="   // base64("ls")
}}
```
```json
{"kind":"response","id":"11","result":{"written":2}}
```

**Latency note.** `pane.write` per keystroke over JSON has ~2ms
overhead per event. For MVP this is fine (~human typing latency).
Phase I (remote attach) may add a dedicated binary input channel on
the transport socket if latency becomes noticeable.

### 7.5 Client attachment

#### `client.attach`
Reserve a stream on the transport socket for pushing screen frames
from a specific pane. Returns a `stream_id` the client uses to
identify itself when it connects to `emux-client.sock`.

```json
{"kind":"request","id":"12","method":"client.attach","params":{"pane_id":"01H..."}}
```
```json
{"kind":"response","id":"12","result":{"stream_id":"01H..."}}
```

After receiving the response, the client MUST connect to
`emux-client.sock` within 5 seconds and complete the transport-socket
`hello` (§3) with the same `stream_id`. If the client doesn't attach
in time, the daemon expires the reservation.

#### `client.detach`
Release a stream. The transport socket for that stream should already
have been closed by the client; this call cleans up daemon-side state.

```json
{"kind":"request","id":"13","method":"client.detach","params":{"stream_id":"01H..."}}
```
```json
{"kind":"response","id":"13","result":{"detached":true}}
```

## 8. Push events (control socket)

Events are `{"kind":"event","name":"<name>","payload":{...}}`. No
response.

### 8.1 `workspace.updated`
Fires after any successful `workspace.mutate` targeting this window.
Every client that has an active `client.attach` for a pane in this
window receives the update. Clients without any attached panes for
this window are NOT notified — they don't need to be.

```json
{"kind":"event","name":"workspace.updated","payload":{
  "window_id":"01H...",
  "snapshot":/* updated WindowSnapshot */
}}
```

### 8.2 `pane.exit`
Fires when a pane's PTY exits (shell dies, user runs `exit`, external
kill). Also fires with `reason: "closed_by_client"` for explicit
`pane.close` calls.

```json
{"kind":"event","name":"pane.exit","payload":{
  "pane_id":"01H...",
  "exit_code":0,          // optional; null if killed by signal or closed
  "signal":null,          // optional; "SIGKILL" etc.
  "reason":"exit"         // "exit" | "signal" | "closed_by_client"
}}
```
Delivered to all clients with an active `client.attach` for this pane.

### 8.3 `daemon.shutting_down`
Sent before a `daemon.stop` completes, or before an unexpected
shutdown if the daemon has time.

```json
{"kind":"event","name":"daemon.shutting_down","payload":{"reason":"user_requested"}}
```
Clients should show a banner and prepare to reconnect.

## 9. Binary transport frames (client transport socket)

Every frame:
```
+--------+------+--------------------------------+
|  len   | type |            payload             |
+--------+------+--------------------------------+
| 4-byte | 1-B  |        len - 1 bytes           |
| BE u32 |      |                                |
+--------+------+--------------------------------+
```

- `len` is the total payload length **including the 1-byte type**.
  So the number of payload bytes is `len - 1`.
- Max `len` = 4 MiB. Larger frames close the transport connection with
  a `pane.exit` event on the control socket (reason:
  `"transport_error"`).
- Direction is inferable from the type — `SCREEN_*`, `CURSOR`,
  `TITLE_CHANGED`, `BELL` are daemon → client; `INPUT`, `RESIZE` are
  client → daemon.

### 9.1 Frame types

| Type byte | Name | Direction | Payload |
|---|---|---|---|
| `0x01` | `SCREEN_UPDATE` | daemon → client | zstd-compressed ANSI byte diff since last SCREEN_* frame on this stream |
| `0x02` | `SCREEN_RESET` | daemon → client | zstd-compressed ANSI full-screen dump (sent on attach, resize, or any state the daemon can't diff cleanly) |
| `0x03` | `CURSOR` | daemon → client | JSON: `{"row":0,"col":0,"visible":true,"style":"block"}` — style ∈ `block`/`bar`/`underline` |
| `0x04` | `TITLE_CHANGED` | daemon → client | UTF-8 string, the new pane title |
| `0x05` | `BELL` | daemon → client | empty (0 bytes after type) |
| `0x10` | `INPUT` | client → daemon | raw input bytes (keystrokes, paste). Not compressed — usually tiny. |
| `0x11` | `RESIZE` | client → daemon | JSON: `{"cols":80,"rows":24}` — equivalent to `pane.resize` on the control socket but faster path for continuous drag-resize |

Types `0x06`-`0x0F` reserved for future server → client frames (mouse
events, hyperlinks, semantic zones). Types `0x12`-`0x1F` reserved for
future client → server frames.

### 9.2 zstd usage

`SCREEN_UPDATE` and `SCREEN_RESET` payloads are zstd-compressed if the
uncompressed payload is > 256 bytes. If ≤ 256 bytes, payload is raw
ANSI. The receiver detects compression by the first bytes: zstd magic
number is `0x28 B5 2F FD` (little-endian) — if the payload starts with
these 4 bytes, decompress; otherwise treat as raw. Small screen tics
(cursor movement, single-char echo) skip compression to keep latency
low.

### 9.3 Ordering

Frames on a single stream are strictly ordered by daemon dispatch time.
The daemon guarantees that any `SCREEN_UPDATE` frame delivered after a
`SCREEN_RESET` correctly extends the reset's state — a client that
receives `RESET, UPDATE, UPDATE` can replay them in that order to
match daemon state exactly.

`CURSOR`, `TITLE_CHANGED`, and `BELL` are interleaved with `SCREEN_*`
frames and applied in receipt order. `CURSOR` frames may be batched by
the daemon (last-writer-wins over 16ms windows).

### 9.4 Backpressure

The transport socket uses OS-level backpressure — if a client's read
buffer fills up, the daemon's `write` blocks. The daemon runs each
stream's writer on its own thread so one slow client doesn't block
others. If a stream's write blocks for > 10 seconds, the daemon closes
that transport connection (the client sees EOF) and emits a
`pane.exit` control event with `reason: "transport_stalled"`.

## 10. Reconnection

There is no reconnection protocol built in. If a client's control or
transport connection drops, it must reopen from scratch:

1. Reconnect control socket, redo the JSON `hello`.
2. `workspace.list` (or `workspace.snapshot(known_window_id)`) to get
   current state.
3. For each pane the client wants to view again: `client.attach`.
4. Reconnect the transport socket, redo the JSON `hello` with the new
   stream_id.

The daemon does not preserve old stream_ids across connection drops.
This keeps reconnection stateless and predictable.

## 11. Forward compatibility

- Clients ignore unknown top-level fields in responses and events.
  Daemons ignore unknown top-level fields in requests.
- Unknown `WorkspaceMutation.type` values return `invalid_params`.
- Unknown method names return `unknown_method`.
- New frame types on the transport socket: receivers of an unknown
  type MUST skip the frame based on `len` and continue reading. They
  MUST NOT close the connection.
- Adding a new required field to an existing request / response is a
  protocol version bump. Adding an optional field is not.

## 12. Reference: minimal client → daemon session

Order of operations for the app opening one window and showing one pane:

```
CLIENT                                          DAEMON
  |                                               |
  |-- connect emux.sock                        -->|
  |-- {kind:hello, protocol_version:1, ...}    -->|
  |<-- {kind:hello, protocol_version:1, ...}   ---|
  |                                               |
  |-- {method: workspace.list}                 -->|
  |<-- [WindowSnapshot A, WindowSnapshot B]    ---|
  |                                               |
  |-- {method: pane.spawn, window: A, tab: T} -->|   (daemon spawns PTY)
  |<-- {pane_id: P}                            ---|
  |                                               |
  |-- {method: client.attach, pane_id: P}     -->|
  |<-- {stream_id: S}                          ---|
  |                                               |
  |-- connect emux-client.sock                 -->|
  |-- {kind:hello, stream_id: S}\n             -->|
  |<-- 0x00 (accepted)                         ---|
  |                                               |
  |<== SCREEN_RESET frame (full screen)        ===|
  |<== SCREEN_UPDATE (shell prompt appears)    ===|
  |<== CURSOR (row=0, col=len-of-prompt)       ===|
  |                                               |
  |== INPUT (user types "ls\n")               ===>|
  |<== SCREEN_UPDATE (ls output)               ===|
  |<== CURSOR                                  ===|
  |                                               |
  |     ... session continues indefinitely ...    |
  |                                               |
  |-- close both sockets (window closed)      ==>|   (daemon keeps pane alive)
```

Reattach from a fresh app launch:
```
CLIENT                                          DAEMON
  |                                               |
  |-- connect emux.sock, hello                 -->|
  |<-- hello                                   ---|
  |-- workspace.list                           -->|
  |<-- [A (contains pane P now), B]            ---|
  |                                               |
  |-- client.attach(pane_id: P)                -->|
  |<-- {stream_id: S'}                         ---|
  |                                               |
  |-- connect emux-client.sock, hello(S')      -->|
  |<-- 0x00                                    ---|
  |<== SCREEN_RESET (full screen state as of now)|
  |     ... resume ...                            |
```
