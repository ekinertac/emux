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

    /// Index into SwiftUI's `DynamicTypeSize` cases used to scale the emux
    /// chrome (sidebar + tab strip + any future UI). The terminal's own font
    /// size is independent and stays under `⌘+ / ⌘-`. Range maps to:
    ///   0 = .xSmall, 1 = .small, 2 = .medium, 3 = .large (default),
    ///   4 = .xLarge, 5 = .xxLarge, 6 = .xxxLarge
    /// We avoid the accessibility sizes for keyboard-nav simplicity.
    var uiTypeSizeIndex: Int

    static let currentSchemaVersion = 2

    /// The default index — corresponds to `DynamicTypeSize.large`.
    static let defaultUITypeSizeIndex: Int = 3

    static let empty = AppState(
        schemaVersion: currentSchemaVersion,
        projects: [],
        lastActiveProjectId: nil,
        sidebarCollapsed: false,
        uiTypeSizeIndex: defaultUITypeSizeIndex
    )

    // Backward-compatible decoder: existing state.json files predate
    // `uiTypeSizeIndex` and would otherwise fail decoding. We default the
    // missing key to `defaultUITypeSizeIndex` so older files load cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.projects = try c.decode([Project].self, forKey: .projects)
        self.lastActiveProjectId = try c.decodeIfPresent(UUID.self, forKey: .lastActiveProjectId)
        self.sidebarCollapsed = try c.decode(Bool.self, forKey: .sidebarCollapsed)
        self.uiTypeSizeIndex = (try? c.decode(Int.self, forKey: .uiTypeSizeIndex))
            ?? Self.defaultUITypeSizeIndex
    }

    // Memberwise init is no longer synthesized because of the custom Decodable
    // initializer, so we provide it explicitly.
    init(
        schemaVersion: Int,
        projects: [Project],
        lastActiveProjectId: UUID?,
        sidebarCollapsed: Bool,
        uiTypeSizeIndex: Int
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.lastActiveProjectId = lastActiveProjectId
        self.sidebarCollapsed = sidebarCollapsed
        self.uiTypeSizeIndex = uiTypeSizeIndex
    }
}
