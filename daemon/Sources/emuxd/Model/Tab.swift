// Tab — persisted tab within a project. Daemon-side copy of the app's
// Sources/Features/Projects/Tab.swift; kept in sync manually. When drift
// becomes annoying we'll extract into a shared SPM package both targets
// link. For now the type is small and both sides serialize the same
// wire shape via JSON.

import Foundation

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
