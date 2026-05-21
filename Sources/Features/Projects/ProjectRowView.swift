import SwiftUI

/// A single row in the projects sidebar list. Shows a folder icon, the
/// project's display name, and the directory's last-path-component as a
/// subtitle. Selection and edit state are owned by the parent — the row
/// renders an inline TextField when `isEditing` is true.
struct ProjectRowView: View {
    let project: Project
    let isSelected: Bool
    let isEditing: Bool
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 14))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium))
                        .focused($fieldFocused)
                        .onSubmit { onCommitRename(draftName) }
                        .onExitCommand { onCancelRename() }
                        .onAppear {
                            draftName = project.name
                            // Defer focus by one runloop so SwiftUI has
                            // finished laying out the field before we ask
                            // for the focus ring.
                            DispatchQueue.main.async { fieldFocused = true }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(project.path.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 0) {
        ProjectRowView(
            project: Project(
                name: "self-healing-crawler",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/self-healing-crawler"),
                sortOrder: 0
            ),
            isSelected: true,
            isEditing: false,
            onCommitRename: { _ in },
            onCancelRename: { }
        )
        ProjectRowView(
            project: Project(
                name: "gaffer",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer"),
                sortOrder: 1
            ),
            isSelected: false,
            isEditing: false,
            onCommitRename: { _ in },
            onCancelRename: { }
        )
        ProjectRowView(
            project: Project(
                name: "editing-me",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/editing-me"),
                sortOrder: 2
            ),
            isSelected: false,
            isEditing: true,
            onCommitRename: { _ in },
            onCancelRename: { }
        )
    }
    .padding()
    .frame(width: 220)
}
#endif
