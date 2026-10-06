/**
 * `kanban export`: a whole session as Markdown, the same text the app copies
 * with "Copy conversation as Markdown". The Markdown comes from the Swift
 * exporter through the `kanban-code-export` helper; this side only finds the
 * card and the helper.
 */

import { spawn } from "node:child_process";
import { accessSync, constants, createWriteStream, existsSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { cardForTmuxSession, cardFromEnvironment } from "./broadcast.js";
import { findCard, findSessionJsonl } from "./data.js";
import { stripAt } from "./handles.js";
import { kanbanHome } from "./paths.js";
import type { Link } from "./types.js";

export const EXPORT_BINARY = "kanban-code-export";

/** What to export: a card on the board, or a bare Claude session file. */
export type ExportTarget =
  | { kind: "card"; card: Link }
  | { kind: "session"; sessionId: string; sessionPath: string };

export interface ExportLookup {
  links: Link[];
  env?: NodeJS.ProcessEnv;
  tmuxSession?: () => string | undefined;
  /** The card a channel member handle belongs to. */
  cardForHandle?: (handle: string) => Link | undefined;
  /** A Claude session transcript by id, for sessions that are not on the board. */
  sessionFile?: (sessionId: string) => string | undefined;
}

/**
 * Resolves the export target. No reference means the card this command runs
 * in (`KANBAN_CARD_ID`, then the tmux session). Otherwise a card id or prefix,
 * a `@handle`, a card name, a tmux session name, or a Claude session id.
 */
export function resolveExportTarget(ref: string | undefined, lookup: ExportLookup): ExportTarget {
  const { links } = lookup;
  const query = ref?.trim();
  if (!query) {
    const declared = cardFromEnvironment(links, lookup.env ?? process.env);
    if (declared) return { kind: "card", card: declared };
    const session = lookup.tmuxSession?.();
    const card = session ? cardForTmuxSession(links, session) : undefined;
    if (card) return { kind: "card", card };
    throw new Error(
      "Not running inside a Kanban Code card. Pass a card id, a @handle or a session id."
    );
  }

  if (query.startsWith("@")) {
    const card = lookup.cardForHandle?.(stripAt(query));
    if (card) return { kind: "card", card };
    throw new Error(`No card with handle ${query}`);
  }

  const card = findCard(links, query) ?? lookup.cardForHandle?.(query);
  if (card) return { kind: "card", card };

  const sessionPath = lookup.sessionFile?.(query);
  if (sessionPath) return { kind: "session", sessionId: query, sessionPath };
  throw new Error(`Card or session not found: ${query}`);
}

/** Arguments for `kanban-code-export`. */
export function exportArguments(target: ExportTarget, home: string = kanbanHome()): string[] {
  if (target.kind === "card") return ["--card", target.card.id, "--home", home];
  return ["--path", target.sessionPath, "--session-id", target.sessionId];
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Where `kanban-code-export` lives: `$KANBAN_CODE_EXPORT`, the app bundle's
 * Helpers next to the bundled CLI, the app and SwiftPM builds of the checkout
 * the CLI was built from, then `PATH` (the Linux server installs it in /usr/local/bin).
 */
export function findExportBinary(
  env: NodeJS.ProcessEnv = process.env,
  distDir: string = dirname(fileURLToPath(import.meta.url))
): string | undefined {
  const explicit = env.KANBAN_CODE_EXPORT?.trim();
  if (explicit) return explicit;
  const candidates = [
    // KanbanCode.app/Contents/Resources/cli/dist -> Contents/Helpers
    resolve(distDir, "..", "..", "..", "Helpers", EXPORT_BINARY),
    // <checkout>/cli/dist -> the app `make app` built, then the SwiftPM builds
    resolve(distDir, "..", "..", "build", "KanbanCode.app", "Contents", "Helpers", EXPORT_BINARY),
    ...["release", "arm64-apple-macosx/release", "x86_64-apple-macosx/release", "debug"].map((dir) =>
      resolve(distDir, "..", "..", ".build", dir, EXPORT_BINARY)
    ),
    ...(env.PATH ?? "").split(delimiter).filter(Boolean).map((dir) => join(dir, EXPORT_BINARY)),
  ];
  return candidates.find((path) => existsSync(path) && isExecutable(path));
}

export interface ExportRun {
  code: number;
  stderr: string;
  /** The Markdown, when it was captured instead of written to a file or stdout. */
  markdown?: string;
  bytes: number;
}

/**
 * Runs the helper. The Markdown streams to `out` (a file) or to this process's
 * stdout; with `capture` it is collected and returned instead.
 */
export function runExport(
  binary: string,
  args: string[],
  options: { out?: string; capture?: boolean } = {}
): Promise<ExportRun> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(binary, args, { stdio: ["ignore", "pipe", "pipe"] });
    const file = options.out ? createWriteStream(options.out) : undefined;
    const chunks: Buffer[] = [];
    let bytes = 0;
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (options.capture) chunks.push(chunk);
    });
    if (file) child.stdout.pipe(file);
    else if (!options.capture) {
      // A reader that stops early (`| head`) closes the pipe: stop the export quietly.
      process.stdout.on("error", (error: NodeJS.ErrnoException) => {
        if (error.code !== "EPIPE") throw error;
        child.kill();
        process.exit(0);
      });
      child.stdout.pipe(process.stdout);
    }
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf-8");
    });
    child.on("error", reject);
    child.on("close", (code) => {
      const done = () =>
        resolvePromise({
          code: code ?? 1,
          stderr: stderr.trim(),
          bytes,
          markdown: options.capture ? Buffer.concat(chunks).toString("utf-8") : undefined,
        });
      if (file) file.end(done);
      else done();
    });
  });
}

/** Session file lookup for a bare Claude session id. */
export function claudeSessionFile(sessionId: string): string | undefined {
  if (!/^[0-9a-f-]{8,}$/i.test(sessionId)) return undefined;
  return findSessionJsonl(sessionId);
}
