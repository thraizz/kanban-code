/**
 * Proxy mode of the CLI. Inside a remote card's tmux session the machine has no
 * board, no channels and no links.json, so a `kanban` command written by the
 * agent there is handed to the Mac instead of being run locally.
 *
 * The request goes to `~/.kanban-code/commands/proxy/<id>.json`, the Mac runs
 * the bundled CLI with the same arguments and writes the result to
 * `commands/proxy-responses/<id>.json`.
 */

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { proxyRequestsDir, proxyResponsesDir } from "./paths.js";

export interface ProxyImage {
  name: string;
  base64: string;
}

export interface ProxyRequest {
  id: string;
  argv: string[];
  cwd: string;
  stdin?: string;
  env: { KANBAN_CARD_ID?: string };
  images: ProxyImage[];
}

export interface ProxyResponse {
  id: string;
  stdout?: string;
  stderr?: string;
  code?: number;
}

/** Commands that always belong to the machine, never to the Mac. */
export function runsOnMachine(argv: string[]): boolean {
  const command = firstCommand(argv);
  if (command === "remote-agent") return true;
  // `kanban remote` talks to a Mac over HTTP and needs nothing from the board here.
  if (command === "remote") return true;
  return command === "hooks" && subCommand(argv) === "install";
}

/**
 * Commands the Mac cannot usefully run for a remote card: they either open a
 * window, own a long-lived process, or address a path that only exists on one
 * of the two machines.
 */
export function proxyRefusalReason(argv: string[]): string | undefined {
  const command = firstCommand(argv);
  const sub = subCommand(argv);
  if (argv.some((arg) => arg === "--project" || arg.startsWith("--project="))) {
    return "`--project` names a path that does not exist on both sides of a remote card.";
  }
  if (command === "export" && argv.some((arg) => arg === "-o" || arg === "--out" || arg.startsWith("--out="))) {
    return "`kanban export --out` would write the file on the Mac; redirect stdout instead (`kanban export > file.md`).";
  }
  if (command === "channel" && sub === "share") {
    return "`kanban channel share` is not available on a remote card.";
  }
  for (const refused of ["slack", "daemon", "launch", "reconcile", "open"]) {
    if (command === refused) {
      return `\`kanban ${refused}\` runs on the Mac only and is not available on a remote card.`;
    }
  }
  return undefined;
}

/** Whether this invocation must be handed to the Mac. */
export function shouldProxy(argv: string[], env: NodeJS.ProcessEnv = process.env): boolean {
  if (!env.KANBAN_REMOTE_PROXY) return false;
  if (argv.length === 0) return false;
  return !runsOnMachine(argv);
}

function firstCommand(argv: string[]): string | undefined {
  return argv.find((arg) => !arg.startsWith("-"));
}

function subCommand(argv: string[]): string | undefined {
  const rest = argv.filter((arg) => !arg.startsWith("-"));
  return rest[1];
}

/**
 * Inline every `--image <file>` attachment and repoint its argument at the
 * directory the Mac unpacks the images into, so both sides name the same file.
 */
export function inlineProxyImages(
  argv: string[],
  id: string,
  read: (path: string) => Buffer = (path) => readFileSync(path)
): { argv: string[]; images: ProxyImage[] } {
  const images: ProxyImage[] = [];
  const rewritten: string[] = [];
  const taken = new Set<string>();
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const inlineValue = arg.startsWith("--image=") ? arg.slice("--image=".length) : undefined;
    const separateValue = arg === "--image" ? argv[index + 1] : undefined;
    const value = inlineValue ?? separateValue;
    if (value === undefined) {
      rewritten.push(arg);
      continue;
    }
    const name = uniqueImageName(value, taken);
    images.push({ name, base64: read(value).toString("base64") });
    const remotePath = `~/.kanban-code/images/proxy/${id}/${name}`;
    if (inlineValue !== undefined) {
      rewritten.push(`--image=${remotePath}`);
    } else {
      rewritten.push("--image", remotePath);
      index += 1;
    }
  }
  return { argv: rewritten, images };
}

function uniqueImageName(path: string, taken: Set<string>): string {
  const base = basename(path) || "image";
  let name = base;
  let counter = 1;
  while (taken.has(name)) {
    const dot = base.lastIndexOf(".");
    name = dot > 0
      ? `${base.slice(0, dot)}-${counter}${base.slice(dot)}`
      : `${base}-${counter}`;
    counter += 1;
  }
  taken.add(name);
  return name;
}

export interface BuildProxyRequestOptions {
  id?: string;
  cwd?: string;
  stdin?: string;
  cardId?: string;
  readImage?: (path: string) => Buffer;
}

export function buildProxyRequest(
  argv: string[],
  options: BuildProxyRequestOptions = {}
): ProxyRequest {
  const id = options.id ?? randomUUID().toLowerCase();
  const { argv: rewritten, images } = inlineProxyImages(argv, id, options.readImage);
  return {
    id,
    argv: rewritten,
    cwd: options.cwd ?? process.cwd(),
    stdin: options.stdin,
    env: { KANBAN_CARD_ID: options.cardId ?? process.env.KANBAN_CARD_ID },
    images,
  };
}

export function writeProxyRequest(request: ProxyRequest): string {
  const dir = proxyRequestsDir();
  mkdirSync(dir, { recursive: true });
  mkdirSync(proxyResponsesDir(), { recursive: true });
  const target = join(dir, `${request.id}.json`);
  const temp = `${target}.tmp`;
  writeFileSync(temp, JSON.stringify(request, null, 2));
  renameSync(temp, target);
  return target;
}

export interface AwaitProxyResponseOptions {
  timeoutMs?: number;
  pollIntervalMs?: number;
}

export async function awaitProxyResponse(
  id: string,
  options: AwaitProxyResponseOptions = {}
): Promise<ProxyResponse> {
  const requestPath = join(proxyRequestsDir(), `${id}.json`);
  const responsePath = join(proxyResponsesDir(), `${id}.json`);
  const timeoutMs = options.timeoutMs ?? 120_000;
  const pollIntervalMs = options.pollIntervalMs ?? 100;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(responsePath)) {
      let response: ProxyResponse;
      try {
        response = JSON.parse(readFileSync(responsePath, "utf-8")) as ProxyResponse;
      } catch (error) {
        rmSync(responsePath, { force: true });
        rmSync(requestPath, { force: true });
        throw new Error(`Kanban Code returned an invalid proxy response: ${String(error)}`);
      }
      rmSync(responsePath, { force: true });
      rmSync(requestPath, { force: true });
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
  rmSync(requestPath, { force: true });
  throw new Error(
    `Kanban Code did not answer the proxied command within ${Math.ceil(timeoutMs / 1_000)} seconds.`
  );
}

export interface RunProxiedOptions extends BuildProxyRequestOptions, AwaitProxyResponseOptions {
  write?: (text: string) => void;
  writeError?: (text: string) => void;
}

/**
 * Hands one invocation to the Mac and returns the exit code the CLI should use.
 * Refused commands never reach the Mac.
 */
export async function runProxiedCommand(
  argv: string[],
  options: RunProxiedOptions = {}
): Promise<number> {
  const write = options.write ?? ((text: string) => process.stdout.write(text));
  const writeError = options.writeError ?? ((text: string) => process.stderr.write(text));
  const refusal = proxyRefusalReason(argv);
  if (refusal) {
    writeError(`Error: ${refusal}\n`);
    return 2;
  }
  const stdin = options.stdin ?? (await readStdinIfPiped());
  const request = buildProxyRequest(argv, { ...options, stdin });
  writeProxyRequest(request);
  let response: ProxyResponse;
  try {
    response = await awaitProxyResponse(request.id, options);
  } catch (error) {
    writeError(`Error: ${(error as Error).message}\n`);
    return 1;
  }
  if (response.stdout) write(response.stdout);
  if (response.stderr) writeError(response.stderr);
  return response.code ?? 0;
}

async function readStdinIfPiped(): Promise<string | undefined> {
  if (process.stdin.isTTY) return undefined;
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf-8");
}
