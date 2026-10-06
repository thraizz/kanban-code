/**
 * Proxy mode: what the CLI hands to the Mac from inside a remote card, what it
 * refuses, and how it reads the answer back.
 */

import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import {
  buildProxyRequest,
  inlineProxyImages,
  proxyRefusalReason,
  runProxiedCommand,
  runsOnMachine,
  shouldProxy,
} from "./remote-proxy.js";

const CLI = resolve(import.meta.dirname, "kanban.ts");

let home: string;
let previousHome: string | undefined;

function runCli(
  args: string[],
  env: NodeJS.ProcessEnv,
  input = ""
): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execFileSync("npx", ["tsx", CLI, ...args], {
      encoding: "utf-8",
      env: { ...process.env, ...env },
      input,
    });
    return { stdout, stderr: "", code: 0 };
  } catch (e: any) {
    return { stdout: String(e.stdout ?? ""), stderr: String(e.stderr ?? ""), code: e.status ?? 1 };
  }
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-remote-proxy-"));
  previousHome = process.env.KANBAN_CODE_HOME;
  process.env.KANBAN_CODE_HOME = join(home, ".kanban-code");
  mkdirSync(process.env.KANBAN_CODE_HOME, { recursive: true });
});

afterEach(() => {
  if (previousHome === undefined) delete process.env.KANBAN_CODE_HOME;
  else process.env.KANBAN_CODE_HOME = previousHome;
  rmSync(home, { recursive: true, force: true });
});

describe("proxy gate", () => {
  test("stays off without KANBAN_REMOTE_PROXY", () => {
    assert.equal(shouldProxy(["channel", "send", "team", "hi"], {}), false);
  });

  test("hands an ordinary command to the Mac", () => {
    assert.equal(shouldProxy(["channel", "send", "team", "hi"], { KANBAN_REMOTE_PROXY: "1" }), true);
    assert.equal(shouldProxy(["list", "--json"], { KANBAN_REMOTE_PROXY: "1" }), true);
  });

  test("keeps the machine's own commands on the machine", () => {
    assert.equal(runsOnMachine(["remote-agent"]), true);
    assert.equal(runsOnMachine(["hooks", "install"]), true);
    assert.equal(runsOnMachine(["hooks"]), false);
    assert.equal(shouldProxy(["remote-agent"], { KANBAN_REMOTE_PROXY: "1" }), false);
    assert.equal(shouldProxy(["hooks", "install", "--json"], { KANBAN_REMOTE_PROXY: "1" }), false);
  });

  test("does nothing without a command", () => {
    assert.equal(shouldProxy([], { KANBAN_REMOTE_PROXY: "1" }), false);
  });
});

describe("proxy refusals", () => {
  test("refuses the commands that belong to the Mac alone", () => {
    for (const argv of [
      ["slack", "bridge"],
      ["daemon"],
      ["launch", "card"],
      ["reconcile"],
      ["open", "card"],
      ["channel", "share", "team"],
    ]) {
      assert.ok(proxyRefusalReason(argv), `${argv.join(" ")} should be refused`);
    }
  });

  test("refuses a --project path in either spelling", () => {
    assert.ok(proxyRefusalReason(["list", "--project", "/repo"]));
    assert.ok(proxyRefusalReason(["list", "--project=/repo"]));
  });

  test("refuses an export written to a file, allows it on stdout", () => {
    assert.ok(proxyRefusalReason(["export", "--out", "x.md"]));
    assert.ok(proxyRefusalReason(["export", "-o", "x.md"]));
    assert.ok(proxyRefusalReason(["export", "--out=x.md"]));
    assert.equal(proxyRefusalReason(["export"]), undefined);
  });

  test("allows the rest", () => {
    assert.equal(proxyRefusalReason(["channel", "send", "team", "hi"]), undefined);
    assert.equal(proxyRefusalReason(["channel", "list"]), undefined);
    assert.equal(proxyRefusalReason(["subagent", "spawn", "--handle", "x"]), undefined);
  });

  test("prints one line and exits 2 without writing a request", async () => {
    const errors: string[] = [];
    const code = await runProxiedCommand(["daemon"], {
      stdin: "",
      write: () => undefined,
      writeError: (text) => errors.push(text),
    });
    assert.equal(code, 2);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /^Error: /);
    assert.equal(existsSync(join(process.env.KANBAN_CODE_HOME!, "commands", "proxy")), false);
  });
});

describe("image attachments", () => {
  test("inlines the file and repoints the argument at the Mac's copy", () => {
    const source = join(home, "shot.png");
    writeFileSync(source, "png-bytes");
    const { argv, images } = inlineProxyImages(
      ["channel", "send", "team", "look", "--image", source],
      "req-1"
    );
    assert.deepEqual(argv, [
      "channel",
      "send",
      "team",
      "look",
      "--image",
      "~/.kanban-code/images/proxy/req-1/shot.png",
    ]);
    assert.deepEqual(images, [
      { name: "shot.png", base64: Buffer.from("png-bytes").toString("base64") },
    ]);
  });

  test("handles the --image=<path> spelling and repeated names", () => {
    const first = join(home, "a", "shot.png");
    const second = join(home, "b", "shot.png");
    mkdirSync(join(home, "a"), { recursive: true });
    mkdirSync(join(home, "b"), { recursive: true });
    writeFileSync(first, "one");
    writeFileSync(second, "two");
    const { argv, images } = inlineProxyImages(
      ["dm", "send", "@bob", "hi", `--image=${first}`, "--image", second],
      "req-2"
    );
    assert.deepEqual(argv.slice(-3), [
      "--image=~/.kanban-code/images/proxy/req-2/shot.png",
      "--image",
      "~/.kanban-code/images/proxy/req-2/shot-1.png",
    ]);
    assert.deepEqual(
      images.map((image) => image.name),
      ["shot.png", "shot-1.png"]
    );
  });

  test("leaves an argv without images alone", () => {
    const { argv, images } = inlineProxyImages(["channel", "send", "team", "hi"], "req-3");
    assert.deepEqual(argv, ["channel", "send", "team", "hi"]);
    assert.deepEqual(images, []);
  });
});

describe("request shape", () => {
  test("carries the card id, the working directory and the stdin", () => {
    const request = buildProxyRequest(["channel", "send", "team", "hi"], {
      id: "req-4",
      cwd: "/home/boxd/app",
      stdin: "piped body",
      cardId: "card-9",
    });
    assert.deepEqual(request, {
      id: "req-4",
      argv: ["channel", "send", "team", "hi"],
      cwd: "/home/boxd/app",
      stdin: "piped body",
      env: { KANBAN_CARD_ID: "card-9" },
      images: [],
    });
  });
});

describe("the gate in the real CLI", () => {
  test("refuses a Mac-only command with one line and exit 2", () => {
    const r = runCli(["daemon"], {
      KANBAN_CODE_HOME: process.env.KANBAN_CODE_HOME,
      KANBAN_REMOTE_PROXY: "1",
    });
    assert.equal(r.code, 2, r.stdout + r.stderr);
    const errors = r.stderr.split("\n").filter((line) => line.startsWith("Error: "));
    assert.equal(errors.length, 1, r.stderr);
    assert.match(errors[0], /not available on a remote card/);
  });

  test("lets remote-agent run on the machine", () => {
    const r = runCli(["remote-agent"], {
      KANBAN_CODE_HOME: process.env.KANBAN_CODE_HOME,
      KANBAN_REMOTE_PROXY: "1",
    });
    assert.equal(r.code, 0, r.stderr);
    const hello = JSON.parse(r.stdout.trim().split("\n")[0]);
    assert.equal(hello.type, "hello");
    assert.equal(hello.kanbanHome, process.env.KANBAN_CODE_HOME);
    assert.equal(hello.home, homedir());
  });
});

describe("round trip", () => {
  test("writes the request, prints the answer and returns its code", async () => {
    const requestPath = join(process.env.KANBAN_CODE_HOME!, "commands", "proxy", "req-5.json");
    const responsePath = join(
      process.env.KANBAN_CODE_HOME!,
      "commands",
      "proxy-responses",
      "req-5.json"
    );
    const answered = (async () => {
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline && !existsSync(requestPath)) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      const request = JSON.parse(readFileSync(requestPath, "utf-8"));
      assert.deepEqual(request.argv, ["channel", "send", "team", "hi"]);
      assert.equal(request.env.KANBAN_CARD_ID, "card-9");
      writeFileSync(
        responsePath,
        JSON.stringify({ id: "req-5", stdout: "delivered\n", stderr: "a warning\n", code: 7 })
      );
    })();

    const out: string[] = [];
    const errors: string[] = [];
    const code = await runProxiedCommand(["channel", "send", "team", "hi"], {
      id: "req-5",
      cwd: "/home/boxd/app",
      stdin: "",
      cardId: "card-9",
      pollIntervalMs: 10,
      timeoutMs: 5_000,
      write: (text) => out.push(text),
      writeError: (text) => errors.push(text),
    });
    await answered;

    assert.equal(code, 7);
    assert.deepEqual(out, ["delivered\n"]);
    assert.deepEqual(errors, ["a warning\n"]);
    assert.equal(existsSync(requestPath), false);
    assert.equal(existsSync(responsePath), false);
  });

  test("reports a timeout instead of hanging", async () => {
    const errors: string[] = [];
    const code = await runProxiedCommand(["channel", "list"], {
      id: "req-6",
      stdin: "",
      pollIntervalMs: 10,
      timeoutMs: 60,
      write: () => undefined,
      writeError: (text) => errors.push(text),
    });
    assert.equal(code, 1);
    assert.match(errors.join(""), /did not answer the proxied command/);
    assert.equal(
      existsSync(join(process.env.KANBAN_CODE_HOME!, "commands", "proxy", "req-6.json")),
      false
    );
  });
});
