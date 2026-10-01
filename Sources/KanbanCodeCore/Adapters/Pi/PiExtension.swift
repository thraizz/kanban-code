import Foundation

/// Kanban's Pi extension: Pi's counterpart of the Claude and Gemini hook
/// entries.
///
/// Pi has no hook settings; it loads every file in `~/.pi/agent/extensions/`
/// and hands each one its lifecycle events. The extension turns the events
/// Kanban cares about into the same lines the hook script appends to
/// `~/.kanban-code/hook-events.jsonl`, with the session file as
/// `transcriptPath` so they route to `PiActivityDetector`.
public enum PiExtension {
    /// Marker that identifies the file as Kanban's (and its version).
    static let marker = "kanban-code-pi-extension"

    /// `~/.pi/agent/extensions/kanban-code.js`.
    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("\(CodingAssistant.pi.configDirName)/extensions/kanban-code.js")
    }

    /// True when the current version of the extension is in place.
    public static func isInstalled(at path: String? = nil) -> Bool {
        (try? String(contentsOfFile: path ?? defaultPath(), encoding: .utf8)) == content
    }

    /// True when some version of Kanban's extension is in place.
    public static func isPresent(at path: String? = nil) -> Bool {
        (try? String(contentsOfFile: path ?? defaultPath(), encoding: .utf8))?.contains(marker) == true
    }

    public static func install(at path: String? = nil) throws {
        let resolved = path ?? defaultPath()
        try FileManager.default.createDirectory(
            atPath: (resolved as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try content.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    /// Removes the extension, and only a file that is Kanban's.
    public static func uninstall(at path: String? = nil) throws {
        let resolved = path ?? defaultPath()
        guard isPresent(at: resolved) else { return }
        try FileManager.default.removeItem(atPath: resolved)
    }

    /// Rewrites an older version of the extension. A machine that never
    /// installed it is left to the Settings flow.
    @discardableResult
    public static func refresh(at path: String? = nil) -> Bool {
        let resolved = path ?? defaultPath()
        guard isPresent(at: resolved), !isInstalled(at: resolved) else { return false }
        return (try? install(at: resolved)) != nil
    }

    /// The extension source. Bump the version in the first line on any change.
    static let content = #"""
    // kanban-code-pi-extension v1
    // Reports Pi session activity to Kanban Code. Installed and kept up to
    // date by Kanban Code (Settings > Hooks); local edits are overwritten.
    import { appendFileSync, mkdirSync } from "node:fs"
    import { homedir } from "node:os"
    import { join } from "node:path"

    const EVENTS_DIR = join(homedir(), ".kanban-code")
    const EVENTS_FILE = join(EVENTS_DIR, "hook-events.jsonl")

    export default function (pi) {
      let lastLine = ""

      function emit(ctx, event, extra) {
        const sessionId = ctx.sessionManager.getSessionId()
        // Without a file (--no-session) there is nothing to show on a card.
        const transcriptPath = ctx.sessionManager.getSessionFile()
        if (!sessionId || !transcriptPath) return
        const key = sessionId + " " + event
        if (key === lastLine) return
        lastLine = key
        try {
          mkdirSync(EVENTS_DIR, { recursive: true })
          appendFileSync(EVENTS_FILE, JSON.stringify({
            sessionId,
            event,
            timestamp: new Date().toISOString(),
            transcriptPath,
            ...extra,
          }) + "\n")
        } catch {}
      }

      pi.on("session_start", async (event, ctx) => {
        // A reload restarts the extension runtime, not the session.
        if (event.reason === "reload") return
        emit(ctx, "SessionStart", { source: event.reason === "resume" ? "resume" : "startup" })
      })
      let running = false
      pi.on("agent_start", async (_event, ctx) => {
        running = true
        emit(ctx, "UserPromptSubmit")
      })
      // agent_end can be followed by retries or queued prompts; settled is
      // the point where Pi will not continue on its own.
      pi.on("agent_settled", async (_event, ctx) => {
        running = false
        emit(ctx, "Stop")
      })
      // Pi itself never asks; an extension's dialog blocks until answered.
      pi.on("ui_prompt_start", async (_event, ctx) =>
        emit(ctx, "Notification", { notificationType: "permission_prompt" }))
      pi.on("ui_prompt_end", async (_event, ctx) => emit(ctx, running ? "UserPromptSubmit" : "Stop"))
      pi.on("session_shutdown", async (event, ctx) => {
        if (event.reason === "reload") return
        emit(ctx, "SessionEnd")
      })
    }

    """#
}
