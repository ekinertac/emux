import SwiftUI

/// A single row in the projects sidebar list. Shows a folder icon, the
/// project's display name, and the directory's last-path-component as a
/// subtitle. Visual selection state is owned by the parent.
struct ProjectRowView: View {
    let project: Project
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 14))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
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
            isSelected: true
        )
        ProjectRowView(
            project: Project(
                name: "gaffer",
                path: URL(fileURLWithPath: "/Users/ekinertac/Code/gaffer"),
                sortOrder: 1
            ),
            isSelected: false
        )
    }
    .padding()
    .frame(width: 220)
}
#endif
