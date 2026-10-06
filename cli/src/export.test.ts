import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { exportArguments, findExportBinary, resolveExportTarget, runExport, EXPORT_BINARY } from "./export.js";
import type { Link } from "./types.js";

function link(id: string, extra: Partial<Link> = {}): Link {
  return {
    id,
    column: "in_progress",
    createdAt: "2026-09-30T00:00:00Z",
    updatedAt: "2026-09-30T00:00:00Z",
    manualOverrides: { worktreePath: false, tmuxSession: false, name: false, column: false, prLink: false, issueLink: false },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    ...extra,
  } as Link;
}

const judge = link("card_judge", {
  name: "Judge lab",
  tmuxLink: { sessionName: "judge-lab" } as Link["tmuxLink"],
  sessionLink: { sessionId: "11111111-2222-3333-4444-555555555555", sessionPath: "/t/judge.jsonl" } as Link["sessionLink"],
});
const other = link("card_other", { name: "Other work" });
const links = [judge, other];

describe("resolveExportTarget", () => {
  test("no reference is the card named by KANBAN_CARD_ID", () => {
    const target = resolveExportTarget(undefined, { links, env: { KANBAN_CARD_ID: "card_other" } });
    assert.deepEqual(target, { kind: "card", card: other });
  });

  test("no reference falls back to the card of the current tmux session", () => {
    const target = resolveExportTarget(undefined, { links, env: {}, tmuxSession: () => "judge-lab" });
    assert.deepEqual(target, { kind: "card", card: judge });
  });

  test("no reference outside a card fails", () => {
    assert.throws(() => resolveExportTarget(undefined, { links, env: {}, tmuxSession: () => undefined }), /Not running inside/);
  });

  test("a card id, prefix, name and Claude session id all find the card", () => {
    for (const ref of ["card_judge", "card_j", "Judge lab", "11111111-2222-3333-4444-555555555555"]) {
      assert.deepEqual(resolveExportTarget(ref, { links }), { kind: "card", card: judge }, ref);
    }
  });

  test("a @handle goes through the channel members", () => {
    const cardForHandle = (handle: string) => (handle === "judge" ? judge : undefined);
    assert.deepEqual(resolveExportTarget("@judge", { links, cardForHandle }), { kind: "card", card: judge });
    assert.throws(() => resolveExportTarget("@nobody", { links, cardForHandle }), /No card with handle/);
  });

  test("a session id that is not on the board exports the session file", () => {
    const target = resolveExportTarget("aaaa-bbbb", {
      links,
      sessionFile: (id) => (id === "aaaa-bbbb" ? "/claude/p/aaaa-bbbb.jsonl" : undefined),
    });
    assert.deepEqual(target, { kind: "session", sessionId: "aaaa-bbbb", sessionPath: "/claude/p/aaaa-bbbb.jsonl" });
    assert.deepEqual(exportArguments(target), ["--path", "/claude/p/aaaa-bbbb.jsonl", "--session-id", "aaaa-bbbb"]);
  });

  test("an unknown reference fails", () => {
    assert.throws(() => resolveExportTarget("zzz-nothing", { links }), /not found/);
  });

  test("a card exports by id against this kanban home", () => {
    assert.deepEqual(exportArguments({ kind: "card", card: judge }, "/home/k"), ["--card", "card_judge", "--home", "/home/k"]);
  });
});

describe("findExportBinary", () => {
  test("prefers KANBAN_CODE_EXPORT, then the bundle Helpers, then PATH", () => {
    const root = mkdtempSync(join(tmpdir(), "kanban-export-"));
    const dist = join(root, "Contents", "Resources", "cli", "dist");
    mkdirSync(dist, { recursive: true });
    const bin = join(root, "bin");
    mkdirSync(bin);
    const onPath = join(bin, EXPORT_BINARY);
    writeFileSync(onPath, "#!/bin/sh\n");
    chmodSync(onPath, 0o755);

    assert.equal(findExportBinary({ KANBAN_CODE_EXPORT: "/x/y" }, dist), "/x/y");
    assert.equal(findExportBinary({ PATH: bin }, dist), onPath);

    mkdirSync(join(root, "Contents", "Helpers"));
    const helper = join(root, "Contents", "Helpers", EXPORT_BINARY);
    writeFileSync(helper, "#!/bin/sh\n");
    chmodSync(helper, 0o755);
    assert.equal(findExportBinary({ PATH: bin }, dist), helper);
    assert.equal(findExportBinary({ PATH: "" }, join(root, "nowhere", "a", "b")), undefined);
  });
});

describe("runExport", () => {
  test("streams the helper's stdout to a file or captures it", async () => {
    const root = mkdtempSync(join(tmpdir(), "kanban-export-run-"));
    const fake = join(root, "fake-export");
    writeFileSync(fake, '#!/bin/sh\nprintf "# Title\\n\\n%s\\n" "$2"\n');
    chmodSync(fake, 0o755);

    const captured = await runExport(fake, ["--card", "card_1"], { capture: true });
    assert.equal(captured.code, 0);
    assert.equal(captured.markdown, "# Title\n\ncard_1\n");

    const out = join(root, "out.md");
    const written = await runExport(fake, ["--card", "card_2"], { out });
    assert.equal(written.bytes, "# Title\n\ncard_2\n".length);
    const { readFileSync } = await import("node:fs");
    assert.equal(readFileSync(out, "utf-8"), "# Title\n\ncard_2\n");
  });

  test("reports the helper's failure", async () => {
    const root = mkdtempSync(join(tmpdir(), "kanban-export-fail-"));
    const fake = join(root, "fake-export");
    writeFileSync(fake, "#!/bin/sh\necho 'kanban-code-export: no card x' >&2\nexit 1\n");
    chmodSync(fake, 0o755);
    const result = await runExport(fake, [], { capture: true });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /no card x/);
  });
});
