import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Selectable markdown text")
struct SelectableMarkdownTextTests {

    static let tableMarkdown = """
        | Component | Version | Notes |
        | --- | --- | --- |
        | alpha | 1.2.0 | first |
        | beta | 3.4.5 | second |
        """

    static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor
    )

    private static func columnOrigins(_ view: SelectableMarkdownText.WrappingTextView) -> [CGFloat] {
        guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
        layout.ensureLayout(for: container)
        var origins: Set<CGFloat> = []
        var index = 0
        while index < layout.numberOfGlyphs {
            var effective = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            origins.insert(rect.minX)
            index = NSMaxRange(effective)
        }
        return origins.sorted()
    }

    /// The view is configured before SwiftUI has given it a frame, so its first
    /// `configure` runs at width zero. Sizing probes measure off screen and
    /// leave the view alone — a probe width is usually not the width the row
    /// ends up with — so the columns take their shape when the frame lands.
    @Test("measures at the proposed width and renders when the frame lands")
    func rendersWhenTheFrameLands() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .markdown(Self.tableMarkdown), appearance: Self.appearance, highlight: nil)
        #expect(view.bounds.width == 0)

        let size = view.fittingSize(forWidth: 690)
        #expect(size.width > 200)
        #expect(size.height > 40)

        view.setFrameSize(NSSize(width: 690, height: size.height))
        let origins = Self.columnOrigins(view)
        #expect(origins.count == 3)
        if origins.count == 3 {
            // Columns spread across the width rather than stacking at the left.
            #expect(origins[1] - origins[0] > 40)
            #expect(origins[2] - origins[1] > 40)
        }
    }

    /// Stack layout probes a row at many candidate widths per pass, and the
    /// probes multiply through nested stacks. A probe that re-lays the live
    /// text view out each time turns a long feed's layout pass into minutes of
    /// blocked main thread, so measuring must leave the view alone.
    @Test("a sizing probe does not render the live view")
    func sizingProbeLeavesTheViewAlone() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .markdown(Self.tableMarkdown), appearance: Self.appearance, highlight: nil)

        for width in [300, 500, 690, 500, 300] {
            _ = view.fittingSize(forWidth: CGFloat(width))
        }
        #expect(view.textStorage?.length == 0)
    }

    /// The representable's `sizeThatFits` runs inside SwiftUI's layout pass.
    /// New text arriving there must not reach the text storage or the frame:
    /// either change invalidates the layout that is asking, and on a long
    /// transcript that kept a window relaying itself out until AppKit threw.
    @Test("new text taken during a sizing pass leaves the live view alone")
    func updateDuringSizingLeavesTheViewAlone() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .plain("First."), appearance: Self.appearance, highlight: nil)
        view.setFrameSize(NSSize(width: 500, height: 40))
        let storage = view.textStorage?.string
        let frame = view.frame

        for width: CGFloat in [300, 690, 500, 1200] {
            view.update(
                content: .markdown(Self.tableMarkdown), appearance: Self.appearance,
                highlight: nil)
            _ = view.fittingSize(for: .init(width: width, height: nil))
            _ = view.fittingSize(for: .unspecified)
        }
        #expect(view.textStorage?.string == storage)
        #expect(view.frame == frame)
    }

    /// SwiftUI owns the frame. A text view that sizes itself to new text
    /// overrides the frame it was just given and asks for another pass.
    @Test("rendering keeps the frame SwiftUI gave the view")
    func renderingKeepsTheFrame() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .plain(String(repeating: "lorem ipsum ", count: 300)),
            appearance: Self.appearance, highlight: nil)
        for size in [NSSize(width: 500, height: 100), NSSize(width: 400, height: 900)] {
            view.setFrameSize(size)
            #expect(view.frame.size == size)
        }
        view.configure(content: .plain("Short."), appearance: Self.appearance, highlight: nil)
        #expect(view.frame.size == NSSize(width: 400, height: 900))
    }

    /// System notices sit inside a centring `HStack`. A row that reports the
    /// full proposed width leaves the spacers nothing to take, so it drifts to
    /// the leading edge instead of staying centred.
    @Test("reports its own width so short rows can be centred")
    func shortRowReportsItsOwnWidth() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .plain("Background command completed"),
            appearance: Self.appearance,
            highlight: nil
        )
        let size = view.fittingSize(forWidth: 690)
        #expect(size.width < 400)
    }

    @Test("takes the full width when the text needs it")
    func wrappingRowTakesTheFullWidth() {
        let long = String(repeating: "wrapping text that keeps going ", count: 12)
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .plain(long), appearance: Self.appearance, highlight: nil)
        let size = view.fittingSize(forWidth: 690)
        #expect(size.width > 600)
        #expect(size.height > 20)
    }

    /// A table narrower than the container keeps its content width, so the
    /// table that proves a re-render has to be wide enough to be squeezed.
    @Test("re-renders when the width changes")
    func reRendersOnWidthChange() {
        let wideTable = """
            | Component | Notes |
            | --- | --- |
            | a fairly long component name here | an even longer note that will \
            not fit in a narrow container without being squeezed |
            """
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .markdown(wideTable), appearance: Self.appearance, highlight: nil)
        view.setFrameSize(NSSize(width: 400, height: 400))
        let narrow = Self.columnOrigins(view)

        view.setFrameSize(NSSize(width: 900, height: 400))
        let wide = Self.columnOrigins(view)

        #expect(narrow.count == 2)
        #expect(wide.count == 2)
        if narrow.count == 2, wide.count == 2 {
            #expect(wide[1] > narrow[1])
        }
    }
}
