import SwiftUI

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let action: () -> Void

    init(id: String? = nil, _ title: String, icon: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.id = id ?? "cmd:\(title)"
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.action = action
    }
}
