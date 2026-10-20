/**
 * Several masters (the Mac app, an always-on server) share one board. Each card
 * names the master that runs it in `ownerMachine`; its tmux session only exists
 * there. A prompt for a card another master owns is handed to the local master
 * through the command inbox, and the local master forwards it to the owner.
 */

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { commandInboxDir, commandResponsesDir, kanbanHome, machinePath } from "./paths.js";
import type { Link } from "./types.js";

export interface MachineIdentity {
  id: string;
  name?: string;
}

function readJson(path: string): unknown {
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    return undefined;
  }
}

/** This master's identity, or undefined when `machine.json` is missing or unreadable. */
export function readLocalMachine(): MachineIdentity | undefined {
  const raw = readJson(machinePath()) as Partial<MachineIdentity> | undefined;
  if (!raw || typeof raw.id !== "string" || !raw.id) return undefined;
  return { id: raw.id, name: typeof raw.name === "string" ? raw.name : undefined };
}

/**
 * Whether another master runs this card. Without a local machine id every card
 * is local: a machine that never joined a fleet owns its whole board.
 */
export function isForeignCard(link: Link | undefined, localMachineId: string | undefined): boolean {
  if (!link || !localMachineId) return false;
  return Boolean(link.ownerMachine) && link.ownerMachine !== localMachineId;
}

/** Display name for a machine id: this machine's name when it matches, else the id. */
export function machineLabel(machineId: string): string {
  const local = readLocalMachine();
  if (local && local.id === machineId && local.name) return local.name;
  return machineId;
}

export interface ForeignPromptRequest {
  id: string;
  operation: "enqueuePrompt";
  createdAt: string;
  parentCardId: string;
  cardId: string;
  prompt: string;
}

export interface ForeignPromptResponse {
  id: string;
  ok: boolean;
  error?: string;
}

/**
 * Writes an `enqueuePrompt` command for the local master. It never waits: the
 * master drains the inbox on its own loop, and a request left there while it is
 * down is picked up when it starts.
 */
export function enqueueForeignPrompt(cardId: string, prompt: string, id: string = randomUUID().toLowerCase()): ForeignPromptRequest {
  const request: ForeignPromptRequest = {
    id,
    operation: "enqueuePrompt",
    createdAt: new Date().toISOString(),
    parentCardId: cardId,
    cardId,
    prompt,
  };
  const inbox = commandInboxDir();
  mkdirSync(inbox, { recursive: true });
  mkdirSync(commandResponsesDir(), { recursive: true });
  const target = join(inbox, `${id}.json`);
  const temp = `${target}.tmp`;
  writeFileSync(temp, JSON.stringify(request, null, 2));
  renameSync(temp, target);
  return request;
}

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function takeResponse(id: string): ForeignPromptResponse | undefined {
  const path = join(commandResponsesDir(), `${id}.json`);
  if (!existsSync(path)) return undefined;
  let response: ForeignPromptResponse;
  try {
    response = JSON.parse(readFileSync(path, "utf-8")) as ForeignPromptResponse;
  } catch (error) {
    response = { id, ok: false, error: `invalid response: ${String(error)}` };
  }
  rmSync(path, { force: true });
  return response;
}

/**
 * Collects the master's answers to the given requests, waiting at most
 * `timeoutMs` in total. Requests still unanswered are left in the inbox.
 */
export function collectForeignResponses(
  ids: string[],
  timeoutMs: number,
  pollIntervalMs = 50
): Map<string, ForeignPromptResponse> {
  const answered = new Map<string, ForeignPromptResponse>();
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    for (const id of ids) {
      if (answered.has(id)) continue;
      const response = takeResponse(id);
      if (response) answered.set(id, response);
    }
    if (answered.size === ids.length || Date.now() >= deadline) return answered;
    sleepSync(Math.min(pollIntervalMs, Math.max(1, deadline - Date.now())));
  }
}

/**
 * Image paths in a delivered message point into this machine's kanban home.
 * They are sent relative to the home directory, so the owner resolves them
 * against its own kanban home.
 */
export function portableImagePath(path: string, homes: string[] = [kanbanHome()]): string {
  for (const home of homes) {
    const prefix = home.endsWith("/") ? home : `${home}/`;
    if (path.startsWith(prefix)) return `~/.kanban-code/${path.slice(prefix.length)}`;
  }
  return path;
}
