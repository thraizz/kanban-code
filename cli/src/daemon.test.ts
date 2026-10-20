import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Daemon, DEFAULT_SELF_COMPACT_RULES } from "./agents/daemon.js";
import { writeLinks, isoNow } from "./cards.js";
import { readLinks } from "./data.js";
import { hookEventsPath, contextDir } from "./paths.js";
import type { Link, QueuedPrompt } from "./types.js";

const SID = "11111111-1111-5111-8111-111111111111";

function card(queued: QueuedPrompt[] = []): Link {
  const now = isoNow();
  return {
    id: "card_d",
    name: "daemon-agent",
    column: "in_progress",
    createdAt: now,
    updatedAt: now,
    manualOverrides: { worktreePath: false, tmuxSession: false, name: true, column: false, prLink: false, issueLink: false },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    sessionLink: { sessionId: SID },
    tmuxLink: { sessionName: "daemon-agent" },
    queuedPrompts: queued,
  };
}

function writeContextPct(pct: number, windowSize = 1_000_000): void {
  mkdirSync(contextDir(), { recursive: true });
  writeFileSync(
    join(contextDir(), `${SID}.json`),
    JSON.stringify({ usedPercentage: pct, contextWindowSize: windowSize, totalInputTokens: 0, totalOutputTokens: 0, totalCostUsd: 0, model: "x" })
  );
}

describe("daemon (sandboxed, injected paste)", () => {
  let home: string;
  let pastes: [string, string][];
  let interrupts: [string, string][];
  function newDaemon() {
    return new Daemon({
      selfCompact: { enabled: true },
      paste: (s, t) => pastes.push([s, t]),
      interrupt: (s, t) => interrupts.push([s, t]),
    });
  }

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-daemon-"));
    process.env.KANBAN_CODE_HOME = home;
    process.env.CLAUDE_CONFIG_DIR = join(home, "claude");
    pastes = [];
    interrupts = [];
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(home, { recursive: true, force: true });
  });

  test("auto-sends an eligible queued prompt on Stop and dequeues it", () => {
    writeLinks([card([{ id: "p1", body: "continue the work", sendAutomatically: true }])]);
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, true);
    assert.deepEqual(pastes, [["daemon-agent", "continue the work"]]);
    assert.equal(readLinks()[0].queuedPrompts?.length, 0);
  });

  test("does not auto-send a non-auto prompt", () => {
    writeLinks([card([{ id: "p1", body: "manual only", sendAutomatically: false }])]);
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, false);
    assert.equal(r.reason, "no-eligible");
    assert.equal(pastes.length, 0);
  });

  test("a user prompt after the Stop pauses auto-send", () => {
    writeLinks([card([{ id: "p1", body: "go", sendAutomatically: true }])]);
    const d = newDaemon();
    const stopMs = Date.now();
    // A UserPromptSubmit recorded after the stop should block the send.
    appendFileSync(
      hookEventsPath(),
      JSON.stringify({ sessionId: SID, event: "UserPromptSubmit", timestamp: new Date(stopMs + 200).toISOString() }) + "\n"
    );
    d.processEvents();
    const r = d.maybeAutoSend(SID, stopMs);
    assert.equal(r.sent, false);
    assert.equal(r.reason, "user-prompted");
    assert.equal(pastes.length, 0);
  });

  test("drops a stale self-compact warning instead of sending it", () => {
    const warning = DEFAULT_SELF_COMPACT_RULES[0].message; // the 500k warning
    writeLinks([card([{ id: "p1", body: warning, sendAutomatically: true }])]);
    writeContextPct(10); // 100k tokens -> below 500k -> stale
    const r = newDaemon().maybeAutoSend(SID, Date.now());
    assert.equal(r.sent, false);
    assert.equal(r.reason, "dropped-stale");
    assert.equal(pastes.length, 0);
    assert.equal(readLinks()[0].queuedPrompts?.length, 0, "stale warning dropped from queue");
  });

  test("auto-compact queues the crossed warning once (no re-queue)", () => {
    writeLinks([card()]);
    writeContextPct(55); // 550k -> crosses 500k queuePrompt rule
    const d = newDaemon();
    const acted = d.evaluateAutoCompact();
    assert.deepEqual(acted, [{ sessionId: SID, action: "queuePrompt", thresholdTokens: 500_000 }]);
    assert.equal(readLinks()[0].queuedPrompts?.[0].body, DEFAULT_SELF_COMPACT_RULES[0].message);

    const again = d.evaluateAutoCompact();
    assert.equal(again.length, 0, "must not re-trigger the same threshold");
    assert.equal(readLinks()[0].queuedPrompts?.length, 1, "no duplicate queued warning");
  });

  test("auto-compact interrupts with /compact at the hard threshold", () => {
    writeLinks([card()]);
    writeContextPct(80); // 800k -> crosses the 750k interrupt rule
    const acted = newDaemon().evaluateAutoCompact();
    assert.deepEqual(acted, [{ sessionId: SID, action: "interrupt", thresholdTokens: 750_000 }]);
    assert.deepEqual(interrupts, [["daemon-agent", "/compact"]]);
    assert.deepEqual(pastes, [], "an interrupt must not also steer");
  });

  test("the steer threshold pastes without stopping the turn", () => {
    writeLinks([card()]);
    writeContextPct(72); // 720k -> crosses the 700k steer rule
    const acted = newDaemon().evaluateAutoCompact();
    assert.deepEqual(acted, [{ sessionId: SID, action: "steer", thresholdTokens: 700_000 }]);
    assert.deepEqual(pastes, [["daemon-agent", DEFAULT_SELF_COMPACT_RULES[2].message]]);
    assert.deepEqual(interrupts, []);
  });

  test("settings saved before the split still steer", () => {
    writeLinks([card()]);
    writeContextPct(80);
    const daemon = new Daemon({
      selfCompact: {
        enabled: true,
        rules: [{ thresholdTokens: 750_000, action: "compactNow" as never, message: "/compact" }],
      },
      paste: (s, t) => pastes.push([s, t]),
      interrupt: (s, t) => interrupts.push([s, t]),
    });

    const acted = daemon.evaluateAutoCompact();

    assert.deepEqual(acted, [{ sessionId: SID, action: "steer", thresholdTokens: 750_000 }]);
    assert.deepEqual(pastes, [["daemon-agent", "/compact"]]);
    assert.deepEqual(interrupts, []);
  });

  test("card threshold overrides a disabled global guard and queues ahead of user work", () => {
    const child = card([{ id: "user-work", body: "continue queued work", sendAutomatically: true }]);
    child.selfCompactContextThresholdTokens = 250_000;
    writeLinks([child]);
    writeContextPct(25);
    const daemon = new Daemon({
      selfCompact: { enabled: false },
      paste: (session, text) => pastes.push([session, text]),
    });

    const acted = daemon.evaluateAutoCompact();

    assert.deepEqual(acted, [{ sessionId: SID, action: "queuePrompt", thresholdTokens: 250_000 }]);
    const queue = readLinks()[0].queuedPrompts ?? [];
    assert.equal(queue[0].selfCompactThresholdTokens, 250_000);
    assert.match(queue[0].body, /passing an argument for the post-compact message on how to continue/);
    assert.equal(queue[1].id, "user-work");
  });

  test("card threshold forces compact exactly 200k above its nudge", () => {
    const child = card();
    child.selfCompactContextThresholdTokens = 250_000;
    writeLinks([child]);
    writeContextPct(45);
    const daemon = new Daemon({
      selfCompact: { enabled: false },
      paste: (session, text) => pastes.push([session, text]),
      interrupt: (session, text) => interrupts.push([session, text]),
    });

    const acted = daemon.evaluateAutoCompact();

    assert.deepEqual(acted, [{ sessionId: SID, action: "interrupt", thresholdTokens: 450_000 }]);
    assert.deepEqual(interrupts, [["daemon-agent", "/compact"]]);
  });

  test("card threshold is ignored for assistants without Claude context telemetry", () => {
    const child = card([
      {
        id: "compact-warning",
        body: "old compact warning",
        sendAutomatically: true,
        selfCompactThresholdTokens: 250_000,
      },
      { id: "user-work", body: "continue queued work", sendAutomatically: true },
    ]);
    child.assistant = "gemini";
    child.selfCompactContextThresholdTokens = 250_000;
    writeLinks([child]);
    writeContextPct(45);
    const daemon = new Daemon({
      selfCompact: { enabled: false },
      paste: (session, text) => pastes.push([session, text]),
    });

    assert.deepEqual(daemon.evaluateAutoCompact(), []);
    assert.deepEqual(pastes, []);
    assert.deepEqual(readLinks()[0].queuedPrompts?.map((prompt) => prompt.id), ["user-work"]);
  });

  test("changing a card threshold clears its old warning without replaying crossed rules", () => {
    const child = card();
    child.selfCompactContextThresholdTokens = 250_000;
    writeLinks([child]);
    writeContextPct(25);
    const daemon = newDaemon();
    daemon.evaluateAutoCompact();
    assert.equal(readLinks()[0].queuedPrompts?.[0].selfCompactThresholdTokens, 250_000);

    const updated = readLinks()[0];
    updated.selfCompactContextThresholdTokens = 200_000;
    writeLinks([updated]);

    assert.deepEqual(daemon.evaluateAutoCompact(), []);
    assert.equal(readLinks()[0].queuedPrompts?.length, 0);
  });

  test("reads appended hook events incrementally", () => {
    const d = newDaemon();
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "SessionStart", timestamp: isoNow() }) + "\n");
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "Stop", timestamp: isoNow() }) + "\n");
    assert.equal(d.readNewHookEvents().length, 2);
    assert.equal(d.readNewHookEvents().length, 0, "offset advanced; nothing new");
    appendFileSync(hookEventsPath(), JSON.stringify({ sessionId: SID, event: "Stop", timestamp: isoNow() }) + "\n");
    assert.equal(d.readNewHookEvents().length, 1);
  });
});
