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
    static let content = #"""
    // kanban-code-opencode-plugin v1
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

    export const KanbanCode = async () => ({
      event: async ({ event }) => {
        const p = event.properties ?? {}
        switch (event.type) {
          case "session.created":
            // Subagent runs are sessions too; they are never cards.
            if (p.info?.parentID) childSessions.add(p.info.id)
            else emit(p.info?.id, "SessionStart")
            break
          case "session.status":
            if (p.status?.type === "busy") emit(p.sessionID, "UserPromptSubmit")
            else if (p.status?.type === "idle") emit(p.sessionID, "Stop")
            break
          case "session.idle":
          case "session.error":
            emit(p.sessionID, "Stop")
            break
          case "permission.asked":
            emit(p.sessionID, "Notification")
            break
          case "permission.replied":
            emit(p.sessionID, "UserPromptSubmit")
            break
          case "session.deleted":
            emit(p.info?.id, "SessionEnd")
            break
        }
      },
    })

    """#
}
