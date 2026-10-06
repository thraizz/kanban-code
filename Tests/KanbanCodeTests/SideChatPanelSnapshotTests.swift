import AppKit
import SwiftUI
import Testing
import KanbanCodeRemoteKit
@testable import KanbanCode

/// Draws the side chat panel to PNG files, for looking at it without the
/// app: `KANBAN_SIDE_CHAT_SNAPSHOT=<directory> swift test --filter SideChatPanelSnapshot`.
@Suite("Side chat panel snapshot")
@MainActor
struct SideChatPanelSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_SIDE_CHAT_SNAPSHOT"]

    private func controller(kind: RemoteSideChatKind, answer: String) async -> SideChatController {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let refs = (1...6).map {
            RemoteSideChatRef(ref: "m\($0)", offset: $0 * 100, role: "assistant", at: at.addingTimeInterval(Double($0) * 600), preview: "…")
        }
        let run = RemoteSideChatRun(
            id: "run1", cardId: "card", kind: kind, state: .done, text: answer,
            since: kind == .catchup ? RemoteSideChatSince(text: "Move the reports to the new API. Keep the old endpoints working.", at: at, offset: 100) : nil,
            refs: kind == .catchup ? refs : nil)
        let chat = SideChatController(transport: .init(start: { _ in run }, poll: { _ in run }, cancel: { _ in }))
        chat.pollInterval = .milliseconds(5)
        kind == .catchup ? chat.run(.catchup) : chat.run(.btw("which report was last?"))
        for _ in 0..<200 where chat.state.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        return chat
    }

    private func draw(_ chat: SideChatController, collapsed: Bool = false, to name: String) async throws {
        let directory = try #require(Self.directory)
        let view = ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            SideChatPanel(controller: chat, collapsed: .constant(collapsed), onJump: { _ in }, onSendToMain: { _ in })
        }
        .frame(width: 820, height: 620)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The panel measures its content before it takes its height.
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test(.enabled(if: directory != nil))
    func catchUpAndBtw() async throws {
        let lines = [
            #"{"section":"asked","text":"You asked to move the reports to the new API.","refs":["m1"]}"#,
            #"{"section":"status","text":"Done: all 40 reports moved.","refs":["m5"]}"#,
            #"{"section":"report","text":"Full report","refs":["m5"]}"#,
            #"{"section":"facts","text":"Staging has been on the new API since 14:00.","refs":["m2"]}"#,
            #"{"section":"waiting","text":"Decide on the export index: adding it locks the table for minutes.","refs":["m3"]}"#,
            #"{"section":"other","text":"The nightly export failed once and passed on retry.","refs":["m6"]}"#,
        ]
        let catchUp = await controller(kind: .catchup, answer: lines.joined(separator: "\n"))
        try await draw(catchUp, to: "mac-catchup.png")
        try await draw(catchUp, collapsed: true, to: "mac-folded.png")
        let btw = await controller(kind: .btw, answer: "Report 40, the **export** report.\n\n- It moved at 19:52.\n- Its test passes.")
        try await draw(btw, to: "mac-btw.png")
    }
}
