import Foundation

/// Snapshot of one window's persisted state — its own project list,
/// active project, sidebar collapse, UI scale, and window frame. One
/// entry per emux window on disk. Each window is fully independent:
/// projects added in window A do NOT appear in window B.
struct WindowSnapshot: Codable, Identifiable {
    var id: UUID
    var projects: [Project]
    var activeProjectId: UUID?
    var sidebarCollapsed: Bool
    var uiTypeSizeIndex: Int
    /// The window's last frame. Applied on next launch. Independent of
    /// which project is currently active in this window.
    var windowFrame: WindowFrame?

    static func empty(id: UUID = UUID()) -> WindowSnapshot {
        WindowSnapshot(
            id: id,
            projects: [],
            activeProjectId: nil,
            sidebarCollapsed: false,
            uiTypeSizeIndex: AppState.defaultUITypeSizeIndex,
            windowFrame: nil
        )
    }
}

/// The root persisted state for emux. Serialized to disk as
/// `~/Library/Application Support/emux/state.json`. Schema v3 is
/// multi-window: `windows` is the list of persisted windows in the
/// order they should be restored on next launch.
struct AppState: Codable {
    /// Migration anchor. Bump when an incompatible schema change is
    /// made and add a migration step below.
    var schemaVersion: Int

    /// One snapshot per persisted window. Order matters: it's the
    /// order windows are recreated on next launch.
    var windows: [WindowSnapshot]

    static let currentSchemaVersion = 3

    /// The default index — corresponds to `DynamicTypeSize.large`.
    static let defaultUITypeSizeIndex: Int = 3

    static let empty = AppState(
        schemaVersion: currentSchemaVersion,
        windows: []
    )

    /// Decoder handles migration from v2 (single flat AppState with
    /// `projects` at the root) to v3 (list of windows). v2 files are
    /// wrapped as a single-window v3 state so users don't lose their
    /// project list on schema bump.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: AnyCodingKey("schemaVersion"))

        if version >= 3 {
            self.schemaVersion = version
            self.windows = try c.decode([WindowSnapshot].self, forKey: AnyCodingKey("windows"))
            return
        }

        // v2 migration: root-level fields become the single window.
        let projects = try c.decode([Project].self, forKey: AnyCodingKey("projects"))
        let activeId = try c.decodeIfPresent(UUID.self, forKey: AnyCodingKey("lastActiveProjectId"))
        let collapsed = (try? c.decode(Bool.self, forKey: AnyCodingKey("sidebarCollapsed"))) ?? false
        let uiScale = (try? c.decode(Int.self, forKey: AnyCodingKey("uiTypeSizeIndex")))
            ?? Self.defaultUITypeSizeIndex
        let migratedFrame = projects.compactMap(\.windowFrame).first

        self.schemaVersion = Self.currentSchemaVersion
        self.windows = [
            WindowSnapshot(
                id: UUID(),
                projects: projects,
                activeProjectId: activeId,
                sidebarCollapsed: collapsed,
                uiTypeSizeIndex: uiScale,
                windowFrame: migratedFrame
            )
        ]
    }

    init(schemaVersion: Int, windows: [WindowSnapshot]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

/// String-keyed coding helper — lets AppState's custom decoder read
/// either the v3 shape or the v2 shape from the same container without
/// declaring two enums.
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}
