import AppKit
import MarkdownUI
import SwiftUI

/// A read-only text view that renders a whole chat row as one selectable run.
///
/// SwiftUI selection is per `Text`, so a message split into per-block views can
/// only ever be selected one block at a time. A single text view lets a drag
/// run from the first heading to the last paragraph, through tables and code,
/// with the formatting intact.
struct SelectableMarkdownText: NSViewRepresentable {
    let content: ChatTextContent
    var appearance: ChatTextAppearance
    var highlight: ChatTextHighlight?
    var links = ChatTextLinks()
    /// Caps the drawn text at this many lines, ellipsis and all.
    var lineLimit: Int?
    /// Called with the height the text needs, when the frame it was laid out in
    /// cannot hold it. A text view does not clip, so the overflow is drawn
    /// straight over whatever is below it.
    var onHeightOverflow: ((CGFloat) -> Void)?

    @Environment(\.chatSelectionCoordinator) private var coordinator

    func makeNSView(context: Context) -> WrappingTextView {
        WrappingTextView.make()
    }

    func updateNSView(_ nsView: WrappingTextView, context: Context) {
        nsView.coordinator = self.coordinator
        nsView.onHeightOverflow = self.onHeightOverflow
        nsView.configure(
            content: self.content, appearance: self.appearance, highlight: self.highlight,
            links: self.links, lineLimit: self.lineLimit)
    }

    /// Measures without rendering. Replacing the text storage here, in the
    /// middle of a layout pass, invalidates the layout that is asking.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: WrappingTextView, context: Context
    ) -> CGSize? {
        nsView.update(
            content: self.content, appearance: self.appearance, highlight: self.highlight,
            links: self.links, lineLimit: self.lineLimit)
        return nsView.fittingSize(for: proposal)
    }

    static func dismantleNSView(_ nsView: WrappingTextView, coordinator: ()) {
        nsView.coordinator?.unregister(nsView)
        nsView.coordinator = nil
    }

    /// Renders and measures itself, rebuilding whenever its width changes.
    ///
    /// The text depends on the width, because table columns are sized from
    /// their content against the space available. Building it once from the
    /// representable would freeze the layout at whatever width the view had
    /// before SwiftUI proposed one, which is none.
    final class WrappingTextView: NSTextView {
        static func make() -> WrappingTextView {
            // An explicit TextKit 1 stack. NSTextTable and NSTextAttachmentCell
            // are laid out by NSLayoutManager and by nothing in TextKit 2, and
            // a plain NSTextView(frame:) gives TextKit 2, where tables flatten.
            let storage = NSTextStorage()
            let layoutManager = MarkdownLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            // The container's width is set from the width the text was built
            // for, never from the frame. Tracking the view would let AppKit
            // re-wrap behind the renderer's back, at a width nothing measured.
            container.widthTracksTextView = false
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)

            let textView = WrappingTextView(frame: CGRect.zero, textContainer: container)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.allowsUndo = false
            textView.isRichText = true
            textView.textContainerInset = CGSize.zero
            textView.isHorizontallyResizable = false
            // SwiftUI owns the frame. A resizable text view sizes itself to its
            // text whenever the storage changes, which overrides the frame
            // SwiftUI just placed and asks for another layout pass.
            textView.isVerticallyResizable = false
            textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            return textView
        }

        private var content: ChatTextContent = .plain("")
        private var textAppearance = ChatTextAppearance(
            font: .systemFont(ofSize: NSFont.systemFontSize), foregroundColor: .labelColor)
        private var highlight: ChatTextHighlight?
        private var links = ChatTextLinks()
        private var lineLimit: Int?
        private var renderedWidth: CGFloat = 0

        /// Per-width memos for this view's own text. Stack layout negotiates a
        /// row's width by probing it at many candidate widths, and the probes
        /// multiply through nested stacks: answering each one through the
        /// global caches means hashing the whole message per call, which a
        /// long feed turns into a multi-minute layout pass. A view holds one
        /// message, so keying by width alone makes a repeat probe a plain
        /// dictionary hit.
        private var attributedByWidth: [CGFloat: NSAttributedString] = [:]
        private var sizeByWidth: [CGFloat: CGSize] = [:]
        /// A live width drag can visit many widths; past this the older
        /// entries are worthless, so the memo starts over.
        private static let widthMemoLimit = 12

        func configure(
            content: ChatTextContent,
            appearance: ChatTextAppearance,
            highlight: ChatTextHighlight?,
            links: ChatTextLinks = ChatTextLinks(),
            lineLimit: Int? = nil
        ) {
            self.update(
                content: content, appearance: appearance, highlight: highlight, links: links,
                lineLimit: lineLimit)
            self.render(width: self.bounds.width)
        }

        /// Takes the new inputs without touching the text storage, so a sizing
        /// probe can measure them.
        func update(
            content: ChatTextContent,
            appearance: ChatTextAppearance,
            highlight: ChatTextHighlight?,
            links: ChatTextLinks = ChatTextLinks(),
            lineLimit: Int? = nil
        ) {
            let changed =
                content != self.content || appearance != self.textAppearance
                || highlight != self.highlight || links != self.links
                || lineLimit != self.lineLimit
            self.content = content
            self.textAppearance = appearance
            self.highlight = highlight
            self.links = links
            self.lineLimit = lineLimit
            if changed {
                self.renderedWidth = 0
                self.reportedOverflow = nil
                self.attributedByWidth.removeAll(keepingCapacity: true)
                self.sizeByWidth.removeAll(keepingCapacity: true)
            }
            self.textContainer?.maximumNumberOfLines = lineLimit ?? 0
            self.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        }

        /// The width a row is measured at when no width is proposed.
        static let idealWidth: CGFloat = 700

        func fittingSize(for proposal: ProposedViewSize) -> CGSize {
            self.fittingSize(forWidth: Self.resolveWidth(proposal))
        }

        /// SwiftUI probes a representable with zero, unspecified and infinite
        /// widths to learn how flexible it is. Answering nil sends it to the
        /// text view's own fitting size, which follows whatever was last
        /// rendered: a stale narrow answer becomes a narrow frame, and a table
        /// laid out one character per column over the message below it.
        ///
        /// The answer must depend on the proposal alone. SwiftUI caches sizes,
        /// and an answer that follows the last width probed changes the ideal
        /// size of everything above the row on every pass. A hosting view turns
        /// its ideal size into constraints, so each pass asks for another one,
        /// until AppKit gives up on the window and throws.
        private static func resolveWidth(_ proposal: ProposedViewSize) -> CGFloat {
            if let proposed = proposal.width, proposed > 1, proposed.isFinite {
                return proposed
            }
            return Self.idealWidth
        }

        /// Nothing here has a size of its own: every answer comes from
        /// measuring the text against a width.
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        /// A pure measurement: it must never touch the live text view. This is
        /// the answer to a sizing probe, and stack layout probes a row many
        /// times per pass at widths it will not use — rendering here re-lays
        /// the text out per probe and turns one pass into minutes. The view
        /// itself is rendered from `setFrameSize`, at the width that won.
        func fittingSize(forWidth width: CGFloat) -> CGSize {
            let width = width.rounded()
            if let cached = self.sizeByWidth[width] { return cached }
            let attributed = self.attributedText(width: width)
            let size = ChatTextMeasurement.size(
                of: attributed, width: width, lineLimit: self.lineLimit)
            // Report the text's own width, not the whole proposal. A short row
            // that claims the full width cannot be centred by its container,
            // which is how system notices are laid out, and it stretches a user
            // bubble across the whole column.
            let fitting = self.content.shrinksToFit
                ? CGSize(width: min(width, size.width), height: size.height)
                : CGSize(width: width, height: size.height)
            if self.sizeByWidth.count >= Self.widthMemoLimit {
                self.sizeByWidth.removeAll(keepingCapacity: true)
            }
            self.sizeByWidth[width] = fitting
            return fitting
        }

        private func attributedText(width: CGFloat) -> NSAttributedString {
            let width = width.rounded()
            if let cached = self.attributedByWidth[width] { return cached }
            let built = ChatAttributedText.make(
                content: self.content, appearance: self.textAppearance,
                highlight: self.highlight, links: self.links, width: width
            )
            if self.attributedByWidth.count >= Self.widthMemoLimit {
                self.attributedByWidth.removeAll(keepingCapacity: true)
            }
            self.attributedByWidth[width] = built
            return built
        }

        private func render(width: CGFloat) {
            let width = width.rounded()
            guard width > 1, abs(width - self.renderedWidth) > 0.5 else { return }
            self.renderedWidth = width
            self.textContainer?.size = CGSize(
                width: width, height: CGFloat.greatestFiniteMagnitude)

            let attributed = self.attributedText(width: width)
            guard self.textStorage?.isEqual(to: attributed) != true else { return }

            // Chat polling re-renders live messages, so a drag in progress has
            // to survive the swap rather than being dropped mid selection.
            let selection = self.selectedRanges
            self.textStorage?.setAttributedString(attributed)
            let length = self.textStorage?.length ?? 0
            if selection.allSatisfy({ NSMaxRange($0.rangeValue) <= length }) {
                self.selectedRanges = selection
            }
        }

        var onHeightOverflow: ((CGFloat) -> Void)?
        private var reportedOverflow: CGFloat?

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            self.render(width: newSize.width)
            self.reportOverflow(inHeight: newSize.height)
        }

        /// Says so when the text no longer fits the frame it was given.
        ///
        /// The height a row gets comes from `sizeThatFits`, and that measures
        /// correctly. What it cannot do is notice a frame that was decided
        /// before the text grew, which is what expanding a truncated message
        /// does to a row that is already on screen. Nothing clips the result:
        /// the rest of the message is drawn over the next one.
        private func reportOverflow(inHeight height: CGFloat) {
            guard self.onHeightOverflow != nil, self.renderedWidth > 1 else { return }
            let needed = self.fittingSize(forWidth: self.renderedWidth).height
            guard needed > height + 0.5, needed != self.reportedOverflow else { return }
            // Off this layout pass, since the answer is a state change that
            // decides the next one, and checked again once it has finished. A
            // row is resized in steps while its text is laid out, and a step on
            // the way to the right height is not a row drawing over anything.
            DispatchQueue.main.async { [weak self] in
                guard let self, let onHeightOverflow = self.onHeightOverflow,
                    self.frame.height + 0.5 < needed, needed != self.reportedOverflow
                else { return }
                self.reportedOverflow = needed
                onHeightOverflow(needed)
            }
        }

        /// Scrolling belongs to the surrounding chat scroll view.
        override func scrollWheel(with event: NSEvent) {
            self.nextResponder?.scrollWheel(with: event)
        }

        // MARK: - Cross message selection

        var coordinator: ChatSelectionCoordinator? {
            didSet {
                guard oldValue !== self.coordinator else { return }
                oldValue?.unregister(self)
                if self.window != nil { self.coordinator?.register(self) }
            }
        }

        /// The part of a cross message selection this view is painting.
        private(set) var carriedSelectionRange: NSRange?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if self.window == nil {
                self.coordinator?.unregister(self)
            } else {
                self.coordinator?.register(self)
            }
        }

        /// Paints a selection this view did not make itself.
        ///
        /// A range set through `setSelectedRange` on a view that is not first
        /// responder draws in the unemphasised colour, so a selection spanning
        /// messages would change shade at every boundary.
        func carrySelection(_ range: NSRange) {
            guard let layoutManager = self.layoutManager else { return }
            self.clearCarriedSelection()
            guard range.length > 0 else { return }
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: NSColor.selectedTextBackgroundColor],
                forCharacterRange: range
            )
            self.carriedSelectionRange = range
        }

        func clearCarriedSelection() {
            guard let carried = self.carriedSelectionRange, let layoutManager = self.layoutManager
            else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: carried)
            self.carriedSelectionRange = nil
        }

        override func mouseDown(with event: NSEvent) {
            guard let coordinator else { return super.mouseDown(with: event) }
            let point = self.convert(event.locationInWindow, from: nil)

            // Word and line selection, and following a link, stay with AppKit.
            if event.clickCount > 1 || self.hasLink(at: point) {
                coordinator.clearAll()
                return super.mouseDown(with: event)
            }

            self.window?.makeFirstResponder(self)
            coordinator.beginDrag(in: self, at: self.characterIndexForInsertion(at: point))

            // NSTextView tracks a drag in its own loop inside mouseDown, so
            // mouseDragged never arrives and a drag can never leave the view.
            // Tracking it here is what lets the selection reach the next
            // message.
            while let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true
            ) {
                if next.type == .leftMouseUp { break }
                coordinator.extendDrag(toWindowPoint: next.locationInWindow)
                self.autoscroll(with: next)
            }
            coordinator.endDrag()
        }

        private func hasLink(at point: NSPoint) -> Bool {
            guard let storage = self.textStorage, storage.length > 0 else { return false }
            let index = self.characterIndexForInsertion(at: point)
            guard index < storage.length else { return false }
            return storage.attribute(.link, at: index, effectiveRange: nil) != nil
        }

        override func copy(_ sender: Any?) {
            let text = self.coordinator?.selectedText() ?? self.ownSelectionText()
            guard let text else { return super.copy(sender) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// This view's own selection, flattened for pasting.
        ///
        /// Even a selection inside one message needs it: a code block is held
        /// together by line separators and a table cell is its own paragraph.
        private func ownSelectionText() -> String? {
            guard let storage = self.textStorage, self.selectedRange().length > 0 else {
                return nil
            }
            return ChatSelectionText.plainText(storage, range: self.selectedRange())
        }

        override func selectAll(_ sender: Any?) {
            guard let coordinator else { return super.selectAll(sender) }
            coordinator.selectAll()
        }
    }
}

/// A chat row's text, held to a height that covers what it draws.
///
/// Expanding a truncated message replaces the text of a row that is already
/// laid out, and the height it was laid out at does not always follow. A text
/// view draws past its frame rather than clipping, so what that leaves is a
/// message drawn over the one after it. The floor is a minimum rather than an
/// exact height, so it can only ever correct upwards, and it is dropped when the
/// text changes so a message that shrinks is not held open.
struct ChatText: View {
    let content: ChatTextContent
    var appearance: ChatTextAppearance
    var highlight: ChatTextHighlight?
    var links = ChatTextLinks()
    var lineLimit: Int?

    @State private var heightFloor: CGFloat?

    var body: some View {
        SelectableMarkdownText(
            content: self.content,
            appearance: self.appearance,
            highlight: self.highlight,
            links: self.links,
            lineLimit: self.lineLimit,
            onHeightOverflow: { self.heightFloor = $0 }
        )
        .frame(minHeight: self.heightFloor, alignment: .top)
        .onChange(of: self.content) { self.heightFloor = nil }
    }
}

extension ChatText {
    /// An assistant's markdown answer, drawn as the chat draws one.
    ///
    /// Use this, not `Markdown(…).textSelection(.enabled)`, for selectable
    /// markdown. SwiftUI's selection overlay is a text field with one font,
    /// and for a paragraph with bold or code runs it sets the other font on
    /// every update. Each change invalidates its intrinsic size and asks the
    /// window for another constraint pass, which loops.
    init(answer text: String, font: NSFont = .systemFont(ofSize: 13)) {
        let content: ChatTextContent = text.containsBlockMarkdown ? .markdown(text) : .inlineMarkdown(text)
        // As in the chat: only the inline path carries line spacing of its
        // own, a markdown answer takes it from the theme.
        let lineSpacing: CGFloat
        if case .inlineMarkdown = content { lineSpacing = 4 } else { lineSpacing = 0 }
        self.init(
            content: content,
            appearance: .init(font: font, foregroundColor: .labelColor, lineSpacing: lineSpacing))
    }
}

/// Measures attributed text off screen, memoised per text and width.
///
/// Every mounted message is asked for its size on each layout pass, so an
/// uncached layout here shows up directly as scroll jank.
@MainActor
enum ChatTextMeasurement {
    /// The whole attributed string, not its characters. Two rows can hold the
    /// same words in a different font, at a different line spacing, or as a
    /// table rather than a paragraph, and those are different heights.
    private struct Key: Hashable {
        let text: NSAttributedString
        let width: CGFloat
        let lineLimit: Int
    }

    private static var cache = LRUCache<Key, CGSize>(limit: 2_000)

    static func size(
        of attributed: NSAttributedString, width: CGFloat, lineLimit: Int? = nil
    ) -> CGSize {
        let rounded = width.rounded()
        let key = Key(text: attributed, width: rounded, lineLimit: lineLimit ?? 0)
        if let cached = self.cache[key] { return cached }
        let measured = self.measure(attributed, width: rounded, lineLimit: lineLimit)
        self.cache[key] = measured
        return measured
    }

    private static func measure(
        _ attributed: NSAttributedString, width: CGFloat, lineLimit: Int?
    ) -> CGSize {
        // Measure on a detached stack. The live view's container width tracks a
        // frame SwiftUI has not set during the sizing pass, so heights come
        // back short and messages end up drawn on top of each other.
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lineLimit ?? 0
        container.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        let layoutManager = MarkdownLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let used = layoutManager.usedRect(for: container)
        // usedRect can stop short of a trailing table's bottom edge, which is
        // what draws one message over the next.
        var height = used.maxY
        if layoutManager.numberOfGlyphs > 0 {
            let last = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
            height = max(height, last.maxY)
        }
        // A block fill spans the container, so a code block or a diff has to
        // claim the whole width even when its longest line is short, or the
        // band behind it would stop where the text does.
        let spansContainer = self.hasFullWidthFill(attributed)
        return CGSize(width: spansContainer ? width : ceil(used.maxX), height: ceil(height))
    }

    private static func hasFullWidthFill(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(
            .markdownBlockDecoration, in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, stop in
            guard let decoration = value as? MarkdownBlockDecoration, decoration.kind == .fill
            else { return }
            found = true
            stop.pointee = true
        }
        return found
    }
}
