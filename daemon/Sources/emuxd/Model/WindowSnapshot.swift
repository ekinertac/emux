// WindowSnapshot + AppState — daemon-side copies of Sources/Features/
// Projects/AppState.swift. See Tab.swift for the duplication policy.
//
// Schema v3 (multi-window): AppState is { schemaVersion, windows: [WindowSnapshot] }.
// The v2 → v3 migration wraps the old flat state as a single-window entry.

import Foundation

struct WindowSnapshot: Codable, Identifiable {
    var id: UUID
    var projects: [Project]
    var activeProjectId: UUID?
    var sidebarCollapsed: Bool
    var uiTypeSizeIndex: Int
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

struct AppState: Codable {
    var schemaVersion: Int
    var windows: [WindowSnapshot]

    static let currentSchemaVersion = 3
    static let defaultUITypeSizeIndex: Int = 3

    static let empty = AppState(schemaVersion: currentSchemaVersion, windows: [])

    /// Decoder handles migration from v2 (flat AppState with `projects` at
    /// root) to v3 (list of windows). Wraps v2 as a single-window entry
    /// so the user doesn't lose their project list on schema bump.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: AnyCodingKey("schemaVersion"))

        if version >= 3 {
            self.schemaVersion = version
            self.windows = try c.decode([WindowSnapshot].self, forKey: AnyCodingKey("windows"))
            return
        }

        // v2 migration.
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

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}
