// WorkspaceStore — daemon-side owner of the workspace/tab/pane tree.
// The app's old ProjectsModel-per-window became this single store with
// windowId-keyed WindowSnapshots. Mutations happen via apply(mutation:
// toWindow:) which mirrors the WorkspaceMutation cases.
//
// Concurrency: single NSLock guards windowsById + order. All mutations
// are serial through the lock. Reads snapshot the state under lock and
// return copies (structs, so cheap).
//
// Change notifications: onWindowChanged fires after any successful
// mutation, delete, or create. ControlServer wires this to
// workspace.updated event broadcasts.

import Foundation
import GhosttyKit

final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private let lock = NSLock()
    private var windowsById: [UUID: WindowSnapshot] = [:]
    /// Persisted restore order for next launch.
    private var order: [UUID] = []

    /// Fires when a window's snapshot changes (mutation or create). Not
    /// called for delete — see onWindowDeleted.
    var onWindowChanged: ((WindowSnapshot) -> Void)?
    /// Fires when a window is deleted. Handlers use the id to notify
    /// clients / clean up per-window state.
    var onWindowDeleted: ((UUID) -> Void)?

    private init() {}

    // MARK: - Loading

    /// Hydrate from persisted state. Call once at daemon startup, before
    /// serving any client requests. Panics if called twice.
    func loadFromDisk() {
        let snapshots = Persistence.shared.load()
        lock.lock()
        precondition(windowsById.isEmpty, "WorkspaceStore already loaded")
        for w in snapshots { windowsById[w.id] = w }
        order = snapshots.map(\.id)
        lock.unlock()
        Log.info("workspace", "loaded \(snapshots.count) windows from disk")
    }

    // MARK: - Reads

    func listOrdered() -> [WindowSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { windowsById[$0] }
    }

    func snapshot(windowId: UUID) -> WindowSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return windowsById[windowId]
    }

    // MARK: - Lifecycle

    func createWindow() -> WindowSnapshot {
        let snap = WindowSnapshot.empty()
        lock.lock()
        windowsById[snap.id] = snap
        order.append(snap.id)
        lock.unlock()
        onWindowChanged?(snap)
        schedulePersist()
        Log.info("workspace", "created window \(snap.id.uuidString.prefix(8))")
        return snap
    }

    func deleteWindow(_ id: UUID) -> Bool {
        lock.lock()
        let existed = windowsById.removeValue(forKey: id) != nil
        if existed { order.removeAll { $0 == id } }
        lock.unlock()
        if existed {
            onWindowDeleted?(id)
            schedulePersist()
            Log.info("workspace", "deleted window \(id.uuidString.prefix(8))")
        }
        return existed
    }

    // MARK: - Mutations

    enum MutationError: Error {
        case windowNotFound(UUID)
        case projectNotFound(UUID)
        case tabNotFound(UUID)
        case invalidReorder(String)
    }

    /// Apply a mutation. Returns the resulting WindowSnapshot on
    /// success. Throws on missing window/project/tab. Fires
    /// onWindowChanged before returning.
    ///
    /// Deadlock trap history: applyMutation can throw
    /// (projectNotFound, tabNotFound, invalidReorder). The original
    /// version unlocked manually after applyMutation, which meant a
    /// throw exited without unlocking, leaked the lock, and hung the
    /// whole daemon on the next request. Now we use defer so the
    /// unlock runs on every exit path. The onWindowChanged callback
    /// and schedulePersist call must NOT be inside the locked
    /// region (broadcast → sendEvent → write can block on a slow
    /// client, and we don't want to hold the store lock while
    /// waiting on socket buffers), so we capture the snapshot before
    /// unlocking and fire the callbacks after.
    func apply(_ mutation: WorkspaceMutation, toWindow windowId: UUID) throws -> WindowSnapshot {
        let updatedSnapshot: WindowSnapshot = try {
            lock.lock()
            defer { lock.unlock() }
            guard var snap = windowsById[windowId] else {
                throw MutationError.windowNotFound(windowId)
            }
            try Self.applyMutation(mutation, to: &snap)
            windowsById[windowId] = snap
            return snap
        }()
        onWindowChanged?(updatedSnapshot)
        schedulePersist()
        return updatedSnapshot
    }

    /// Pure function that mutates a snapshot in place. Split from
    /// apply() so it's unit-testable without needing a live store.
    static func applyMutation(_ mutation: WorkspaceMutation, to snap: inout WindowSnapshot) throws {
        switch mutation {
        case .addProject(let path):
            // Idempotent on path — herdr's rule and ours: same folder
            // added twice = one entry.
            if snap.projects.first(where: { $0.path == path }) != nil {
                return
            }
            let sortOrder = (snap.projects.map(\.sortOrder).max() ?? -1) + 1
            snap.projects.append(Project.fromFolder(path, sortOrder: sortOrder))

        case .renameProject(let projectId, let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let idx = snap.projects.firstIndex(where: { $0.id == projectId }) else {
                throw MutationError.projectNotFound(projectId)
            }
            snap.projects[idx].name = trimmed

        case .deleteProject(let projectId):
            snap.projects.removeAll { $0.id == projectId }
            if snap.activeProjectId == projectId { snap.activeProjectId = nil }

        case .reorderProjects(let from, let to):
            // Array.move(fromOffsets:toOffset:) is a SwiftUI/AppKit
            // extension not available in Foundation-only builds. Do
            // the reorder manually: pull the source elements, then
            // insert at the destination offset.
            let source = IndexSet(from)
            guard source.min().flatMap({ $0 >= 0 }) ?? true,
                  source.max().flatMap({ $0 < snap.projects.count }) ?? true,
                  to >= 0, to <= snap.projects.count else {
                throw MutationError.invalidReorder("indices out of bounds for \(snap.projects.count) projects")
            }
            var items = snap.projects
            let picked = source.map { items[$0] }
            // Remove from highest index to lowest so indices stay valid.
            for idx in source.reversed() { items.remove(at: idx) }
            // Adjust destination for any picks that came before it.
            let indicesBeforeDest = source.filter { $0 < to }.count
            let insertAt = max(0, min(items.count, to - indicesBeforeDest))
            items.insert(contentsOf: picked, at: insertAt)
            snap.projects = items
            for (i, _) in snap.projects.enumerated() {
                snap.projects[i].sortOrder = i
            }

        case .addTab(let projectId, let cwd):
            guard let pIdx = snap.projects.firstIndex(where: { $0.id == projectId }) else {
                throw MutationError.projectNotFound(projectId)
            }
            let effectiveCwd = cwd ?? snap.projects[pIdx].path
            let sortOrder = (snap.projects[pIdx].tabs.map(\.sortOrder).max() ?? -1) + 1
            let tab = Tab(title: effectiveCwd.lastPathComponent,
                          sortOrder: sortOrder,
                          cwd: effectiveCwd)
            snap.projects[pIdx].tabs.append(tab)
            snap.projects[pIdx].activeTabId = tab.id

        case .closeTab(let projectId, let tabId):
            guard let pIdx = snap.projects.firstIndex(where: { $0.id == projectId }) else {
                throw MutationError.projectNotFound(projectId)
            }
            guard let tIdx = snap.projects[pIdx].tabs.firstIndex(where: { $0.id == tabId }) else {
                throw MutationError.tabNotFound(tabId)
            }
            snap.projects[pIdx].tabs.remove(at: tIdx)
            let nextActive: UUID?
            if snap.projects[pIdx].tabs.isEmpty {
                nextActive = nil
            } else if tIdx < snap.projects[pIdx].tabs.count {
                nextActive = snap.projects[pIdx].tabs[tIdx].id
            } else {
                nextActive = snap.projects[pIdx].tabs.last?.id
            }
            if snap.projects[pIdx].activeTabId == tabId {
                snap.projects[pIdx].activeTabId = nextActive
            }
            for (i, _) in snap.projects[pIdx].tabs.enumerated() {
                snap.projects[pIdx].tabs[i].sortOrder = i
            }

        case .switchTab(let projectId, let tabId):
            guard let pIdx = snap.projects.firstIndex(where: { $0.id == projectId }) else {
                throw MutationError.projectNotFound(projectId)
            }
            guard snap.projects[pIdx].tabs.contains(where: { $0.id == tabId }) else {
                throw MutationError.tabNotFound(tabId)
            }
            snap.projects[pIdx].activeTabId = tabId

        case .renameTab(let projectId, let tabId, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let pIdx = snap.projects.firstIndex(where: { $0.id == projectId }) else {
                throw MutationError.projectNotFound(projectId)
            }
            guard let tIdx = snap.projects[pIdx].tabs.firstIndex(where: { $0.id == tabId }) else {
                throw MutationError.tabNotFound(tabId)
            }
            snap.projects[pIdx].tabs[tIdx].title = trimmed

        case .setActiveProject(let projectId):
            snap.activeProjectId = projectId
            if let id = projectId,
               let idx = snap.projects.firstIndex(where: { $0.id == id }) {
                snap.projects[idx].lastOpenedAt = Date()
            }

        case .setSidebarCollapsed(let collapsed):
            snap.sidebarCollapsed = collapsed

        case .setUIScaleIndex(let index):
            // Clamp to [0, 6] (xSmall..xxxLarge).
            snap.uiTypeSizeIndex = max(0, min(6, index))

        case .setWindowFrame(let frame):
            snap.windowFrame = frame
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        Persistence.shared.scheduleSave { [weak self] in
            guard let self else { return AppState.empty }
            return AppState(
                schemaVersion: AppState.currentSchemaVersion,
                windows: self.listOrdered()
            )
        }
    }

    // MARK: - Counts (for daemon.status)

    var windowCount: Int {
        lock.lock(); defer { lock.unlock() }
        return windowsById.count
    }

    var paneCount: Int {
        panesLock.lock(); defer { panesLock.unlock() }
        return panesById.count
    }

    // MARK: - Live panes (Task 6c)
    //
    // Runtime PTY state, separate from persisted WindowSnapshot data.
    // Panes are created via pane.spawn and destroyed via pane.close
    // (or the shell exiting, which fires close_surface_cb — Task 6c
    // followup wires that to fire pane.exit + remove from this map).
    //
    // Separate lock from the workspaces-snapshot lock: shell exit
    // events fire on libghostty's callback thread and shouldn't have
    // to wait behind a snapshot mutation, and vice versa.

    private let panesLock = NSLock()
    private var panesById: [UUID: PTYRuntime] = [:]
    /// Reverse index: ghostty_surface_t pointer → paneId. Registered
    /// at PTYRuntime.spawn, deregistered at PTYRuntime.close. Used by
    /// GhosttyRuntime.action to route surface-scoped actions (RENDER,
    /// TITLE_CHANGED, BELL) to the right pane without scanning every
    /// runtime. Pointer-keyed via `Int(bitPattern:)` because
    /// UnsafeMutableRawPointer isn't Hashable in Swift.
    private var paneIdBySurface: [Int: UUID] = [:]

    /// Register a surface → pane binding. Called by PTYRuntime.spawn
    /// after ghostty_surface_new returns.
    func registerSurface(_ surface: ghostty_surface_t, paneId: UUID) {
        panesLock.lock()
        paneIdBySurface[Int(bitPattern: surface)] = paneId
        panesLock.unlock()
    }

    /// Deregister. Called by PTYRuntime.close before ghostty_surface_free.
    func deregisterSurface(_ surface: ghostty_surface_t) {
        panesLock.lock()
        paneIdBySurface.removeValue(forKey: Int(bitPattern: surface))
        panesLock.unlock()
    }

    /// Look up paneId by surface pointer. Called from libghostty
    /// callback threads.
    func paneId(forSurface surface: ghostty_surface_t) -> UUID? {
        panesLock.lock(); defer { panesLock.unlock() }
        return paneIdBySurface[Int(bitPattern: surface)]
    }

    /// Spawn a new PTY runtime bound to a window+tab. Returns the
    /// paneId; the underlying ghostty_surface_t is alive until
    /// closePane() runs or the shell exits. Must be called on the
    /// main thread — PTYRuntime.spawn has a runtime precondition
    /// checking this (libghostty surface init requires main).
    func spawnPane(windowId: UUID, tabId: UUID, cwd: URL) throws -> UUID {
        let paneId = UUID()
        let pty = PTYRuntime(paneId: paneId, windowId: windowId, tabId: tabId)
        try pty.spawn(cwd: cwd)
        panesLock.lock()
        panesById[paneId] = pty
        panesLock.unlock()
        return paneId
    }

    /// Send input bytes to a pane. Returns false if the pane doesn't
    /// exist (already closed, wrong id, etc).
    @discardableResult
    func writePane(_ paneId: UUID, bytes: Data) -> Bool {
        panesLock.lock()
        let pty = panesById[paneId]
        panesLock.unlock()
        guard let pty else { return false }
        pty.sendInput(bytes)
        return true
    }

    /// Resize a pane's grid. Returns false if pane not found. Must
    /// be called on main (libghostty requirement).
    @discardableResult
    func resizePane(_ paneId: UUID, cols: UInt16, rows: UInt16) -> Bool {
        panesLock.lock()
        let pty = panesById[paneId]
        panesLock.unlock()
        guard let pty else { return false }
        pty.resize(cols: cols, rows: rows)
        return true
    }

    /// Read the current viewport of a pane as text. Empty string if
    /// pane not found.
    func readPane(_ paneId: UUID) -> String {
        panesLock.lock()
        let pty = panesById[paneId]
        panesLock.unlock()
        return pty?.readScreen() ?? ""
    }

    /// Close a pane's PTY. Returns true if it existed.
    @discardableResult
    func closePane(_ paneId: UUID) -> Bool {
        panesLock.lock()
        let pty = panesById.removeValue(forKey: paneId)
        panesLock.unlock()
        guard let pty else { return false }
        pty.close()
        return true
    }

    /// Get a pane's metadata for pane.spawn responses.
    func paneInfo(_ paneId: UUID) -> (windowId: UUID, tabId: UUID, cols: UInt16, rows: UInt16)? {
        panesLock.lock()
        let pty = panesById[paneId]
        panesLock.unlock()
        guard let pty else { return nil }
        return (pty.windowId, pty.tabId, pty.cols, pty.rows)
    }
}
