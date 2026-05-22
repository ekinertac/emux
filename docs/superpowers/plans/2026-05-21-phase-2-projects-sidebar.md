# Phase 2 — Projects Sidebar Shell

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a projects sidebar to every emux terminal window. The sidebar shows a list of user-added projects (folders), supports add / rename / delete / reorder, persists across launches via `state.json`, and exposes a Settings gear button. **The sidebar is decorative in Phase 2** — clicking a project doesn't yet scope tabs. That wiring lands in Phase 3.

**Architecture:** Smallest-possible footprint. We do NOT touch AppKit window plumbing (`TerminalViewContainer`, glass effects, intrinsicContentSize stay untouched). Instead, we wrap the existing SwiftUI `TerminalView` inside a SwiftUI `NavigationSplitView` whose sidebar is the new `ProjectsSidebarView`. `AppDelegate` gains a `projectsModel: ProjectsModel` singleton, which owns the project list and persists to disk via a separate `StatePersistence` actor. Six new Swift files under `Sources/Features/Projects/`; two existing files lightly modified.

**Tech Stack:** Swift 5.9+, SwiftUI (`NavigationSplitView`, `List`, `.contextMenu`), Combine (`@Published` / `@ObservedObject`), `Foundation.JSONEncoder`/`Decoder`, `FileManager` for atomic writes, `NSOpenPanel` for folder picker. macOS 14.6 deployment target. No new third-party dependencies.

**Plan scope:** Phase 2 of 9. Subsequent phases (project scoping, file tree, editor, scrollback, palette, modifier hints, polish) are planned individually after this phase ships. Do not pre-plan later phases.

---

## Prerequisites

- Phase 1 plan is shipped and committed (commit `36aa47a` on `main`).
- `emux.xcodeproj` builds cleanly with `xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build`.
- The user is the operator for interactive Xcode steps (synchronized folder groups in Xcode 16+ mean *most* file additions auto-pick-up, but verify).

---

## File map for this phase

```
Sources/Features/Projects/                     [NEW directory]
├── Project.swift                              [NEW]  Codable Project struct
├── AppState.swift                             [NEW]  Codable root persistence container
├── StatePersistence.swift                     [NEW]  load/save state.json (atomic + debounced)
├── ProjectsModel.swift                        [NEW]  ObservableObject — orchestrates project list + persistence
├── ProjectsSidebarView.swift                  [NEW]  SwiftUI sidebar view + folder picker
└── ProjectRowView.swift                       [NEW]  single row in the sidebar list

Sources/App/macOS/AppDelegate.swift            [MODIFIED]  own ProjectsModel singleton; wire log subsystem
Sources/Features/Terminal/TerminalController.swift  [MODIFIED]  wrap SwiftUI root in NavigationSplitView with sidebar

(No tests added in this phase — see plan scope.)
```

### Schema (Phase 2 subset of spec §2)

In Phase 2 we only need a subset of the spec's `AppState` schema. We define ONLY the fields used in Phase 2. The rest (`tabs`, `openEditorFiles`, etc.) get added in the phase that introduces them.

```swift
// Project.swift
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String                    // user-renameable; defaults to path.lastPathComponent
    var path: URL                       // project root directory
    var sortOrder: Int                  // monotonic; lower = higher in sidebar
    var createdAt: Date
    var lastOpenedAt: Date              // updated when scoping fires in Phase 3; touched on add for now
}

// AppState.swift
struct AppState: Codable {
    var schemaVersion: Int              // = 1 initially
    var projects: [Project]
    var lastActiveProjectId: UUID?      // updated in Phase 3; nil in Phase 2 (sidebar selection is in-memory only)
    var sidebarCollapsed: Bool          // global UI state for Phase 2

    static let empty = AppState(schemaVersion: 1, projects: [], lastActiveProjectId: nil, sidebarCollapsed: false)
    static let currentSchemaVersion = 1
}
```

### Persistence location

```
~/Library/Application Support/emux/state.json
```

Created on first write. Read on launch; if missing, start from `AppState.empty`. If corrupt, rename to `state.json.corrupt-<timestamp>` and start empty (never crash on startup).

### NavigationSplitView integration sketch

In `TerminalController.windowDidLoad()`, the existing line:

```swift
let container = TerminalViewContainer {
    TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
}
```

…becomes:

```swift
let container = TerminalViewContainer {
    NavigationSplitView(columnVisibility: .constant(.all)) {
        ProjectsSidebarView(model: appDelegate.projectsModel)
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
    } detail: {
        TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
    }
    .navigationSplitViewStyle(.balanced)
}
```

(Exact reference to `appDelegate` resolved inside `TerminalController`; see Task 7 for the details.)

---

## Task 1: Create the Project model

**Files:**
- Create: `Sources/Features/Projects/Project.swift`

- [ ] **Step 1: Create the Sources/Features/Projects/ directory.**

Run:
```bash
mkdir -p /Users/ekinertac/Code/emux/Sources/Features/Projects
```

Verify:
```bash
ls -d /Users/ekinertac/Code/emux/Sources/Features/Projects
```
Expected: directory exists.

- [ ] **Step 2: Create `Project.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/Project.swift` with these exact contents:

```swift
import Foundation

/// A single project the user has added to emux. A project is conceptually a
/// directory on disk that scopes a workspace (its own tabs, splits, editor
/// files in later phases). In Phase 2 the project is just an entry in the
/// sidebar — nothing else is scoped to it yet.
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: URL
    var sortOrder: Int
    var createdAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sortOrder: Int,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

    /// Convenience: build a project for a given on-disk folder, with the
    /// display name defaulting to the folder's last path component.
    static func fromFolder(_ url: URL, sortOrder: Int) -> Project {
        Project(
            name: url.lastPathComponent,
            path: url,
            sortOrder: sortOrder
        )
    }
}
```

- [ ] **Step 3: Verify the file compiles.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **` (Xcode 16's synchronized folder groups auto-include the new file).

If the build doesn't find `Project.swift`, the operator must open `emux.xcodeproj` and confirm the `Projects` folder appears under the `Features` group in the Project Navigator. If not, drag the folder in via Finder (the synchronized group should pick it up automatically; if not, use **File → Add Files to "emux"…**).

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/Project.swift && \
  git commit -m "feat(projects): add Project Codable model"
```

---

## Task 2: Create the AppState root persistence model

**Files:**
- Create: `Sources/Features/Projects/AppState.swift`

- [ ] **Step 1: Create `AppState.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/AppState.swift` with these exact contents:

```swift
import Foundation

/// The root persisted state for emux. Serialized to disk as
/// `~/Library/Application Support/emux/state.json`. Phase 2 contains only
/// project-list + global sidebar collapse state. Later phases extend this
/// with per-project tabs, splits, editor files, etc.
struct AppState: Codable {
    /// Migration anchor. Bump when an incompatible schema change is made
    /// and add a migration step in `StatePersistence.load(...)`.
    var schemaVersion: Int

    var projects: [Project]

    /// The project the user had selected at last quit. Populated in Phase 3
    /// when scoping arrives; nil in Phase 2 because selection is in-memory only.
    var lastActiveProjectId: UUID?

    /// Whether the sidebar was collapsed at last quit. Phase 2 uses a single
    /// global flag (not per-project); per-project collapse comes later.
    var sidebarCollapsed: Bool

    static let currentSchemaVersion = 1

    static let empty = AppState(
        schemaVersion: currentSchemaVersion,
        projects: [],
        lastActiveProjectId: nil,
        sidebarCollapsed: false
    )
}
```

- [ ] **Step 2: Verify the file compiles.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/AppState.swift && \
  git commit -m "feat(projects): add AppState persistence root"
```

---

## Task 3: Create the StatePersistence load/save layer

**Files:**
- Create: `Sources/Features/Projects/StatePersistence.swift`

This task implements:
- Resolving the storage directory (creates it if missing)
- Loading `state.json` (returns `.empty` if missing or corrupt, renaming corrupt files for postmortem)
- Atomic writes (`state.json.tmp` → rename to `state.json`)
- A debounced `scheduleSave(_:)` API so the model can call it on every mutation without overwhelming I/O

- [ ] **Step 1: Create `StatePersistence.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/StatePersistence.swift` with these exact contents:

```swift
import Foundation
import OSLog

/// Reads/writes `AppState` to `~/Library/Application Support/emux/state.json`.
/// Writes are debounced (250ms) and atomic (write-temp + rename) so a crash
/// never produces a partial file. On corruption, the bad file is preserved as
/// `state.json.corrupt-<timestamp>` and we proceed with `AppState.empty`.
final class StatePersistence {
    static let shared = StatePersistence()

    private let log = Logger(subsystem: "com.ekinertac.emux", category: "persistence")
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Single serial queue for all read/write work. Keeps file ops off the
    /// main thread and avoids tearing if two writes race.
    private let queue = DispatchQueue(label: "com.ekinertac.emux.persistence", qos: .utility)

    /// Debounce timer for `scheduleSave`. Replaced on every call so bursts
    /// of mutations collapse to a single fsync.
    private var pendingWorkItem: DispatchWorkItem?

    private init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Public API

    /// Synchronous load. Call this once on app launch. Returns `AppState.empty`
    /// if the file is missing or corrupt — never throws to the caller.
    func load() -> AppState {
        let url = stateFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            log.info("state.json missing, starting empty")
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AppState.self, from: data)
            log.info("loaded state.json with \(decoded.projects.count) projects")
            return decoded
        } catch {
            log.error("state.json corrupt: \(String(describing: error)). Renaming and starting empty.")
            handleCorruption(at: url)
            return .empty
        }
    }

    /// Debounced save. Call after every model mutation. Bursts within 250ms
    /// collapse to one write.
    func scheduleSave(_ state: AppState) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow(state)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    // MARK: - Internal

    private func writeNow(_ state: AppState) {
        let url = stateFileURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // rename(2) is atomic on the same volume
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
            log.debug("state.json written (\(state.projects.count) projects)")
        } catch {
            log.error("state.json write failed: \(String(describing: error))")
            // We swallow the error rather than crashing. Next save attempt will retry.
        }
    }

    private func handleCorruption(at url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("state.json.corrupt-\(stamp)")
        try? fileManager.moveItem(at: url, to: backup)
    }

    private func stateFileURL() -> URL {
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("emux", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
```

- [ ] **Step 2: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/StatePersistence.swift && \
  git commit -m "feat(projects): add StatePersistence with debounced atomic writes"
```

---

## Task 4: Create the ProjectsModel observable

**Files:**
- Create: `Sources/Features/Projects/ProjectsModel.swift`

`ProjectsModel` is the single source of truth for the project list at runtime. It loads from `StatePersistence` on init, publishes `@Published var projects`, exposes mutation methods (`add`/`rename`/`delete`/`reorder`), and forwards every mutation to `StatePersistence.scheduleSave`.

- [ ] **Step 1: Create `ProjectsModel.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/ProjectsModel.swift` with these exact contents:

```swift
import Foundation
import Combine
import OSLog

/// The runtime owner of the user's project list. Loaded once at app launch,
/// mutated via `add`/`rename`/`delete`/`reorder`. Every mutation triggers a
/// debounced disk save via `StatePersistence`.
@MainActor
final class ProjectsModel: ObservableObject {
    @Published private(set) var projects: [Project]

    /// In-memory only in Phase 2. Promoted to persisted state in Phase 3 when
    /// project switching actually scopes the window.
    @Published var selectedProjectId: UUID?

    /// Global sidebar collapse — persists across launches.
    @Published var sidebarCollapsed: Bool {
        didSet { scheduleSave() }
    }

    private let persistence: StatePersistence
    private let log = Logger(subsystem: "com.ekinertac.emux", category: "projects")

    init(persistence: StatePersistence = .shared) {
        self.persistence = persistence
        let state = persistence.load()
        self.projects = state.projects.sorted { $0.sortOrder < $1.sortOrder }
        self.selectedProjectId = state.lastActiveProjectId
        self.sidebarCollapsed = state.sidebarCollapsed
        log.info("ProjectsModel loaded with \(state.projects.count) projects")
    }

    // MARK: - Mutations

    /// Add a project for the given folder. Sort order is appended to the end.
    /// Idempotent if a project for the same path already exists — returns the
    /// existing project unchanged.
    @discardableResult
    func addProject(at url: URL) -> Project {
        if let existing = projects.first(where: { $0.path == url }) {
            log.debug("project already exists for \(url.path)")
            return existing
        }
        let nextSort = (projects.map(\.sortOrder).max() ?? -1) + 1
        let project = Project.fromFolder(url, sortOrder: nextSort)
        projects.append(project)
        scheduleSave()
        log.info("added project \(project.name) at \(project.path.path)")
        return project
    }

    /// Rename a project. No-op if id not found.
    func renameProject(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = trimmed
        scheduleSave()
    }

    /// Delete a project. The on-disk folder is NOT touched. No-op if id not found.
    func deleteProject(id: UUID) {
        projects.removeAll { $0.id == id }
        if selectedProjectId == id { selectedProjectId = nil }
        scheduleSave()
    }

    /// Reorder projects. `sourceIndices` is the IndexSet from SwiftUI's
    /// `.onMove`; `destination` is the SwiftUI destination index.
    func moveProjects(from sourceIndices: IndexSet, to destination: Int) {
        projects.move(fromOffsets: sourceIndices, toOffset: destination)
        // Renumber sortOrder so it stays monotonic
        for (i, _) in projects.enumerated() {
            projects[i].sortOrder = i
        }
        scheduleSave()
    }

    // MARK: - Persistence helpers

    /// Build a snapshot AppState for persistence. Called on every mutation.
    private func snapshot() -> AppState {
        AppState(
            schemaVersion: AppState.currentSchemaVersion,
            projects: projects,
            lastActiveProjectId: selectedProjectId,
            sidebarCollapsed: sidebarCollapsed
        )
    }

    private func scheduleSave() {
        persistence.scheduleSave(snapshot())
    }
}
```

- [ ] **Step 2: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectsModel.swift && \
  git commit -m "feat(projects): add ProjectsModel observable + mutations"
```

---

## Task 5: Wire ProjectsModel into AppDelegate

**Files:**
- Modify: `Sources/App/macOS/AppDelegate.swift`

We add a `projectsModel: ProjectsModel` property next to the existing `ghostty: Ghostty.App` so that every `TerminalController` window can reach it via `(NSApp.delegate as? AppDelegate)?.projectsModel`.

- [ ] **Step 1: Read the current declaration block.**

Run:
```bash
sed -n '95,105p' /Users/ekinertac/Code/emux/Sources/App/macOS/AppDelegate.swift
```
Expected: the `let ghostty: Ghostty.App` line (around line 98) is visible.

- [ ] **Step 2: Add the `projectsModel` property immediately after `let ghostty: Ghostty.App`.**

Use the Edit tool to insert a new property declaration right after the `ghostty` line. The exact change:

Replace this existing line:

```swift
    let ghostty: Ghostty.App
```

With:

```swift
    let ghostty: Ghostty.App

    /// The user's project list, persisted to ~/Library/Application Support/emux/state.json.
    /// Phase 2: sidebar is decorative. Phase 3 wires scoping.
    let projectsModel = ProjectsModel()
```

(If the line `let ghostty: Ghostty.App` appears multiple times — it shouldn't — pick the one in the property declarations block near the top of the class, not in a method body.)

- [ ] **Step 3: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

If you see `error: cannot find 'ProjectsModel' in scope`, the `Projects/` folder isn't being picked up by the synchronized group — open `emux.xcodeproj` and verify it appears under `Features/` in the Project Navigator.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/App/macOS/AppDelegate.swift && \
  git commit -m "feat(projects): own ProjectsModel singleton in AppDelegate"
```

---

## Task 6: Create ProjectRowView (single sidebar row)

**Files:**
- Create: `Sources/Features/Projects/ProjectRowView.swift`

A single row in the sidebar list: a folder icon, the project name (primary), the folder name as a subtitle (in a smaller secondary color), and a selection-highlight background when the row is selected.

- [ ] **Step 1: Create `ProjectRowView.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/ProjectRowView.swift` with these exact contents:

```swift
import SwiftUI

/// A single row in the projects sidebar list. Shows a folder icon, the
/// project's display name, and the directory's last-path-component as a
/// subtitle. Visual selection state is owned by the parent.
struct ProjectRowView: View {
    let project: Project
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 14))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(project.path.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 0) {
        ProjectRowView(
            project: Project(
                name: "self-healing-crawler",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler"),
                sortOrder: 0
            ),
            isSelected: true
        )
        ProjectRowView(
            project: Project(
                name: "gaffer",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer"),
                sortOrder: 1
            ),
            isSelected: false
        )
    }
    .padding()
    .frame(width: 220)
}
#endif
```

- [ ] **Step 2: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|\*\* BUILD)' | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectRowView.swift && \
  git commit -m "feat(projects): add ProjectRowView for sidebar entries"
```

---

## Task 7: Create ProjectsSidebarView (the sidebar)

**Files:**
- Create: `Sources/Features/Projects/ProjectsSidebarView.swift`

The sidebar pulls together: a "PROJECTS" header with a `+` button on the right, the list of projects (with selection + drag-reorder + context menu for rename/delete), an empty state when no projects exist, and a settings gear button anchored at the bottom. Folder selection uses `NSOpenPanel`. Rename uses a SwiftUI alert with an inline TextField. Delete uses an inline confirmation alert.

- [ ] **Step 1: Create `ProjectsSidebarView.swift`.**

Write file `/Users/ekinertac/Code/emux/Sources/Features/Projects/ProjectsSidebarView.swift` with these exact contents:

```swift
import SwiftUI
import AppKit

/// The left-column sidebar listing every project the user has added.
/// In Phase 2 selection is purely visual — Phase 3 wires the scoping.
struct ProjectsSidebarView: View {
    @ObservedObject var model: ProjectsModel

    @State private var renameTarget: Project?
    @State private var renameDraft: String = ""
    @State private var showRename: Bool = false

    @State private var deleteTarget: Project?
    @State private var showDelete: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 150, idealWidth: 200, maxWidth: 400)
        // Rename — modern .alert API supports an inline TextField inside `actions`.
        .alert(
            "Rename \(renameTarget?.name ?? "project")",
            isPresented: $showRename,
            presenting: renameTarget
        ) { project in
            TextField("Project name", text: $renameDraft)
            Button("Rename") {
                model.renameProject(id: project.id, to: renameDraft)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Enter a new display name. The folder on disk is not affected.")
        }
        // Delete — destructive confirmation.
        .alert(
            "Delete \(deleteTarget?.name ?? "project")?",
            isPresented: $showDelete,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
                model.deleteProject(id: project.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the project from emux. The folder on disk is not touched.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("PROJECTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Button {
                pickFolderAndAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Project…") { pickFolderAndAdd() }
                .controlSize(.small)
        }
        .padding(24)
    }

    private var projectList: some View {
        List(selection: $model.selectedProjectId) {
            ForEach(model.projects) { project in
                ProjectRowView(
                    project: project,
                    isSelected: model.selectedProjectId == project.id
                )
                .tag(project.id)
                .contextMenu {
                    Button("Rename…") {
                        renameTarget = project
                        renameDraft = project.name
                        showRename = true
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
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Settings")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Actions

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
    }

    /// Open the standard macOS Settings window via AppKit's responder chain.
    /// On macOS 14+ NSApplication responds to `showSettingsWindow:`; on macOS 13
    /// the legacy selector is `showPreferencesWindow:`. We send both — the one
    /// the responder chain doesn't recognize is silently ignored.
    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
```

- [ ] **Step 2: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD)' | head -20
```
Expected: `** BUILD SUCCEEDED **`. Any warnings about deprecated `Alert` usage in macOS 14+ are acceptable for Phase 2 — we use the older API to keep the file short. We can migrate to `.alert(... presenting:)` in a polish pass.

- [ ] **Step 3: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Projects/ProjectsSidebarView.swift && \
  git commit -m "feat(projects): add ProjectsSidebarView (list + folder picker + rename/delete)"
```

---

## Task 8: Wire the sidebar into TerminalController via NavigationSplitView

**Files:**
- Modify: `Sources/Features/Terminal/TerminalController.swift` (around line 1037-1040)

This is the integration point. Inside `TerminalController.windowDidLoad()`, the existing block:

```swift
// Initialize our content view to the SwiftUI root
let container = TerminalViewContainer {
    TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
}
```

…becomes a `NavigationSplitView`-wrapped version that puts the sidebar on the left.

- [ ] **Step 1: Re-read the relevant block to confirm exact text.**

Run:
```bash
sed -n '1037,1045p' /Users/ekinertac/Code/emux/Sources/Features/Terminal/TerminalController.swift
```
Expected: lines that look like:
```swift
        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }
```

(If the line numbers don't match, search for `let container = TerminalViewContainer` and use that block.)

- [ ] **Step 2: Replace the block with the NavigationSplitView wrapper.**

Use the Edit tool. Replace the exact text:

```swift
        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }
```

With:

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
```

(The `?? ProjectsModel()` fallback prevents a crash in the unlikely case the AppDelegate isn't yet wired — that branch should never execute in production, but it keeps the code total.)

- [ ] **Step 3: Verify build.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme Ghostty -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD|.*\.swift:[0-9]+:[0-9]+: error)' | head
```
Expected: `** BUILD SUCCEEDED **`.

If you see `error: cannot find 'NavigationSplitView' in scope`, the minimum deployment target is wrong. NavigationSplitView requires macOS 13.0+. Our project targets 14.6 so this should not happen.

- [ ] **Step 4: Commit.**

```bash
cd /Users/ekinertac/Code/emux && \
  git add Sources/Features/Terminal/TerminalController.swift && \
  git commit -m "feat(projects): wrap terminal view in NavigationSplitView with sidebar"
```

---

## Task 9: Launch and visual smoke check

**Files:** none modified.

- [ ] **Step 1: Launch the app.**

Run:
```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -1)
open "$APP_PATH"
```
Expected: emux launches; a window appears with a sidebar on the left and a terminal on the right.

- [ ] **Step 2: Visually verify the following — operator action.**

The OPERATOR (user) checks:

1. **Sidebar visible.** Left column shows "PROJECTS" header with a `+` button on the right of the header.
2. **Empty state.** Below the header: a folder-plus icon, "No projects yet" text, and an "Add Project…" button.
3. **Terminal still works.** The right column shows the existing terminal pane — you can type into it.
4. **Add Project flow.** Click `+` (or the "Add Project…" button). An NSOpenPanel appears asking to choose a folder. Pick any folder (e.g. `~/Code`). The sidebar updates: empty state disappears, a row appears with a folder icon, the folder name, and the path subtitle.
5. **Multiple projects.** Add 2–3 different folders. Each gets its own row. The latest-added is selected (highlight color on the row).
6. **Persistence.** Quit emux (`⌘Q`). Re-launch via `open "$APP_PATH"`. The same projects should reappear.
7. **Right-click context menu.** Right-click a project row. Menu shows "Rename…", "Reveal in Finder", and (after Divider) "Delete…". Try each:
   - Rename: opens a SwiftUI alert with an inline TextField. Edit the name, click Rename. The row updates. Quit + relaunch to confirm persistence.
   - Reveal in Finder: opens Finder with the project folder selected.
   - Delete: destructive confirmation alert. Confirming removes the project from the sidebar but not from disk.
8. **Settings gear.** Click the gear at the bottom-left of the sidebar. The existing Settings window opens (emux Settings, inherited from Ghostty).
9. **Drag-to-reorder.** Drag a project row up or down. The list reorders. Quit & relaunch — the new order persists.

- [ ] **Step 3: Confirm `state.json` exists and contains the projects.**

Run:
```bash
ls -la ~/Library/Application\ Support/emux/
cat ~/Library/Application\ Support/emux/state.json
```
Expected: `state.json` exists; contains a JSON object with `schemaVersion: 1`, a non-empty `projects` array (after operator added some), and `sidebarCollapsed`.

- [ ] **Step 4: Quit the app.**

```bash
osascript -e 'tell application id "com.ekinertac.emux.debug" to quit'
```

---

## Task 10: Push Phase 2 to origin

**Files:** none modified.

- [ ] **Step 1: Confirm clean working tree.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git status
```
Expected: `nothing to commit, working tree clean`. If there are uncommitted changes, complete the in-progress task's commit step before continuing.

- [ ] **Step 2: Push.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git push origin main
```
Expected: a push summary listing the new commits.

- [ ] **Step 3: Confirm remote state.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git log --oneline main origin/main | head -10
```
Expected: local `main` and `origin/main` are in sync.

---

## Phase 2 done — verification summary

Before declaring Phase 2 complete, all of these must be true:

- [ ] `xcodebuild` succeeds for Debug + Release configs
- [ ] App launches; sidebar appears on the left of every terminal window
- [ ] `+` button opens a folder picker that adds the chosen folder as a project
- [ ] Empty state shows when no projects exist
- [ ] Right-click row → Reveal in Finder works; Delete (with confirm) removes from sidebar
- [ ] Drag-to-reorder persists across launches
- [ ] Settings gear opens the existing Settings window
- [ ] `~/Library/Application Support/emux/state.json` exists with the expected contents after a save
- [ ] Quit + relaunch restores the project list and selection state
- [ ] All commits pushed to `origin/main` on `github.com/ekinertac/emux`

When all of the above pass, **pause for the user to review the visual feel of the sidebar before Phase 3 planning starts.** Per the project's development style, UI/UX iteration happens between phases.

## Known limitations (deliberate, deferred)

These are NOT bugs — they are scoped out of Phase 2 intentionally and will be addressed in later phases:

- **Selecting a project does nothing functional.** No tab scoping yet. Phase 3 wires it.
- **Sidebar collapse via toolbar button** is provided by SwiftUI's `NavigationSplitView` but its collapsed state is not yet wired to our `sidebarCollapsed` persisted flag. The model field is there for Phase 3+.
- **No `Cmd-0` "New project" keybinding yet.** Hooking the menubar / global keymap is its own task in a later phase.
- **No tests.** XCTest infrastructure for emux is in unknown shape (Phase 1 didn't copy the inherited `Tests/` directory). A dedicated test-infrastructure setup task lands when persistence regressions become a real risk — earliest Phase 3 (where state.json starts driving the visible window state).
