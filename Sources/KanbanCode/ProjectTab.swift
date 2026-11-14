import SwiftUI

/// One tab in the project tab bar above the board: the project's name and
/// how many cards it holds, after a dot in the project's color. The selected
/// tab sits on glass tinted with that color.
struct ProjectTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    /// Shown while Cmd is held, as a reminder of the tab's Cmd+number.
    var shortcutNumber: Int? = nil
    var tint: Color? = nil
    var help: String = ""
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let shortcutNumber {
                    Text("⌘\(shortcutNumber)")
                        .font(.app(.caption).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background((tint ?? .secondary).opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                        .transition(.opacity)
                } else if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.app(.callout).weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.app(.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if !isSelected && isHovered {
                    Capsule().fill((tint ?? .primary).opacity(0.08))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: Capsule())
        .animation(.easeOut(duration: 0.12), value: shortcutNumber)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var glass: Glass {
        guard isSelected else { return .identity }
        guard let tint else { return .regular }
        return .regular.tint(tint.opacity(0.35))
    }
}
