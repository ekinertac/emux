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
struct ProjectWindowContentView<Controller>: View
where Controller: BaseTerminalController {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: Controller

    // Optional — BaseTerminalController itself conforms to TerminalViewDelegate,
    // so callers can pass the controller directly or nil out if unused.
    weak var delegate: (any TerminalViewDelegate)?

    /// The project this window is bound to. Required to call ProjectsModel
    /// mutators with the correct projectId.
    let projectId: UUID
    @ObservedObject var projectsModel: ProjectsModel

    var body: some View {
        VStack(spacing: 0) {
            // TabStripView expects [Tab] (the persisted model), not [TabState].
            // We project controller.tabs (which is [TabState]) down to [Tab]
            // via the `meta` property on each TabState.
            //
            // The .dynamicTypeSize is scoped to the tab strip ONLY — the
            // terminal below uses its own font size system (⌘+/⌘-).
            TabStripView(
                tabs: controller.tabs.map(\.meta),
                activeTabId: controller.activeTabId,
                onSelect: { id in
                    controller.activateTab(id)
                    projectsModel.switchTab(to: id, inProject: projectId)
                },
                onClose: { id in
                    controller.closeTab(id)
                    let next = projectsModel.closeTab(id, inProject: projectId)
                    if let next { controller.activateTab(next) }
                },
                onNew: {
                    // If this controller is bound to a project, persist via
                    // ProjectsModel. Otherwise (scratch window from ⌘N) add a
                    // transient tab spawned at $HOME.
                    if let project = projectsModel.projects.first(where: { $0.id == projectId }) {
                        if let meta = projectsModel.addTab(toProject: projectId, cwd: project.path) {
                            controller.addTab(meta: meta)
                        }
                    } else {
                        let cwd = URL(fileURLWithPath: NSHomeDirectory())
                        let meta = Tab(title: cwd.lastPathComponent,
                                       sortOrder: controller.tabs.count,
                                       cwd: cwd)
                        controller.addTab(meta: meta)
                    }
                }
            )
            .dynamicTypeSize(UIScale.dynamicTypeSize(forIndex: projectsModel.uiTypeSizeIndex))

            // TerminalView renders controller.surfaceTree (the active tab's
            // split tree). The controller itself is the viewModel because
            // BaseTerminalController conforms to TerminalViewModel.
            TerminalView(ghostty: ghostty, viewModel: controller, delegate: delegate)
        }
    }
}
