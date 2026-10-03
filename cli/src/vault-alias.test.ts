/**
 * `kanban vault` is `kv`: same arguments, same output, same exit code.
 * Runs the real CLI against a fake vault master.
 */

import { test } from "node:test";
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { EXIT_DENIED } from "./vault.js";

const CLI = resolve(import.meta.dirname, "kanban.ts");
const KV = resolve(import.meta.dirname, "kv.ts");

function run(entry: string, args: string[], env: NodeJS.ProcessEnv): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((done) => {
    const child = spawn("npx", ["tsx", entry, ...args], { env: { ...process.env, ...env } });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code) => done({ stdout, stderr, code: code ?? -1 }));
  });
}

async function fakeMaster(reply: (body: any) => unknown): Promise<{ url: string; bodies: any[]; server: Server }> {
  const bodies: any[] = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (d) => (raw += d));
    req.on("end", () => {
      const body = raw ? JSON.parse(raw) : undefined;
      bodies.push({ path: req.url, body });
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(reply(body)));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  return { url: `http://127.0.0.1:${port}`, bodies, server };
}

const env = (url: string) => ({ KANBAN_VAULT_URL: url, HOME: mkdtempSync(join(tmpdir(), "kanban-vault-alias-")) });

test("kanban vault --help prints kv's own help", async () => {
  const viaKanban = await run(CLI, ["vault", "--help"], {});
  const viaKv = await run(KV, ["--help"], {});
  assert.equal(viaKanban.code, 0);
  assert.equal(viaKanban.stdout, viaKv.stdout);
  assert.match(viaKanban.stdout, /kv run NAME/);
});

test("kanban vault run passes the arguments through and the secret reaches the command", async () => {
  const master = await fakeMaster(() => ({ status: "granted", message: "ok", values: { DEMO_TOKEN: "s3cret" } }));
  try {
    const reason = "Check that the vault alias forwards arguments";
    const r = await run(CLI, ["vault", "run", "DEMO_TOKEN", "--reason", reason, "--", "sh", "-c", "printf %s \"$DEMO_TOKEN\"; exit 3"], env(master.url));
    assert.equal(r.stdout, "s3cret");
    assert.equal(r.code, 3);
    const release = master.bodies.find((b) => b.path === "/v1/vault/release");
    assert.deepEqual(release.body.names, ["DEMO_TOKEN"]);
    assert.equal(release.body.reason, reason);
  } finally {
    master.server.close();
  }
});

test("kanban vault keeps kv's denied exit code", async () => {
  const master = await fakeMaster(() => ({ status: "denied", message: "denied by test" }));
  try {
    const r = await run(CLI, ["vault", "run", "DEMO_TOKEN", "--reason", "Check that a denial keeps its exit code", "--", "true"], env(master.url));
    assert.equal(r.code, EXIT_DENIED);
    assert.match(r.stderr, /denied by test/);
  } finally {
    master.server.close();
  }
});
