import Foundation
import Combine
import OSLog

/// The runtime owner of ONE window's project list. Multi-window model:
/// each TerminalController owns its own ProjectsModel; there is no
/// global model. Each model has a stable `windowId` that keys its
/// snapshot inside the shared state.json (via StatePersistence).
///
/// Every mutation calls `scheduleSave()` which rebuilds this window's
/// `WindowSnapshot` and pushes it to StatePersistence. The persistence
/// layer holds all windows' snapshots in-memory and debounces writes.
///
/// Ephemeral mode (persistence=nil) is used by internal undo/restore
/// paths that need a working model without touching disk.
@MainActor
final class ProjectsModel: ObservableObject {
    @Published private(set) var projects: [Project]

    /// The project this window has last activated. Persisted so the
    /// window opens on that project after quit+relaunch.
    @Published var selectedProjectId: UUID?

    @Published var sidebarCollapsed: Bool {
        didSet { scheduleSave() }
    }

    /// Index into emux's UI-scale presets (clamped to
    /// `[minUITypeSizeIndex, maxUITypeSizeIndex]`). Drives the SwiftUI
    /// `dynamicTypeSize` applied to the sidebar + tab strip. Terminal
    /// font size is independent and stays under `⌘+ / ⌘-`.
    @Published var uiTypeSizeIndex: Int {
        didSet { scheduleSave() }
    }

    static let minUITypeSizeIndex = 0  // .xSmall
    static let maxUITypeSizeIndex = 6  // .xxxLarge

    /// This model's window id — key into StatePersistence's snapshot map.
    let windowId: UUID

    /// Last-known frame for this window. Held here so it can be
    /// snapshotted; TerminalController writes into it on
    /// windowDidResize/windowDidMove.
    private var windowFrame: WindowFrame?

    /// nil = ephemeral (no disk writes). Set = persisted model, saves
    /// via this StatePersistence instance.
    private let persistence: StatePersistence?
    private let log = Logger(subsystem: "com.ekinertac.emux", category: "projects")

    /// Persisted model. If `snapshot` is nil, this is a brand-new
    /// window that hasn't been saved yet — starts empty. If given,
    /// hydrates from that snapshot (restore-on-launch flow).
    init(persistence: StatePersistence = .shared, snapshot: WindowSnapshot? = nil) {
        self.persistence = persistence
        if let s = snapshot {
            self.windowId = s.id
            self.projects = s.projects.sorted { $0.sortOrder < $1.sortOrder }
            self.selectedProjectId = s.activeProjectId
            self.sidebarCollapsed = s.sidebarCollapsed
            self.uiTypeSizeIndex = s.uiTypeSizeIndex
            self.windowFrame = s.windowFrame
            log.info("ProjectsModel restored window \(s.id.uuidString.prefix(8)) with \(s.projects.count) projects")
        } else {
            self.windowId = UUID()
            self.projects = []
            self.selectedProjectId = nil
            self.sidebarCollapsed = false
            self.uiTypeSizeIndex = AppState.defaultUITypeSizeIndex
            self.windowFrame = nil
            log.info("ProjectsModel new window \(self.windowId.uuidString.prefix(8))")
        }
    }

    /// Ephemeral (in-memory only) model — no disk load, no disk save.
    /// Used by undo/restore paths in TerminalController that need a
    /// working ProjectsModel but shouldn't leak into persisted state.
    static func ephemeral() -> ProjectsModel {
        return ProjectsModel(ephemeralWindowId: UUID())
    }

    private init(ephemeralWindowId id: UUID) {
        self.persistence = nil
        self.windowId = id
        self.projects = []
        self.selectedProjectId = nil
        self.sidebarCollapsed = false
        self.uiTypeSizeIndex = AppState.defaultUITypeSizeIndex
        self.windowFrame = nil
    }

    /// Called when the owning window closes and the model's snapshot
    /// should be removed from persisted state. No-op for ephemeral.
    func deletePersistedSnapshot() {
        persistence?.removeWindow(id: windowId)
    }

    // MARK: - UI scale

    func incrementUIScale() {
        uiTypeSizeIndex = min(Self.maxUITypeSizeIndex, uiTypeSizeIndex + 1)
    }

    func decrementUIScale() {
        uiTypeSizeIndex = max(Self.minUITypeSizeIndex, uiTypeSizeIndex - 1)
    }

    func resetUIScale() {
        uiTypeSizeIndex = AppState.defaultUITypeSizeIndex
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

    /// Persist this WINDOW's frame. Called by AppDelegate on
    /// windowDidResize/windowDidMove. Dedupes to avoid write storms
    /// during live drag.
    func updateWindowFrame(_ frame: WindowFrame) {
        guard windowFrame != frame else { return }
        windowFrame = frame
        scheduleSave()
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

    /// Update the record of which project this window is showing. The
    /// window's controller.projectId is the real source of truth for
    /// runtime; this call keeps the persisted snapshot in sync so
    /// restart opens the right project.
    func setActiveProject(_ projectId: UUID?) {
        selectedProjectId = projectId
        if let id = projectId, let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].lastOpenedAt = Date()
        }
        scheduleSave()
    }

    /// The persisted frame from the last session, applied by
    /// AppDelegate when the window is first shown on restore. nil for
    /// fresh windows.
    var persistedWindowFrame: WindowFrame? { windowFrame }

    // MARK: - Persistence helpers

    /// Build a snapshot of this window's current state.
    private func snapshot() -> WindowSnapshot {
        WindowSnapshot(
            id: windowId,
            projects: projects,
            activeProjectId: selectedProjectId,
            sidebarCollapsed: sidebarCollapsed,
            uiTypeSizeIndex: uiTypeSizeIndex,
            windowFrame: windowFrame
        )
    }

    private func scheduleSave() {
        persistence?.updateWindow(snapshot())
    }
}
