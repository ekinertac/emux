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
