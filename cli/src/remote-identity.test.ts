/**
 * Caller identity on a remote card. The machine has no board, so the tmux
 * session there tells the CLI which card it is with KANBAN_CARD_ID, and the Mac
 * passes the same variable when it runs a proxied command.
 */

import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import { cardFromEnvironment } from "./broadcast.js";
import { currentCardOrThrow } from "./subagents.js";
import type { Link } from "./types.js";

const CLI = resolve(import.meta.dirname, "kanban.ts");

let home: string;

function runCli(
  args: string[],
  env: NodeJS.ProcessEnv = {}
): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execFileSync("npx", ["tsx", CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, TMUX: undefined, KANBAN_CARD_ID: undefined, ...env },
    });
    return { stdout, stderr: "", code: 0 };
  } catch (e: any) {
    return { stdout: String(e.stdout ?? ""), stderr: String(e.stderr ?? ""), code: e.status ?? 1 };
  }
}

function card(id: string, name: string, sessionName: string): Record<string, unknown> {
  return {
    id,
    name,
    column: "in_progress",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    tmuxLink: { sessionName },
    isRemote: true,
    remote: { mode: "boxd", machineName: "vm-1" },
    prLinks: [],
    manualOverrides: {},
    source: "manual",
    manuallyArchived: false,
  };
}

function seedLinks(links: unknown[]): void {
  const dir = join(home, ".kanban-code");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "links.json"), JSON.stringify({ links }, null, 2));
}

function seedFakeTmux(sessionName: string): { binDir: string; logPath: string } {
  const binDir = join(home, "bin");
  const logPath = join(home, "tmux.log");
  mkdirSync(binDir, { recursive: true });
  const tmuxPath = join(binDir, "tmux");
  writeFileSync(
    tmuxPath,
    `#!/bin/sh
printf '%s\\n' "$*" >> "$TMUX_LOG"
if [ "$1" = "display-message" ]; then
  printf '%s\\n' "${sessionName}"
  exit 0
fi
exit 0
`
  );
  chmodSync(tmuxPath, 0o755);
  return { binDir, logPath };
}

/**
 * The detached self-compact shell sleeps before it drives tmux, so the log
 * fills in after the CLI already exited. Poll it until the last expected line
 * arrives instead of guessing a wall-clock wait.
 */
function waitForLog(logPath: string, pattern: RegExp, timeoutSeconds = 20): string {
  const deadline = Date.now() + timeoutSeconds * 1000;
  let log = "";
  for (;;) {
    try {
      log = readFileSync(logPath, "utf-8");
    } catch {
      log = "";
    }
    if (pattern.test(log) || Date.now() >= deadline) return log;
    execFileSync("sleep", ["0.1"]);
  }
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-remote-identity-"));
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

describe("cardFromEnvironment", () => {
  const links = [
    { id: "card-a", name: "a" } as unknown as Link,
    { id: "card-b", name: "b" } as unknown as Link,
  ];

  test("picks the card named by KANBAN_CARD_ID", () => {
    assert.equal(cardFromEnvironment(links, { KANBAN_CARD_ID: "card-b" })?.id, "card-b");
  });

  test("says nothing when the variable is missing or unknown", () => {
    assert.equal(cardFromEnvironment(links, {}), undefined);
    assert.equal(cardFromEnvironment(links, { KANBAN_CARD_ID: "  " }), undefined);
    assert.equal(cardFromEnvironment(links, { KANBAN_CARD_ID: "card-z" }), undefined);
  });
});

describe("currentCardOrThrow", () => {
  const links = [
    { id: "card-a", name: "a", tmuxLink: { sessionName: "sess-a" } } as unknown as Link,
  ];

  test("uses KANBAN_CARD_ID before any tmux lookup", () => {
    const previous = process.env.KANBAN_CARD_ID;
    process.env.KANBAN_CARD_ID = "card-a";
    try {
      assert.equal(currentCardOrThrow(links).id, "card-a");
    } finally {
      if (previous === undefined) delete process.env.KANBAN_CARD_ID;
      else process.env.KANBAN_CARD_ID = previous;
    }
  });

  test("still needs a tmux session without the variable", () => {
    const previous = { tmux: process.env.TMUX, card: process.env.KANBAN_CARD_ID };
    delete process.env.TMUX;
    delete process.env.KANBAN_CARD_ID;
    try {
      assert.throws(() => currentCardOrThrow(links), /Could not detect the current tmux session/);
    } finally {
      if (previous.tmux !== undefined) process.env.TMUX = previous.tmux;
      if (previous.card !== undefined) process.env.KANBAN_CARD_ID = previous.card;
    }
  });
});

describe("channel identity outside tmux", () => {
  test("joins as the card named by KANBAN_CARD_ID", () => {
    seedLinks([card("card_alice", "alice-card", "kc-remote")]);
    runCli(["channel", "create", "general", "--as-user"], { HOME: home });

    let r = runCli(["channel", "join", "general", "--as", "alice"], {
      HOME: home,
      KANBAN_CARD_ID: "card_alice",
    });
    assert.equal(r.code, 0, r.stderr);

    r = runCli(["channel", "members", "general", "--json"], { HOME: home });
    const members = JSON.parse(r.stdout);
    assert.equal(members.find((m: any) => m.handle === "alice")?.cardId, "card_alice");
  });

  test("derives the handle from the card when no --as is given", () => {
    seedLinks([card("card_alice", "alice-card", "kc-remote")]);
    runCli(["channel", "create", "general", "--as-user"], { HOME: home });

    let r = runCli(["channel", "join", "general"], { HOME: home, KANBAN_CARD_ID: "card_alice" });
    assert.equal(r.code, 0, r.stderr);

    r = runCli(["channel", "members", "general", "--json"], { HOME: home });
    const members = JSON.parse(r.stdout);
    assert.ok(
      members.some((m: any) => m.cardId === "card_alice"),
      r.stdout
    );
  });

  test("still refuses an unknown caller without the variable", () => {
    seedLinks([card("card_alice", "alice-card", "kc-remote")]);
    runCli(["channel", "create", "general", "--as-user"], { HOME: home });
    const r = runCli(["channel", "join", "general"], { HOME: home });
    assert.notEqual(r.code, 0);
    assert.match(r.stderr + r.stdout, /Could not detect your tmux session/);
  });
});

describe("self-compact identity outside tmux", () => {
  test("compacts the session of the card named by KANBAN_CARD_ID", () => {
    const sessionName = "sess-remote";
    seedLinks([
      {
        ...card("card_self", "self card", sessionName),
        isRemote: false,
        remote: undefined,
      },
    ]);
    const { binDir, logPath } = seedFakeTmux(sessionName);
    const r = runCli(["self-compact", "--follow-up-delay", "0.1", "Continue", "later."], {
      HOME: home,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      TMUX_LOG: logPath,
      KANBAN_CARD_ID: "card_self",
    });
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /Sent \/compact to sess-remote/);

    const log = waitForLog(logPath, /set-buffer -b kc-\d+-\d+ -- \[Self-compact follow-up from this card\]: Continue later\./);
    assert.match(log, /send-keys -t sess-remote Escape/);
    assert.match(log, /set-buffer -b kc-\d+-\d+ -- \/compact/);
    assert.match(log, /set-buffer -b kc-\d+-\d+ -- \[Self-compact follow-up from this card\]: Continue later\./);
  });
});
