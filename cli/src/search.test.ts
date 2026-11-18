import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { searchTerms, searchTranscripts, snippetAround, formatSearchResult } from "./search.js";
import type { Link } from "./types.js";

function link(id: string, extra: Partial<Link> = {}): Link {
  return {
    id,
    column: "done",
    createdAt: "2026-11-01T00:00:00Z",
    updatedAt: "2026-11-01T00:00:00Z",
    manualOverrides: { worktreePath: false, tmuxSession: false, name: false, column: false, prLink: false, issueLink: false },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    ...extra,
  } as Link;
}

function line(type: "user" | "assistant", text: string, timestamp: string, extra: object = {}): string {
  return JSON.stringify({ type, timestamp, cwd: "/repo", gitBranch: "main", message: { content: [{ type: "text", text }] }, ...extra });
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "kc-search-"));
  const dir = join(root, "-repo");
  mkdirSync(dir);
  writeFileSync(
    join(dir, "aaaa.jsonl"),
    [
      line("user", "grep for eslint-disable", "2026-11-17T15:00:00Z"),
      line("user", "[Image #1] how can we push these Metrics further?", "2026-11-17T16:39:00Z"),
      line("assistant", "Here is how each metric could go down.", "2026-11-17T16:40:00Z"),
      JSON.stringify({ type: "user", timestamp: "2026-11-17T16:41:00Z", message: { content: [{ type: "tool_result", content: "push these metrics" }] } }),
    ].join("\n") + "\n"
  );
  writeFileSync(join(dir, "bbbb.jsonl"), line("user", "unrelated work", "2026-11-17T10:00:00Z") + "\n");
  const skipped = join(root, "-orchestrator");
  mkdirSync(skipped);
  writeFileSync(join(skipped, "cccc.jsonl"), line("user", "push these metrics", "2026-11-18T10:00:00Z") + "\n");
  return root;
}

describe("searchTerms", () => {
  test("splits words and keeps quoted phrases", () => {
    assert.deepEqual(searchTerms('Ratchet "design audit"  baseline'), ["ratchet", "design audit", "baseline"]);
  });
});

describe("snippetAround", () => {
  test("centers on the first term and flattens whitespace", () => {
    const text = "x".repeat(400) + " the ratchet\nmoves " + "y".repeat(400);
    const s = snippetAround(text, ["ratchet"], 60);
    assert.ok(s.includes("ratchet moves"));
    assert.ok(s.startsWith("…") && s.endsWith("…"));
  });
});

describe("searchTranscripts", () => {
  test("finds a session without a card, matching all words in any case", () => {
    const root = fixture();
    const r = searchTranscripts("push metrics", { root, links: [], days: 0, limit: 10, role: "any", skipDirs: ["-orchestrator"] });
    assert.equal(r.sessions.length, 1);
    const s = r.sessions[0];
    assert.equal(s.sessionId, "aaaa");
    assert.equal(s.cardId, undefined);
    assert.equal(s.cwd, "/repo");
    assert.equal(s.firstPrompt, "grep for eslint-disable");
    // The tool result is not counted.
    assert.equal(s.matchCount, 1);
    assert.equal(s.matches[0].role, "user");
    assert.ok(formatSearchResult(r).includes("no card"));
  });

  test("names the card of a session, archived too, and matches card fields", () => {
    const root = fixture();
    const card = link("card_x", {
      name: "Improve ratchet",
      manuallyArchived: true,
      sessionLink: { sessionId: "aaaa" } as Link["sessionLink"],
    });
    const r = searchTranscripts("ratchet", { root, links: [card], days: 0, limit: 10, role: "any" });
    assert.equal(r.cards.length, 1);
    assert.equal(r.cards[0].archived, true);
    const m = searchTranscripts("metric", { root, links: [card], days: 0, limit: 10, role: "assistant", skipDirs: ["-orchestrator"] });
    assert.equal(m.sessions[0].cardId, "card_x");
    assert.equal(m.sessions[0].archived, true);
    assert.equal(m.sessions[0].matches[0].role, "assistant");
  });

  test("leaves out old transcripts when days is set", () => {
    const root = fixture();
    const r = searchTranscripts("push metrics", {
      root, links: [], days: 1, limit: 10, role: "any", now: new Date(Date.now() + 5 * 86_400_000),
    });
    assert.equal(r.sessions.length, 0);
  });
});
