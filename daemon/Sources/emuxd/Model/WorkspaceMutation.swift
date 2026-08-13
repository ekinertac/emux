// WorkspaceMutation — tagged union of every mutation the daemon
// accepts on workspace.mutate. Matches docs/protocol.md §6.6.
//
// Serialized wire shape: {"type": "add_project", "path": "..."}. Decoded
// via a custom Decodable that dispatches on the "type" discriminator.
// Encoded via the mirror pattern.

import Foundation

enum WorkspaceMutation: Codable {
    case addProject(path: URL)
    case renameProject(projectId: UUID, name: String)
    case deleteProject(projectId: UUID)
    case reorderProjects(from: [Int], to: Int)
    case addTab(projectId: UUID, cwd: URL?)
    case closeTab(projectId: UUID, tabId: UUID)
    case switchTab(projectId: UUID, tabId: UUID)
    case renameTab(projectId: UUID, tabId: UUID, title: String)
    case setActiveProject(projectId: UUID?)
    case setSidebarCollapsed(collapsed: Bool)
    case setUIScaleIndex(index: Int)
    case setWindowFrame(frame: WindowFrame)

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case projectId = "project_id"
        case tabId = "tab_id"
        case name
        case title
        case cwd
        case from
        case to
        case collapsed
        case index
        case frame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "add_project":
            self = .addProject(path: try c.decode(URL.self, forKey: .path))
        case "rename_project":
            self = .renameProject(
                projectId: try c.decode(UUID.self, forKey: .projectId),
                name: try c.decode(String.self, forKey: .name))
        case "delete_project":
            self = .deleteProject(projectId: try c.decode(UUID.self, forKey: .projectId))
        case "reorder_projects":
            self = .reorderProjects(
                from: try c.decode([Int].self, forKey: .from),
                to: try c.decode(Int.self, forKey: .to))
        case "add_tab":
            self = .addTab(
                projectId: try c.decode(UUID.self, forKey: .projectId),
                cwd: try c.decodeIfPresent(URL.self, forKey: .cwd))
        case "close_tab":
            self = .closeTab(
                projectId: try c.decode(UUID.self, forKey: .projectId),
                tabId: try c.decode(UUID.self, forKey: .tabId))
        case "switch_tab":
            self = .switchTab(
                projectId: try c.decode(UUID.self, forKey: .projectId),
                tabId: try c.decode(UUID.self, forKey: .tabId))
        case "rename_tab":
            self = .renameTab(
                projectId: try c.decode(UUID.self, forKey: .projectId),
                tabId: try c.decode(UUID.self, forKey: .tabId),
                title: try c.decode(String.self, forKey: .title))
        case "set_active_project":
            self = .setActiveProject(projectId: try c.decodeIfPresent(UUID.self, forKey: .projectId))
        case "set_sidebar_collapsed":
            self = .setSidebarCollapsed(collapsed: try c.decode(Bool.self, forKey: .collapsed))
        case "set_ui_scale_index":
            self = .setUIScaleIndex(index: try c.decode(Int.self, forKey: .index))
        case "set_window_frame":
            self = .setWindowFrame(frame: try c.decode(WindowFrame.self, forKey: .frame))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown mutation type '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addProject(let path):
            try c.encode("add_project", forKey: .type)
            try c.encode(path, forKey: .path)
        case .renameProject(let projectId, let name):
            try c.encode("rename_project", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(name, forKey: .name)
        case .deleteProject(let projectId):
            try c.encode("delete_project", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
        case .reorderProjects(let from, let to):
            try c.encode("reorder_projects", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .addTab(let projectId, let cwd):
            try c.encode("add_tab", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encodeIfPresent(cwd, forKey: .cwd)
        case .closeTab(let projectId, let tabId):
            try c.encode("close_tab", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(tabId, forKey: .tabId)
        case .switchTab(let projectId, let tabId):
            try c.encode("switch_tab", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(tabId, forKey: .tabId)
        case .renameTab(let projectId, let tabId, let title):
            try c.encode("rename_tab", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(tabId, forKey: .tabId)
            try c.encode(title, forKey: .title)
        case .setActiveProject(let projectId):
            try c.encode("set_active_project", forKey: .type)
            try c.encodeIfPresent(projectId, forKey: .projectId)
        case .setSidebarCollapsed(let collapsed):
            try c.encode("set_sidebar_collapsed", forKey: .type)
            try c.encode(collapsed, forKey: .collapsed)
        case .setUIScaleIndex(let index):
            try c.encode("set_ui_scale_index", forKey: .type)
            try c.encode(index, forKey: .index)
        case .setWindowFrame(let frame):
            try c.encode("set_window_frame", forKey: .type)
            try c.encode(frame, forKey: .frame)
        }
    }
}
