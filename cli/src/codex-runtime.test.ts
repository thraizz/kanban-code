/**
 * Unit tests for the codex runtime: the runtime descriptor (arg building),
 * config parsing of the `runtime` field, codex hook installation, and that a
 * codex agent launches fresh (never tries Claude --resume) and tags its card.
 */
import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runtimeSpec, isRuntime } from "./agents/runtime.js";
import { trustCodexDirectory } from "./agents/codex-trust.js";
import { parseAgentsConfig } from "./agents/config.js";
import { agentIdentity } from "./agents/identity.js";
import { ensureAgentSession, nameStartedSession } from "./agents/launch.js";
import { installCodexHooks } from "./hooks.js";
import { readLinks } from "./data.js";

describe("runtime descriptor", () => {
  test("claude builds --session-id / --resume args", () => {
    const c = runtimeSpec("claude");
    assert.equal(c.bin, "claude");
    assert.equal(c.canResume, true);
    assert.equal(c.selfCompact, true);
    assert.deepEqual(
      c.buildArgs({ sessionId: "sid", slug: "agent", resume: false, skipPermissions: true, model: "opus" }),
      ["--session-id", "sid", "--name", "agent", "--dangerously-skip-permissions", "--model", "opus"]
    );
    assert.deepEqual(
      c.buildArgs({ sessionId: "sid", slug: "agent", resume: true, skipPermissions: true }),
      ["--resume", "sid", "--name", "agent", "--dangerously-skip-permissions"]
    );
  });

  test("codex builds inline + full-auto bypass args and never uses session-id", () => {
    const x = runtimeSpec("codex");
    assert.equal(x.bin, "codex");
    assert.equal(x.canResume, true);
    assert.equal(x.selfCompact, false);
    const args = x.buildArgs({ sessionId: "sid", slug: "agent", resume: false, skipPermissions: true, model: "gpt-5.5" });
    assert.deepEqual(args, [
      "--no-alt-screen",
      "--dangerously-bypass-approvals-and-sandbox",
      "--dangerously-bypass-hook-trust",
      "-m",
      "gpt-5.5",
    ]);
    assert.ok(!args.includes("--session-id"));
    assert.ok(!args.includes("--resume"));
  });

  test("codex resume keeps the global flags before the subcommand and uses resume --last", () => {
    const x = runtimeSpec("codex");
    const args = x.buildArgs({ sessionId: "sid", slug: "agent", resume: true, skipPermissions: true });
    assert.deepEqual(args, [
      "--no-alt-screen",
      "--dangerously-bypass-approvals-and-sandbox",
      "--dangerously-bypass-hook-trust",
      "resume",
      "--last",
    ]);
    // The bypass flags must precede the subcommand (they are global, not
    // resume-subcommand options), and no model is re-passed on resume.
    assert.ok(args.indexOf("--dangerously-bypass-approvals-and-sandbox") < args.indexOf("resume"));
    assert.ok(!args.includes("-m"));
  });

  test("codex names a started session, claude was named at launch", () => {
    assert.equal(runtimeSpec("codex").nameCommand?.("pr-reviewer"), "/rename pr-reviewer");
    assert.equal(runtimeSpec("claude").nameCommand, undefined);
  });

  test("isRuntime guards the union", () => {
    assert.ok(isRuntime("claude"));
    assert.ok(isRuntime("codex"));
    assert.ok(!isRuntime("gemini"));
    assert.ok(!isRuntime(undefined));
  });
});

describe("agents config runtime field", () => {
  test("defaults to claude and accepts codex", () => {
    const f = parseAgentsConfig(`agents:\n  - slug: a\n    repos: ["acme/x"]\n  - slug: b\n    runtime: codex\n    repos: ["acme/y"]\n`);
    assert.equal(f.agents[0].runtime, "claude");
    assert.equal(f.agents[1].runtime, "codex");
  });

  test("rejects an unknown runtime", () => {
    assert.throws(
      () => parseAgentsConfig(`agents:\n  - slug: a\n    runtime: gemini\n    repos: []\n`),
      /invalid runtime/
    );
  });
});

describe("installCodexHooks", () => {
  let codexHome: string;
  beforeEach(() => {
    codexHome = mkdtempSync(join(tmpdir(), "kanban-codex-"));
  });
  afterEach(() => rmSync(codexHome, { recursive: true, force: true }));

  test("writes hooks.json pointing at the shared hook.sh, idempotently", () => {
    const hooksPath = join(codexHome, "hooks.json");
    const hookScriptPath = join(codexHome, "hook.sh");
    const r = installCodexHooks({ hooksPath, hookScriptPath });
    assert.deepEqual(r.events, ["SessionStart", "UserPromptSubmit", "Stop"]);
    const json = JSON.parse(readFileSync(hooksPath, "utf-8"));
    // Codex requires the top-level "hooks" wrapper.
    assert.ok(json.hooks, "events must be nested under a top-level hooks key");
    for (const ev of r.events) {
      assert.equal(json.hooks[ev][0].hooks[0].command, hookScriptPath);
    }
    // Re-install does not duplicate the entry.
    installCodexHooks({ hooksPath, hookScriptPath });
    const json2 = JSON.parse(readFileSync(hooksPath, "utf-8"));
    assert.equal(json2.hooks.Stop[0].hooks.length, 1);
  });
});

function hasTmux(): boolean {
  try { execSync("tmux -V", { stdio: "ignore" }); return true; } catch { return false; }
}

describe("trusting the workspace before the runtime asks about it", () => {
  let home: string;
  let configPath: string;

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-codex-trust-"));
    configPath = join(home, "config.toml");
  });
  afterEach(() => rmSync(home, { recursive: true, force: true }));

  test("records the workspace as trusted, in the table codex writes itself", () => {
    assert.equal(trustCodexDirectory("/home/ubuntu/agent-workspaces/pr-reviewer", configPath), true);
    assert.equal(
      readFileSync(configPath, "utf-8"),
      '\n[projects."/home/ubuntu/agent-workspaces/pr-reviewer"]\ntrust_level = "trusted"\n'
    );
  });

  test("keeps what the config already held, and starts its own table", () => {
    writeFileSync(configPath, '[otel]\nenabled = true\n');
    trustCodexDirectory("/w/pr-reviewer", configPath);
    const written = readFileSync(configPath, "utf-8");
    assert.match(written, /^\[otel\]\nenabled = true\n/);
    // A table of its own, so nothing above it is read as part of this one.
    assert.match(written, /\n\[projects\."\/w\/pr-reviewer"\]\ntrust_level = "trusted"\n$/);
  });

  test("leaves an answer the operator already gave", () => {
    writeFileSync(configPath, '[projects."/w/pr-reviewer"]\ntrust_level = "untrusted"\n');
    assert.equal(trustCodexDirectory("/w/pr-reviewer", configPath), false);
    // Overwriting it would undo a deliberate choice.
    assert.match(readFileSync(configPath, "utf-8"), /trust_level = "untrusted"/);
    assert.doesNotMatch(readFileSync(configPath, "utf-8"), /trust_level = "trusted"/);
  });

  test("writes one entry however many times a workspace is launched", () => {
    assert.equal(trustCodexDirectory("/w/pr-reviewer", configPath), true);
    assert.equal(trustCodexDirectory("/w/pr-reviewer", configPath), false);
    const headers = readFileSync(configPath, "utf-8").match(/\[projects\./g) ?? [];
    assert.equal(headers.length, 1);
  });

  test("quotes a path that would otherwise break the table header", () => {
    trustCodexDirectory('/w/od"d\\one', configPath);
    assert.match(readFileSync(configPath, "utf-8"), /\[projects\."\/w\/od\\"d\\\\one"\]/);
  });

  test("codex settles its workspace, claude has nothing to settle", () => {
    assert.equal(typeof runtimeSpec("codex").prepareWorkspace, "function");
    assert.equal(runtimeSpec("claude").prepareWorkspace, undefined);
  });
});

describe("naming a session the runtime takes no launch flag for", () => {
  const BANNER = "  >_ OpenAI Codex (v0.149.0)\n  Tip: Try the Desktop app.";
  const TRUST = `${BANNER}\n› 1. Yes, continue\n  2. No, quit\n  Press enter to continue`;
  const COMPOSER = `${BANNER}\n› Ask Codex to do anything\n  gpt-5.6-sol low · /home/ubuntu/agent-workspaces/pr-reviewer`;
  const RENAMED = `${BANNER}\n• Session renamed to pr-reviewer.\n› Ask Codex to do anything\n  gpt-5.6-sol low · /home/ubuntu/agent-workspaces/pr-reviewer`;

  /// A pane driven by a script of frames: one read per call, the last frame
  /// repeating, which is how a runtime stuck on one screen is expressed.
  /// Typed text takes `drawAfter` reads to appear, the way a real TUI renders
  /// its own keystrokes a beat late, and stays in the composer until an Enter
  /// the runtime actually accepted. `dropEnters` is a runtime still loading a
  /// resumed session, which swallows that many before it listens.
  function fakeIo(
    frames: string[],
    opts: {
      alive?: boolean;
      submits?: boolean;
      after?: string;
      drawAfter?: number;
      dropEnters?: number;
    } = {}
  ) {
    const typed: string[] = [];
    const enters: number[] = [];
    let clock = 0;
    let read = 0;
    let composer: string | null = null;
    let readsSinceTyped = 0;
    let dropped = 0;
    let submitted = false;
    const pane = () => {
      const frame = submitted
        ? (opts.after ?? RENAMED)
        : frames[Math.min(read++, frames.length - 1)];
      if (composer === null) return frame;
      const drawn = readsSinceTyped++ >= (opts.drawAfter ?? 0);
      return drawn ? `${frame}\n› ${composer}` : frame;
    };
    return {
      typed,
      enters,
      elapsed: () => clock,
      io: {
        capture: () => pane(),
        type: (_tmuxName: string, text: string) => {
          typed.push(text);
          composer = text;
          readsSinceTyped = 0;
          return { ok: true };
        },
        enter: (_tmuxName: string) => {
          enters.push(clock);
          if (dropped++ < (opts.dropEnters ?? 0)) return { ok: true };
          if (opts.submits ?? true) {
            composer = null;
            submitted = true;
          }
          return { ok: true };
        },
        alive: () => opts.alive ?? true,
        sleep: (ms: number) => {
          clock += ms;
        },
        now: () => clock,
      },
    };
  }

  test("waits for the composer, then renames the thread to the slug", () => {
    const { io, typed, enters } = fakeIo([BANNER, BANNER, COMPOSER]);
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    assert.equal(named, true);
    assert.deepEqual(typed, ["/rename pr-reviewer"]);
    assert.equal(enters.length, 1);
  });

  test("submits the command with its own keystroke, not alongside the text", () => {
    // Sent together, a TUI reads the newline as pasted text and the command
    // sits unrun in the composer.
    const { io, enters } = fakeIo([COMPOSER]);
    nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    assert.equal(enters.length, 1);
  });

  test("reports a command that stayed in the composer as unnamed", () => {
    const { io, typed } = fakeIo([COMPOSER], { submits: false });
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    // The keys went out and the runtime kept them: the session has no name,
    // and saying otherwise would send an operator looking in the wrong place.
    assert.deepEqual(typed, ["/rename pr-reviewer"]);
    assert.equal(named, false);
  });

  test("waits for its own keystrokes to be drawn before reading the answer", () => {
    // A pane that has not drawn the command yet looks exactly like one that
    // has already run it. Reading too early called an unnamed session named,
    // which is what happened on a box: the command sat in the composer of a
    // live agent while the launch reported success.
    const { io, typed } = fakeIo([COMPOSER], { drawAfter: 3, submits: false });
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    assert.deepEqual(typed, ["/rename pr-reviewer"]);
    assert.equal(named, false);
  });

  test("presses Enter again for a runtime that dropped the first one", () => {
    // A codex still loading a resumed session swallows the first Enter with
    // no sign of it.
    const { io, enters, typed } = fakeIo([COMPOSER], { dropEnters: 2 });
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    assert.equal(named, true);
    assert.equal(enters.length, 3);
    // Retrying must never type the command a second time.
    assert.deepEqual(typed, ["/rename pr-reviewer"]);
  });

  test("gives up rather than pressing Enter forever", () => {
    const { io, enters } = fakeIo([COMPOSER], { submits: false });
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex") },
      io
    );
    assert.equal(named, false);
    assert.equal(enters.length, 4);
  });

  test("types nothing into the directory-trust question", () => {
    const { io, typed, elapsed } = fakeIo([TRUST]);
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex"), timeoutMs: 2_000 },
      io
    );
    // Answering it with a rename would pick one of its options at random.
    assert.equal(named, false);
    assert.deepEqual(typed, []);
    assert.ok(elapsed() >= 2_000);
  });

  test("gives up as soon as the session is gone, rather than waiting it out", () => {
    const { io, typed, elapsed } = fakeIo([BANNER], { alive: false });
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex"), timeoutMs: 60_000 },
      io
    );
    assert.equal(named, false);
    assert.deepEqual(typed, []);
    assert.equal(elapsed(), 0);
  });

  test("sends nothing for a runtime that was named at launch", () => {
    const { io, typed } = fakeIo([COMPOSER]);
    const named = nameStartedSession(
      { tmuxName: "docs-writer", slug: "docs-writer", spec: runtimeSpec("claude") },
      io
    );
    assert.equal(named, false);
    assert.deepEqual(typed, []);
  });

  test("reads the marker off the last line, so scrollback cannot pass for ready", () => {
    // The status line of the session BEFORE this one, still in the scrollback
    // above a fresh banner.
    const stale = `  gpt-5.6-sol low · /home/ubuntu/agent-workspaces/pr-reviewer\n${BANNER}`;
    const { io, typed } = fakeIo([stale]);
    const named = nameStartedSession(
      { tmuxName: "pr-reviewer", slug: "pr-reviewer", spec: runtimeSpec("codex"), timeoutMs: 1_000 },
      io
    );
    assert.equal(named, false);
    assert.deepEqual(typed, []);
  });
});

describe("codex agent launch (real tmux)", { skip: !hasTmux() }, () => {
  let home: string;
  let workspace: string;
  const slug = `kanban-codex-test-${Date.now()}`;
  const identity = agentIdentity(slug, "codex");

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-codex-home-"));
    workspace = mkdtempSync(join(tmpdir(), "kanban-codex-ws-"));
    process.env.KANBAN_CODE_HOME = home;
  });
  afterEach(() => {
    try { execSync(`tmux kill-session -t ${identity.tmuxName}`, { stdio: "ignore" }); } catch {}
    delete process.env.KANBAN_CODE_HOME;
    rmSync(home, { recursive: true, force: true });
    rmSync(workspace, { recursive: true, force: true });
  });

  test("launches codex fresh (no resume) and tags the card assistant=codex", () => {
    // nameTimeoutMs 0: `true` is not codex, so it never draws the status line
    // the rename waits for, and this test is about the launch, not the name.
    const launch = { cwd: workspace, bin: "true", nameTimeoutMs: 0 };
    const result = ensureAgentSession(identity, launch);
    assert.equal(result.action, "launched");
    assert.match(result.command!, /true --no-alt-screen --dangerously-bypass-approvals-and-sandbox/);
    assert.equal(result.named, false);
    const card = readLinks().find((l) => l.name === slug);
    assert.equal(card?.assistant, "codex");
    // A second reconcile is a no-op while the session is alive.
    const again = ensureAgentSession(identity, launch);
    assert.equal(again.action, "noop-running");
  });
});
