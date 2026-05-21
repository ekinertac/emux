import SwiftUI

/// The custom tab strip rendered at the top of the terminal pane. Replaces
/// macOS native NSWindow tabbing, which we disable globally (see
/// TerminalWindow.swift). The strip is bound to a Project's `tabs` and
/// `activeTabId`; callbacks for select/close/new are routed to the
/// AppDelegate's per-project TerminalController.
struct TabStripView: View {
    let tabs: [Tab]
    let activeTabId: UUID?

    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabCell(
                            title: tab.title,
                            isActive: tab.id == activeTabId,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) }
                        )
                    }
                }
            }

            // New-tab "+" button
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")

            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .background(Color.black)
    }
}

#if DEBUG
#Preview {
    TabStripView(
        tabs: [
            Tab(title: "self-healing-crawler", sortOrder: 0,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler")),
            Tab(title: "gaffer", sortOrder: 1,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer")),
            Tab(title: "picture-me", sortOrder: 2,
                cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/picture-me")),
        ],
        activeTabId: nil,
        onSelect: { _ in },
        onClose: { _ in },
        onNew: { }
    )
    .frame(width: 600)
}

#Preview("with active tab") {
    // A separate preview where the first tab is active. We rebuild the array
    // inline so the preview compiles without needing access to UUID literals.
    let t0 = Tab(title: "self-healing-crawler", sortOrder: 0,
                 cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler"))
    let t1 = Tab(title: "gaffer", sortOrder: 1,
                 cwd: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer"))
    return TabStripView(
        tabs: [t0, t1],
        activeTabId: t0.id,
        onSelect: { _ in },
        onClose: { _ in },
        onNew: { }
    )
    .frame(width: 600)
}
#endif
