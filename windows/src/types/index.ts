// TypeScript types mirroring Rust/Swift domain entities

export type KanbanColumn =
  | "backlog"
  | "in_progress"
  | "requires_attention"
  | "in_review"
  | "done"
  | "all_sessions";

export const COLUMN_DISPLAY: Record<KanbanColumn, string> = {
  backlog: "Backlog",
  in_progress: "In Progress",
  requires_attention: "Waiting",
  in_review: "In Review",
  done: "Done",
  all_sessions: "All Sessions",
};

export const COLUMNS: KanbanColumn[] = [
  "backlog",
  "in_progress",
  "requires_attention",
  "in_review",
  "done",
  "all_sessions",
];

export interface SessionLink {
  sessionId: string;
  sessionPath?: string;
  sessionNumber?: number;
}

export interface WorktreeLink {
  path: string;
  branch?: string;
}

export interface PrCheckRun {
  name: string;
  conclusion?: string;
}

export interface PrLink {
  number: number;
  url?: string;
  status?: string;
  title?: string;
  body?: string;
  approvalCount?: number;
  unresolvedThreads?: number;
  mergeStateStatus?: string;
  /** APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED */
  reviewDecision?: string;
  /** Flattened statusCheckRollup. Empty when no CI configured. */
  checkRuns?: PrCheckRun[];
}

export interface IssueLink {
  number: number;
  url?: string;
  title?: string;
  body?: string;
}

export interface ManualOverrides {
  worktreePath: boolean;
  tmuxSession: boolean;
  name: boolean;
  column: boolean;
  prLink: boolean;
  issueLink: boolean;
  dismissedPrs?: number[];
  branchWatermark?: number;
}

export interface QueuedPrompt {
  id: string;
  body: string;
  sendAutomatically: boolean;
  /** Set only for prompts the self-compact guard enqueued (mirrors macOS). */
  selfCompactThresholdTokens?: number;
  /** Absolute paths to images attached to this prompt. Referenced from body
   *  via `[Image #N]` markers (1-based). Mirrors macOS QueuedPrompt. */
  imagePaths?: string[];
}

export interface Link {
  id: string;
  name?: string;
  projectPath?: string;
  column: KanbanColumn;
  createdAt: string;
  updatedAt: string;
  lastActivity?: string;
  manualOverrides: ManualOverrides;
  manuallyArchived: boolean;
  source: "discovered" | "hook" | "github_issue" | "manual";
  promptBody?: string;
  /** Absolute paths to images attached to the prompt body. Referenced via
   *  `[Image #N]` markers (1-based). Mirrors macOS Link.promptImagePaths. */
  promptImagePaths?: string[];
  sessionLink?: SessionLink;
  worktreeLink?: WorktreeLink;
  prLinks: PrLink[];
  issueLink?: IssueLink;
  discoveredBranches?: string[];
  isRemote: boolean;
  isLaunching?: boolean;
  queuedPrompts?: QueuedPrompt[];
  /** Manual sort position within a column; undefined = time-based ordering. */
  sortOrder?: number;
  /** When set, the card is shown in the Pinned section above the lanes. */
  pinnedAt?: string;
  /** Manual order within the Pinned section. Separate from sortOrder so
   *  rearranging a pin never disturbs the card's lane position. */
  pinnedSortOrder?: number;
  /** Coding assistant that owns this card. Drives which CLI runs in the
   *  terminal. Defaults to "claude" for legacy/macOS-written cards. */
  assistantId?: AssistantId;
  /** ISO timestamp of the last drawer open. Stamped by `mark_card_opened`
   *  on selectCard. Mirrors macOS Link.lastOpenedAt. */
  lastOpenedAt?: string;
  /** Per-card override for the resolved APIService. Falls back to
   *  Settings.defaultAPIServiceIds[assistantId]. Mirrors macOS
   *  Link.apiServiceId. */
  apiServiceId?: string;
  /** Persisted state for the card's embedded browser panel. Absent when
   *  the user never opened a tab on this card. Mirrors macOS
   *  Link.browserTabs. */
  browserTabs?: BrowserTabInfo[];
  /** Which shell this card's embedded terminal launches into. `null` /
   *  undefined means the user hasn't picked yet — the gate panel asks
   *  Windows or WSL before any terminal can launch. No global default. */
  cardRuntime?: CardRuntime | null;
}

/** Persisted state for one tab in the card's embedded browser panel.
 *  Live WebView instances are managed separately on the UI side. */
export interface BrowserTabInfo {
  id: string;
  url: string;
  title?: string;
}

export type AssistantId = "claude" | "codex" | "gemini";

export const ASSISTANT_DISPLAY: Record<AssistantId, string> = {
  claude: "Claude Code",
  codex: "Codex CLI",
  gemini: "Gemini CLI",
};

export const ASSISTANT_CLI: Record<AssistantId, string> = {
  claude: "claude",
  codex: "codex",
  gemini: "gemini",
};

export interface Session {
  id: string;
  name?: string;
  firstPrompt?: string;
  projectPath?: string;
  gitBranch?: string;
  messageCount: number;
  modifiedTime: string;
  jsonlPath?: string;
}

export type ActivityState =
  | "activelyWorking"
  | "needsAttention"
  | "idleWaiting"
  | "ended"
  | "stale";

export interface CardDto {
  id: string;
  link: Link;
  session?: Session;
  activityState?: ActivityState;
  displayTitle: string;
  projectName?: string;
  relativeTime: string;
  showSpinner: boolean;
}

export interface BoardStateDto {
  cards: CardDto[];
  lastRefresh?: string;
}

export interface Project {
  path: string;
  name?: string;
  githubFilter?: string;
  repoRoot?: string;
  /** Per-project prompt prefix override (falls back to Settings.promptTemplate). */
  promptTemplate?: string;
}

export interface GlobalViewSettings {
  excludedPaths: string[];
}

export interface GitHubSettings {
  defaultFilter: string;
  pollIntervalSeconds: number;
  mergeCommand: string;
}

export interface NotificationSettings {
  notificationsEnabled: boolean;
  pushoverEnabled: boolean;
  pushoverToken?: string;
  pushoverUserKey?: string;
  renderMarkdownImage: boolean;
}

export interface SessionTimeoutSettings {
  activeThresholdMinutes: number;
}

/** Byte-compatible with macOS RemoteSettings — same JSON field names. */
export interface RemoteSettings {
  host: string;
  remotePath: string;
  localPath: string;
  /** Omitted = use Mutagen defaults from mutagen.rs::default_ignores(). */
  syncIgnores?: string[];
}

export type SyncStatusKind =
  | "disabled"
  | "watching"
  | "scanning"
  | "staging"
  | "conflicts"
  | "paused"
  | "error";

export interface SyncStatus {
  kind: SyncStatusKind;
  sessionName?: string;
  conflictCount: number;
  message?: string;
}

export interface RemoteHostStatus {
  host: string;
  online: boolean;
  since?: string;
}

export interface RemotePrereqs {
  mutagenAvailable: boolean;
  bashAvailable: boolean;
  sshAvailable: boolean;
  mutagenPath?: string;
  bashPath?: string;
}

export type SelfCompactAction = "queuePrompt" | "compactNow";

export interface SelfCompactRule {
  id: string;
  thresholdTokens: number;
  action: SelfCompactAction;
  message: string;
}

export interface SelfCompactSettings {
  enabled: boolean;
  pollIntervalSeconds: number;
  rules: SelfCompactRule[];
}

/** Byte-compatible with macOS APIService. Wraps a coding assistant CLI with
 *  a launcher prefix, model override, and optional base URL injected as an
 *  env var at launch time. */
export interface APIService {
  id: string;
  name: string;
  assistant: AssistantId | string;
  /** Shell command prepended before the assistant CLI (e.g. "ollama launch"). */
  launcherPrefix?: string;
  /** Value passed to `--model`. Omits the flag when undefined. */
  modelFlag?: string;
  /** Base URL injected as `ANTHROPIC_BASE_URL` (or the assistant's
   *  equivalent) at launch time. */
  baseURL?: string;
}

/** Which shell a card's embedded terminal launches into. Lives on
 *  `Link.cardRuntime` — each card asks once via its gate panel; no global
 *  default. Matches `CardRuntime` in `settings_store.rs` (serialized as the
 *  lowercase variant name). */
export type CardRuntime = "windows" | "wsl";

export interface Settings {
  projects: Project[];
  globalView: GlobalViewSettings;
  github: GitHubSettings;
  notifications: NotificationSettings;
  sessionTimeout: SessionTimeoutSettings;
  promptTemplate: string;
  githubIssuePromptTemplate: string;
  hasCompletedOnboarding: boolean;
  editor: string;
  terminalFontSize: number;
  /** Font size for the History tab transcript (8-20). Mirrors macOS
   *  `sessionDetailFontSize` AppStorage; defaults to 12. */
  sessionDetailFontSize?: number;
  remote?: RemoteSettings;
  /** Automatic context-limit guard for Claude sessions (mirrors macOS). */
  selfCompact?: SelfCompactSettings;
  /** Named API service bindings — see APIService. */
  apiServices?: APIService[];
  /** Per-assistant default APIService id (assistant id → service id). */
  defaultAPIServiceIds?: Record<string, string>;
}

/** Mirrors macOS APIService.needsSeparator — a `--` separator before the
 *  assistant's own flags is required iff a launcher prefix or model flag is
 *  set. */
export function apiServiceNeedsSeparator(svc: APIService): boolean {
  return Boolean(svc.launcherPrefix || svc.modelFlag);
}

/** Resolves an APIService for a launch. Per-card override → per-assistant
 *  default → undefined. Mirrors the Rust `Settings::resolve_api_service`
 *  logic; both must stay in sync. */
export function resolveAPIService(
  settings: Settings,
  cardOverride: string | undefined,
  assistantId: string,
): APIService | undefined {
  const services = settings.apiServices ?? [];
  if (cardOverride) {
    const hit = services.find((s) => s.id === cardOverride);
    if (hit) return hit;
    // stale override — fall through so a deleted service doesn't brick the card
  }
  const defaults = settings.defaultAPIServiceIds ?? {};
  const defaultId = defaults[assistantId];
  if (!defaultId) return undefined;
  return services.find((s) => s.id === defaultId);
}

export interface DependencyStatus {
  claudeAvailable: boolean;
  gitAvailable: boolean;
  ghAvailable: boolean;
  ghAuthenticated: boolean;
}

export interface ContentBlock {
  kind: "text" | "tool_use" | "tool_result" | "thinking";
  text: string;
}

export interface Turn {
  index: number;
  role: "user" | "assistant";
  textPreview: string;
  timestamp?: string;
  contentBlocks: ContentBlock[];
}

export interface TranscriptPage {
  turns: Turn[];
  totalTurns: number;
  hasMore: boolean;
  nextOffset: number;
}
