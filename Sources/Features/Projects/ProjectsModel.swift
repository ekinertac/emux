// ProjectsModel — per-window shim over DaemonConnection.
//
// Daemon (emuxd) owns the authoritative state. This class:
//   • holds cached @Published copies of this window's state so SwiftUI
//     views observe changes with zero migration.
//   • routes every mutator through workspace.mutate JSON-RPC.
//   • subscribes to workspace.updated events for this windowId and
//     applies the fresh snapshot to the @Published fields (drives UI
//     updates for changes originated by OTHER clients / other app
//     windows attached to the same daemon).
//
// Sync-blocking on mutators for MVP — see DaemonConnection.request.
// Return values (addProject → Project, addTab → Tab?, closeTab → UUID?)
// are computed from the returned snapshot; see per-method comments.
//
// Ephemeral mode is gone — every window has a persisted windowId in
// the daemon. Callers that used `.ephemeral()` before now call
// `AppDelegate.workspace.create()` to get a fresh window.

import Foundation
import Combine
import OSLog

@MainActor
final class ProjectsModel: ObservableObject {
    @Published private(set) var projects: [Project]

    /// The project this window has last activated. Persisted daemon-side.
    @Published var selectedProjectId: UUID?

    @Published var sidebarCollapsed: Bool = false
    @Published var uiTypeSizeIndex: Int

    static let minUITypeSizeIndex = 0
    static let maxUITypeSizeIndex = 6

    /// This window's stable id in the daemon.
    let windowId: UUID

    /// Cached frame — used only to dedup rapid updateWindowFrame calls
    /// during live drag/resize. Authoritative value lives daemon-side.
    private var cachedWindowFrame: WindowFrame?

    /// nil = detached mode (used only by internal Ghostty paths like
    /// undo-restore and tab-split spawn — those controllers aren't
    /// bound to an emux window). Mutations become no-ops. All
    /// user-facing windows have a real daemon.
    private let daemon: DaemonConnection?
    private let log = Logger(subsystem: "com.ekinertac.emux", category: "projects")

    /// Init from a daemon-returned WindowSnapshot (workspace.create or
    /// workspace.snapshot response).
    init(daemon: DaemonConnection, snapshot: WindowSnapshot) {
        self.daemon = daemon
        self.windowId = snapshot.id
        self.projects = snapshot.projects.sorted { $0.sortOrder < $1.sortOrder }
        self.selectedProjectId = snapshot.activeProjectId
        self.sidebarCollapsed = snapshot.sidebarCollapsed
        self.uiTypeSizeIndex = snapshot.uiTypeSizeIndex
        self.cachedWindowFrame = snapshot.windowFrame

        // Subscribe to workspace.updated events for our window. Handler
        // runs on the daemon reader thread — hop to main.
        daemon.subscribe(event: "workspace.updated", forWindow: windowId) { [weak self] payload in
            guard let self,
                  let snapObj = payload["snapshot"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.applySnapshotFromPayload(snapObj)
            }
        }
    }

    /// Detached model — no daemon, mutations no-op. Used by internal
    /// Ghostty paths (undo, tab-split spawn) that need a ProjectsModel
    /// for the TerminalController init signature but aren't part of
    /// emux's workspace lifecycle.
    static func detached() -> ProjectsModel {
        return ProjectsModel(detachedStub: ())
    }

    private init(detachedStub: Void) {
        self.daemon = nil
        self.windowId = UUID()
        self.projects = []
        self.selectedProjectId = nil
        self.sidebarCollapsed = false
        self.uiTypeSizeIndex = 3
        self.cachedWindowFrame = nil
    }

    // MARK: - Deletion

    /// Called when the owning window closes. Removes this window's
    /// snapshot from persisted state so it doesn't come back on
    /// relaunch. During app termination the caller skips this so
    /// state IS preserved for restore.
    func deletePersistedSnapshot() {
        guard let daemon else { return }  // detached — nothing to delete
        let payload: [String: Any] = ["window_id": windowId.uuidString]
        do {
            _ = try daemon.request(method: "workspace.delete", params: payload)
        } catch {
            log.error("workspace.delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UI scale

    func incrementUIScale() {
        applyMutation(["type": "set_ui_scale_index", "index": min(Self.maxUITypeSizeIndex, uiTypeSizeIndex + 1)])
    }
    func decrementUIScale() {
        applyMutation(["type": "set_ui_scale_index", "index": max(Self.minUITypeSizeIndex, uiTypeSizeIndex - 1)])
    }
    func resetUIScale() {
        applyMutation(["type": "set_ui_scale_index", "index": 3])
    }

    // MARK: - Mutations

    /// Add a project. Returns the added project (or the pre-existing
    /// one if a project with the same path already exists — the daemon
    /// treats add_project idempotently on path).
    @discardableResult
    func addProject(at url: URL) -> Project {
        applyMutation(["type": "add_project", "path": url.absoluteString])
        // Post-mutation, find the project matching this path in our
        // freshly-updated `projects` list.
        if let match = projects.first(where: { $0.path == url }) { return match }
        // Fallback — shouldn't happen if daemon is behaving.
        return Project.fromFolder(url, sortOrder: projects.count)
    }

    func renameProject(id: UUID, to newName: String) {
        applyMutation([
            "type": "rename_project",
            "project_id": id.uuidString,
            "name": newName
        ])
    }

    func deleteProject(id: UUID) {
        applyMutation([
            "type": "delete_project",
            "project_id": id.uuidString
        ])
    }

    func moveProjects(from sourceIndices: IndexSet, to destination: Int) {
        applyMutation([
            "type": "reorder_projects",
            "from": Array(sourceIndices),
            "to": destination
        ])
    }

    // MARK: - Tab mutations

    /// Add a tab. Returns the new Tab (identified as the project's
    /// activeTabId after the mutation — daemon always makes the new
    /// tab active).
    @discardableResult
    func addTab(toProject projectId: UUID, cwd: URL? = nil) -> Tab? {
        var params: [String: Any] = [
            "type": "add_tab",
            "project_id": projectId.uuidString
        ]
        if let cwd { params["cwd"] = cwd.absoluteString }
        applyMutation(params)
        // Locate the new tab: it's the project's activeTabId after mutation.
        guard let project = projects.first(where: { $0.id == projectId }),
              let activeId = project.activeTabId,
              let tab = project.tabs.first(where: { $0.id == activeId }) else {
            return nil
        }
        return tab
    }

    /// Close a tab. Returns the id of the tab that should become active
    /// next (nil if project now has no tabs). Determined from the
    /// project's activeTabId after mutation.
    @discardableResult
    func closeTab(_ tabId: UUID, inProject projectId: UUID) -> UUID? {
        applyMutation([
            "type": "close_tab",
            "project_id": projectId.uuidString,
            "tab_id": tabId.uuidString
        ])
        return projects.first(where: { $0.id == projectId })?.activeTabId
    }

    func switchTab(to tabId: UUID, inProject projectId: UUID) {
        applyMutation([
            "type": "switch_tab",
            "project_id": projectId.uuidString,
            "tab_id": tabId.uuidString
        ])
    }

    func renameTab(_ tabId: UUID, to newTitle: String, inProject projectId: UUID) {
        applyMutation([
            "type": "rename_tab",
            "project_id": projectId.uuidString,
            "tab_id": tabId.uuidString,
            "title": newTitle
        ])
    }

    // MARK: - Window frame

    /// Dedupe rapid updateWindowFrame calls during drag/resize — same
    /// value → skip the RPC. Authoritative value still lives daemon-side.
    func updateWindowFrame(_ frame: WindowFrame) {
        guard cachedWindowFrame != frame else { return }
        cachedWindowFrame = frame
        applyMutation([
            "type": "set_window_frame",
            "frame": [
                "x": frame.x,
                "y": frame.y,
                "width": frame.width,
                "height": frame.height
            ]
        ])
    }

    var persistedWindowFrame: WindowFrame? { cachedWindowFrame }

    // MARK: - Active project

    func setActiveProject(_ projectId: UUID?) {
        var params: [String: Any] = ["type": "set_active_project"]
        if let projectId { params["project_id"] = projectId.uuidString }
        applyMutation(params)
    }

    // MARK: - Sidebar collapsed

    func setSidebarCollapsed(_ collapsed: Bool) {
        applyMutation(["type": "set_sidebar_collapsed", "collapsed": collapsed])
    }

    // MARK: - Wire helpers

    /// Issue a workspace.mutate to the daemon and apply the returned
    /// snapshot to our @Published fields. Errors are logged but not
    /// propagated — the previous ProjectsModel was fire-and-forget too.
    /// Detached mode: no-op (used by internal Ghostty paths).
    private func applyMutation(_ mutation: [String: Any]) {
        guard let daemon else {
            log.debug("mutation on detached model — skipping: \(mutation["type"] as? String ?? "?")")
            return
        }
        let params: [String: Any] = [
            "window_id": windowId.uuidString,
            "mutation": mutation
        ]
        do {
            let result = try daemon.request(method: "workspace.mutate", params: params)
            if let snapObj = result["snapshot"] as? [String: Any] {
                applySnapshotFromPayload(snapObj)
            }
        } catch {
            log.error("workspace.mutate(\(mutation["type"] as? String ?? "?")) failed: \(error.localizedDescription)")
        }
    }

    /// Decode a snapshot dict back into WindowSnapshot and apply its
    /// fields to our @Published state.
    private func applySnapshotFromPayload(_ payload: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(WindowSnapshot.self, from: data)
            self.projects = snapshot.projects.sorted { $0.sortOrder < $1.sortOrder }
            self.selectedProjectId = snapshot.activeProjectId
            self.sidebarCollapsed = snapshot.sidebarCollapsed
            self.uiTypeSizeIndex = snapshot.uiTypeSizeIndex
            self.cachedWindowFrame = snapshot.windowFrame
        } catch {
            log.error("snapshot decode failed: \(error.localizedDescription)")
        }
    }
}
