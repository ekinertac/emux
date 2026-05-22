import SwiftUI

/// Maps emux's persisted `uiTypeSizeIndex` to SwiftUI's `DynamicTypeSize`,
/// which proportionally scales text and SF Symbol icons under any view that
/// applies `.dynamicTypeSize(_:)`. Used by the sidebar and tab strip; any
/// future chrome (file tree, editor tabs, etc.) should adopt the same modifier.
///
/// We intentionally skip the accessibility tiers (`.accessibility1`...) — those
/// require explicit layout work to look right, and emux's chrome would feel
/// awkward at those sizes. Range mirrors `ProjectsModel.min/maxUITypeSizeIndex`.
enum UIScale {
    static func dynamicTypeSize(forIndex index: Int) -> DynamicTypeSize {
        switch index {
        case 0: return .xSmall
        case 1: return .small
        case 2: return .medium
        case 3: return .large       // default
        case 4: return .xLarge
        case 5: return .xxLarge
        case 6: return .xxxLarge
        default: return .large
        }
    }
}
