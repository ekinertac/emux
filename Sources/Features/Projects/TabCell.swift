import SwiftUI

/// One cell in the custom tab strip. Renders the tab title and an optional
/// close button that appears on hover. Visual states:
///   • Active   — dark-gray background, near-white text, no border
///   • Inactive — black background, dimmed text, subtle hairline divider
///   • Hover    — close button (×) becomes visible
struct TabCell: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.55))
                    .lineLimit(1)

                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                } else {
                    // Reserve the same horizontal space so the title doesn't jitter
                    Color.clear.frame(width: 13, height: 13)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color(red: 0.18, green: 0.18, blue: 0.18) : Color.black)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 1) {
        TabCell(title: "self-healing-crawler", isActive: true,  onSelect: {}, onClose: {})
        TabCell(title: "gaffer",                isActive: false, onSelect: {}, onClose: {})
        TabCell(title: "picture-me",            isActive: false, onSelect: {}, onClose: {})
    }
    .padding()
    .background(Color.black)
    .frame(width: 600)
}
#endif
