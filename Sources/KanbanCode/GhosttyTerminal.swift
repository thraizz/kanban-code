#if KANBAN_GHOSTTY
import AppKit
import GhosttyKit
import KanbanCodeCore

/// Experimental terminal backed by libghostty (GhosttyKit) instead of SwiftTerm.
///
/// Turned on with `defaults write com.kanban-code.app experimentalGhosttyTerminal -bool true`.
/// Font, line height, padding and colors come from the user's Ghostty config
/// (`~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config`),
/// then `~/.kanban-code/ghostty.config` (a dark theme by default).
/// Needs `Frameworks/GhosttyKit.xcframework` (`Scripts/build-ghosttykit.sh`).
///
/// This is a spike: keyboard input without IME, mouse, scroll and resize.
/// No clipboard reads, no URL detection, no tmux scroll bridging.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "experimentalGhosttyTerminal")
    }

    private(set) var app: ghostty_app_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            KanbanCodeLog.info("ghostty", "ghostty_init failed")
            return
        }
        guard let config = ghostty_config_new() else { return }
        ghostty_config_load_default_files(config)
        // Overrides for terminals inside Kanban Code, loaded after the user's
        // Ghostty config. The app is always dark, so the default picks a dark theme.
        let overrides = NSHomeDirectory() + "/.kanban-code/ghostty.config"
        if !FileManager.default.fileExists(atPath: overrides) {
            try? "# Ghostty settings for terminals inside Kanban Code (on top of your Ghostty config).\n# https://ghostty.org/docs/config\ntheme = GitHub Dark\n"
                .write(toFile: overrides, atomically: true, encoding: .utf8)
        }
        ghostty_config_load_file(config, overrides)
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                if let app = GhosttyRuntime.shared.app { ghostty_app_tick(app) }
            }
        }
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content[0].data else { return }
            let text = String(cString: data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        runtime.close_surface_cb = { _, _ in }

        // No ghostty_app_set_color_scheme: any scheme change reloads the
        // surface config and drops the surface's command (seen with 1.4.0).
        app = ghostty_app_new(&runtime, config)
        if app == nil { KanbanCodeLog.info("ghostty", "ghostty_app_new failed") }
    }
}

/// Ghostty surfaces by tmux session; they outlive the container like SwiftTerm's.
@MainActor
enum GhosttySurfaceCache {
    private static var views: [String: GhosttySurfaceView] = [:]

    static func existing(_ session: String) -> GhosttySurfaceView? { views[session] }

    static func view(for session: String, frame: NSRect) -> GhosttySurfaceView {
        if let view = views[session] { return view }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = TerminalCache.shared.attachScript(for: session)
        // Ghostty runs this through `/bin/sh -c "exec -l …"` itself. The `env`
        // in front keeps its shell integration from recognizing the login shell
        // and replacing the command with a bare interactive shell.
        let command = "/usr/bin/env \(shellQuote(shell)) -l -c \(shellQuote(script))"
        let view = GhosttySurfaceView(frame: frame, command: command)
        views[session] = view
        return view
    }

    static func remove(_ session: String) {
        views.removeValue(forKey: session)?.removeFromSuperview()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One Ghostty surface running a shell command (the tmux attach script).
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    init(frame: NSRect, command: String) {
        super.init(frame: frame)
        wantsLayer = true
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surface = command.withCString { cmd in
            cfg.command = cmd
            return ghostty_surface_new(app, &cfg)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: Size

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let surface, let window {
            let scale = window.backingScaleFactor
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let px = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        // Let AppKit translate (dead keys, option-letters), collecting the text.
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let texts = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        if texts.isEmpty {
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: event.characters)
        } else {
            for text in texts {
                sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: text)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS, text: nil)
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            ghostty_surface_text(surface, text, UInt(text.utf8.count))
        }
    }

    override func doCommand(by selector: Selector) {
        // Special keys (arrows, return, backspace) are encoded by Ghostty from the keycode.
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
        key.composing = false
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        // Control characters are encoded by Ghostty itself.
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            _ = text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: Paste (Cmd+V)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
           let surface, let text = NSPasteboard.general.string(forType: .string) {
            ghostty_surface_paste_text(surface, text, UInt(text.utf8.count))
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            // Ghostty copies through its own binding (copy_to_clipboard) on Cmd+C.
            sendKey(event, action: GHOSTTY_ACTION_PRESS, text: nil)
            return true
        }
        return false
    }

    // MARK: Mouse

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, p.y, Self.mods(event.modifierFlags))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) { mousePos(event) }
    override func mouseDragged(with event: NSEvent) { mousePos(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mousePos(event)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        mousePos(event)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        ghostty_surface_mouse_scroll(surface, x, y, precise ? 1 : 0)
    }
}
#endif
