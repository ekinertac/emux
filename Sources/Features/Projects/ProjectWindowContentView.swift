// ProjectWindowContentView.swift
// emux — Sources/Features/Projects/
//
// The right-pane content for an emux project window. Composes a custom
// TabStripView on top with Ghostty's TerminalView below. This view is a
// thin observer: it reads model state from the window's BaseTerminalController
// and ProjectsModel, then routes user actions (tab select, close, new) back
// to both.
//
// Related files:
//   - TabStripView.swift         — the custom tab strip rendered at the top
//   - Tab.swift                  — Tab (persisted model) and TabState (live)
//   - BaseTerminalController.swift — owns tabs[], activeTabId, surfaceTree
//   - ProjectsModel.swift        — persists tab mutations to disk
//   - EmuxSplitController.swift  — wires this view into the window (Task 11)
//   - Sources/Features/Terminal/TerminalView.swift — inherited Ghostty view

import SwiftUI

/// The right-pane content for an emux project window. A custom tab strip sits
/// on top; the inherited Ghostty `TerminalView` (rendering the active tab's
/// `surfaceTree`) sits below. The window's `BaseTerminalController` owns the
/// tab list + the active id; this view is a thin observer that turns model
/// state into UI and routes user actions back to the controller and the
/// persisted `ProjectsModel`.
///
/// Generic constraint: `Controller` must be a `BaseTerminalController`
/// (which already conforms to `TerminalViewModel`) so that it can be passed
/// directly to `TerminalView<ViewModel: TerminalViewModel>`.
struct ProjectWindowContentView: View {
    @ObservedObject var ghostty: Ghostty.App
    // Observed so body re-runs when the window switches project or its
    // tab list changes. TerminalController (not just Base) so we can
    // read `projectId` — which lives on the macOS-specific subclass.
    @ObservedObject var controller: TerminalController

    // Optional — BaseTerminalController itself conforms to TerminalViewDelegate,
    // so callers can pass the controller directly or nil out if unused.
    weak var delegate: (any TerminalViewDelegate)?

    @ObservedObject var projectsModel: ProjectsModel

    var body: some View {
        VStack(spacing: 0) {
            // Layout cases (all per-window state):
            //   • No project selected → "Select a project" placeholder.
            //   • Project + no tabs   → tab strip + "No active terminal".
            //   • Project + tabs      → tab strip + terminal.
            if controller.projectId == nil {
                selectAProjectState
            } else if controller.tabs.isEmpty {
                tabStrip
                emptyTerminalState
            } else {
                tabStrip
                TerminalView(ghostty: ghostty, viewModel: controller, delegate: delegate)
            }
        }
    }

    private var tabStrip: some View {
        // The .dynamicTypeSize is scoped to the tab strip ONLY — the
        // terminal below uses its own font size system (⌘+/⌘-).
        TabStripView(
            tabs: controller.tabs.map(\.meta),
            activeTabId: controller.activeTabId,
            onSelect: { id in
                controller.activateTab(id)
                if let pid = controller.projectId {
                    projectsModel.switchTab(to: id, inProject: pid)
                }
            },
            onClose: { id in
                controller.closeTab(id)
                if let pid = controller.projectId {
                    let next = projectsModel.closeTab(id, inProject: pid)
                    if let next { controller.activateTab(next) }
                }
            },
            onNew: {
                guard let pid = controller.projectId,
                      let project = projectsModel.projects.first(where: { $0.id == pid })
                else { return }
                if let meta = projectsModel.addTab(toProject: pid, cwd: project.path) {
                    controller.addTab(meta: meta)
                }
            }
        )
        .dynamicTypeSize(UIScale.dynamicTypeSize(forIndex: projectsModel.uiTypeSizeIndex))
    }

    private var selectAProjectState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sidebar.left")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a project")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Pick a project from the sidebar, or press ⌘0 to add one.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var emptyTerminalState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No active terminal")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Press ⌘T to open a new terminal")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
