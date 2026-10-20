/**
 * Delivery layer for direct card-to-card messages (`kanban subagent dm`,
 * `kanban parent dm`): paste the message into the recipient's tmux session,
 * or hand it to the owning machine's inbox when another machine owns the card.
 * Auto-detects the sender's card from $TMUX when not passed.
 *
 * The actual `tmux paste-buffer + Enter` is delegated to an injectable
 * `Sender` function so tests can run without a real tmux server.
 */

import { execSync } from "node:child_process";
import { pasteTmuxPrompt } from "./data.js";
import type { Link } from "./types.js";
import {
  collectForeignResponses,
  enqueueForeignPrompt,
  isForeignCard,
  machineLabel,
  portableImagePath,
  readLocalMachine,
} from "./machines.js";
import { kanbanHome } from "./paths.js";
import { formatHandle } from "./handles.js";
import {
  relationshipLabel,
  subagentRelationship,
  type SubagentRelationship,
} from "./hierarchy.js";

// ── Types / injectables ───────────────────────────────────────────────

export interface Sender {
  (tmuxSession: string, text: string): { ok: boolean; error?: string };
}

export interface LiveSessionProbe {
  (tmuxSession: string): boolean;
}

export interface DeliveryOptions {
  sender?: Sender;
  liveSessionProbe?: LiveSessionProbe;
  /**
   * This master's machine id. Cards another machine owns get the message
   * through the command inbox instead of a tmux paste. Undefined reads
   * `machine.json`; null treats every card as local.
   */
  localMachineId?: string | null;
  /** Longest wait for the master to confirm foreign deliveries. */
  foreignResponseTimeoutMs?: number;
  /** Request id generator for foreign deliveries (tests). */
  foreignRequestId?: () => string;
}

// ── Resolve current card from tmux ───────────────────────────────────

/**
 * Resolve the tmux session name the CLI is running INSIDE. Returns undefined
 * if not running inside tmux.
 */
export function currentTmuxSessionName(): string | undefined {
  if (!process.env.TMUX) return undefined;
  try {
    const out = execSync(`tmux display-message -p '#S'`, { encoding: "utf-8" }).trim();
    return out || undefined;
  } catch {
    return undefined;
  }
}

function tmuxLinkMatchScore(link: Link, sessionName: string, primary: boolean): number {
  let score = primary ? 100 : 0;
  if (sessionName.includes(link.id)) score += 1000;
  if (!link.manuallyArchived) score += 100;
  if (link.column !== "all_sessions") score += 50;
  if (link.worktreeLink) score += 20;
  if (link.sessionLink) score += 10;
  return score;
}

/** Find the card whose tmux session matches the given session name. */
export function cardForTmuxSession(links: Link[], sessionName: string): Link | undefined {
  const matches = links
    .map((link) => {
      if (link.tmuxLink?.sessionName === sessionName) {
        return { link, score: tmuxLinkMatchScore(link, sessionName, true) };
      }
      if (link.tmuxLink?.extraSessions?.includes(sessionName)) {
        return { link, score: tmuxLinkMatchScore(link, sessionName, false) };
      }
      return undefined;
    })
    .filter((m): m is { link: Link; score: number } => Boolean(m));

  matches.sort((a, b) => b.score - a.score);
  return matches[0]?.link;
}

/**
 * The card named by `KANBAN_CARD_ID`. A remote card exports it into its tmux
 * session because the machine has no board to look the session up in, and the
 * Mac exports it again when it runs a proxied command on the card's behalf.
 * It wins over the tmux lookup: it is the caller the card itself declared.
 */
export function cardFromEnvironment(
  links: Link[],
  env: NodeJS.ProcessEnv = process.env
): Link | undefined {
  const id = env.KANBAN_CARD_ID?.trim();
  if (!id) return undefined;
  return links.find((link) => link.id === id);
}

// ── Foreign cards ────────────────────────────────────────────────────

export const FOREIGN_RESPONSE_TIMEOUT_MS = 3_000;

function resolveLocalMachineId(opts: DeliveryOptions): string | undefined {
  if (opts.localMachineId === null) return undefined;
  return opts.localMachineId ?? readLocalMachine()?.id;
}

function portableImages(imagePaths: string[] | undefined): string[] | undefined {
  if (!imagePaths || imagePaths.length === 0) return imagePaths;
  const homes = [kanbanHome()];
  return imagePaths.map((p) => portableImagePath(p, homes));
}

// ── Formatting ────────────────────────────────────────────────────────

function renderImageRefs(imagePaths?: string[]): string {
  if (!imagePaths || imagePaths.length === 0) return "";
  return "\n" + imagePaths.map((p) => `![](${p})`).join("\n");
}

export function formatDirectMessage(
  handle: string,
  body: string,
  imagePaths?: string[],
  relationship?: SubagentRelationship
): string {
  const role = relationshipLabel(relationship);
  return `[DM from ${formatHandle(handle)}${role}]: ${body}${renderImageRefs(imagePaths)}`;
}

// ── Direct message delivery ──────────────────────────────────────────

export interface DirectMessage {
  id: string;
  ts: string;
  from: { cardId: string | null; handle: string };
  to: { cardId: string | null; handle: string };
  body: string;
  imagePaths?: string[];
}

/**
 * Deliver a direct message to one card. Nothing is persisted: the message
 * lives only in the recipient's session.
 */
export function sendDirectMessage(
  from: { cardId: string | null; handle: string },
  to: { cardId: string | null; handle: string },
  body: string,
  links: Link[],
  opts: DeliveryOptions = {},
  imagePaths: string[] = []
): { msg: DirectMessage; delivered: boolean; error?: string; via?: string } {
  const sender: Sender = opts.sender ?? pasteTmuxPrompt;
  const probe: LiveSessionProbe = opts.liveSessionProbe ?? ((_n) => true);
  const images = imagePaths.filter((p) => p.length > 0);
  const msg: DirectMessage = {
    id: `msg_${Date.now().toString(36)}`,
    ts: new Date().toISOString(),
    from,
    to,
    body,
    ...(images.length > 0 ? { imagePaths: images } : {}),
  };
  if (to.cardId === null) {
    return { msg, delivered: false, error: "recipient has no tmux session (user)" };
  }
  const link = links.find((l) => l.id === to.cardId);
  if (link && isForeignCard(link, resolveLocalMachineId(opts))) {
    const text = formatDirectMessage(
      from.handle,
      body,
      images.length > 0 ? portableImages(images) : undefined,
      subagentRelationship(from.cardId, to.cardId, links)
    );
    const via = machineLabel(link.ownerMachine!);
    const request = enqueueForeignPrompt(link.id, text, opts.foreignRequestId?.());
    const answer = collectForeignResponses(
      [request.id],
      opts.foreignResponseTimeoutMs ?? FOREIGN_RESPONSE_TIMEOUT_MS
    ).get(request.id);
    if (answer && !answer.ok) {
      return { msg, delivered: false, error: `${via} refused: ${answer.error ?? "unknown error"}`, via };
    }
    return { msg, delivered: true, via };
  }
  const session = link?.tmuxLink?.sessionName;
  if (!session) return { msg, delivered: false, error: "recipient has no tmux session" };
  if (!probe(session)) return { msg, delivered: false, error: "recipient offline" };
  const text = formatDirectMessage(
    from.handle,
    body,
    images.length > 0 ? images : undefined,
    subagentRelationship(from.cardId, to.cardId, links)
  );
  const r = sender(session, text);
  return { msg, delivered: r.ok, error: r.error };
}
