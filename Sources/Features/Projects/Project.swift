import Foundation
import CoreGraphics

/// Codable snapshot of an NSWindow frame. CGRect isn't Codable by default;
/// this wraps the four values we need. Stored as bottom-left origin +
/// size, matching AppKit's `NSWindow.frame` coordinate system.
struct WindowFrame: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A single project the user has added to emux. A project is conceptually a
/// directory on disk that scopes a workspace — its own tabs (and, in later
/// phases, editor files and a file tree).
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: URL
    var sortOrder: Int
    var createdAt: Date
    var lastOpenedAt: Date

    /// The tabs that belong to this project. Empty for a fresh project until
    /// the user opens its window — on first activation a default tab is added.
    var tabs: [Tab]

    /// The tab currently active in this project's window. nil if no tabs.
    var activeTabId: UUID?

    /// Legacy per-project frame from schema v2 — kept as an optional
    /// decodable so the v2→v3 migration in AppState can pull it out
    /// into WindowSnapshot.windowFrame. New writes never set this;
    /// window frames live on WindowSnapshot now.
    var windowFrame: WindowFrame?

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sortOrder: Int,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        tabs: [Tab] = [],
        activeTabId: UUID? = nil,
        windowFrame: WindowFrame? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.windowFrame = windowFrame
    }

    /// Convenience: build a project for a given on-disk folder, with the
    /// display name defaulting to the folder's last path component. Starts
    /// with no tabs — they're added on first window activation.
    static func fromFolder(_ url: URL, sortOrder: Int) -> Project {
        Project(name: url.lastPathComponent, path: url, sortOrder: sortOrder)
    }
}
