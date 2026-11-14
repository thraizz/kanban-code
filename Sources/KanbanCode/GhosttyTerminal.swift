import AppKit
import GhosttyKit
import KanbanCodeCore

/// The app's terminal, backed by libghostty (GhosttyKit).
///
/// Font, line height, padding and colors come from the user's Ghostty config
/// (`~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config`),
/// then `~/.kanban-code/ghostty.config` (a dark theme by default).
/// Needs `Frameworks/GhosttyKit.xcframework` (`Scripts/build-ghosttykit.sh`).
///
/// Keyboard input without IME, mouse, scroll, resize, paste and copy.
/// Programs cannot read the clipboard, and there is no URL detection.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

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

/// One Ghostty surface running a shell command (the tmux attach script).
/// The view exists before its command runs: `start(command:)` creates the
/// surface once the view has a size, so tmux does not attach at 0x0.
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    private var keyTextAccumulator: [String]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Creates the surface, which spawns `command`. Does nothing the second time.
    func start(command: String) {
        guard surface == nil, let app = GhosttyRuntime.shared.app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surface = command.withCString { cmd in
            cfg.command = cmd
            return ghostty_surface_new(app, &cfg)
        }
        guard let surface else { return }
        viewDidChangeBackingProperties()
        ghostty_surface_set_focus(surface, window?.firstResponder === self)
    }

    /// The process in the foreground of the terminal's pty (the tmux client,
    /// or the ssh or expect that carries it), 0 when there is none.
    var foregroundPid: pid_t {
        guard let surface else { return 0 }
        return pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
    }

    /// Pastes `text` the way the terminal pastes the clipboard (bracketed
    /// when the program asked for it).
    func paste(text: String) {
        guard let surface, !text.isEmpty else { return }
        ghostty_surface_paste_text(surface, text, UInt(text.utf8.count))
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
        if let window {
            let scale = window.backingScaleFactor
            // The layer draws at the window's scale, or a move to a screen
            // of another scale shows the old bitmap stretched.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scale
            CATransaction.commit()
            if let surface { ghostty_surface_set_content_scale(surface, scale, scale) }
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
        UsageLog.record("terminal", "input")
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
           surface != nil, let text = NSPasteboard.general.string(forType: .string) {
            paste(text: text)
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
