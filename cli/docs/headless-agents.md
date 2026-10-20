# Headless agents

Run long-lived Claude Code agents on a server with no macOS app. Each agent is a
persistent Claude Code session in a tmux session or on a rush host, driven
entirely by the `kanban` CLI + Claude Code hooks. This is what powers an always-on agent fleet (e.g. a
nightly dependency-review agent).

## Model

- **Stable, readable identity.** An agent is identified by a slug like
  `dependabot-scout`. The slug deterministically maps to a Claude session id
  (UUIDv5), and is also the `--name`, the tmux session name (on tmux), the kanban card name,
  and the git worktree name. `claude --session-id` needs a UUID, so the id is
  derived from the slug while everything you see and type stays readable.
- **Worktree-only.** An agent's working directory is always its per-agent worktree
  workspace under `workspacesDir/<slug>/`, never a canonical clone. It cannot dirty
  the canonical clone.
- **Repo hygiene is the deployer's job.** The CLI never clones, stashes, pulls, or
  resets repos. The host (your IaC) provisions the canonical clones under
  `reposDir` and keeps their `main` clean and current. The reconciler errors loudly
  if a canonical clone is missing.

## Config (`agents.yaml`)

```yaml
reposDir: /home/ubuntu/agent-repos
workspacesDir: /home/ubuntu/agent-workspaces
host: rush                           # optional, tmux (default) or rush, for every agent
agents:
  - slug: dependabot-scout
    host: tmux                       # optional, overrides the top-level host
    repos: [langwatch/langwatch, langwatch/scenario]
    model: opus                      # optional, claude --model
    schedule: "06:00"                # used by your scheduler (systemd timer)
    dailyPrompt: |
      It's a new day. Check open Dependabot PRs ...
```

Point the CLI at it with `--config` or `KANBAN_AGENTS_CONFIG`.

## Hosts (`host: tmux | rush`)

`tmux` (the default) runs `claude` in a tmux session named after the slug.

`rush` runs the agent on a [rush](https://github.com/0xdeafcafe/rush) host
started with `rush session start --agent claude`. Rush keeps several Claude
accounts signed in and moves the session to another one when the current account
runs low, so a fleet on one box does not stop on a single logout or empty plan.
Rush runs Claude only: a `runtime: codex` agent stays on tmux and the CLI prints a
warning if it asked for rush.

- The host id is the first eight hex digits of the agent's session id, and the
  card's session name is `rush-<host id>`. `kanban send`, `interrupt`,
  `self-compact` and the daemon all address the agent through
  that name, which maps to `rush session send | interrupt | stop`.
- The host carries the metas `kanban_session=rush-<id>`, `kanban_agent=<slug>`
  and `kanban_card=<card id>`. `rush session list --meta kanban_agent=<slug>`
  finds an agent's host.
- Reconcile never restarts a host that is running or resting after its turn (the
  next message wakes a resting one). A dead host with a transcript is started with
  `--resume`; a new agent is started fresh with `--session-id`.
- Switching an agent from tmux to rush kills its old tmux session before the host
  starts, and switching back stops the host, so two processes never run one
  conversation. The card keeps its id and gets the new session name.

## Commands

| Command | What it does |
|---|---|
| `kanban launch <slug> --cwd <dir> [--host tmux\|rush]` | Launch or resume one agent session (idempotent) |
| `kanban reconcile [--prune]` | Ensure every configured agent's worktree + session + card; `--prune` tears down de-configured agents |
| `kanban daemon [--poll-interval ms] [--no-self-compact]` | Always-on engine: auto-send queued prompts on Stop, auto-compact long sessions |
| `kanban hooks install` | Install Claude hooks + statusline into `~/.claude/settings.json` |
| `kanban send <slug> "<msg>"` | Paste a prompt directly into one agent's tmux session |

## Auto-compaction

The daemon polls each session's context usage (written by the statusline hook to
`~/.kanban-code/context/<sessionId>.json`) and, by threshold:

- 500k / 600k / 700k tokens: queue a self-compact reminder for the agent (auto-sent
  on the next idle Stop). A reminder is dropped if context already fell back below
  its threshold.
- 750k tokens: send `/compact` to the session directly.

## Deploying as services (systemd sketch)

```
agents-reconcile.service   # oneshot on boot: kanban reconcile (resumes sessions)
agents-daemon.service      # long-running: kanban daemon
agents-<slug>.timer        # daily: kanban send <slug> "<dailyPrompt>"
```

On reboot or spot reclaim, `agents-reconcile.service` resumes every agent with
`claude --resume`, so sessions survive indefinitely. Make the daily timers
`After=agents-reconcile.service` so a morning wake resumes before it nudges.

## State

All under `~/.kanban-code/` (override with `KANBAN_CODE_HOME`):
`links.json` (cards), `context/<sessionId>.json` (usage, from the statusline hook),
`hook-events.jsonl` (hook events the daemon tails), `hook.sh`, `statusline.sh`.
