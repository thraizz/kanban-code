/**
 * `kv import`: finds plaintext secrets on this machine, plans their move
 * into the vault, and with `--apply` adds them and writes a `.env.vault`
 * next to each `.env` it took secrets from. Nothing is deleted: the
 * plaintext files stay until Rogerio decides.
 *
 * The plan names secrets and their sources, never values.
 */

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import type { VaultClient, VaultIO, VaultResponse, VaultSecretInfo } from "./vault.js";

export type Tier = "open" | "judged" | "ask" | "never";

export interface FoundValue {
  key: string;
  value: string;
  file: string;
}

export interface PlannedSecret {
  name: string;
  tier: Tier;
  rules: string;
  value: string;
  sources: { file: string; key: string }[];
  everyUseAsks?: boolean;
  aws?: { sourceSecret: string; roleArn?: string; policyArns: string[]; durationSeconds: number };
}

const SKIP_DIRS = new Set([
  "node_modules", ".venv", "venv", ".git", "worktrees", ".worktrees", "dist", "build", ".build", ".next",
  "target", "__pycache__", ".cache", ".turbo", "vendor", "Pods", "DerivedData", ".pnpm-store", "site-packages",
]);

const SAMPLE = /\.(example|sample|template|dist|defaults?|tpl|vault)$|example|sample|template/i;

/** `.env` and `.env.<x>` files under `root`, skipping dependency and worktree folders. */
export function findEnvFiles(root: string, maxDepth = 7): string[] {
  const out: string[] = [];
  const walk = (dir: string, depth: number) => {
    if (depth > maxDepth) return;
    let entries: import("node:fs").Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const path = join(dir, e.name);
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name) || e.name.endsWith("-worktrees") || path.includes("/.claude/worktrees/")) continue;
        walk(path, depth + 1);
      } else if (e.isFile() && (e.name === ".env" || e.name.startsWith(".env.")) && !SAMPLE.test(e.name)) {
        out.push(path);
      }
    }
  };
  walk(root, 0);
  return out.sort();
}

export function parseDotenv(text: string): { key: string; value: string }[] {
  const out: { key: string; value: string }[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"') && value.length >= 2) || (value.startsWith("'") && value.endsWith("'") && value.length >= 2)) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/, "");
    }
    out.push({ key: m[1], value });
  }
  return out;
}

const SECRET_KEY = /(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS$|_PASS_|AUTH|CREDENTIAL|PRIVATE|DSN|COOKIE|SESSION_SECRET|SIGNING|WEBHOOK)/i;
const SECRET_PREFIX = /^(sk-|sk_live_|sk_test_|rk_live_|pk_live_|ghp_|gho_|ghs_|github_pat_|xox[abpors]-|AKIA|ASIA|AIza|ya29\.|eyJ|glpat-|kc_|lwl_|lw_|sk-ant-|nxk_|apik|hf_|r8_|gsk_|xai-|pplx-)/;

/** Values that are clearly configuration, not credentials. */
export function looksLikePlainConfig(value: string): boolean {
  if (value === "") return true;
  if (/^(true|false|yes|no|on|off|null|undefined|none|production|development|test|staging|debug|info|warn|error)$/i.test(value)) return true;
  if (/^-?\d+(\.\d+)?$/.test(value)) return true;
  if (/^(https?|wss?|redis|postgres(ql)?|clickhouse|mysql|mongodb(\+srv)?):\/\/[^/@\s]*$/i.test(value) && !value.includes("@")) {
    return true;
  }
  if (/^(https?|wss?):\/\/[^@\s]+$/i.test(value)) return true;
  if (/^[a-z0-9-]+(\.[a-z0-9-]+)*(:\d+)?$/i.test(value) && value.length < 40 && !/\d{6,}/.test(value)) return true;
  if (value.startsWith("/") || value.startsWith("./") || value.startsWith("~")) return true;
  return false;
}

const PLACEHOLDER = /^(x+|changeme|change-me|your[-_].*|<.*>|\$\{.*\}|\.\.\.|todo|tbd|placeholder|dummy|fake|test|secret|password|sk-1234.*|sk-xxx.*|undefined|null)$/i;

export function isSecret(key: string, value: string): boolean {
  if (!value || PLACEHOLDER.test(value) || value.length < 8) return false;
  if (SECRET_PREFIX.test(value)) return true;
  if (/^[a-z]+:\/\/[^:/\s]+:[^@\s]+@/i.test(value)) return true;
  if (SECRET_KEY.test(key)) return !looksLikePlainConfig(value) || value.length >= 16;
  // High-entropy blobs under innocent names.
  if (value.length >= 24 && /[A-Z]/.test(value) && /[a-z]/.test(value) && /\d/.test(value) && !/\s/.test(value) && !value.includes("/")) {
    return true;
  }
  return false;
}

const OPEN = /(OPENAI|ANTHROPIC|GEMINI|GOOGLE_API_KEY|GOOGLE_GENERATIVE|AZURE_OPENAI|AZURE_API|GROQ|MISTRAL|COHERE|TOGETHER|OPENROUTER|DEEPSEEK|XAI|PERPLEXITY|HUGGINGFACE|HF_TOKEN|REPLICATE|ELEVENLABS|VOYAGE|FIREWORKS|CEREBRAS|JEV|TYPESAFE|GRANOLA|NOTION|NEXUS|LITELLM|DEEPGRAM|ASSEMBLYAI|TAVILY|SERPER|EXA_API)/i;
const JUDGED = /(CLOUDFLARE|CF_API|GITHUB|GH_TOKEN|SLACK|GMAIL|GOOGLE_CLIENT|AWS|SENTRY|POSTHOG|RESEND|SENDGRID|TWILIO|LINEAR|VERCEL|NPM_TOKEN|DOCKER|BOXD|TAILSCALE|CUSTOMERIO)/i;
const ASK = /(STRIPE.*LIVE|METABASE|LICENSE.*(PRIVATE|SIGNING)|PRIVATE_KEY|PROD.*(ADMIN|ROOT)|ROOT_TF)/i;

export function tierFor(key: string, value: string): { tier: Tier; everyUseAsks?: boolean; rules: string } {
  if (value.startsWith("kc_")) return { tier: "never", rules: "Kanban Code device token: never released." };
  if (value.startsWith("sk_live_") || value.startsWith("rk_live_") || /STRIPE/i.test(key) && /live/i.test(value)) {
    return { tier: "ask", everyUseAsks: true, rules: "Stripe live key: every use needs Rogerio." };
  }
  if (ASK.test(key)) return { tier: "ask", rules: "Sensitive production credential: Rogerio approves." };
  if (OPEN.test(key) || /^(sk-ant-|sk-proj-|AIza|apik|gsk_|xai-|pplx-)/.test(value)) {
    return { tier: "open", rules: "Model provider or tooling key for development and tests." };
  }
  if (/SLACK/i.test(key) || value.startsWith("xox")) {
    return { tier: "judged", rules: "Slack token. Reading is fine. Posting speaks as Rogerio or the bot: ask unless the task says to post." };
  }
  if (/GMAIL/i.test(key)) return { tier: "judged", rules: "Gmail access. Reading and drafting are fine; sending anything external asks." };
  if (/GITHUB|GH_TOKEN/i.test(key) || /^(ghp_|gho_|github_pat_)/.test(value)) {
    return { tier: "judged", rules: "GitHub token: pushing branches, opening and commenting on PRs is fine; deleting repos or changing org settings is not." };
  }
  if (/CLOUDFLARE|CF_API/i.test(key)) return { tier: "judged", rules: "Cloudflare token: deploys of Workers and Pages are fine; DNS or zone changes ask." };
  if (JUDGED.test(key)) return { tier: "judged", rules: "" };
  return { tier: "judged", rules: "" };
}

function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function projectOf(file: string, home: string): string {
  const rel = relative(join(home, "Projects"), file);
  if (rel.startsWith("..")) return basename(dirname(file)).replace(/^\./, "") || "home";
  const parts = rel.split("/");
  return parts[0] === "local" && parts.length > 2 ? parts[1] : parts[0];
}

/** Groups found values by value, names each group, and picks its tier. */
export function planSecrets(found: FoundValue[], home = homedir()): PlannedSecret[] {
  const byValue = new Map<string, FoundValue[]>();
  for (const f of found) {
    const h = hash(f.value);
    byValue.set(h, [...(byValue.get(h) ?? []), f]);
  }
  const groups = [...byValue.values()].sort((a, b) => b.length - a.length);
  const taken = new Map<string, string>();
  const plans: PlannedSecret[] = [];
  for (const group of groups) {
    const counts = new Map<string, number>();
    for (const f of group) counts.set(f.key, (counts.get(f.key) ?? 0) + 1);
    const key = [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].length - b[0].length || a[0].localeCompare(b[0]))[0][0];
    const base = key.toUpperCase().replace(/[^A-Z0-9_]/g, "_");
    let name = base;
    if (taken.has(name)) {
      const projects = new Map<string, number>();
      for (const f of group) {
        const p = projectOf(f.file, home).toUpperCase().replace(/[^A-Z0-9]/g, "_");
        projects.set(p, (projects.get(p) ?? 0) + 1);
      }
      const ranked = [...projects.entries()].sort((a, b) => b[1] - a[1]).map(([p]) => `${base}__${p}`);
      name = ranked.find((n) => !taken.has(n)) ?? ranked[0];
      for (let n = 2; taken.has(name); n++) name = `${ranked[0]}_${n}`;
    }
    taken.set(name, group[0].value);
    const t = tierFor(key, group[0].value);
    plans.push({
      name,
      tier: t.tier,
      rules: t.rules,
      everyUseAsks: t.everyUseAsks,
      value: group[0].value,
      sources: group.map((f) => ({ file: f.file, key: f.key })),
    });
  }
  return plans.sort((a, b) => a.name.localeCompare(b.name));
}

interface AwsProfile {
  name: string;
  keyId?: string;
  secret?: string;
  sourceProfile?: string;
  roleArn?: string;
}

export function parseIni(text: string): Map<string, Record<string, string>> {
  const out = new Map<string, Record<string, string>>();
  let current: Record<string, string> | undefined;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const section = /^\[(.+)\]$/.exec(line);
    if (section) {
      current = {};
      out.set(section[1].replace(/^profile\s+/, "").trim(), current);
      continue;
    }
    const kv = /^([^=]+?)\s*=\s*(.*)$/.exec(line);
    if (kv && current) current[kv[1].trim()] = kv[2].trim();
  }
  return out;
}

/** AWS long-lived keys plus one vault profile per role, per the tier list. */
export function planAws(credentialsText: string, home = homedir()): PlannedSecret[] {
  const file = join(home, ".aws/credentials");
  const profiles: AwsProfile[] = [...parseIni(credentialsText).entries()].map(([name, v]) => ({
    name,
    keyId: v.aws_access_key_id,
    secret: v.aws_secret_access_key,
    sourceProfile: v.source_profile,
    roleArn: v.role_arn,
  }));
  const plans: PlannedSecret[] = [];
  const keyName = (p: string) => `AWS_KEY_${p.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
  for (const p of profiles) {
    if (!p.keyId || !p.secret) continue;
    plans.push({
      name: keyName(p.name),
      tier: "never",
      rules: "Long-lived AWS key: only the vault uses it, to mint 1 hour STS credentials.",
      value: JSON.stringify({ accessKeyId: p.keyId, secretAccessKey: p.secret }),
      sources: [{ file, key: `[${p.name}]` }],
    });
    plans.push({
      name: `aws:${p.name}`,
      tier: "ask",
      everyUseAsks: true,
      rules: "Root account session credentials: every use needs Rogerio.",
      value: "",
      sources: [{ file, key: `[${p.name}]` }],
      aws: { sourceSecret: keyName(p.name), policyArns: [], durationSeconds: 3600 },
    });
  }
  for (const p of profiles) {
    if (!p.roleArn || !p.sourceProfile) continue;
    const source = keyName(p.sourceProfile);
    const sources = [{ file, key: `[${p.name}]` }];
    const role = { sourceSecret: source, roleArn: p.roleArn, policyArns: [] as string[], durationSeconds: 3600 };
    if (/prod/.test(p.name)) {
      plans.push({
        name: `aws:${p.name}:read`,
        tier: "ask",
        rules: `${p.name} read-only (ReadOnlyAccess session policy): a card lease lasts 2 days.`,
        value: "",
        sources,
        aws: { ...role, policyArns: ["arn:aws:iam::aws:policy/ReadOnlyAccess"] },
      });
      plans.push({
        name: `aws:${p.name}`,
        tier: "ask",
        everyUseAsks: true,
        rules: `${p.name} admin: every call needs Rogerio.`,
        value: "",
        sources,
        aws: role,
      });
    } else {
      plans.push({
        name: `aws:${p.name}`,
        tier: "judged",
        rules: `${p.name} account: development work is fine (reads, deploys, kubectl on dev clusters). Deleting accounts, IAM users or billing settings asks.`,
        value: "",
        sources,
        aws: role,
      });
    }
  }
  return plans;
}

export function collectFound(files: string[]): FoundValue[] {
  const found: FoundValue[] = [];
  for (const file of files) {
    let text: string;
    try {
      if (statSync(file).size > 512 * 1024) continue;
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const { key, value } of parseDotenv(text)) {
      if (isSecret(key, value)) found.push({ key, value, file });
    }
  }
  return found;
}

export function renderPlan(plans: PlannedSecret[], files: string[], home = homedir()): string {
  const tilde = (p: string) => (p.startsWith(home) ? "~" + p.slice(home.length) : p);
  const byTier = (t: Tier) => plans.filter((p) => p.tier === t);
  const lines = [
    "# Vault import plan",
    "",
    `Generated ${new Date().toISOString()} by \`kv import\`. Names and sources only, no values.`,
    "",
    `${files.length} files scanned, ${plans.length} secrets after deduplicating by value.`,
    `Tiers: open ${byTier("open").length}, judged ${byTier("judged").length}, ask ${byTier("ask").length}, never ${byTier("never").length}.`,
    "",
  ];
  for (const tier of ["open", "judged", "ask", "never"] as Tier[]) {
    const list = byTier(tier);
    if (!list.length) continue;
    lines.push(`## ${tier}`, "");
    for (const p of list) {
      const extra = p.everyUseAsks ? " (every use asks)" : "";
      lines.push(`- \`${p.name}\`${extra}: ${p.sources.map((s) => `${tilde(s.file)} ${s.key}`).join("; ")}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

/** The `.env.vault` for one `.env`: its secret keys as vault references, its plain config as is. */
export function envVaultFor(envText: string, refs: Map<string, string>): string {
  const out = ["# Names only: kv env .env.vault -- <cmd> loads the values from the Kanban Code vault."];
  for (const { key, value } of parseDotenv(envText)) {
    const name = refs.get(key);
    if (name) out.push(`${key}={{vault:${name}}}`);
    else if (!isSecret(key, value) && looksLikePlainConfig(value)) out.push(`${key}=${/\s|#/.test(value) ? JSON.stringify(value) : value}`);
  }
  return out.join("\n") + "\n";
}

export async function runImport(args: string[], client: VaultClient, io: VaultIO): Promise<number> {
  const apply = args.includes("--apply");
  // --only <dir> (repeatable): write .env.vault files only under these folders.
  const only: string[] = [];
  for (let i = 0; i < args.length; i++) if (args[i] === "--only" && args[i + 1]) only.push(args[i + 1].replace(/\/+$/, ""));
  const home = homedir();
  const root = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--only") ?? join(home, "Projects");
  const extra = [join(home, ".agent-vault/open.env"), join(home, ".config/slack-rogerio.env")].filter(existsSync);
  const files = [...findEnvFiles(root), ...extra];
  const plans = planSecrets(collectFound(files), home);
  const credentials = join(home, ".aws/credentials");
  if (existsSync(credentials)) plans.push(...planAws(readFileSync(credentials, "utf8"), home));

  const planDir = io.env.KV_IMPORT_PLAN_DIR || join(home, "Projects/kanban/.claude/tmp/vault");
  mkdirSync(planDir, { recursive: true });
  const planPath = join(planDir, "import-plan.md");
  writeFileSync(planPath, renderPlan(plans, files, home));
  io.stderr(`kv: plan for ${plans.length} secrets from ${files.length} files written to ${planPath}\n`);
  if (!apply) {
    io.stderr("kv: nothing imported; run kv import --apply to add them to the vault.\n");
    return 0;
  }

  const existing = new Set((await client.call<VaultSecretInfo[]>("GET", "secrets")).body.map((s) => s.name));
  let added = 0;
  let kept = 0;
  for (const p of plans) {
    if (existing.has(p.name)) {
      kept++;
      continue;
    }
    const { body } = await client.call<VaultResponse>("POST", "secrets", {
      name: p.name,
      value: p.value,
      tier: p.tier,
      rules: p.rules,
      aws: p.aws,
      leasePolicy: p.everyUseAsks ? { leaseSeconds: 172800, everyUseAsks: true } : undefined,
      sources: p.sources.map((s) => `${s.file.startsWith(home) ? "~" + s.file.slice(home.length) : s.file} ${s.key}`),
    });
    if (body.status !== "granted") throw new Error(`could not add ${p.name}: ${body.message}`);
    added++;
  }

  if (args.includes("--secrets-only")) {
    io.stderr(`kv: added ${added} secrets (${kept} were already there); no .env.vault written.\n`);
    return 0;
  }

  // One .env.vault per .env that gave secrets, next to it.
  const refsByFile = new Map<string, Map<string, string>>();
  for (const p of plans) {
    for (const s of p.sources) {
      if (!s.file.endsWith("credentials") && !extra.includes(s.file) && !/backup|\.bak|\.orig|\.old/i.test(basename(s.file))) {
        const m = refsByFile.get(s.file) ?? new Map<string, string>();
        m.set(s.key, p.name);
        refsByFile.set(s.file, m);
      }
    }
  }
  let written = 0;
  for (const [file, refs] of refsByFile) {
    if (only.length && !only.some((dir) => file.startsWith(dir + "/"))) continue;
    const target = join(dirname(file), basename(file) === ".env" ? ".env.vault" : `${basename(file)}.vault`);
    if (existsSync(target) && !readFileSync(target, "utf8").startsWith("# Names only")) continue;
    writeFileSync(target, envVaultFor(readFileSync(file, "utf8"), refs));
    written++;
  }
  io.stderr(`kv: added ${added} secrets (${kept} were already there), wrote ${written} .env.vault files. The plaintext files are untouched.\n`);
  return 0;
}
