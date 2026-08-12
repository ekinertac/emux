import SwiftUI
import AppKit

/// The left-column sidebar listing every project the user has added.
///
/// Each window owns an independent instance of this view. Selection state
/// (which row is highlighted) is per-window and reflects the owning
/// `TerminalController`'s `projectId`, not any global "active project".
/// Clicking a row calls `onSelectProject` — the consumer decides how to
/// interpret that (typically: switch this window's project).
///
/// The "+" button (and its ⌘0 equivalent) adds a project to the global
/// model and immediately switches THIS window to it. Adding never affects
/// any other window.
struct ProjectsSidebarView: View {
    @ObservedObject var model: ProjectsModel

    /// The controller that owns this sidebar. Observed so selection
    /// highlighting tracks the window's current project. Weak-like via
    /// SwiftUI's observation lifecycle — the sidebar dies with the
    /// window's contentViewController.
    @ObservedObject var controller: TerminalController

    /// Called when the user picks a project row. Consumer switches the
    /// window's `projectId` and rebuilds tabs.
    var onSelectProject: (Project) -> Void

    /// The id of the project currently in inline-rename mode. nil means no row
    /// is being edited.
    @State private var editingProjectId: UUID?

    @State private var deleteTarget: Project?
    @State private var showDelete: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 150, idealWidth: 200, maxWidth: 400)
        // emux: scale sidebar chrome proportionally via the model's UI-scale.
        // ⌘⇧+ / ⌘⇧- / ⌘⇧0 adjust the underlying index.
        .dynamicTypeSize(UIScale.dynamicTypeSize(forIndex: model.uiTypeSizeIndex))
        // Delete — destructive confirmation. (Rename is inline on the row itself.)
        .alert(
            "Delete \(deleteTarget?.name ?? "project")?",
            isPresented: $showDelete,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
                // Per-window model: this projectId only exists in this
                // window. If this window is currently showing the
                // project being deleted, clear the binding so the
                // content pane falls back to "Select a project" instead
                // of silently pointing at a removed row.
                if controller.projectId == project.id {
                    controller.projectId = nil
                }
                model.deleteProject(id: project.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the project from emux. The folder on disk is not touched.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("PROJECTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Button {
                pickFolderAndAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Project…") { pickFolderAndAdd() }
                .controlSize(.small)
        }
        .padding(24)
    }

    private var projectList: some View {
        // Selection is a computed binding backed by the controller's
        // projectId: reading returns THIS window's current project,
        // writing dispatches through onSelectProject (which switches
        // just this window). SwiftUI's List selection semantics require
        // Binding<Set<UUID>> for tag-based selection.
        let selection = Binding<UUID?>(
            get: { controller.projectId },
            set: { newId in
                guard let newId,
                      let project = model.projects.first(where: { $0.id == newId })
                else { return }
                onSelectProject(project)
            }
        )
        return List(selection: selection) {
            ForEach(model.projects) { project in
                ProjectRowView(
                    project: project,
                    isSelected: controller.projectId == project.id,
                    isEditing: editingProjectId == project.id,
                    onCommitRename: { newName in
                        model.renameProject(id: project.id, to: newName)
                        editingProjectId = nil
                    },
                    onCancelRename: {
                        editingProjectId = nil
                    }
                )
                .tag(project.id)
                .contextMenu {
                    Button("Rename") {
                        editingProjectId = project.id
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.path])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        deleteTarget = project
                        showDelete = true
                    }
                }
            }
            .onMove { source, destination in
                model.moveProjects(from: source, to: destination)
            }
        }
        .listStyle(.sidebar)
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Settings")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func pickFolderAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add as an emux project"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = model.addProject(at: url)
        // Adding via this sidebar's "+" always switches THIS window to
        // the new project. Other windows are unaffected.
        onSelectProject(added)
    }

    /// Open the standard macOS Settings window via AppKit's responder chain.
    /// On macOS 14+ NSApplication responds to `showSettingsWindow:`; on macOS 13
    /// the legacy selector is `showPreferencesWindow:`. We send both — the one
    /// the responder chain doesn't recognize is silently ignored.
    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
