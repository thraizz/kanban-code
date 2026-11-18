import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { installHooks, areHooksInstalled, HOOK_EVENTS, HOOK_SCRIPT } from "./hooks.js";

describe("hook installer (sandboxed)", () => {
  let home: string;
  let claudeDir: string;
  let settings: string;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-hooks-home-"));
    claudeDir = mkdtempSync(join(tmpdir(), "kanban-hooks-claude-"));
    settings = join(claudeDir, "settings.json");
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = claudeDir;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
    rmSync(claudeDir, { recursive: true, force: true });
  });

  test("registers all events + statusline and deploys executable scripts", () => {
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    for (const event of HOOK_EVENTS) {
      const cmds = root.hooks[event].flatMap((g: any) => g.hooks.map((h: any) => h.command));
      assert.ok(cmds.includes(r.hookScriptPath), `${event} missing hook`);
    }
    assert.equal(root.statusLine.command, r.statuslinePath);
    assert.ok(areHooksInstalled(undefined, r.hookScriptPath));
    // scripts exist and are executable
    assert.ok(statSync(r.hookScriptPath).mode & 0o111);
    assert.ok(statSync(r.statuslinePath).mode & 0o111);
  });

  test("is idempotent: no duplicate hook entries on repeat install", () => {
    installHooks();
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    const stopHooks = root.hooks.Stop.flatMap((g: any) => g.hooks).filter(
      (h: any) => h.command === r.hookScriptPath
    );
    assert.equal(stopHooks.length, 1);
  });

  test("preserves unrelated settings and pre-existing hooks", () => {
    mkdirSync(claudeDir, { recursive: true });
    writeFileSync(
      settings,
      JSON.stringify({
        model: "opus",
        hooks: { Stop: [{ matcher: "", hooks: [{ type: "command", command: "/other/tool.sh" }] }] },
      })
    );
    const r = installHooks();
    const root = JSON.parse(readFileSync(settings, "utf-8"));
    assert.equal(root.model, "opus");
    const stopCmds = root.hooks.Stop.flatMap((g: any) => g.hooks.map((h: any) => h.command));
    assert.ok(stopCmds.includes("/other/tool.sh"), "pre-existing hook preserved");
    assert.ok(stopCmds.includes(r.hookScriptPath), "ours added");
  });
});

/// The app's HookManager.swift writes the same hook.sh to the same path, and
/// the Mac's machine bootstrap runs `kanban hooks install`: the copy written
/// last wins. A CLI copy without the subagent id once left a finished
/// background agent counted as running, holding its card in In Progress.
describe("hook script parity with the app", () => {
  test("is the exact text HookManager.swift writes", () => {
    const swiftPath = join(
      import.meta.dirname, "..", "..",
      "Sources", "KanbanCodeCore", "Adapters", "ClaudeCode", "HookManager.swift"
    );
    const source = readFileSync(swiftPath, "utf-8");
    const open = 'static let hookScriptContent = """\n';
    const start = source.indexOf(open);
    assert.ok(start >= 0, "hookScriptContent not found in HookManager.swift");
    const bodyStart = start + open.length;
    const end = source.indexOf('\n    """', bodyStart);
    const swiftScript = source
      .slice(bodyStart, end)
      .split("\n")
      .map((line) => line.replace(/^ {4}/, ""))
      .join("\n")
      .replace(/\\(.)/g, "$1");
    assert.equal(HOOK_SCRIPT, swiftScript);
  });
});

describe("hook script events (sandboxed)", () => {
  let home: string;
  let claudeDir: string;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-hooks-home-"));
    claudeDir = mkdtempSync(join(tmpdir(), "kanban-hooks-claude-"));
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = claudeDir;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
    rmSync(claudeDir, { recursive: true, force: true });
  });

  function run(script: string, payload: object): void {
    const r = spawnSync("/bin/bash", [script], {
      input: JSON.stringify(payload),
      env: { PATH: "/usr/bin:/bin", HOME: home, KANBAN_CODE_HOME: home },
    });
    assert.equal(r.status, 0, r.stderr.toString());
  }

  test("records subagent ids and the prompt payload", () => {
    const { hookScriptPath } = installHooks();
    run(hookScriptPath, { session_id: "s1", hook_event_name: "SubagentStart", transcript_path: "/t.jsonl", agent_id: "a1" });
    run(hookScriptPath, { session_id: "s1", hook_event_name: "SubagentStop", transcript_path: "/t.jsonl", agent_id: "a1" });
    run(hookScriptPath, { session_id: "s1", hook_event_name: "UserPromptSubmit", transcript_path: "/t.jsonl", prompt: 'say "hi"\nthen stop' });
    run(hookScriptPath, { session_id: "s1", hook_event_name: "Notification", transcript_path: "/t.jsonl", notification_type: "permission_prompt" });

    const lines = readFileSync(join(home, "hook-events.jsonl"), "utf-8").trim().split("\n").map((l) => JSON.parse(l));
    assert.deepEqual(lines.map((l) => l.agentId), ["a1", "a1", undefined, undefined]);
    const prompt = JSON.parse(Buffer.from(lines[2].payloadB64, "base64").toString("utf-8")).prompt;
    assert.equal(prompt, 'say "hi"\nthen stop');
    assert.equal(lines[3].notificationType, "permission_prompt");
    assert.ok(lines[3].payloadB64, "the notification keeps its payload next to its type");
  });
});
