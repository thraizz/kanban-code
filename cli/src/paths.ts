import { homedir } from "node:os";
import { join } from "node:path";

/// Root of the Kanban Code state dir. Honors KANBAN_CODE_HOME so tests (and
/// alternate deployments) can sandbox into a temp dir; defaults to ~/.kanban-code.
export function kanbanHome(): string {
  return process.env.KANBAN_CODE_HOME || join(homedir(), ".kanban-code");
}

export function linksPath(): string {
  return join(kanbanHome(), "links.json");
}

export function settingsPath(): string {
  return join(kanbanHome(), "settings.json");
}

export function contextDir(): string {
  return join(kanbanHome(), "context");
}

export function hookEventsPath(): string {
  return join(kanbanHome(), "hook-events.jsonl");
}

/// This master's identity: `{"id", "name"}`. Cards key ownership on the id.
export function machinePath(): string {
  return join(kanbanHome(), "machine.json");
}

export function commandInboxDir(): string {
  return join(kanbanHome(), "commands", "inbox");
}

export function commandResponsesDir(): string {
  return join(kanbanHome(), "commands", "responses");
}

/// Commands a remote machine hands back to the Mac to run, and their results.
export function proxyRequestsDir(): string {
  return join(kanbanHome(), "commands", "proxy");
}

export function proxyResponsesDir(): string {
  return join(kanbanHome(), "commands", "proxy-responses");
}

/// Images the Mac stores for a proxied command, one directory per request.
export function proxyImagesDir(requestId: string): string {
  return join(kanbanHome(), "images", "proxy", requestId);
}

/// Claude Code's config dir. Honors CLAUDE_CONFIG_DIR so a sandboxed test can
/// point it elsewhere.
export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
}

/// Where Claude Code writes per-project session transcripts.
export function claudeProjectsDir(): string {
  return join(claudeConfigDir(), "projects");
}

export function claudeSettingsPath(): string {
  return join(claudeConfigDir(), "settings.json");
}

/// Codex's config dir. Honors CODEX_HOME the same way Codex itself does.
export function codexConfigDir(): string {
  return process.env.CODEX_HOME || join(homedir(), ".codex");
}

/// Where Codex writes its rollout transcripts.
export function codexSessionsDir(): string {
  return join(codexConfigDir(), "sessions");
}
