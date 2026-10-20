import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Link } from "./types.js";
import {
  cardForTmuxSession,
  formatDirectMessage,
  sendDirectMessage,
} from "./broadcast.js";

let base: string;
function tmp(): string { return mkdtempSync(join(tmpdir(), "kanban-broadcast-test-")); }

function mkLink(id: string, tmuxName: string, name?: string): Link {
  return {
    id,
    name: name ?? id,
    column: "in_progress",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    tmuxLink: { sessionName: tmuxName },
    isRemote: false,
    prLinks: [],
    manualOverrides: {
      worktreePath: false,
      tmuxSession: false,
      name: false,
      column: false,
      prLink: false,
      issueLink: false,
    },
    source: "manual",
    manuallyArchived: false,
  } as unknown as Link;
}

describe("formatting", () => {
  test("formatDirectMessage shape", () => {
    const s = formatDirectMessage("alice", "privately");
    assert.equal(s, "[DM from @alice]: privately");
  });
  test("accepts handle with or without @", () => {
    assert.equal(formatDirectMessage("@alice", "hi"), "[DM from @alice]: hi");
  });
  test("DM appends markdown image refs when imagePaths present", () => {
    const s = formatDirectMessage("alice", "psst", ["/tmp/a.png"]);
    assert.equal(s, "[DM from @alice]: psst\n![](/tmp/a.png)");
  });
  test("empty imagePaths yields no trailing content", () => {
    assert.equal(formatDirectMessage("alice", "hi", []), "[DM from @alice]: hi");
  });
});

describe("cardForTmuxSession", () => {
  test("resolves by primary session", () => {
    const links = [mkLink("card_A", "session-a"), mkLink("card_B", "session-b")];
    assert.equal(cardForTmuxSession(links, "session-b")?.id, "card_B");
    assert.equal(cardForTmuxSession(links, "session-x"), undefined);
  });

  test("prefers card id embedded in duplicate primary tmux session name", () => {
    const sessionName = "langwatch-card_current";
    const stale = mkLink("card_stale", sessionName);
    stale.column = "all_sessions";
    stale.manuallyArchived = true;
    const current = mkLink("card_current", sessionName);
    const links = [stale, current];

    assert.equal(cardForTmuxSession(links, sessionName)?.id, "card_current");
  });
});

describe("sendDirectMessage", () => {
  test("delivers to the recipient only", () => {
    const links = [mkLink("card_A", "session-a"), mkLink("card_B", "session-b")];
    const calls: { session: string; text: string }[] = [];
    const { msg, delivered } = sendDirectMessage(
      { cardId: "card_A", handle: "alice" },
      { cardId: "card_B", handle: "bob" },
      "private note",
      links,
      { sender: (s, t) => { calls.push({ session: s, text: t }); return { ok: true }; } }
    );
    assert.equal(delivered, true);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].session, "session-b");
    assert.equal(calls[0].text, "[DM from @alice]: private note");
    assert.equal(msg.body, "private note");
  });

  test("tells the receiver whether the sender is its parent or its subagent", () => {
    const parent = mkLink("card_parent", "session-parent");
    const child = { ...mkLink("card_child", "session-child"), parentCardId: "card_parent" } as Link;
    const links = [parent, child];
    const calls: string[] = [];
    const sender = { sender: (_s: string, t: string) => { calls.push(t); return { ok: true }; } };

    sendDirectMessage(
      { cardId: parent.id, handle: "coordinator" },
      { cardId: child.id, handle: "worker" },
      "check the cache path",
      links,
      sender
    );
    sendDirectMessage(
      { cardId: child.id, handle: "worker" },
      { cardId: parent.id, handle: "coordinator" },
      "root cause found",
      links,
      sender
    );

    assert.equal(calls[0], "[DM from @coordinator (parent agent)]: check the cache path");
    assert.equal(calls[1], "[DM from @worker (subagent)]: root cause found");
  });

  test("reports recipient offline without delivery", () => {
    const links = [mkLink("card_A", "session-a")]; // no card_B
    const { delivered, error } = sendDirectMessage(
      { cardId: "card_A", handle: "alice" },
      { cardId: "card_B", handle: "bob" },
      "anybody?",
      links,
      { sender: () => ({ ok: true }) }
    );
    assert.equal(delivered, false);
    assert.match(error ?? "", /no tmux session/);
  });
});

describe("foreign cards", () => {
  let previousHome: string | undefined;
  let kanbanHomeDir: string;

  beforeEach(() => {
    base = tmp();
    previousHome = process.env.KANBAN_CODE_HOME;
    kanbanHomeDir = join(base, "kanban-home");
    process.env.KANBAN_CODE_HOME = kanbanHomeDir;
    mkdirSync(kanbanHomeDir, { recursive: true });
    writeFileSync(join(kanbanHomeDir, "machine.json"), JSON.stringify({ id: "home-box", name: "box" }));
  });
  afterEach(() => {
    if (previousHome === undefined) delete process.env.KANBAN_CODE_HOME;
    else process.env.KANBAN_CODE_HOME = previousHome;
    rmSync(base, { recursive: true, force: true });
  });

  function ownedBy(link: Link, machine: string): Link {
    return { ...link, ownerMachine: machine };
  }

  function inboxRequests(): any[] {
    const dir = join(kanbanHomeDir, "commands", "inbox");
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => JSON.parse(readFileSync(join(dir, f), "utf-8")));
  }

  function respond(id: string, body: object): void {
    const dir = join(kanbanHomeDir, "commands", "responses");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({ id, ...body }));
  }

  test("images reach a foreign card as markdown refs relative to the home dir", () => {
    const image = join(kanbanHomeDir, "images", "shot.png");
    mkdirSync(join(kanbanHomeDir, "images"), { recursive: true });
    writeFileSync(image, "png");
    const links = [mkLink("card_A", "session-a"), ownedBy(mkLink("card_B", "session-b"), "mac-1")];
    sendDirectMessage(
      { cardId: "card_A", handle: "alice" },
      { cardId: "card_B", handle: "bob" },
      "look",
      links,
      { sender: () => ({ ok: true }), foreignResponseTimeoutMs: 0 },
      [image]
    );
    const [request] = inboxRequests();
    assert.equal(request.prompt, "[DM from @alice]: look\n![](~/.kanban-code/images/shot.png)");
  });

  test("without machine.json every card is local", () => {
    rmSync(join(kanbanHomeDir, "machine.json"));
    const links = [mkLink("card_A", "session-a"), ownedBy(mkLink("card_B", "session-b"), "mac-1")];
    const pasted: string[] = [];
    sendDirectMessage({ cardId: "card_A", handle: "alice" }, { cardId: "card_B", handle: "bob" }, "hi", links, {
      sender: (session) => { pasted.push(session); return { ok: true }; },
    });
    assert.deepEqual(pasted, ["session-b"]);
    assert.equal(inboxRequests().length, 0);
  });

  test("a DM to a foreign card goes through the inbox and reports the owner", () => {
    const links = [mkLink("card_A", "session-a"), ownedBy(mkLink("card_B", "session-b"), "mac-1")];
    respond("req-dm", { ok: true });
    const pasted: string[] = [];
    const result = sendDirectMessage(
      { cardId: "card_A", handle: "alice" },
      { cardId: "card_B", handle: "bob" },
      "private",
      links,
      {
        sender: (session) => { pasted.push(session); return { ok: true }; },
        liveSessionProbe: () => false,
        foreignRequestId: () => "req-dm",
      }
    );
    assert.equal(result.delivered, true);
    assert.equal(result.via, "mac-1");
    assert.deepEqual(pasted, []);
    const [request] = inboxRequests();
    assert.equal(request.prompt, "[DM from @alice]: private");
    assert.equal(request.cardId, "card_B");
  });

  test("a refused foreign DM is not delivered", () => {
    const links = [mkLink("card_A", "session-a"), ownedBy(mkLink("card_B", "session-b"), "mac-1")];
    respond("req-dm", { ok: false, error: "owner offline" });
    const result = sendDirectMessage(
      { cardId: "card_A", handle: "alice" },
      { cardId: "card_B", handle: "bob" },
      "private",
      links,
      { foreignRequestId: () => "req-dm" }
    );
    assert.equal(result.delivered, false);
    assert.equal(result.error, "mac-1 refused: owner offline");
  });
});
