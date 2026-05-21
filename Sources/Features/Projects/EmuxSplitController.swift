import AppKit
import SwiftUI

/// The window-level layout host for an emux project window. Holds the
/// projects sidebar (left, collapsible) and the terminal content (right,
/// non-collapsible). Persists the user-dragged sidebar width to UserDefaults.
final class EmuxSplitController: NSSplitViewController {
    private static let sidebarWidthKey = "emux.sidebar.width"
    private static let defaultSidebarWidth: CGFloat = 200

    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem

    /// - Parameters:
    ///   - sidebar: the SwiftUI sidebar view (typically ProjectsSidebarView).
    ///   - content: the NSView that hosts tabs + the active terminal.
    init<Sidebar: View>(sidebar: Sidebar, content: NSView) {
        let sidebarHost = NSHostingController(rootView: sidebar)
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        self.sidebarItem.minimumThickness = 150
        self.sidebarItem.maximumThickness = 400
        self.sidebarItem.canCollapse = true

        let contentVC = NSViewController()
        contentVC.view = content
        self.contentItem = NSSplitViewItem(viewController: contentVC)
        self.contentItem.canCollapse = false
        self.contentItem.holdingPriority = .defaultLow  // sidebar wins fights, content grows

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        // Restore persisted sidebar width
        let stored = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        let width = stored > 0 ? CGFloat(stored) : Self.defaultSidebarWidth
        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(width, ofDividerAt: 0)
        }
    }

    /// NSSplitViewDelegate hook — called any time the user drags the divider.
    /// We persist the sidebar's resulting width.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let width = Double(sidebarItem.viewController.view.frame.width)
        // Only persist values within our min/max — avoids saving spurious
        // values during window resize storms.
        guard width >= 150, width <= 400 else { return }
        UserDefaults.standard.set(width, forKey: Self.sidebarWidthKey)
    }
}
