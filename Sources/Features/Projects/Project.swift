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
