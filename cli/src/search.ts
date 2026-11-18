import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { Link } from "./types.js";

/// `kanban search`: finds the sessions and cards a text was said in.
///
/// It reads every Claude Code transcript under ~/.claude/projects (not only
/// the ones with a card, and archived cards too) plus the transcripts cards
/// point at elsewhere (Codex, Gemini), and matches the words of user prompts
/// and assistant replies. Tool output is left out: it is mostly noise.

export interface SearchMatch {
  role: "user" | "assistant";
  timestamp?: string;
  snippet: string;
}

export interface SessionHit {
  sessionId: string;
  sessionPath: string;
  /// The folder the session ran in.
  cwd?: string;
  gitBranch?: string;
  firstPrompt?: string;
  lastActivity?: string;
  cardId?: string;
  cardName?: string;
  column?: string;
  archived?: boolean;
  matchCount: number;
  matches: SearchMatch[];
}

export interface CardHit {
  cardId: string;
  cardName: string;
  column: string;
  archived: boolean;
  sessionId?: string;
  field: "name" | "prompt" | "branch" | "pr";
  snippet: string;
}

export interface SearchResult {
  query: string;
  terms: string[];
  scannedFiles: number;
  sessions: SessionHit[];
  cards: CardHit[];
}

export interface SearchOptions {
  root: string;
  links: Link[];
  /// Only transcripts written in the last `days` days; 0 reads all.
  days: number;
  /// Most sessions returned.
  limit: number;
  role: "user" | "assistant" | "any";
  /// Snippets kept per session.
  perSession?: number;
  /// Project directories under `root` never read (the orchestrator's own).
  skipDirs?: string[];
  now?: Date;
}

/// Words to match, all of them, in any order and case. "quoted phrases"
/// stay one term.
export function searchTerms(query: string): string[] {
  const terms: string[] = [];
  const re = /"([^"]+)"|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(query))) {
    const term = (m[1] ?? m[2]).toLowerCase().trim();
    if (term) terms.push(term);
  }
  return terms;
}

export function matchesAll(text: string, terms: string[]): boolean {
  const lower = text.toLowerCase();
  return terms.every((t) => lower.includes(t));
}

/// The part of `text` around the first term, on one line.
export function snippetAround(text: string, terms: string[], width = 220): string {
  const flat = text.replace(/\s+/g, " ").trim();
  const lower = flat.toLowerCase();
  let at = -1;
  for (const t of terms) {
    const i = lower.indexOf(t);
    if (i >= 0 && (at < 0 || i < at)) at = i;
  }
  if (at < 0 || flat.length <= width) return flat.slice(0, width);
  const start = Math.max(0, at - Math.floor(width / 3));
  const end = Math.min(flat.length, start + width);
  return (start > 0 ? "…" : "") + flat.slice(start, end) + (end < flat.length ? "…" : "");
}

/// The text of one transcript line, Claude or Codex format.
export function lineText(obj: any): { role: "user" | "assistant"; text: string } | undefined {
  if (obj?.type === "user" || obj?.type === "assistant") {
    if (obj.isMeta) return undefined;
    const content = obj.message?.content;
    let text = "";
    if (typeof content === "string") text = content;
    else if (Array.isArray(content)) {
      text = content
        .filter((b: any) => b?.type === "text")
        .map((b: any) => b.text || "")
        .join("\n");
    }
    text = text.trim();
    return text ? { role: obj.type, text } : undefined;
  }
  if (
    obj?.type === "event_msg" &&
    (obj.payload?.type === "user_message" || obj.payload?.type === "agent_message") &&
    typeof obj.payload?.message === "string" &&
    obj.payload.message.trim()
  ) {
    return { role: obj.payload.type === "user_message" ? "user" : "assistant", text: obj.payload.message.trim() };
  }
  return undefined;
}

/// Prompts the CLI injects that are not the human's words.
function isNoise(text: string): boolean {
  return (
    text.startsWith("<command-") ||
    text.startsWith("<local-command-") ||
    text.startsWith("<system-reminder>") ||
    text.startsWith("Caveat: The messages below")
  );
}

interface TranscriptFile {
  path: string;
  mtime: Date;
}

function transcriptFiles(opts: SearchOptions): TranscriptFile[] {
  const since = opts.days > 0 ? (opts.now ?? new Date()).getTime() - opts.days * 86_400_000 : 0;
  const seen = new Set<string>();
  const files: TranscriptFile[] = [];
  const add = (path: string) => {
    if (seen.has(path)) return;
    seen.add(path);
    try {
      const st = statSync(path);
      if (st.isFile() && st.mtimeMs >= since) files.push({ path, mtime: st.mtime });
    } catch {
      // gone
    }
  };
  const skip = new Set(opts.skipDirs ?? []);
  if (existsSync(opts.root)) {
    for (const dir of safeReaddir(opts.root)) {
      if (skip.has(dir)) continue;
      const dirPath = join(opts.root, dir);
      for (const name of safeReaddir(dirPath)) {
        if (name.endsWith(".jsonl")) add(join(dirPath, name));
      }
    }
  }
  for (const link of opts.links) {
    const p = link.sessionLink?.sessionPath;
    if (p && p.endsWith(".jsonl") && existsSync(p)) add(p);
  }
  return files.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
}

function safeReaddir(path: string): string[] {
  try {
    return readdirSync(path);
  } catch {
    return [];
  }
}

/// Reads a file in 8 MB chunks and reports whether every term occurs in
/// its raw bytes; most files are ruled out here without parsing a line.
function rawContainsAll(path: string, terms: string[]): boolean {
  const left = new Set(terms);
  const fd = openSync(path, "r");
  try {
    const size = statSync(path).size;
    const chunk = 8 * 1024 * 1024;
    const overlap = Math.max(...terms.map((t) => Buffer.byteLength(t))) + 8;
    const buf = Buffer.alloc(chunk + overlap);
    let carry = "";
    for (let pos = 0; pos < size && left.size; pos += chunk) {
      const n = readSync(fd, buf, 0, chunk, pos);
      const text = (carry + buf.toString("utf-8", 0, n)).toLowerCase();
      for (const t of [...left]) if (text.includes(t)) left.delete(t);
      carry = text.slice(-overlap);
    }
  } finally {
    closeSync(fd);
  }
  return left.size === 0;
}

function sessionIdOf(path: string): string {
  return basename(path).replace(/\.jsonl$/, "");
}

export function searchTranscripts(query: string, opts: SearchOptions): SearchResult {
  const terms = searchTerms(query);
  const result: SearchResult = { query, terms, scannedFiles: 0, sessions: [], cards: [] };
  if (!terms.length) return result;

  const bySessionId = new Map<string, Link>();
  const byPath = new Map<string, Link>();
  for (const link of opts.links) {
    if (link.sessionLink?.sessionId) bySessionId.set(link.sessionLink.sessionId, link);
    if (link.sessionLink?.sessionPath) byPath.set(link.sessionLink.sessionPath, link);
  }

  // Cards: titles, first prompts, branches and pull requests.
  for (const link of opts.links) {
    const fields: [CardHit["field"], string | undefined][] = [
      ["name", link.name],
      ["prompt", link.promptBody],
      ["branch", link.worktreeLink?.branch],
      ["pr", (link.prLinks ?? []).map((p) => `#${p.number} ${p.title ?? ""}`).join(" ")],
    ];
    const hit = fields.find(([, text]) => text && matchesAll(text, terms));
    if (hit) {
      result.cards.push({
        cardId: link.id,
        cardName: link.name ?? link.promptBody?.split("\n")[0].slice(0, 80) ?? link.id,
        column: link.column,
        archived: Boolean(link.manuallyArchived),
        sessionId: link.sessionLink?.sessionId,
        field: hit[0],
        snippet: snippetAround(hit[1]!, terms),
      });
    }
  }

  const perSession = opts.perSession ?? 3;
  for (const file of transcriptFiles(opts)) {
    result.scannedFiles++;
    let raw: boolean;
    try {
      raw = rawContainsAll(file.path, terms);
    } catch {
      continue;
    }
    if (!raw) continue;
    const link = byPath.get(file.path) ?? bySessionId.get(sessionIdOf(file.path));
    const hit: SessionHit = {
      sessionId: sessionIdOf(file.path),
      sessionPath: file.path,
      lastActivity: file.mtime.toISOString(),
      matchCount: 0,
      matches: [],
    };
    if (link) {
      hit.cardId = link.id;
      hit.cardName = link.name ?? link.promptBody?.split("\n")[0].slice(0, 80);
      hit.column = link.column;
      hit.archived = Boolean(link.manuallyArchived);
    }
    let text: string;
    try {
      text = readFileSync(file.path, "utf-8");
    } catch {
      continue;
    }
    for (const line of text.split("\n")) {
      if (!line) continue;
      let obj: any;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (!hit.cwd && typeof obj.cwd === "string") hit.cwd = obj.cwd;
      if (!hit.cwd && typeof obj.payload?.cwd === "string") hit.cwd = obj.payload.cwd;
      if (typeof obj.gitBranch === "string" && obj.gitBranch) hit.gitBranch = obj.gitBranch;
      const turn = lineText(obj);
      if (!turn || isNoise(turn.text)) continue;
      if (!hit.firstPrompt && turn.role === "user") hit.firstPrompt = turn.text.replace(/\s+/g, " ").slice(0, 160);
      if (opts.role !== "any" && turn.role !== opts.role) continue;
      if (!matchesAll(turn.text, terms)) continue;
      hit.matchCount++;
      hit.matches.push({ role: turn.role, timestamp: obj.timestamp, snippet: snippetAround(turn.text, terms) });
      if (hit.matches.length > perSession) hit.matches.shift(); // keep the latest
    }
    if (hit.matchCount === 0) continue;
    // A transcript that moved with its session (into a worktree) can sit in
    // two project folders: keep the copy with more matches.
    const twin = result.sessions.findIndex((s) => s.sessionId === hit.sessionId);
    if (twin < 0) result.sessions.push(hit);
    else if (hit.matchCount > result.sessions[twin].matchCount) result.sessions[twin] = hit;
  }

  const latest = (h: SessionHit) => h.matches[h.matches.length - 1]?.timestamp ?? h.lastActivity ?? "";
  result.sessions.sort((a, b) => latest(b).localeCompare(latest(a)));
  result.sessions = result.sessions.slice(0, opts.limit);
  return result;
}

export function formatSearchResult(r: SearchResult): string {
  const out: string[] = [];
  if (!r.terms.length) return "Nothing to search for.";
  if (r.cards.length) {
    out.push(`Cards (${r.cards.length}):`);
    for (const c of r.cards.slice(0, 30)) {
      const state = c.archived ? `${c.column}, archived` : c.column;
      out.push(`  ${c.cardId}  ${c.cardName}  [${state}]  ${c.field}: ${c.snippet}`);
    }
    out.push("");
  }
  out.push(`Sessions (${r.sessions.length}, ${r.scannedFiles} transcripts read):`);
  for (const s of r.sessions) {
    const card = s.cardId
      ? `card ${s.cardId} "${s.cardName ?? ""}" [${s.column}${s.archived ? ", archived" : ""}]`
      : "no card";
    out.push(`- session ${s.sessionId}  ${card}`);
    out.push(`  cwd ${s.cwd ?? "?"}${s.gitBranch ? `  branch ${s.gitBranch}` : ""}  last write ${s.lastActivity ?? "?"}`);
    if (s.firstPrompt) out.push(`  first prompt: ${s.firstPrompt}`);
    out.push(`  ${s.matchCount} match${s.matchCount === 1 ? "" : "es"}, latest:`);
    for (const m of s.matches) out.push(`    [${m.timestamp ?? "?"}] ${m.role === "user" ? "YOU" : " AI"}: ${m.snippet}`);
  }
  if (!r.sessions.length && !r.cards.length) out.push("  none");
  return out.join("\n");
}
