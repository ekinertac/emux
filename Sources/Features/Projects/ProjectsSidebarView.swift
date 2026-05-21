import SwiftUI
import AppKit

/// The left-column sidebar listing every project the user has added.
/// In Phase 2 selection is purely visual — Phase 3 wires the scoping.
struct ProjectsSidebarView: View {
    @ObservedObject var model: ProjectsModel

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
        // Delete — destructive confirmation. (Rename is inline on the row itself.)
        .alert(
            "Delete \(deleteTarget?.name ?? "project")?",
            isPresented: $showDelete,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
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
        List(selection: $model.selectedProjectId) {
            ForEach(model.projects) { project in
                ProjectRowView(
                    project: project,
                    isSelected: model.selectedProjectId == project.id,
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
        .onChange(of: model.selectedProjectId) { _, newId in
            guard let id = newId,
                  let project = model.projects.first(where: { $0.id == id }),
                  let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.activateProject(project)
        }
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
        model.selectedProjectId = added.id
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.activateProject(added)
        }
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
