// Project — daemon-side copy of Sources/Features/Projects/Project.swift.
// See Tab.swift for the sync/duplication policy.

import Foundation
import CoreGraphics

/// Codable snapshot of a window frame (CGRect isn't Codable). Legacy
/// per-project field from schema v2; new writes never set it, but the
/// v2→v3 migration in AppState reads it to seed WindowSnapshot.windowFrame.
struct WindowFrame: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: URL
    var sortOrder: Int
    var createdAt: Date
    var lastOpenedAt: Date
    var tabs: [Tab]
    var activeTabId: UUID?
    /// Legacy v2 field. New writes never set this; kept optional for
    /// v2→v3 migration only.
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

    static func fromFolder(_ url: URL, sortOrder: Int) -> Project {
        Project(name: url.lastPathComponent, path: url, sortOrder: sortOrder)
    }
}
