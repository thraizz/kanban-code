import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  EXIT_DENIED,
  VaultClient,
  checkedReason,
  envFromVault,
  findEnvVault,
  hookRewrite,
  execProviderAnswer,
  leasePolicyFlags,
  parseEnvVault,
  reasonProblem,
  runKv,
  shellQuote,
  type VaultIO,
} from "./vault.js";
import { envVaultFor, isSecret, planAws, planSecrets, renderPlan, tierFor } from "./vault-import.js";

test("parses .env.vault references and plain values", () => {
  const entries = parseEnvVault(`# comment\nOPENAI_API_KEY={{vault:OPENAI_API_KEY}}\nexport DB={{ vault:DB_URL }}\nPORT=3000\nNAME="a b"\n`);
  assert.deepEqual(entries, [
    { key: "OPENAI_API_KEY", secret: "OPENAI_API_KEY" },
    { key: "DB", secret: "DB_URL" },
    { key: "PORT", value: "3000" },
    { key: "NAME", value: "a b" },
  ]);
  assert.deepEqual(envFromVault(entries, { OPENAI_API_KEY: "v1" }), { OPENAI_API_KEY: "v1", PORT: "3000", NAME: "a b" });
});

test("shell quoting survives quotes", () => {
  assert.equal(shellQuote("plain-word"), "plain-word");
  assert.equal(shellQuote("it's"), `'it'\\''s'`);
  assert.equal(shellQuote("a b"), "'a b'");
});

test("the hook wraps Bash commands only in projects with .env.vault", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  mkdirSync(join(root, "repo/sub"), { recursive: true });
  mkdirSync(join(root, "other/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  assert.equal(findEnvVault(join(root, "repo/sub"), root), join(root, "repo/.env.vault"));
  assert.equal(findEnvVault(join(root, "other"), root), undefined);

  // A linked worktree without its own .env.vault uses the main checkout's.
  mkdirSync(join(root, "repo/.git/worktrees/wt"), { recursive: true });
  mkdirSync(join(root, "wt/sub"), { recursive: true });
  writeFileSync(join(root, "wt/.git"), `gitdir: ${join(root, "repo/.git/worktrees/wt")}\n`);
  assert.equal(findEnvVault(join(root, "wt/sub"), root), join(root, "repo/.env.vault"));
  writeFileSync(join(root, "wt/.env.vault"), "A={{vault:A}}\n");
  assert.equal(findEnvVault(join(root, "wt/sub"), root), join(root, "wt/.env.vault"));

  const out = hookRewrite({ tool_name: "Bash", tool_input: { command: "cd x && pnpm test" }, cwd: join(root, "repo/sub") }, "/bin/kv") as {
    hookSpecificOutput: { updatedInput: { command: string } };
  };
  const cmd = out.hookSpecificOutput.updatedInput.command;
  assert.match(cmd, /env .*\.env\.vault --export --command-b64 /);
  assert.ok(cmd.endsWith("\ncd x && pnpm test"));
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: cmd }, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Read", tool_input: {}, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: join(root, "other") }, "/bin/kv"), undefined);
});

test("the hook answers Codex with permissionDecision allow and Claude Code without it", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  const input = { tool_name: "Bash", tool_input: { command: "pnpm test" }, cwd: join(root, "repo") };
  type Out = { hookSpecificOutput: { permissionDecision?: string; updatedInput: { command: string } } };
  const claude = hookRewrite(input, "/bin/kv") as Out;
  const codex = hookRewrite(input, "/bin/kv", "codex") as Out;
  assert.equal(claude.hookSpecificOutput.permissionDecision, undefined);
  assert.equal(codex.hookSpecificOutput.permissionDecision, "allow");
  assert.equal(codex.hookSpecificOutput.updatedInput.command, claude.hookSpecificOutput.updatedInput.command);
});

async function fakeMaster(handler: (method: string, path: string, body: any) => { status: number; body: unknown }) {
  const calls: { method: string; path: string; body: any }[] = [];
  const server = createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const body = data ? JSON.parse(data) : undefined;
      calls.push({ method: req.method!, path: req.url!, body });
      const r = handler(req.method!, req.url!, body);
      res.writeHead(r.status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(r.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { url, calls, close: () => server.close() };
}

function io(url: string, notes: string[]): VaultIO {
  return { env: { KANBAN_VAULT_URL: url, KANBAN_CARD_ID: "card_x" }, fetch, stderr: (t) => notes.push(t), sleep: async () => {} };
}

test("a pending release waits for the approval and says so", async () => {
  let polls = 0;
  const m = await fakeMaster((method, path) => {
    if (path === "/v1/vault/release") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting for Rogerio's approval on his phone or Mac (card X)" } };
    polls++;
    return polls < 3
      ? { status: 202, body: { status: "pending", id: "vault_1", message: "still waiting" } }
      : { status: 200, body: { status: "granted", message: "released", values: { A: "1" } } };
  });
  const notes: string[] = [];
  const r = await new VaultClient(m.url, io(m.url, notes)).decide("release", { mode: "run", names: ["A"] });
  m.close();
  assert.equal(r.status, "granted");
  assert.deepEqual(r.values, { A: "1" });
  assert.match(notes.join(""), /Waiting for Rogerio's approval/);
});

test("a denial exits with the denied code and a hint", async () => {
  const m = await fakeMaster(() => ({ status: 403, body: { status: "denied", message: "Rogerio denied it." } }));
  await assert.rejects(runKv(["run", "A", "--", "true"], io(m.url, [])), (e: any) => {
    assert.equal(e.code, EXIT_DENIED);
    assert.match(e.message, /kv request NAME --reason/);
    return true;
  });
  m.close();
});

test("kv run passes the command line for Jev", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", values: { A: "v" } } }));
  const reason = "Check that the test script sees the key it needs";
  const code = await runKv(["run", "A", "--reason", reason, "--", "sh", "-c", 'test "$A" = v'], io(m.url, []));
  m.close();
  assert.equal(code, 0);
  assert.equal(m.calls[0].body.command, `sh -c 'test "$A" = v'`);
  assert.equal(m.calls[0].body.reason, reason);
});

test("reasons must be one plain sentence a human reads on a phone", () => {
  assert.equal(reasonProblem(undefined), "missing");
  assert.equal(reasonProblem("change aws:lw-dev: rules"), "tooShort");
  assert.equal(reasonProblem("kubectl apply -f deploy.yaml"), "looksLikeCommand");
  assert.equal(reasonProblem("run the deploy with --force please"), "looksLikeCommand");
  assert.equal(reasonProblem("load env && run the migration now"), "looksLikeCommand");
  assert.equal(reasonProblem("first line\nsecond line of it"), "tooLong");
  assert.equal(reasonProblem("Deploy the langwatch staging app to check the fix for the login bug"), undefined);
  assert.equal(checkedReason(undefined, {}, false), undefined);
  assert.equal(checkedReason(undefined, { KV_REASON: "Read the dev cluster nodes after the autoscaler change" }, true),
    "Read the dev cluster nodes after the autoscaler change");
  assert.throws(() => checkedReason(undefined, {}, true), (e: any) => e.code === 2 && /one short plain sentence/.test(e.message));
});

test("a terse or command-like reason is refused before asking the master", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", values: { A: "v" } } }));
  for (const argv of [
    ["request", "A", "--reason", "change aws:lw-dev: rules"],
    ["request", "A"],
    ["run", "A", "--reason", "aws s3 ls", "--", "true"],
    ["rules", "A", "deploys only", "--reason", "rules"],
  ]) {
    await assert.rejects(runKv(argv, io(m.url, [])), (e: any) => {
      assert.equal(e.code, 2, argv.join(" "));
      assert.match(e.message, /Deploy the langwatch staging app/);
      return true;
    });
  }
  assert.equal(m.calls.length, 0);
  const reason = "Let the release script post the notes on its own";
  await runKv(["label", "A", "Release bot token", "--reason", reason], io(m.url, []));
  m.close();
  assert.deepEqual(m.calls[0].body, { label: "Release bot token", reason });
});

test("import finds secrets, skips config and placeholders", () => {
  assert.ok(isSecret("OPENAI_API_KEY", "sk-proj-abcdefghijklmnopqrstuvwxyz0123"));
  assert.ok(isSecret("DATABASE_URL", "postgres://user:pa55word@db.example.com:5432/app"));
  assert.ok(!isSecret("DATABASE_URL", "postgres://localhost:5432/app"));
  assert.ok(!isSecret("PORT", "3000"));
  assert.ok(!isSecret("OPENAI_API_KEY", "your-key-here"));
  assert.ok(!isSecret("API_KEY", "changeme"));
  assert.ok(!isSecret("NODE_ENV", "development"));
  assert.equal(tierFor("OPENAI_API_KEY", "sk-proj-x").tier, "open");
  assert.equal(tierFor("CLOUDFLARE_API_TOKEN", "abc").tier, "judged");
  assert.equal(tierFor("STRIPE_SECRET_KEY", "sk_live_abc").tier, "ask");
  assert.equal(tierFor("KANBAN_TOKEN", "kc_abc").tier, "never");
});

test("import dedupes by value and never writes values into the plan", () => {
  const plans = planSecrets(
    [
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/a/.env" },
      { key: "OPENAI_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/b/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/c/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-two-bbbbbbbbbbbb", file: "/h/Projects/d/.env" },
    ],
    "/h"
  );
  assert.deepEqual(plans.map((p) => p.name), ["OPENAI_API_KEY", "OPENAI_API_KEY__D"]);
  assert.equal(plans[0].sources.length, 3);
  const md = renderPlan(plans, ["/h/Projects/a/.env"], "/h");
  assert.ok(!md.includes("sk-proj-value"));
  assert.match(md, /`OPENAI_API_KEY`: ~\/Projects\/a\/.env OPENAI_API_KEY/);
});

test("import plans AWS profiles with read leases for prod", () => {
  const plans = planAws(
    `[root]\naws_access_key_id = AKIAEXAMPLE\naws_secret_access_key = s3cr3t\n\n[lw-prod]\nsource_profile = root\nrole_arn = arn:aws:iam::1:role/R\n\n[lw-dev]\nsource_profile = root\nrole_arn = arn:aws:iam::2:role/R\n`,
    "/h"
  );
  const byName = Object.fromEntries(plans.map((p) => [p.name, p]));
  assert.equal(byName["AWS_KEY_ROOT"].tier, "never");
  assert.equal(byName["aws:lw-dev"].tier, "judged");
  assert.equal(byName["aws:lw-prod:read"].tier, "ask");
  assert.deepEqual(byName["aws:lw-prod:read"].aws?.policyArns, ["arn:aws:iam::aws:policy/ReadOnlyAccess"]);
  assert.equal(byName["aws:lw-prod"].everyUseAsks, true);
});

test(".env.vault keeps names and plain config only", () => {
  const out = envVaultFor("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz\nPORT=3000\nWEIRD=Zx9kLmQ2vB7nR4tY8uW1eA3sD6fG\n", new Map([["OPENAI_API_KEY", "OPENAI_API_KEY"]]));
  assert.match(out, /OPENAI_API_KEY=\{\{vault:OPENAI_API_KEY\}\}/);
  assert.match(out, /PORT=3000/);
  assert.ok(!out.includes("sk-proj"));
  assert.ok(!out.includes("Zx9kLmQ2"));
});

test("the exec provider answers OpenClaw's protocol without waiting on a human", async () => {
  const m = await fakeMaster((_method, _path, body) => {
    const name = body.names[0];
    if (name === "OPEN") return { status: 200, body: { status: "granted", message: "released", values: { OPEN: "v1" } } };
    if (name === "ASK") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting" } };
    return { status: 403, body: { status: "denied", message: `no secret named ${name} in the vault` } };
  });
  const client = new VaultClient(m.url, io(m.url, []));
  const answer = await execProviderAnswer(client, { protocolVersion: 1, provider: "kv", ids: ["OPEN", "ASK", "GONE"] }, { cwd: "/" });
  m.close();
  assert.deepEqual(answer, {
    protocolVersion: 1,
    values: { OPEN: "v1" },
    errors: { ASK: { code: "NEEDS_APPROVAL" }, GONE: { code: "NOT_FOUND" } },
  });
  assert.equal(m.calls.length, 3);
  assert.equal(m.calls[0].body.mode, "get");
});

test("--every-use-asks and --leases set the lease policy, together they are refused", () => {
  const a = ["STRIPE", "ask", "--every-use-asks"];
  assert.deepEqual(leasePolicyFlags(a), { leaseSeconds: 172800, everyUseAsks: true });
  assert.deepEqual(a, ["STRIPE", "ask"]);
  assert.deepEqual(leasePolicyFlags(["X", "--leases"]), { leaseSeconds: 172800, everyUseAsks: false });
  assert.equal(leasePolicyFlags(["X", "ask"]), undefined);
  assert.throws(() => leasePolicyFlags(["X", "--leases", "--every-use-asks"]), /contradict/);
});

test("kv tier sends the lease policy with the tier", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "changed STRIPE: tier, every use asks" } }));
  await runKv(["tier", "STRIPE_API_KEY", "ask", "--every-use-asks", "--reason", "Stripe live key must ask on every use"], io(m.url, []));
  m.close();
  assert.equal(m.calls[0].method, "PATCH");
  assert.deepEqual(m.calls[0].body.leasePolicy, { leaseSeconds: 172800, everyUseAsks: true });
  assert.equal(m.calls[0].body.tier, "ask");
});

test("a vault denial says what the vault said, without the reason-writing help", async () => {
  const message = "denied:\n  AWS: Jev denied it against the secret's rules (91%). Its rules: dev work only";
  const m = await fakeMaster(() => ({ status: 403, body: { status: "denied", message } }));
  await assert.rejects(
    runKv(["run", "AWS", "--reason", "Deploy the staging app to check the login fix", "--", "true"], io(m.url, [])),
    (e: any) => {
      assert.match(e.message, /Jev denied it against the secret's rules \(91%\)\. Its rules: dev work only/);
      assert.doesNotMatch(e.message, /Good:|Bad:/);
      return true;
    }
  );
  m.close();
});

test("kv tiers sends one batched change with names and value prefixes", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "changed A, B: tier ask" } }));
  await runKv(
    ["tiers", "ask", "A", "--value-prefix", "sk_live_", "--value-prefix", "rk_live_", "--every-use-asks",
     "--reason", "Live Stripe keys must ask Rogerio on every use"],
    io(m.url, [])
  );
  m.close();
  assert.equal(m.calls.length, 1);
  assert.equal(m.calls[0].method, "PATCH");
  assert.equal(m.calls[0].path, "/v1/vault/secrets");
  assert.deepEqual(m.calls[0].body.names, ["A"]);
  assert.deepEqual(m.calls[0].body.valuePrefixes, ["sk_live_", "rk_live_"]);
  assert.deepEqual(m.calls[0].body.edit.leasePolicy, { leaseSeconds: 172800, everyUseAsks: true });
});

function refused(code = "ECONNREFUSED"): Error {
  return new TypeError("fetch failed", { cause: { code } });
}

function scriptedIO(steps: (() => Response)[], notes: string[], slept: number[]): { io: VaultIO; calls: string[] } {
  const calls: string[] = [];
  const fakeFetch = (async (url: string, init?: RequestInit) => {
    calls.push(`${init?.method} ${url}`);
    const step = steps.shift() ?? (() => { throw refused(); });
    return step();
  }) as unknown as typeof fetch;
  return { io: { env: {}, fetch: fakeFetch, stderr: (t) => notes.push(t), sleep: async (ms) => { slept.push(ms); } }, calls };
}

const json = (status: number, body: unknown) => () => new Response(JSON.stringify(body), { status });

test("a pending approval outlives a master restart: kv waits for the master to come back", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio } = scriptedIO(
    [
      json(202, { status: "pending", id: "vault_1", message: "Waiting for Rogerio" }),
      () => { throw refused(); },
      () => { throw refused(); },
      json(503, { error: "starting" }),
      json(200, { status: "granted", message: "released", values: { A: "1" } }),
    ],
    notes,
    slept
  );
  const r = await new VaultClient("http://127.0.0.1:1", sio).decide("release", { mode: "run", names: ["A"] });
  assert.equal(r.status, "granted");
  assert.equal(notes.filter((n) => /probably restarting; waiting up to 2 min/.test(n)).length, 1);
  assert.ok(notes.some((n) => /the master is back/.test(n)));
  assert.deepEqual(slept, [1500, 1000, 2000, 4000]);
});

test("kv gives up after two minutes of a master that does not answer", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio } = scriptedIO([], notes, slept);
  await assert.rejects(new VaultClient("http://127.0.0.1:1", sio).call("GET", "status"), /cannot reach the Kanban Code master/);
  assert.equal(slept.reduce((a, b) => a + b, 0), 120_000);
});

test("a request that may have reached the master is not sent twice", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio, calls } = scriptedIO([() => { throw refused("ECONNRESET"); }], notes, slept);
  await assert.rejects(new VaultClient("http://127.0.0.1:1", sio).call("POST", "release", { names: ["A"] }), /cannot reach/);
  assert.equal(calls.length, 1);
});

test("a POST nothing accepted is retried", async () => {
  const notes: string[] = [];
  const slept: number[] = [];
  const { io: sio, calls } = scriptedIO(
    [() => { throw refused(); }, json(200, { status: "granted", message: "ok" })],
    notes,
    slept
  );
  const r = await new VaultClient("http://127.0.0.1:1", sio).call<{ status: string }>("POST", "release", { names: ["A"] });
  assert.equal(r.body.status, "granted");
  assert.equal(calls.length, 2);
});

test("exec-provider does not wait for an unreachable master", async () => {
  const slept: number[] = [];
  const { io: sio } = scriptedIO([], [], slept);
  const client = new VaultClient("http://127.0.0.1:1", sio);
  client.retryForMs = 0;
  const answer = await execProviderAnswer(client, { ids: ["A"] }, { cwd: "/" });
  assert.deepEqual(answer.errors, { A: { code: "UNREACHABLE" } });
  assert.deepEqual(slept, []);
});
