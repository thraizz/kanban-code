/**
 * `kanban import`: a Claude Code session started in a terminal of its own
 * (`claude` in Ghostty or Terminal) moves onto the Kanban Code board and
 * continues in a Kanban Code terminal. The app does the move; this finds the
 * session and says what happened.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { claudeConfigDir } from "./paths.js";

const SESSION_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

/** The session id in a bare id, a `claude --resume <id>` line or a transcript path. */
export function sessionIdIn(text: string): string | undefined {
  return text.match(SESSION_ID)?.[0].toLowerCase();
}

/** Where Claude Code registers each running process, as `<pid>.json`. */
export function claudeSessionsDir(): string {
  return join(claudeConfigDir(), "sessions");
}

function parentPid(pid: number): number | undefined {
  try {
    const out = execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf-8" }).trim();
    const parent = Number.parseInt(out, 10);
    return Number.isFinite(parent) && parent > 1 ? parent : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The session of the interactive Claude Code this command runs under: the
 * nearest ancestor process Claude registered in `sessionsDir`. Undefined when
 * no Claude Code runs above it.
 */
export function enclosingClaudeSessionId(
  startPid: number = process.ppid,
  sessionsDir: string = claudeSessionsDir(),
  parentOf: (pid: number) => number | undefined = parentPid
): string | undefined {
  let pid: number | undefined = startPid;
  for (let depth = 0; pid !== undefined && depth < 12; depth += 1) {
    const entryPath = join(sessionsDir, `${pid}.json`);
    if (existsSync(entryPath)) {
      try {
        const entry = JSON.parse(readFileSync(entryPath, "utf-8")) as {
          pid?: number;
          sessionId?: string;
          kind?: string;
        };
        if (entry.pid === pid && entry.sessionId && (entry.kind === undefined || entry.kind === "interactive")) {
          return entry.sessionId;
        }
      } catch {
        // A file Claude is rewriting right now: keep walking.
      }
    }
    pid = parentOf(pid);
  }
  return undefined;
}

/**
 * The Claude Code session this command runs in: the id Claude Code hands its
 * shells, else the nearest Claude process above this one.
 */
export function ownClaudeSessionId(
  env: NodeJS.ProcessEnv = process.env,
  walk: () => string | undefined = () => enclosingClaudeSessionId()
): string | undefined {
  return sessionIdIn(env.CLAUDE_CODE_SESSION_ID ?? "") ?? walk();
}

export type ImportStatus = "resumed" | "waiting" | "running";

/** The line `kanban import` prints for what the app did. */
export function importMessage(status: string | undefined, sessionId: string, cardId: string): string {
  switch (status) {
    case "waiting":
      return (
        `Session ${sessionId} is on the board as card ${cardId}. It still runs in a terminal: ` +
        "quit it there (/exit) and it continues in Kanban Code."
      );
    case "running":
      return `Session ${sessionId} already runs in Kanban Code, card ${cardId}.`;
    default:
      return `Session ${sessionId} continues in Kanban Code, card ${cardId}.`;
  }
}
