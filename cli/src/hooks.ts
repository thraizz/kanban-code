import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { kanbanHome, claudeSettingsPath } from "./paths.js";
import { sortedStringify } from "./cards.js";

/// Claude Code hook events the runtime relies on. Stop drives auto-send;
/// UserPromptSubmit lets the daemon detect a human/relay prompt; SubagentStart
/// and SubagentStop say what still runs under a session after its own turn
/// ended; the rest feed activity tracking. Mirrors the Swift HookManager.
export const HOOK_EVENTS = [
  "Stop",
  "Notification",
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
  "SubagentStart",
  "SubagentStop",
];

/// Codex hook events we register (Codex exposes the same names; we only need the
/// subset that drives the daemon: Stop for auto-send, UserPromptSubmit to note
/// user prompts, SessionStart/Stop for activity).
export const CODEX_HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "Stop"];

function codexConfigDir(): string {
  return process.env.CODEX_HOME ?? join(homedir(), ".codex");
}

function codexHooksPath(): string {
  return join(codexConfigDir(), "hooks.json");
}

function defaultHookScriptPath(): string {
  return join(kanbanHome(), "hook.sh");
}

/// Appends one timestamped line per hook event to hook-events.jsonl. No jq
/// dependency (lightweight grep parsing). Honors KANBAN_CODE_HOME so the same
/// script works in tests and in alternate deployments.
///
/// The app (HookManager.swift) writes this same script to the same path, and
/// whichever ran last owns the file: hooks.test.ts and HookManagerTests fail
/// when the two texts differ. The Mac's machine bootstrap runs
/// `kanban hooks install`, so a CLI copy without a field the app reads (the
/// subagent id) took it from every hook event on that machine.
export const HOOK_SCRIPT = `#!/usr/bin/env bash
# Kanban hook handler for coding assistants (Claude Code, Gemini CLI, Codex).
# Receives JSON on stdin from hooks, appends a timestamped
# event line to <kanban-home>/hook-events.jsonl.
# Written by both the app and \`kanban hooks install\`: keep the two identical.

set -euo pipefail

# A side chat (/btw, /catchup) forks a session to answer a question and
# writes nothing: it is not a session of the board.
if [ -n "\${KANBAN_SIDE_CHAT:-}" ]; then cat > /dev/null; exit 0; fi

EVENTS_DIR="\${KANBAN_CODE_HOME:-$HOME/.kanban-code}"
EVENTS_FILE="\${EVENTS_DIR}/hook-events.jsonl"

# Ensure directory exists
mkdir -p "$EVENTS_DIR"

# Read the JSON payload from stdin
input=$(cat)

# Extract fields using lightweight parsing (no jq dependency)
session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

# Fallback: try sessionId (different hook formats)
if [ -z "$session_id" ]; then
    session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

# The CLI launcher exports KANBAN_SESSION_ID (the stable uuidv5 of the
# slug) into the session, so events correlate to the agent's card
# whatever id the runtime mints (Codex makes its own).
if [ -n "\${KANBAN_SESSION_ID:-}" ]; then
    session_id="$KANBAN_SESSION_ID"
fi

# Skip if we couldn't extract a session ID
[ -z "$session_id" ] && exit 0

# Get current timestamp
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# SessionStart carries a source (startup, resume, clear, compact) that
# tells a real fresh start apart from a compaction of a live session.
# Gated on the event name: other payloads can carry a "source" key
# inside user text or tool input, and that must not leak in here.
extra=""
if [ "$hook_event" = "SessionStart" ]; then
    start_source=$(echo "$input" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [ -n "$start_source" ]; then
        extra=",\\"source\\":\\"$start_source\\""
    fi
fi
# A Notification carries its type (permission_prompt, idle_prompt, ...)
# and text, and a UserPromptSubmit the prompt the CLI daemon mirrors once
# the agent got it; the whole payload goes along, base64 so quotes and
# newlines survive.
if [ "$hook_event" = "Notification" ] || [ "$hook_event" = "UserPromptSubmit" ]; then
    payload_b64=$(printf '%s' "$input" | base64 | tr -d '\\n')
    extra="$extra,\\"payloadB64\\":\\"$payload_b64\\""
fi

# Notification carries a type (permission_prompt, idle_prompt, ...) that
# tells a blocking permission prompt apart from an idle reminder.
if [ "$hook_event" = "Notification" ]; then
    notification_type=$(echo "$input" | grep -o '"notification_type":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [ -n "$notification_type" ]; then
        extra="$extra,\\"notificationType\\":\\"$notification_type\\""
    fi
fi

# SubagentStart and SubagentStop name the subagent, so a stop can be
# matched to its own start: Claude Code also sends stops with no start
# (after a Stop hook runs, for instance), which must not end the count
# of a background agent that is still working.
if [ "$hook_event" = "SubagentStart" ] || [ "$hook_event" = "SubagentStop" ]; then
    agent_id=$(echo "$input" | grep -o '"agent_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [ -n "$agent_id" ]; then
        extra="$extra,\\"agentId\\":\\"$agent_id\\""
    fi
fi

# Append event line
printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s"%s}\\n' \\
    "$session_id" "$hook_event" "$timestamp" "$transcript" "$extra" >> "$EVENTS_FILE"`;

/// Captures Claude Code's context/token usage per session into
/// <kanban-home>/context/<sessionId>.json after each assistant response.
const STATUSLINE_SCRIPT = `#!/usr/bin/env bash
# Kanban Code statusline - captures context/token usage per session.
set -euo pipefail

CONTEXT_DIR="\${KANBAN_CODE_HOME:-\$HOME/.kanban-code}/context"
mkdir -p "$CONTEXT_DIR"

input=$(cat)

session_id=$(echo "$input" | grep -oE '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$session_id" ] && exit 0

used_pct=$(echo "$input" | grep -oE '"used_percentage":[0-9.]+' | head -1 | cut -d: -f2)
ctx_size=$(echo "$input" | grep -oE '"context_window_size":[0-9]+' | head -1 | cut -d: -f2)
input_tokens=$(echo "$input" | grep -oE '"total_input_tokens":[0-9]+' | head -1 | cut -d: -f2)
output_tokens=$(echo "$input" | grep -oE '"total_output_tokens":[0-9]+' | head -1 | cut -d: -f2)
cost=$(echo "$input" | grep -oE '"total_cost_usd":[0-9.]+' | head -1 | cut -d: -f2)
model=$(echo "$input" | grep -oE '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)

tmp_file="\${CONTEXT_DIR}/.\${session_id}.tmp"
out_file="\${CONTEXT_DIR}/\${session_id}.json"
printf '{"usedPercentage":%s,"contextWindowSize":%s,"totalInputTokens":%s,"totalOutputTokens":%s,"totalCostUsd":%s,"model":"%s"}' \\
    "\${used_pct:-0}" "\${ctx_size:-0}" "\${input_tokens:-0}" "\${output_tokens:-0}" "\${cost:-0}" "\${model:-}" > "$tmp_file"
mv -f "$tmp_file" "$out_file"
printf ''
`;

export interface InstallHooksOptions {
  settingsPath?: string;
  hookScriptPath?: string;
  statuslinePath?: string;
}

export interface InstallHooksResult {
  settingsPath: string;
  hookScriptPath: string;
  statuslinePath: string;
  events: string[];
}

function deployScript(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  chmodSync(path, 0o755);
}

function readJson(path: string): Record<string, any> {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf-8")) ?? {};
  } catch {
    return {};
  }
}

/// Install Claude Code hooks + statusline for headless operation. Idempotent:
/// the hook command is added to each event only if not already present, and the
/// statusline is set only if not already ours. Mirrors HookManager.install.
export function installHooks(opts: InstallHooksOptions = {}): InstallHooksResult {
  const settingsPath = opts.settingsPath ?? claudeSettingsPath();
  const hookScriptPath = opts.hookScriptPath ?? defaultHookScriptPath();
  const statuslinePath = opts.statuslinePath ?? join(kanbanHome(), "statusline.sh");

  deployScript(hookScriptPath, HOOK_SCRIPT);
  deployScript(statuslinePath, STATUSLINE_SCRIPT);

  const root = readJson(settingsPath);
  const hooks = (root.hooks ?? {}) as Record<string, any[]>;
  const hookEntry = { type: "command", command: hookScriptPath };

  for (const event of HOOK_EVENTS) {
    const groups: any[] = Array.isArray(hooks[event]) ? hooks[event] : [];
    // Idempotent by exact script path (robust regardless of where the kanban
    // home lives), preserving any other tools' hooks already registered.
    const present = groups.some((g) =>
      (g?.hooks ?? []).some((h: any) => h?.command === hookScriptPath)
    );
    if (!present) {
      if (groups.length === 0) {
        groups.push({ matcher: "", hooks: [hookEntry] });
      } else {
        groups[0].hooks = [...(groups[0].hooks ?? []), hookEntry];
      }
    }
    hooks[event] = groups;
  }
  root.hooks = hooks;

  if (root.statusLine?.command !== statuslinePath) {
    root.statusLine = { type: "command", command: statuslinePath };
  }

  mkdirSync(dirname(settingsPath), { recursive: true });
  writeFileSync(settingsPath, sortedStringify(root));

  // NOTE: Codex hooks are intentionally NOT installed here. Codex 0.134.0 gates
  // command hooks behind an interactive trust prompt that --dangerously-bypass-
  // hook-trust does not reliably suppress in the inline TUI, which hangs the
  // headless session on a modal. Codex agents are instead steered via tmux
  // paste, so no Codex hooks are needed.
  // installCodexHooks() remains available for when Codex honors trust bypass.

  return { settingsPath, hookScriptPath, statuslinePath, events: HOOK_EVENTS };
}

export interface InstallCodexHooksOptions {
  hooksPath?: string;
  hookScriptPath?: string;
}

/// Install Codex hooks (~/.codex/hooks.json) pointing at the shared hook.sh.
/// Idempotent and additive: preserves any other registered hooks for each event.
export function installCodexHooks(opts: InstallCodexHooksOptions = {}): { hooksPath: string; events: string[] } {
  const hooksPath = opts.hooksPath ?? codexHooksPath();
  const hookScriptPath = opts.hookScriptPath ?? defaultHookScriptPath();
  deployScript(hookScriptPath, HOOK_SCRIPT);

  // Codex's hooks.json nests events under a top-level "hooks" key (mirrors the
  // config.toml [hooks] table); without the wrapper Codex ignores the file.
  const root = readJson(hooksPath);
  const hooks = (root.hooks ?? {}) as Record<string, any[]>;
  const hookEntry = { type: "command", command: hookScriptPath };
  for (const event of CODEX_HOOK_EVENTS) {
    const groups: any[] = Array.isArray(hooks[event]) ? hooks[event] : [];
    const present = groups.some((g) => (g?.hooks ?? []).some((h: any) => h?.command === hookScriptPath));
    if (!present) {
      if (groups.length === 0) groups.push({ hooks: [hookEntry] });
      else groups[0].hooks = [...(groups[0].hooks ?? []), hookEntry];
    }
    hooks[event] = groups;
  }
  root.hooks = hooks;

  mkdirSync(dirname(hooksPath), { recursive: true });
  writeFileSync(hooksPath, sortedStringify(root));
  return { hooksPath, events: CODEX_HOOK_EVENTS };
}

/// True if our hook script is registered for every required event.
export function areHooksInstalled(settingsPath?: string, hookScriptPath?: string): boolean {
  const root = readJson(settingsPath ?? claudeSettingsPath());
  const hooks = (root.hooks ?? {}) as Record<string, any[]>;
  const path = hookScriptPath ?? defaultHookScriptPath();
  return HOOK_EVENTS.every((event) =>
    (hooks[event] ?? []).some((g: any) => (g?.hooks ?? []).some((h: any) => h?.command === path))
  );
}
