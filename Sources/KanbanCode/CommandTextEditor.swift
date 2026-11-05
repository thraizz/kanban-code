import SwiftUI

/// Compact command editor for launch dialogs.
///
/// Return confirms the dialog. Command+Return inserts a newline in the command.
/// Escape runs `onEscape`, because the text view takes the key before the
/// responder chain reaches the dialog buttons.
struct CommandTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = CommandNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandNSTextView else { return }
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandTextEditor

        init(_ parent: CommandTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class CommandNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && modifiers == .command {
            insertNewlineIgnoringFieldEditor(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && modifiers.isEmpty {
            onSubmit?()
            return
        }
        if isReturn && modifiers == .command {
            insertNewlineIgnoringFieldEditor(self)
            return
        }
        // Tab and Shift+Tab move focus; Option+Tab types a literal tab.
        if event.keyCode == 48 && !modifiers.contains(.option) {
            if modifiers.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        super.keyDown(with: event)
    }
}
