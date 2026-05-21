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
