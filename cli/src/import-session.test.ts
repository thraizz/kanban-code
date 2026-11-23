/**
 * `kanban import`: finds the session to move onto the board, from an argument
 * or from the Claude Code this command runs under.
 */

import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import { enclosingClaudeSessionId, importMessage, ownClaudeSessionId, sessionIdIn } from "./import-session.js";

const ID = "854054b6-24ff-45e2-bdb9-8feb1f70caf1";

describe("sessionIdIn", () => {
  test("finds the id in a bare id, a resume line and a transcript path", () => {
    assert.equal(sessionIdIn(ID.toUpperCase()), ID);
    assert.equal(sessionIdIn(`claude --resume ${ID}`), ID);
    assert.equal(sessionIdIn(`/Users/me/.claude/projects/-Users-me-repo/${ID}.jsonl`), ID);
    assert.equal(sessionIdIn("854054b6-24ff"), undefined);
  });
});

describe("enclosingClaudeSessionId", () => {
  let dir: string;
  // shell 300 → claude 200 → terminal 100
  const parents: Record<number, number> = { 300: 200, 200: 100 };
  const parentOf = (pid: number) => parents[pid];

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "kanban-import-"));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  test("is the session of the nearest Claude process above the command", () => {
    writeFileSync(join(dir, "200.json"), JSON.stringify({ pid: 200, sessionId: ID, kind: "interactive" }));
    assert.equal(enclosingClaudeSessionId(300, dir, parentOf), ID);
  });

  test("skips a headless run and a file left by another process", () => {
    writeFileSync(join(dir, "300.json"), JSON.stringify({ pid: 300, sessionId: "x", kind: "print" }));
    writeFileSync(join(dir, "200.json"), JSON.stringify({ pid: 999, sessionId: ID }));
    assert.equal(enclosingClaudeSessionId(300, dir, parentOf), undefined);
  });

  test("is undefined outside Claude Code", () => {
    assert.equal(enclosingClaudeSessionId(300, dir, parentOf), undefined);
  });
});

describe("ownClaudeSessionId", () => {
  test("takes the id Claude Code gives its shells, else walks up to the Claude process", () => {
    assert.equal(ownClaudeSessionId({ CLAUDE_CODE_SESSION_ID: ID }, () => "walked"), ID);
    assert.equal(ownClaudeSessionId({}, () => "walked"), "walked");
  });
});

describe("importMessage", () => {
  test("tells a session still open in a terminal to be quit there", () => {
    assert.match(importMessage("waiting", ID, "card_1"), /quit it there \(\/exit\)/);
    assert.match(importMessage("running", ID, "card_1"), /already runs in Kanban Code/);
    assert.match(importMessage("resumed", ID, "card_1"), /continues in Kanban Code, card card_1/);
  });
});
