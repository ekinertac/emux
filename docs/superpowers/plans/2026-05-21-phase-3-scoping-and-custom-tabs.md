# Phase 3 — Project Scoping + Custom In-Content Tabs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each project gets its own window with its own tabs. Tabs are custom in-content (no longer native NSWindow tab groups), with explicit active/inactive visuals (dark gray active background, black inactive). Selecting a project in the sidebar activates that project's window. The sidebar width persists across launches. Every visible piece of tab/project state survives quit + relaunch.

**Architecture:** Three coordinated changes. **(1)** Replace the SwiftUI `NavigationSplitView` from Phase 2 with an `NSSplitViewController` subclass (`EmuxSplitController`) — gives us width persistence and a stable AppKit anchor for the content. **(2)** Disable macOS native NSWindow tabbing (`tabbingMode = .disallowed`) and replace it with a custom SwiftUI tab strip (`TabStripView` + `TabCell`) drawn at the top of the terminal pane — fixes the "tabs above sidebar" visual issue. **(3)** Each project gets a dedicated `TerminalController` instance with its own `[Tab]` list and corresponding `SurfaceView`s; `AppDelegate` owns a `[Project.id: TerminalController]` registry; sidebar clicks call `orderFront` on the target project's window (creating it if absent).

**Tech Stack:** Swift 5.9+, SwiftUI for the tab strip, AppKit (`NSSplitViewController`, `NSWindowController`, `NSView` swap-on-tab-switch) for the layout and per-tab surface management. The existing Ghostty `SplitTree<Ghostty.SurfaceView>` machinery stays — we just give each tab its own tree, plus add an "active tab" pointer that swaps which tree is bound to the controller's `@Published surfaceTree`. macOS 14.6 deployment target.

**Plan scope:** Phase 3 of 9. Subsequent phases (file tree, editor, scrollback persistence, palette, modifier hints, polish) are planned individually after this ships. **Explicit non-goals for Phase 3** (do not implement, even if the spec mentions them — they have their own phases):
- Drag-out-of-window-to-create-new-window (deferred — needs NSDraggingSource on the tab cell)
- File tree column (Phase 4+)
- Editor column (Phase 5+)
- Scrollback persistence (Phase 6)
- ⌘P/⌘⇧P quick-open palette (Phase 7)
- Modifier-key shortcut hint overlay (Phase 8)

---

## Prerequisites

- Phase 2 shipped (sidebar + persistence). HEAD = `419ca79` on `main`.
- `emux.xcodeproj` builds cleanly with `xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build`.
- `~/Library/Application Support/emux/state.json` exists with at least one Project from your Phase 2 testing — useful for smoke checks. (If you blew it away, the app will start with empty state and you'll add one.)

---

## File map for this phase

```
Sources/Features/Projects/
├── Tab.swift                              [NEW]  Codable Tab model + TabState live-state struct
├── TabStripView.swift                     [NEW]  SwiftUI horizontal tab strip + new-tab button
├── TabCell.swift                          [NEW]  Single tab cell (active/inactive visuals)
├── EmuxSplitController.swift              [NEW]  NSSplitViewController hosting sidebar + content; persists width
├── Project.swift                          [MOD]  add tabs: [Tab] + activeTabId: UUID? (Codable)
├── ProjectsModel.swift                    [MOD]  add addTab / closeTab / switchTab / setActiveProject
├── ProjectsSidebarView.swift              [MOD]  selection change calls AppDelegate.activateProject

Sources/App/macOS/AppDelegate.swift        [MOD]  ProjectWindowRegistry + activateProject(_:)
                                                  applicationDidFinishLaunching opens last-active project

Sources/Features/Terminal/
├── BaseTerminalController.swift           [MOD]  add tabs / activeTabId; tab mutation helpers
├── TerminalController.swift               [MOD]  use EmuxSplitController; remove native-tab routing
└── Window Styles/TerminalWindow.swift     [MOD]  tabbingMode = .disallowed
```

**Untouched** (despite being tab-related): `TitlebarTabsTahoeTerminalWindow.swift`, `TitlebarTabsVenturaTerminalWindow.swift`, `HiddenTitlebarTerminalWindow.swift`. These already either disallow native tabs or use their own titlebar tab UI. We don't change them in this phase; they'll be revisited in polish.

---

## Architecture notes (read once before starting)

### How a "tab" maps to existing Ghostty machinery

Ghostty has `SplitTree<Ghostty.SurfaceView>` — a recursive split tree of terminal surfaces. Today, one TerminalController has ONE `@Published surfaceTree` field that holds the active tree. Splits within that tree are Ghostty's existing ⌘D / ⌘⇧D feature.

For Phase 3, we give each **tab** its own `SplitTree`. The TerminalController keeps the existing `surfaceTree` field as "the active tab's tree". We add a parallel `tabs: [TabState]` field that stores all tabs' trees. Switching tabs is:

```
let oldId = activeTabId
let oldTreeIdx = tabs.firstIndex(where: { $0.id == oldId })
if let i = oldTreeIdx { tabs[i].tree = surfaceTree }  // save outgoing
activeTabId = newId
let newTreeIdx = tabs.firstIndex(where: { $0.id == newId })!
surfaceTree = tabs[newTreeIdx].tree                    // load incoming
```

Setting `surfaceTree` triggers `surfaceTreeDidChange` (existing Ghostty hook) which re-renders the SwiftUI view chain. Surfaces from OUTGOING tabs stay alive because they're retained inside `tabs[i].tree`.

### Window-per-project lifecycle

`AppDelegate` owns a registry:

```swift
private var projectWindows: [UUID: TerminalController] = [:]
```

`activateProject(_:Project)`:
1. If `projectWindows[project.id]` exists → `controller.window?.makeKeyAndOrderFront(nil)`. Hide all other project windows via `orderOut`.
2. Else → create a new `TerminalController` for the project, store, show. Hide others.

`applicationDidFinishLaunching` activates `projectsModel.selectedProjectId` (or the first project, or no project if empty).

### Why NSSplitViewController (not NavigationSplitView)

NavigationSplitView's user-dragged width is not surfaced as a binding on macOS 14.6 — we have no way to persist it. NSSplitViewController fires `splitView(_:resizeSubviewsWithOldSize:)` and gives us `splitViewItem.collapsedOrientation` / `.thickness`. Persist via `UserDefaults.standard` keyed by `"emux.sidebar.width"`.

### Schema migration

`AppState.schemaVersion` jumps from `1` → `2`. The `StatePersistence.load()` flow already renames corrupt files and returns `.empty` on decode failure — Phase 3's schema change makes Phase 2-format files "corrupt" from Phase 3's perspective and they'll be moved aside. Acceptable: user loses Phase 2's project list on first Phase 3 launch (they can re-add). If we wanted real migration, we'd add a `LegacyAppState` Codable struct and a v1→v2 step — explicitly out of scope; document only.

---

## Task 1: Add the Tab Codable model + TabState live-state struct

**Files:**
- Create: `Sources/Features/Projects/Tab.swift`

`Tab` (Codable, persisted) has only the fields we restore on launch: id, title, sortOrder, cwd, shellOverride. `TabState` (live in-memory) wraps a `Tab` plus the live `SplitTree<Ghostty.SurfaceView>` for that tab. TabState is NOT Codable — it holds the live AppKit surface views.

- [ ] **Step 1: Create `Tab.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/Tab.swift` with these exact contents:

```swift
import Foundation

/// A persisted tab within a project. Phase 3 stores enough to recreate a
/// fresh shell on relaunch (the actual scrollback / process state is not
/// preserved — that's Phase 6's scrollback tee feature).
struct Tab: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var sortOrder: Int
    var cwd: URL
    var shellOverride: String?

    init(
        id: UUID = UUID(),
        title: String,
        sortOrder: Int,
        cwd: URL,
        shellOverride: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.cwd = cwd
        self.shellOverride = shellOverride
    }
}
```

- [ ] **Step 2: Verify the file compiles.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/Tab.swift && \
  git commit -m "feat(tabs): add Tab Codable model"
```

---

## Task 2: Extend Project with tabs and activeTabId

**Files:**
- Modify: `Sources/Features/Projects/Project.swift`
- Modify: `Sources/Features/Projects/AppState.swift` (schema version bump)

- [ ] **Step 1: Open `Project.swift` and add the two new fields.**

Replace the entire contents of `/Users/ekinertac/Code/emux/Sources/Features/Projects/Project.swift` with:

```swift
import Foundation

/// A single project the user has added to emux. A project is conceptually a
/// directory on disk that scopes a workspace — its own tabs (and, in later
/// phases, editor files and a file tree).
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: URL
    var sortOrder: Int
    var createdAt: Date
    var lastOpenedAt: Date

    /// The tabs that belong to this project. Empty for a fresh project until
    /// the user opens its window — on first activation a default tab is added.
    var tabs: [Tab]

    /// The tab currently active in this project's window. nil if no tabs.
    var activeTabId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sortOrder: Int,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        tabs: [Tab] = [],
        activeTabId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.tabs = tabs
        self.activeTabId = activeTabId
    }

    /// Convenience: build a project for a given on-disk folder, with the
    /// display name defaulting to the folder's last path component. Starts
    /// with no tabs — they're added on first window activation.
    static func fromFolder(_ url: URL, sortOrder: Int) -> Project {
        Project(name: url.lastPathComponent, path: url, sortOrder: sortOrder)
    }
}
```

- [ ] **Step 2: Bump the schema version in `AppState.swift`.**

In `/Users/ekinertac/Code/emux/Sources/Features/Projects/AppState.swift`, change:

```swift
    static let currentSchemaVersion = 1
```

To:

```swift
    static let currentSchemaVersion = 2
```

- [ ] **Step 3: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Move aside any existing Phase 2-format state.json so it doesn't decode-fail at next launch.**

```bash
mv ~/Library/Application\ Support/emux/state.json \
   ~/Library/Application\ Support/emux/state.json.v1.bak 2>/dev/null || echo "no prior state.json"
```

- [ ] **Step 5: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/Project.swift Sources/Features/Projects/AppState.swift && \
  git commit -m "feat(tabs): extend Project schema with tabs[] + activeTabId (v2)"
```

---

## Task 3: Extend ProjectsModel with tab + active-project mutations

**Files:**
- Modify: `Sources/Features/Projects/ProjectsModel.swift`

We add five new mutation methods. Each mutates the `projects` array and calls `scheduleSave()`. None of these create live `SurfaceView`s — the TerminalController owns those (it reads the persisted `Tab` model to spawn surfaces).

- [ ] **Step 1: Open the file and append the new methods inside the existing class.**

Use the Edit tool to insert the new methods AFTER the existing `moveProjects` method (which ends with `scheduleSave()` then `}`). Specifically, replace this existing text:

```swift
    func moveProjects(from sourceIndices: IndexSet, to destination: Int) {
        projects.move(fromOffsets: sourceIndices, toOffset: destination)
        // Renumber sortOrder so it stays monotonic
        for (i, _) in projects.enumerated() {
            projects[i].sortOrder = i
        }
        scheduleSave()
    }

    // MARK: - Persistence helpers
```

With:

```swift
    func moveProjects(from sourceIndices: IndexSet, to destination: Int) {
        projects.move(fromOffsets: sourceIndices, toOffset: destination)
        // Renumber sortOrder so it stays monotonic
        for (i, _) in projects.enumerated() {
            projects[i].sortOrder = i
        }
        scheduleSave()
    }

    // MARK: - Tab mutations

    /// Add a new tab to the given project. Returns the created Tab.
    /// The tab's `cwd` defaults to the project's path; pass an explicit cwd
    /// to spawn the shell elsewhere.
    @discardableResult
    func addTab(toProject projectId: UUID, cwd: URL? = nil) -> Tab? {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        let nextSort = (projects[idx].tabs.map(\.sortOrder).max() ?? -1) + 1
        let tab = Tab(
            title: (cwd ?? projects[idx].path).lastPathComponent,
            sortOrder: nextSort,
            cwd: cwd ?? projects[idx].path
        )
        projects[idx].tabs.append(tab)
        projects[idx].activeTabId = tab.id
        scheduleSave()
        return tab
    }

    /// Close a tab. Returns the id of the tab that should become active after
    /// the close (nil if the project now has no tabs).
    @discardableResult
    func closeTab(_ tabId: UUID, inProject projectId: UUID) -> UUID? {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        guard let tIdx = projects[pIdx].tabs.firstIndex(where: { $0.id == tabId }) else { return nil }

        projects[pIdx].tabs.remove(at: tIdx)

        // Choose the next-active tab: prefer the one that was to the right of
        // the closed tab, fall back to the new last tab if we closed the last.
        let nextActive: UUID?
        if projects[pIdx].tabs.isEmpty {
            nextActive = nil
        } else if tIdx < projects[pIdx].tabs.count {
            nextActive = projects[pIdx].tabs[tIdx].id
        } else {
            nextActive = projects[pIdx].tabs.last?.id
        }
        if projects[pIdx].activeTabId == tabId {
            projects[pIdx].activeTabId = nextActive
        }

        // Renumber sortOrder
        for (i, _) in projects[pIdx].tabs.enumerated() {
            projects[pIdx].tabs[i].sortOrder = i
        }

        scheduleSave()
        return nextActive
    }

    /// Set the active tab within a project. No-op if either id is missing.
    func switchTab(to tabId: UUID, inProject projectId: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        guard projects[pIdx].tabs.contains(where: { $0.id == tabId }) else { return }
        projects[pIdx].activeTabId = tabId
        scheduleSave()
    }

    /// Rename a tab's title.
    func renameTab(_ tabId: UUID, to newTitle: String, inProject projectId: UUID) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pIdx = projects.firstIndex(where: { $0.id == projectId }),
              let tIdx = projects[pIdx].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        projects[pIdx].tabs[tIdx].title = trimmed
        scheduleSave()
    }

    // MARK: - Active project

    /// Switch the active project. This is purely a model update — the
    /// AppDelegate observes selectedProjectId and routes window ordering.
    func setActiveProject(_ projectId: UUID?) {
        selectedProjectId = projectId
        if let id = projectId, let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].lastOpenedAt = Date()
        }
        scheduleSave()
    }

    // MARK: - Persistence helpers
```

(There are five new public methods + a `// MARK: - Active project` section. Total addition: ~75 lines.)

- [ ] **Step 2: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectsModel.swift && \
  git commit -m "feat(tabs): add tab + active-project mutation API to ProjectsModel"
```

---

## Task 4: Create TabCell SwiftUI view (active/inactive visuals)

**Files:**
- Create: `Sources/Features/Projects/TabCell.swift`

The cell renders one tab: title, close button (×) on hover, distinct visuals per state. The user requested: **dark gray background for the active tab; black background for inactive tabs.** We honor that — these are explicit visual constants, not derived from system colors.

- [ ] **Step 1: Create `TabCell.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/TabCell.swift` with these exact contents:

```swift
import SwiftUI

/// One cell in the custom tab strip. Renders the tab title and an optional
/// close button that appears on hover. Visual states:
///   • Active   — dark-gray background, near-white text, no border
///   • Inactive — black background, dimmed text, subtle hairline divider
///   • Hover    — close button (×) becomes visible
struct TabCell: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.55))
                    .lineLimit(1)

                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                } else {
                    // Reserve the same horizontal space so the title doesn't jitter
                    Color.clear.frame(width: 13, height: 13)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color(red: 0.18, green: 0.18, blue: 0.18) : Color.black)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 1) {
        TabCell(title: "self-healing-crawler", isActive: true,  onSelect: {}, onClose: {})
        TabCell(title: "gaffer",                isActive: false, onSelect: {}, onClose: {})
        TabCell(title: "picture-me",            isActive: false, onSelect: {}, onClose: {})
    }
    .padding()
    .background(Color.black)
    .frame(width: 600)
}
#endif
```

- [ ] **Step 2: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/TabCell.swift && \
  git commit -m "feat(tabs): add TabCell with dark-gray active / black inactive visuals"
```

---

## Task 5: Create TabStripView (horizontal strip + new-tab button)

**Files:**
- Create: `Sources/Features/Projects/TabStripView.swift`

A horizontal `HStack` of `TabCell`s + a `+` button on the right. Hairlines between cells. Drops the title under the macOS chrome — the parent (terminal pane's content view) provides any toolbar gap.

- [ ] **Step 1: Create `TabStripView.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/TabStripView.swift` with these exact contents:

```swift
import SwiftUI

/// The custom tab strip rendered at the top of the terminal pane. Replaces
/// macOS native NSWindow tabbing, which we disable globally (see
/// TerminalWindow.swift). The strip is bound to a Project's `tabs` and
/// `activeTabId`; callbacks for select/close/new are routed to the
/// AppDelegate's per-project TerminalController.
struct TabStripView: View {
    let tabs: [Tab]
    let activeTabId: UUID?

    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabCell(
                            title: tab.title,
                            isActive: tab.id == activeTabId,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) }
                        )
                    }
                }
            }

            // New-tab "+" button
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")

            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .background(Color.black)
    }
}

#if DEBUG
#Preview {
    TabStripView(
        tabs: [
            Tab(title: "self-healing-crawler", sortOrder: 0,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler")),
            Tab(title: "gaffer", sortOrder: 1,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer")),
            Tab(title: "picture-me", sortOrder: 2,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/picture-me")),
        ],
        activeTabId: nil,
        onSelect: { _ in },
        onClose: { _ in },
        onNew: { }
    )
    .frame(width: 600)
}

#Preview("with active tab") {
    // A separate preview where the first tab is active. We rebuild the array
    // inline so the preview compiles without needing access to UUID literals.
    let t0 = Tab(title: "self-healing-crawler", sortOrder: 0,
                 cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler"))
    let t1 = Tab(title: "gaffer", sortOrder: 1,
                 cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer"))
    return TabStripView(
        tabs: [t0, t1],
        activeTabId: t0.id,
        onSelect: { _ in },
        onClose: { _ in },
        onNew: { }
    )
    .frame(width: 600)
}
#endif
```

- [ ] **Step 2: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/TabStripView.swift && \
  git commit -m "feat(tabs): add TabStripView (custom in-content tab strip)"
```

---

## Task 6: Disable native NSWindow tabbing in TerminalWindow

**Files:**
- Modify: `Sources/Features/Terminal/Window Styles/TerminalWindow.swift`

Today `TerminalWindow.swift:90` sets `tabbingMode = .preferred`. We change it to `.disallowed` so macOS never auto-creates tabs, the in-titlebar tab UI never fires, and tab-related keyboard shortcuts no longer route to AppKit's native tab handling. The custom TabStripView (Task 5) replaces that UX.

- [ ] **Step 1: Read the existing tabbingMode block in `TerminalWindow.swift`.**

```bash
sed -n '85,100p' /Users/ekinertac/Code/emux/Sources/Features/Terminal/Window\ Styles/TerminalWindow.swift
```
Expected: shows a code block setting `tabbingMode = .preferred` (or `.automatic` under a conditional).

- [ ] **Step 2: Replace the block.**

Use the Edit tool. Find the existing text in `Sources/Features/Terminal/Window Styles/TerminalWindow.swift`:

```swift
        tabbingMode = .preferred
```

(There may be additional related lines like `self.tabbingMode = .automatic` nearby in a conditional. Replace just the one literal `tabbingMode = .preferred` line for now.)

Replace with:

```swift
        // emux: native NSWindow tabbing is disabled. Tabs are rendered by our
        // custom TabStripView inside the terminal pane instead.
        tabbingMode = .disallowed
```

- [ ] **Step 3: Also handle the conditional sibling, if present.**

```bash
grep -n 'self.tabbingMode\b' /Users/ekinertac/Code/emux/Sources/Features/Terminal/Window\ Styles/TerminalWindow.swift
```

If the grep returns a line like `self.tabbingMode = .automatic`, replace its surrounding `if`-block with a comment and the unconditional `.disallowed`. Show the surrounding 4-5 lines via `sed -n` before editing, then use Edit to replace the exact block.

If the grep returns nothing, skip this step.

- [ ] **Step 4: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`. (Existing native-tab code in TerminalController is dead but still compiles; we leave it for now and remove in Task 12.)

- [ ] **Step 5: Manual smoke check — confirm native tabs are gone.**

Launch the app:
```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -1)
open "$APP_PATH"
```
Try ⌘T (new tab). Expected: nothing happens, or you get a new *window* (not a tab in the same window). Quit when verified.

- [ ] **Step 6: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Terminal/Window\ Styles/TerminalWindow.swift && \
  git commit -m "feat(tabs): disable native NSWindow tabbing in TerminalWindow"
```

---

## Task 7: Add TabState in-memory struct + tabs array to BaseTerminalController

**Files:**
- Modify: `Sources/Features/Terminal/BaseTerminalController.swift`

We add an in-memory `TabState` struct (live SurfaceView trees, not Codable) and a `tabs: [TabState]` property, plus an `activeTabId: UUID?`. The existing `@Published var surfaceTree` field is repurposed as "the active tab's tree" — setting `activeTabId` swaps which tree is bound to `surfaceTree`.

This task only adds the storage. The wiring to the actual tab swapping happens in Task 8.

- [ ] **Step 1: Read the existing `@Published var surfaceTree` declaration block.**

```bash
sed -n '40,55p' /Users/ekinertac/Code/emux/Sources/Features/Terminal/BaseTerminalController.swift
```
Expected: shows the `@Published var surfaceTree: SplitTree<Ghostty.SurfaceView>` declaration and `commandPaletteIsShowing`.

- [ ] **Step 2: Insert TabState + tabs + activeTabId right after the surfaceTree declaration.**

Use the Edit tool. Replace this existing text:

```swift
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false
```

With:

```swift
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    /// In-memory state for one tab. `tree` is the live SurfaceView tree for
    /// this tab — it stays alive even when the tab is not the active one.
    /// `meta` is the persisted Tab model (title, cwd, etc).
    struct TabState: Identifiable {
        let id: UUID
        var meta: Tab
        var tree: SplitTree<Ghostty.SurfaceView>
    }

    /// All tabs currently open in this controller's window. The active one
    /// has its tree mirrored into `surfaceTree`.
    @Published var tabs: [TabState] = []

    /// The id of the tab currently active in this window. Setting this via
    /// `activateTab(_:)` swaps `surfaceTree` to the new tab's tree.
    @Published private(set) var activeTabId: UUID?

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false
```

- [ ] **Step 3: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Terminal/BaseTerminalController.swift && \
  git commit -m "feat(tabs): add TabState + tabs[] + activeTabId to BaseTerminalController"
```

---

## Task 8: Tab lifecycle methods on BaseTerminalController

**Files:**
- Modify: `Sources/Features/Terminal/BaseTerminalController.swift`

Add four methods: `addTab(meta:)`, `closeTab(_:)`, `activateTab(_:)`, `rebuildTabs(from:projectsModel:projectId:)`. These manage the live `SurfaceView` lifecycle and keep the persisted `ProjectsModel` in sync.

- [ ] **Step 1: Find a clean place to insert the methods.**

```bash
grep -n '// MARK: - Surface Tree' Sources/Features/Terminal/BaseTerminalController.swift | head -3
```

If a `// MARK: - Surface Tree` section exists, insert the new section immediately ABOVE it. If not, append at the end of the class (just before the closing `}`).

- [ ] **Step 2: Insert the tab lifecycle methods.**

Add a new section. Find the existing line `// MARK: - Surface Tree` (or wherever you decided in Step 1) and insert this block IMMEDIATELY BEFORE it:

```swift
    // MARK: - Tabs

    /// Add a tab to this controller. Creates a new SurfaceView spawned in
    /// `meta.cwd`. Activates the new tab.
    @discardableResult
    func addTab(meta: Tab) -> TabState {
        let baseConfig = Ghostty.SurfaceConfiguration()
        // The plan deliberately uses the default config + the persisted cwd.
        // shellOverride is honored by Ghostty's config; for v1 we don't pass
        // it through (emux uses the user's default shell).
        var configWithCwd = baseConfig
        configWithCwd.workingDirectory = meta.cwd.path

        let surface = Ghostty.SurfaceView(ghostty, baseConfig: configWithCwd)
        let tree = SplitTree<Ghostty.SurfaceView>(view: surface)
        let state = TabState(id: meta.id, meta: meta, tree: tree)
        tabs.append(state)
        activateTab(state.id)
        return state
    }

    /// Close a tab. If it was the last one, the caller is responsible for
    /// closing the window (we don't auto-close here so the AppDelegate can
    /// decide policy). If it was the active tab, the next tab to the right
    /// (or the new last tab) becomes active.
    func closeTab(_ tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs.remove(at: idx)
        guard !tabs.isEmpty else {
            activeTabId = nil
            surfaceTree = .init()
            return
        }
        let nextIdx = min(idx, tabs.count - 1)
        activateTab(tabs[nextIdx].id)
    }

    /// Make `tabId` the active tab. Saves the outgoing tab's tree from
    /// `surfaceTree` and loads the incoming tab's tree. No-op if `tabId`
    /// is already active or not found.
    func activateTab(_ tabId: UUID) {
        guard tabId != activeTabId else { return }
        guard let newIdx = tabs.firstIndex(where: { $0.id == tabId }) else { return }

        // Save outgoing
        if let oldId = activeTabId,
           let oldIdx = tabs.firstIndex(where: { $0.id == oldId }) {
            tabs[oldIdx].tree = surfaceTree
        }

        // Load incoming
        activeTabId = tabId
        surfaceTree = tabs[newIdx].tree
    }

    /// Build live `TabState`s from a project's persisted `Tab[]`. Called
    /// once when a TerminalController is created for a project. If the
    /// project has no persisted tabs, creates a single default tab at the
    /// project root.
    func rebuildTabs(from project: Project) {
        if project.tabs.isEmpty {
            let initial = Tab(
                title: project.path.lastPathComponent,
                sortOrder: 0,
                cwd: project.path
            )
            _ = addTab(meta: initial)
            return
        }
        for tabMeta in project.tabs.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            _ = addTab(meta: tabMeta)
        }
        if let active = project.activeTabId, tabs.contains(where: { $0.id == active }) {
            activateTab(active)
        } else if let first = tabs.first {
            activateTab(first.id)
        }
    }
```

- [ ] **Step 3: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD|.*\.swift:[0-9]+:[0-9]+: error)' | head -15
```
Expected: `** BUILD SUCCEEDED **`.

If you see `error: cannot find 'Ghostty.SurfaceConfiguration' in scope` or similar, the SurfaceView init signature in this codebase may differ from what we wrote. Read `Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` and `Sources/Ghostty/Ghostty.Surface.swift` to find the actual init signature, then update the `addTab` method to match. The required behavior is: "create a SurfaceView that spawns the user's default shell in `meta.cwd`".

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Terminal/BaseTerminalController.swift && \
  git commit -m "feat(tabs): add addTab/closeTab/activateTab/rebuildTabs lifecycle"
```

---

## Task 9: Create EmuxSplitController (NSSplitViewController with width persistence)

**Files:**
- Create: `Sources/Features/Projects/EmuxSplitController.swift`

This NSViewController hosts the sidebar (left) and content (right) for one window. It persists the sidebar width to `UserDefaults` keyed by `"emux.sidebar.width"`.

- [ ] **Step 1: Create `EmuxSplitController.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/EmuxSplitController.swift` with these exact contents:

```swift
import AppKit
import SwiftUI

/// The window-level layout host for an emux project window. Holds the
/// projects sidebar (left, collapsible) and the terminal content (right,
/// non-collapsible). Persists the user-dragged sidebar width to UserDefaults.
final class EmuxSplitController: NSSplitViewController {
    private static let sidebarWidthKey = "emux.sidebar.width"
    private static let defaultSidebarWidth: CGFloat = 200

    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem

    /// - Parameters:
    ///   - sidebar: the SwiftUI sidebar view (typically ProjectsSidebarView).
    ///   - content: the NSView that hosts tabs + the active terminal.
    init<Sidebar: View>(sidebar: Sidebar, content: NSView) {
        let sidebarHost = NSHostingController(rootView: sidebar)
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        self.sidebarItem.minimumThickness = 150
        self.sidebarItem.maximumThickness = 400
        self.sidebarItem.canCollapse = true

        let contentVC = NSViewController()
        contentVC.view = content
        self.contentItem = NSSplitViewItem(viewController: contentVC)
        self.contentItem.canCollapse = false
        self.contentItem.holdingPriority = .defaultLow  // sidebar wins fights, content grows

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        // Restore persisted sidebar width
        let stored = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        let width = stored > 0 ? CGFloat(stored) : Self.defaultSidebarWidth
        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(width, ofDividerAt: 0)
        }
    }

    /// NSSplitViewDelegate hook — called any time the user drags the divider.
    /// We persist the sidebar's resulting width.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let width = Double(sidebarItem.viewController.view.frame.width)
        // Only persist values within our min/max — avoids saving spurious
        // values during window resize storms.
        guard width >= 150, width <= 400 else { return }
        UserDefaults.standard.set(width, forKey: Self.sidebarWidthKey)
    }
}
```

- [ ] **Step 2: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/EmuxSplitController.swift && \
  git commit -m "feat(layout): add EmuxSplitController (sidebar + content with width persistence)"
```

---

## Task 10: Build the per-window content view (TabStripView + terminal area)

**Files:**
- Create: `Sources/Features/Projects/ProjectWindowContentView.swift`

The content side of the split (right of the sidebar) is a vertical layout: TabStripView on top, terminal area below. The terminal area is the existing inherited `TerminalView` from Ghostty (renders the active `surfaceTree`). This file wires them together.

- [ ] **Step 1: Create `ProjectWindowContentView.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/ProjectWindowContentView.swift` with these exact contents:

```swift
import SwiftUI

/// The right-pane content for an emux project window. A custom tab strip on
/// top, the inherited Ghostty `TerminalView` below (which renders the active
/// tab's `surfaceTree`). The window's `BaseTerminalController` owns the
/// tab list + the active id; this view is a thin observer that turns model
/// state into UI and routes user actions back to the controller.
struct ProjectWindowContentView<Controller: BaseTerminalController & TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: Controller
    weak var delegate: (any TerminalViewDelegate)?

    /// The project the window is bound to. We need this to call the model's
    /// tab mutators with the right `projectId`.
    let projectId: UUID
    @ObservedObject var projectsModel: ProjectsModel

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(
                tabs: controller.tabs.map(\.meta),
                activeTabId: controller.activeTabId,
                onSelect: { id in
                    controller.activateTab(id)
                    projectsModel.switchTab(to: id, inProject: projectId)
                },
                onClose: { id in
                    controller.closeTab(id)
                    let next = projectsModel.closeTab(id, inProject: projectId)
                    if let next { controller.activateTab(next) }
                },
                onNew: {
                    let projectPath = projectsModel.projects.first(where: { $0.id == projectId })?.path
                    if let meta = projectsModel.addTab(toProject: projectId, cwd: projectPath) {
                        controller.addTab(meta: meta)
                    }
                }
            )

            // The inherited Ghostty TerminalView renders controller.surfaceTree
            // (the active tab's tree).
            TerminalView(ghostty: ghostty, viewModel: controller, delegate: delegate)
        }
    }
}
```

- [ ] **Step 2: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD|.*\.swift:[0-9]+:[0-9]+: error)' | head -10
```
Expected: `** BUILD SUCCEEDED **`.

If you see `error: cannot find type 'TerminalViewModel' in scope`, the protocol lives in `Sources/Features/Terminal/TerminalView.swift` — adjust the generic constraint to whatever the inherited view model protocol is actually called. The behavioral requirement is: `controller` must conform to whatever protocol `TerminalView` requires for its `viewModel` parameter, plus our new `tabs`/`activeTabId`/`activateTab`/`closeTab`/`addTab` API.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectWindowContentView.swift && \
  git commit -m "feat(tabs): add ProjectWindowContentView (tab strip + terminal)"
```

---

## Task 11: Wire EmuxSplitController + ProjectWindowContentView into TerminalController

**Files:**
- Modify: `Sources/Features/Terminal/TerminalController.swift` (around line 1037-1055, the windowDidLoad block from Phase 2)

We replace the NavigationSplitView-wrapped `TerminalViewContainer` with one that hosts an `EmuxSplitController` instead. The sidebar gets the existing `ProjectsSidebarView`; the content is an `NSHostingView` of `ProjectWindowContentView`. The window's contentViewController becomes the EmuxSplitController.

This task also stores the `projectId` on TerminalController (a new stored property) so future tab operations know which project we belong to.

- [ ] **Step 1: Add a `projectId` stored property to TerminalController.**

Find the existing top-of-class declarations in `TerminalController.swift`. Add:

```swift
    /// The project this window/controller belongs to. Set at construction
    /// time by AppDelegate.activateProject.
    var projectId: UUID?
```

…immediately after the existing `static var lastMain` declaration (around line 45). The exact placement is flexible — just somewhere in the property declarations block, not inside a method.

- [ ] **Step 2: Read the existing block AND its trailing lines.**

```bash
sed -n '1037,1065p' /Users/ekinertac/Code/emux/Sources/Features/Terminal/TerminalController.swift
```

You should see approximately this (post-Phase-2):

```swift
        // Initialize our content view to the SwiftUI root.
        // emux: the SwiftUI hierarchy is now wrapped in a NavigationSplitView whose
        // sidebar lists user-added projects. The detail pane is the inherited
        // Ghostty `TerminalView`. In Phase 2 the sidebar is decorative — selecting
        // a project doesn't yet scope anything.
        let projectsModel = (NSApp.delegate as? AppDelegate)?.projectsModel ?? ProjectsModel()
        let container = TerminalViewContainer {
            NavigationSplitView {
                ProjectsSidebarView(model: projectsModel)
                    .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
            } detail: {
                TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
            }
            .navigationSplitViewStyle(.balanced)
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain.
        container.initialContentSize = focusedSurface?.initialSize

        window.contentView = container
```

**The entire block from `// Initialize our content view to the SwiftUI root.` through `window.contentView = container` must be replaced.** Do NOT preserve the `container.initialContentSize` line — it references a variable that no longer exists in the new code.

- [ ] **Step 3: Replace the ENTIRE block.**

Use the Edit tool with the full old_string above and this new_string:

```swift
        // Initialize our content view as an EmuxSplitController hosting the
        // projects sidebar (left) and a per-project content view (right) that
        // contains our custom tab strip + the inherited Ghostty TerminalView.
        let projectsModel = (NSApp.delegate as? AppDelegate)?.projectsModel ?? ProjectsModel()

        // Right pane: tab strip on top + Ghostty terminal below.
        let contentRoot = ProjectWindowContentView(
            ghostty: ghostty,
            controller: self,
            delegate: self,
            projectId: projectId ?? UUID(),  // AppDelegate sets a real id before showing
            projectsModel: projectsModel
        )
        let contentHost = NSHostingView(rootView: contentRoot)

        // Sidebar.
        let sidebar = ProjectsSidebarView(model: projectsModel)

        // Wire them together. Setting contentViewController also sets contentView.
        let split = EmuxSplitController(sidebar: sidebar, content: contentHost)
        window.contentViewController = split
```

(We lose the `initialContentSize` fallback — Phase 2's UX relied on this for first-paint sizing of the terminal grid. If the terminal renders at a too-small size on first launch in Task 17's smoke check, restore the behavior by computing `focusedSurface?.initialSize` on `contentHost.frame.size` or similar. Defer if it doesn't cause visible problems.)

- [ ] **Step 4: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD|.*\.swift:[0-9]+:[0-9]+: error)' | head -15
```
Expected: `** BUILD SUCCEEDED **`. (TerminalViewContainer is no longer the window's contentView — its glass-effect logic may now no-op or render in a smaller scope. Acceptable for Phase 3.)

If you see `error: argument labels '(ghostty:controller:delegate:projectId:projectsModel:)' do not match`, the constraint we added to `ProjectWindowContentView<Controller>` in Task 10 may need adjustment. Check the generic constraint and adjust the call site to match.

- [ ] **Step 5: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Terminal/TerminalController.swift && \
  git commit -m "feat(layout): host EmuxSplitController in TerminalController windowDidLoad"
```

---

## Task 12: AppDelegate — ProjectWindowRegistry + activateProject

**Files:**
- Modify: `Sources/App/macOS/AppDelegate.swift`

AppDelegate gains a registry `[Project.id: TerminalController]` and an `activateProject(_:Project)` method that creates/shows that project's window (and hides others). On `applicationDidFinishLaunching`, activate the last-active project (or do nothing if no projects).

- [ ] **Step 1: Add the registry property near the other AppDelegate stored properties.**

Find the existing `lazy var projectsModel = ...` line we added in Phase 2. Immediately after it, insert:

```swift
    /// One TerminalController per project that has been opened this session.
    /// We never destroy them — switching projects just orderOut/orderFronts.
    private var projectWindows: [UUID: TerminalController] = [:]
```

- [ ] **Step 2: Add the `activateProject` method.**

Find a clean place inside the AppDelegate class — for example, near the `applicationDidFinishLaunching` method. Insert:

```swift
    /// Make the given project the active one. Brings its window forward,
    /// creating it from persisted state if this is the first activation
    /// in the session. Other project windows are ordered out.
    @MainActor
    func activateProject(_ project: Project) {
        // Hide all other project windows first.
        for (id, controller) in projectWindows where id != project.id {
            controller.window?.orderOut(nil)
        }

        if let existing = projectWindows[project.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.window?.orderFrontRegardless()
            projectsModel.setActiveProject(project.id)
            return
        }

        // First activation this session — build a fresh TerminalController
        // bound to this project's persisted tabs.
        let controller = TerminalController(ghostty)
        controller.projectId = project.id
        projectWindows[project.id] = controller

        // The window has loaded; now hydrate tabs from the project model.
        if let window = controller.window {
            window.makeKeyAndOrderFront(nil)
        }
        controller.rebuildTabs(from: project)
        projectsModel.setActiveProject(project.id)
    }
```

- [ ] **Step 3: Wire `applicationDidFinishLaunching` to activate the last project.**

Find the existing `applicationDidFinishLaunching(_:)` method. Append (or insert near the end of) the following code block, before the closing `}`:

```swift
        // emux: open a window for the last-active project, if any.
        if let lastId = projectsModel.selectedProjectId,
           let last = projectsModel.projects.first(where: { $0.id == lastId }) {
            activateProject(last)
        } else if let first = projectsModel.projects.first {
            activateProject(first)
        }
        // If no projects exist, no window is opened. The user can add one
        // via... (currently impossible until the empty-state sidebar appears.
        // See Task 13 for the workaround.)
```

- [ ] **Step 4: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/App/macOS/AppDelegate.swift && \
  git commit -m "feat(scoping): activateProject + per-project window registry in AppDelegate"
```

---

## Task 13: Sidebar — selection change activates project

**Files:**
- Modify: `Sources/Features/Projects/ProjectsSidebarView.swift`

When the user clicks a row in the sidebar, the new selection should call `AppDelegate.activateProject(_:)`. This is the user-facing trigger for project switching.

Also: when no projects exist, the empty-state "Add Project…" button needs a way to launch a window even though there's no last-active project. We handle that here too — `pickFolderAndAdd` already calls `addProject`, and we extend it to also call `activateProject` on the newly-added project.

- [ ] **Step 1: Modify `projectList` to react to selection changes.**

Find the existing `List(selection: $model.selectedProjectId)` block in `ProjectsSidebarView.swift`. Use the Edit tool to replace it with:

```swift
    private var projectList: some View {
        List(selection: $model.selectedProjectId) {
            ForEach(model.projects) { project in
                ProjectRowView(
                    project: project,
                    isSelected: model.selectedProjectId == project.id,
                    isEditing: editingProjectId == project.id,
                    onCommitRename: { newName in
                        model.renameProject(id: project.id, to: newName)
                        editingProjectId = nil
                    },
                    onCancelRename: {
                        editingProjectId = nil
                    }
                )
                .tag(project.id)
                .contextMenu {
                    Button("Rename") {
                        editingProjectId = project.id
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.path])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        deleteTarget = project
                        showDelete = true
                    }
                }
            }
            .onMove { source, destination in
                model.moveProjects(from: source, to: destination)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedProjectId) { _, newId in
            guard let id = newId,
                  let project = model.projects.first(where: { $0.id == id }),
                  let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.activateProject(project)
        }
    }
```

(The change is the addition of the `.onChange(of: model.selectedProjectId)` modifier at the bottom of the list.)

- [ ] **Step 2: Modify `pickFolderAndAdd` to activate the newly-added project.**

Find the existing `pickFolderAndAdd` method. Replace it with:

```swift
    private func pickFolderAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add as an emux project"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = model.addProject(at: url)
        model.selectedProjectId = added.id
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.activateProject(added)
        }
    }
```

(Only the last three lines — the `if let appDelegate ...` block — are new. The rest is unchanged.)

- [ ] **Step 3: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectsSidebarView.swift && \
  git commit -m "feat(scoping): sidebar selection activates project window"
```

---

## Task 14: Wire ⌘T / ⌘W to active TerminalController's tab methods

**Files:**
- Modify: `Sources/App/macOS/AppDelegate.swift` (or wherever Ghostty's existing ⌘T / ⌘W actions live)

Ghostty inherits ⌘T (new tab) and ⌘W (close tab) bindings. Today they trigger native NSWindow tab logic. We need to route them through our custom tab API instead. The cleanest hook is the `@IBAction newTab(_:)` method on AppDelegate (search for it).

- [ ] **Step 1: Find the existing newTab / closeTab actions.**

```bash
grep -n 'func newTab\|func closeTab\|@IBAction func newTab\|@IBAction func performClose' Sources/App/macOS/AppDelegate.swift | head -10
```

- [ ] **Step 2: Replace the body of `newTab(_:)` (or wrap it).**

Find the `@IBAction func newTab(_:Any?)` method. The existing body probably calls `TerminalController.newTab(...)` (Ghostty's native-tab routing). Replace its body with:

```swift
        // emux: route ⌘T to the active project's TerminalController's addTab API.
        guard let activeProjectId = projectsModel.selectedProjectId,
              let project = projectsModel.projects.first(where: { $0.id == activeProjectId }),
              let controller = projectWindows[activeProjectId] else { return }

        if let meta = projectsModel.addTab(toProject: activeProjectId, cwd: project.path) {
            controller.addTab(meta: meta)
        }
```

If `projectWindows` is `private`, you can either change it to `fileprivate` or add a private helper that accepts a closure.

- [ ] **Step 3: Replace the body of the close-tab action.**

The close-tab is typically the `@IBAction func closeTab(_:Any?)` or `performClose(_:)`. Replace its body with:

```swift
        // emux: route ⌘W to close the active tab in the active project.
        guard let activeProjectId = projectsModel.selectedProjectId,
              let controller = projectWindows[activeProjectId],
              let activeTabId = controller.activeTabId else { return }

        controller.closeTab(activeTabId)
        let next = projectsModel.closeTab(activeTabId, inProject: activeProjectId)
        if let next { controller.activateTab(next) }

        // If no tabs left, close the window. Project record remains in the sidebar.
        if controller.tabs.isEmpty {
            controller.window?.close()
            projectWindows.removeValue(forKey: activeProjectId)
        }
```

- [ ] **Step 4: Verify build.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/App/macOS/AppDelegate.swift && \
  git commit -m "feat(tabs): route ⌘T and ⌘W to custom tab API"
```

---

## Task 15: Tab keyboard navigation — ⌘1..⌘9 and ⌘⇧[ / ⌘⇧]

**Files:**
- Modify: `Sources/App/macOS/AppDelegate.swift`

⌘1..⌘9 selects the Nth tab (1-indexed) in the active project. ⌘⇧[ / ⌘⇧] cycle backward/forward through tabs. Both wrap.

- [ ] **Step 1: Add the keyboard handler hook.**

Find the existing local-event monitor in AppDelegate (search for `addLocalMonitorForEvents`). It's where Ghostty intercepts key events for app-level shortcuts. Add a new branch to that monitor that handles `⌘1..⌘9` and `⌘⇧[ / ⌘⇧]`.

Insert this method anywhere in the AppDelegate class:

```swift
    /// Returns `event` if not consumed, nil if consumed (suppresses default
    /// handling). Called from the existing local key-event monitor.
    private func handleEmuxTabShortcuts(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let activeProjectId = projectsModel.selectedProjectId,
              let controller = projectWindows[activeProjectId],
              !controller.tabs.isEmpty else { return event }

        // ⌘1..⌘9 — select Nth tab.
        if mods == .command, let chars = event.charactersIgnoringModifiers,
           chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            let idx = digit - 1
            guard idx < controller.tabs.count else { return event }
            controller.activateTab(controller.tabs[idx].id)
            projectsModel.switchTab(to: controller.tabs[idx].id, inProject: activeProjectId)
            return nil
        }

        // ⌘⇧[ — previous tab; ⌘⇧] — next tab.
        if mods == [.command, .shift], let chars = event.charactersIgnoringModifiers {
            guard let activeTabId = controller.activeTabId,
                  let curIdx = controller.tabs.firstIndex(where: { $0.id == activeTabId }) else { return event }
            let count = controller.tabs.count
            switch chars {
            case "{":  // ⌘⇧[
                let prev = (curIdx - 1 + count) % count
                controller.activateTab(controller.tabs[prev].id)
                projectsModel.switchTab(to: controller.tabs[prev].id, inProject: activeProjectId)
                return nil
            case "}":  // ⌘⇧]
                let next = (curIdx + 1) % count
                controller.activateTab(controller.tabs[next].id)
                projectsModel.switchTab(to: controller.tabs[next].id, inProject: activeProjectId)
                return nil
            default:
                break
            }
        }

        return event
    }
```

- [ ] **Step 2: Hook the new handler into the existing event monitor.**

Find the call to `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in AppDelegate (probably in `applicationDidFinishLaunching`). The closure typically looks like:

```swift
NSApp.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    // existing handling...
    return event
}
```

At the START of that closure body (immediately after the `[weak self]` guard) insert:

```swift
            if let consumed = self?.handleEmuxTabShortcuts(event), consumed != event {
                return nil
            }
            if let pass = self?.handleEmuxTabShortcuts(event) {
                return pass
            }
```

That awkward double-check pattern is because Swift closures don't let you both consume and pass. Use whichever idiom the existing closure uses; the goal is: if `handleEmuxTabShortcuts` returns nil, the closure returns nil; otherwise the rest of the existing handling runs.

A cleaner reorganization, if you can match it to the existing code:

```swift
NSApp.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    guard let self else { return event }
    if let after = self.handleEmuxTabShortcuts(event), after !== event {
        return after  // possibly nil (consumed) or modified
    }
    if self.handleEmuxTabShortcuts(event) == nil {
        return nil
    }
    // existing handling...
    return event
}
```

The implementer should READ the existing closure and choose the integration that fits — the rule is: emux's `handleEmuxTabShortcuts` returns nil to consume, returns `event` to pass.

- [ ] **Step 3: Verify build + manual smoke check.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

Manual: launch the app, add a project, ⌘T a few times, then ⌘1 / ⌘2 / ⌘3 should switch tabs. ⌘⇧] / ⌘⇧[ should cycle.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/App/macOS/AppDelegate.swift && \
  git commit -m "feat(tabs): wire ⌘1..⌘9 and ⌘⇧[ ⌘⇧] for tab navigation"
```

---

## Task 16: Project keyboard navigation — ⌃1..⌃9 and ⌘[ / ⌘]

**Files:**
- Modify: `Sources/App/macOS/AppDelegate.swift`

⌃1..⌃9 selects the Nth project (1-indexed) in the sidebar order. ⌘[ / ⌘] cycle backward/forward. Both wrap.

- [ ] **Step 1: Add the project-shortcut handler.**

Insert this method in the AppDelegate class (near `handleEmuxTabShortcuts`):

```swift
    /// Returns nil to consume; event to pass.
    private func handleEmuxProjectShortcuts(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !projectsModel.projects.isEmpty else { return event }

        // ⌃1..⌃9 — select Nth project.
        if mods == .control, let chars = event.charactersIgnoringModifiers,
           chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            let idx = digit - 1
            guard idx < projectsModel.projects.count else { return event }
            activateProject(projectsModel.projects[idx])
            return nil
        }

        // ⌘[ — previous project; ⌘] — next project.
        if mods == .command, let chars = event.charactersIgnoringModifiers {
            guard let activeId = projectsModel.selectedProjectId,
                  let curIdx = projectsModel.projects.firstIndex(where: { $0.id == activeId }) else { return event }
            let count = projectsModel.projects.count
            switch chars {
            case "[":
                let prev = (curIdx - 1 + count) % count
                activateProject(projectsModel.projects[prev])
                return nil
            case "]":
                let next = (curIdx + 1) % count
                activateProject(projectsModel.projects[next])
                return nil
            default:
                break
            }
        }

        return event
    }
```

- [ ] **Step 2: Add it to the same event monitor as Task 15.**

In the same key-event monitor closure where you added `handleEmuxTabShortcuts`, also add a similar branch for `handleEmuxProjectShortcuts`. Same pattern: nil = consumed, event = passed.

The order matters slightly: tab shortcuts use ⌘1..⌘9; project shortcuts use ⌃1..⌃9 — disjoint, so order doesn't actually matter for digits. For ⌘[ / ⌘] (project cycling) vs ⌘⇧[ / ⌘⇧] (tab cycling) — also disjoint by modifier set. Safe to call both.

- [ ] **Step 3: Verify build + manual smoke check.**

```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

Manual: with 2-3 projects added, ⌃1 / ⌃2 / ⌃3 should switch which project window is forward. ⌘] / ⌘[ should cycle.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/App/macOS/AppDelegate.swift && \
  git commit -m "feat(scoping): wire ⌃1..⌃9 and ⌘[ ⌘] for project navigation"
```

---

## Task 17: Launch + visual smoke check

**Files:** none modified.

- [ ] **Step 1: Quit any running emux.**

```bash
osascript -e 'tell application id "com.ekinertac.emux.debug" to quit' 2>/dev/null
sleep 1
```

- [ ] **Step 2: Launch.**

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -1)
open "$APP_PATH"
```

- [ ] **Step 3: Operator verification checklist.**

The OPERATOR (user) verifies:

1. **Sidebar appears with no projects** (or with the ones you had — if you wiped state.json before Task 2 you'll be empty).
2. **Add a project** via the `+` button. After picking a folder:
   - Sidebar updates with the new project row.
   - A WINDOW appears (or the existing window's content changes) bound to that project.
   - The terminal column shows: **the new TabStripView at the top** (with one tab, since rebuildTabs creates a default) and the terminal grid below.
3. **Tab visuals:** the active tab has a **dark-gray background** (not the default macOS chrome). Other tabs would have a **black background**.
4. **`⌘T` creates a new tab.** The new tab appears in the strip, spawns a fresh shell at the project's path.
5. **Click between tabs in the strip.** Active tab changes; terminal content swaps. The previous tab's shell stays alive (not killed).
6. **`⌘W` closes the active tab.** Next tab to the right becomes active. If you close all tabs, the window closes.
7. **`⌘1`/`⌘2`/`⌘3` switch tabs by index.** `⌘⇧[` / `⌘⇧]` cycle through tabs.
8. **Add a second project.** Sidebar lists both. Selecting in the sidebar swaps which window is forward.
9. **`⌃1`/`⌃2` switch projects.** The active window changes accordingly.
10. **Sidebar width persists.** Drag the divider, quit, relaunch. The width should restore.
11. **Tab state persists.** Quit while in project A with 3 tabs open. Relaunch. Project A's window should reappear with its 3 tabs (the *titles*; shell processes are fresh per the plan's scope).

Report any failure — at this point we expect a few rough edges around things like:
- Tab title not updating when shell cwd changes (Ghostty's title tracking — defer to polish)
- Window position / size restoration may not be exact (NSWindow restoration is separately complex — defer)
- Native tab keyboard shortcuts that Ghostty inherited might still fire and not be intercepted — flag specific cases

- [ ] **Step 4: Quit when verified.**

`⌘Q`.

---

## Task 18: Push Phase 3 to origin

**Files:** none modified.

- [ ] **Step 1: Confirm clean working tree.**

```bash
cd /Users/ekinertac/Code/emux && git status
```
Expected: `nothing to commit, working tree clean`. If there are uncommitted changes from earlier tasks, complete those task's commits before continuing.

- [ ] **Step 2: Push.**

```bash
cd /Users/ekinertac/Code/emux && git push origin main 2>&1 | tail -10
```

- [ ] **Step 3: Confirm sync.**

```bash
cd /Users/ekinertac/Code/emux && git log --oneline main origin/main | head -5
```
Expected: local and remote in sync.

---

## Phase 3 done — verification summary

Before declaring Phase 3 complete:

- [ ] `xcodebuild` succeeds for Debug + Release.
- [ ] Native NSWindow tabbing is disabled (no macOS tab bar appears above the sidebar).
- [ ] Custom TabStripView renders inside the terminal pane with dark-gray active / black inactive backgrounds.
- [ ] Each project has its own window with its own tab list, persisting across quit + relaunch.
- [ ] Sidebar width is restored to the user-dragged value after relaunch.
- [ ] All keybindings work (⌘T, ⌘W, ⌘1..⌘9, ⌘⇧[ / ⌘⇧], ⌃1..⌃9, ⌘[ / ⌘]).
- [ ] Sidebar click switches which project's window is forward.
- [ ] All commits pushed to `origin/main`.

## Known limitations (deliberate, deferred)

- **Drag-out-of-window** for tabs OR project rows is NOT implemented. Phase 4 / a dedicated UX phase will add NSDraggingSource on the tab cell.
- **Shell processes are NOT preserved across relaunch.** Tabs restore with their title + cwd, but a fresh shell spawns. Scrollback persistence is Phase 6.
- **Tab title doesn't auto-update when the shell `cd`s.** Ghostty's title tracking is per-surface — wire-up is deferred to polish.
- **Window size/position restoration is approximate.** Each window opens at the default size; remembering per-project window frame is a polish item.
- **Per-project sidebar collapse state.** The current `sidebarCollapsed` flag is global; making it per-project waits for the schema-v3 work.
- **Phase 2's `state.json` is invalidated.** Schema v1 → v2 has no migration; existing files are moved aside as `state.json.v1.bak` and the user starts fresh.
- **NSWindow auto-restoration may still try to restore Ghostty's old single-window state.** If problems show up on relaunch, search for `restorable = false` and apply where needed; defer real restoration to a polish pass.
