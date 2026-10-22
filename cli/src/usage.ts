import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { kanbanHome } from "./paths.js";

/// Appends one line per command to ~/.kanban-code/usage/cli.jsonl, so the
/// usage report sees what agents and scripts run, not only what is clicked.
/// `command` is the command path ("remote prompt"), never its arguments; a
/// failure to write never fails the command.
export function recordCliUsage(command: string): void {
  try {
    const dir = join(kanbanHome(), "usage");
    mkdirSync(dir, { recursive: true });
    const line = JSON.stringify({
      date: new Date().toISOString(),
      command,
      fromCard: Boolean(process.env.KANBAN_CARD_ID),
    });
    appendFileSync(join(dir, "cli.jsonl"), line + "\n");
  } catch {
    // Counting is best effort.
  }
}
