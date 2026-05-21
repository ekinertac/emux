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
