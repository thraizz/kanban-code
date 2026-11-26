import Foundation

/// Kanban's OpenCode plugin: OpenCode's counterpart of the Claude and Gemini
/// hook entries.
///
/// OpenCode has no hook settings; it loads every JS file in its `plugins`
/// directory and hands each one its event bus. The plugin turns the events
/// Kanban cares about into the same lines the hook script appends to
/// `~/.kanban-code/hook-events.jsonl`, with the session's virtual path as
/// `transcriptPath` so they route to `OpenCodeActivityDetector`.
public enum OpenCodePlugin {
    /// Marker that identifies the file as Kanban's (and its version).
    static let marker = "kanban-code-opencode-plugin"

    /// `$XDG_CONFIG_HOME/opencode/plugins/kanban-code.js`, as OpenCode
    /// resolves its global config directory.
    public static func defaultPath(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".config")
        return (configHome as NSString).appendingPathComponent("opencode/plugins/kanban-code.js")
    }

    /// True when the current version of the plugin is in place.
    public static func isInstalled(at path: String? = nil) -> Bool {
        (try? String(contentsOfFile: path ?? defaultPath(), encoding: .utf8)) == content
    }

    /// True when some version of Kanban's plugin is in place.
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

    /// Removes the plugin, and only a file that is Kanban's.
    public static func uninstall(at path: String? = nil) throws {
        let resolved = path ?? defaultPath()
        guard isPresent(at: resolved) else { return }
        try FileManager.default.removeItem(atPath: resolved)
    }

    /// Rewrites an older version of the plugin. A machine that never
    /// installed it is left to the Settings flow.
    @discardableResult
    public static func refresh(at path: String? = nil) -> Bool {
        let resolved = path ?? defaultPath()
        guard isPresent(at: resolved), !isInstalled(at: resolved) else { return false }
        return (try? install(at: resolved)) != nil
    }

    /// The plugin source. Bump the version in the first line on any change.
    ///
    /// OpenCode v2 loads a plugin module's default export
    /// (`{ id, server }`); the v1 shape (a named export that is the plugin
    /// function) is ignored, which left the board blind to OpenCode activity.
    static let content = #"""
    // kanban-code-opencode-plugin v2
    // Reports OpenCode session activity to Kanban Code. Installed and kept up
    // to date by Kanban Code (Settings > Hooks); local edits are overwritten.
    import { appendFileSync, mkdirSync } from "node:fs"
    import { homedir } from "node:os"
    import { join } from "node:path"

    const EVENTS_DIR = join(homedir(), ".kanban-code")
    const EVENTS_FILE = join(EVENTS_DIR, "hook-events.jsonl")
    // Kanban's virtual path for a session: nothing is stored there, it only
    // tells Kanban the session is OpenCode's.
    const sessionPath = (id) => join(homedir(), ".local", "share", "opencode", "session", id)

    const lastEvent = new Map()
    const childSessions = new Set()

    function emit(sessionId, event) {
      if (!sessionId || childSessions.has(sessionId)) return
      // session.status repeats "busy" on every step; one line per change.
      if (lastEvent.get(sessionId) === event) return
      lastEvent.set(sessionId, event)
      try {
        mkdirSync(EVENTS_DIR, { recursive: true })
        appendFileSync(EVENTS_FILE, JSON.stringify({
          sessionId,
          event,
          timestamp: new Date().toISOString(),
          transcriptPath: sessionPath(sessionId),
        }) + "\n")
      } catch {}
    }

    function handle(type, p) {
      p = p || {}
      const sid = p.sessionID || p.info?.sessionID || p.form?.sessionID
      switch (type) {
        case "session.created":
          // Subagent runs are sessions too; they are never cards.
          if (p.info?.parentID) childSessions.add(p.info.id)
          else emit(p.info?.id, "SessionStart")
          break
        case "session.status":
          if (p.status?.type === "busy") emit(sid, "UserPromptSubmit")
          else if (p.status?.type === "idle") emit(sid, "Stop")
          break
        // v2 runs a turn as an execution; the started/finished pair is the
        // UserPromptSubmit/Stop pair the board reads.
        case "session.execution.started":
          emit(sid, "UserPromptSubmit")
          break
        case "session.execution.succeeded":
        case "session.execution.failed":
        case "session.execution.interrupted":
        case "session.idle":
        case "session.error":
          emit(sid, "Stop")
          break
        // A permission or a question waits on the human: needs attention.
        // The clear lets a second prompt emit even if the last line was one.
        case "permission.asked":
        case "form.created":
        case "question.asked":
          lastEvent.delete(sid)
          emit(sid, "Notification")
          break
        case "permission.replied":
        case "form.replied":
        case "form.cancelled":
        case "question.replied":
        case "question.rejected":
          emit(sid, "UserPromptSubmit")
          break
        case "session.deleted":
          emit(p.info?.id || sid, "SessionEnd")
          break
      }
    }

    const server = async () => ({
      event: async ({ event }) => handle(event?.type, event?.properties),
    })

    export default { id: "kanban-code", server }

    """#
}
