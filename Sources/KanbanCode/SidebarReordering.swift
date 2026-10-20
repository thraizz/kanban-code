import SwiftUI

/// Sidebar-only drag items. Keep these separate from kanban card drags so
/// reordering a pin cannot accidentally move or merge its underlying card.
enum SidebarReorderItem: Equatable {
    case pinnedCard(String)

    var id: String {
        switch self {
        case .pinnedCard(let id): id
        }
    }

    var payload: String {
        switch self {
        case .pinnedCard(let id): "sidebar-pinned-card:\(id)"
        }
    }

    func hasSameKind(as other: SidebarReorderItem) -> Bool {
        switch (self, other) {
        case (.pinnedCard, .pinnedCard): true
        }
    }
}

@Observable
final class SidebarReorderState {
    var draggingItem: SidebarReorderItem?
}

struct SidebarReorderableRow<Content: View>: View {
    let item: SidebarReorderItem
    let reorderState: SidebarReorderState
    let onMove: (String, String?, Bool) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false
    @State private var insertAbove = true
    @State private var rowHeight: CGFloat = 0

    var body: some View {
        content()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in
                            rowHeight = height
                        }
                }
            }
            .opacity(reorderState.draggingItem == item ? 0.55 : 1)
            .overlay {
                VStack(spacing: 0) {
                    if isTargeted, insertAbove { SidebarReorderIndicator() }
                    Spacer(minLength: 0)
                    if isTargeted, !insertAbove { SidebarReorderIndicator() }
                }
            }
            .onDrag {
                reorderState.draggingItem = item
                return NSItemProvider(object: item.payload as NSString)
            }
            .onDrop(
                of: [.utf8PlainText],
                delegate: SidebarReorderDropDelegate(
                    targetItem: item,
                    targetHeight: rowHeight,
                    reorderState: reorderState,
                    isTargeted: $isTargeted,
                    insertAbove: $insertAbove,
                    onMove: onMove
                )
            )
    }
}

struct SidebarReorderEndTarget: View {
    let kind: SidebarReorderItem
    let reorderState: SidebarReorderState
    let onMove: (String, String?, Bool) -> Void

    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .frame(height: 8)
            .overlay(alignment: .bottom) {
                if isTargeted { SidebarReorderIndicator() }
            }
            .onDrop(
                of: [.utf8PlainText],
                delegate: SidebarReorderDropDelegate(
                    targetItem: nil,
                    acceptedKind: kind,
                    targetHeight: 0,
                    reorderState: reorderState,
                    isTargeted: $isTargeted,
                    insertAbove: .constant(false),
                    onMove: onMove
                )
            )
    }
}

private struct SidebarReorderIndicator: View {
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
    }
}

private struct SidebarReorderDropDelegate: DropDelegate {
    let targetItem: SidebarReorderItem?
    var acceptedKind: SidebarReorderItem?
    let targetHeight: CGFloat
    let reorderState: SidebarReorderState
    @Binding var isTargeted: Bool
    @Binding var insertAbove: Bool
    let onMove: (String, String?, Bool) -> Void

    init(
        targetItem: SidebarReorderItem?,
        acceptedKind: SidebarReorderItem? = nil,
        targetHeight: CGFloat,
        reorderState: SidebarReorderState,
        isTargeted: Binding<Bool>,
        insertAbove: Binding<Bool>,
        onMove: @escaping (String, String?, Bool) -> Void
    ) {
        self.targetItem = targetItem
        self.acceptedKind = acceptedKind
        self.targetHeight = targetHeight
        self.reorderState = reorderState
        self._isTargeted = isTargeted
        self._insertAbove = insertAbove
        self.onMove = onMove
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let source = reorderState.draggingItem else { return false }
        guard let comparison = targetItem ?? acceptedKind,
              source.hasSameKind(as: comparison)
        else { return false }
        return source != targetItem
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        updateTarget(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            isTargeted = false
            reorderState.draggingItem = nil
        }
        guard validateDrop(info: info), let source = reorderState.draggingItem else {
            return false
        }
        onMove(source.id, targetItem?.id, targetItem == nil ? false : insertAbove)
        return true
    }

    private func updateTarget(info: DropInfo) {
        guard validateDrop(info: info) else {
            isTargeted = false
            return
        }
        isTargeted = true
        if targetItem != nil {
            insertAbove = info.location.y < targetHeight / 2
        }
    }
}
