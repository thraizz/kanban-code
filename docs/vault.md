# Vault

The vault keeps secrets out of plaintext files. Every master (the Mac app and `kanban-code-server`) runs it; the box is its home and the Mac keeps a replica.

## Storage

`~/.kanban-code/vault/` on each master:

| File | Content |
|------|---------|
| `vault.age` | All secrets, age-encrypted to the vault key, with an HMAC keyed from the same key so only key holders can write a replica |
| `leases.json` | Card leases: card, secret, expiry. No values |
| `audit.jsonl` | Append-only log of this machine: time, card, secret, tier, outcome, decider, command |
| `pending.age` | Approval requests still waiting for the human, age-encrypted to the vault key (an add carries the new value). Removed when none are open |

The key is an age X25519 identity. On the box it is `vault/identity.txt` (0600, root). On the Mac it is the login keychain item `io.kanbancode.vault` / `age-identity`, readable without a prompt only by the signed app. To give a machine the key, write it to `~/.kanban-code/vault/identity.import`; the master imports it at start and deletes the file.

Recovery without Kanban Code: `age -d -i identity.txt vault.age` gives `{"doc": <base64 JSON>, "auth": ...}`; the `doc` field is the secrets.

Replicas sync with the configured peers every minute (`GET`/`POST /v1/vault/replica`, full-scope peer token). Each secret's newest edit wins; a delete is an edit.

## Tiers and decisions

| Tier | Release |
|------|---------|
| open | Any card session, logged |
| judged | Jev reads the command, the reason, the card title, the card's recent prompts and the secret's rules: allow, ask or deny |
| ask | Rogerio approves on the Mac or the phone |
| never | Refused |

Order, first match wins:

1. Tier never: deny.
2. The caller is not inside a card session: ask, whatever the tier.
3. More than 20 releases of the secret in 5 minutes: ask.
4. The card holds a lease and the secret allows leases: allow.
5. Open: allow. Judged: Jev (allow needs at least 60% probability; Jev unreachable asks). Ask: the human.

"Inside a card session" is checked by the master, not claimed by the client. kv calls the local master over loopback; the master finds the calling process from the TCP connection (`lsof` on macOS, `/proc/net/tcp` on Linux), walks its parents, and matches them against the pane shells of the cards' tmux sessions and the assistant processes rush hosts for cards. A rush host belongs to the card whose terminal is `rush-<host id>` (or `agtop-<host id>` for a host started before rush was renamed from agtop) in Kanban's links, whoever started it (the master, a rush view, `rush session start`); its own `--meta kanban_card` is never read. Accepted risk: a local process can start a host for a card's session id and act as that card; such a process already runs as the user. `KANBAN_CARD_ID` is only shown to the human when it could not be verified. Requests over the network are never inside a card.

OpenClaw agents on a Linux master count like card sessions under the principal `openclaw:<agent>`: the master finds, in the caller's ancestry, a process whose cgroup is the gateway's systemd unit (`openclaw-gateway.service`, set by systemd, not by the process), then the topmost process below the gateway whose working directory is an agent workspace from `~/.openclaw/openclaw.json` (the agent runtime the gateway started; a child that changes directory does not change it). The gateway itself, resolving SecretRefs, is `openclaw:gateway`. Each principal holds its own leases. Commands an agent starts outside the unit (`systemd-run`, cron) are outside, so they ask.

Human approvals are attention requests of kind `vaultApproval` with the options "Approve for this card (2 days)", "Approve once", "Deny". A secret with "every use asks" never offers the lease. No answer in 60 minutes denies; kv says so when it starts waiting.

### What Jev reads

For a caller the master matched to a card, Jev also gets the card's recent prompts, read from its transcript on the master that runs it (its own path, the peer mirror, or the session id under `~/.claude/projects`; Claude Code and Codex). `CardPromptReader` keeps the last 5 prompts entered in the session, each cut to its first 900 and last 400 characters, 4000 characters in all, and up to 20 older prompts before them, each cut to its first 200 characters, another 4000 in all, so an instruction given early in the task still counts. Jev gets them under `what_rogerio_asked_this_card`, oldest first, the older ones marked as shortened. The agent's `--reason` goes as `agent_reason_unverified`, a claim Jev trusts only as far as those prompts back it.

Text the harness writes (task notifications, messages between Claude sessions, compact summaries, command output, tool results) is left out. Every Kanban path that pastes another sender's text marks it, and prompts that open with a marker are listed under `messages_from_other_senders` with their sender, never as Rogerio's:

| Marker | Sent by |
|--------|---------|
| `[DM from @x]:` | `kanban dm` |
| `[Message from #c @x]:` | a channel message |
| `[Message from @x]:` | `kanban send` or `kanban subagent send` run inside card `@x` (on this master or forwarded to another) |
| `[Message from NAME (remote agent)]:` | `POST /v1/cards/{id}/prompt` with an agent-scope device token |
| `[Self-compact follow-up from this card]:` | the follow-up of `kanban self-compact` |
| `You are running as subagent card` | the goal a parent agent gives its subagent |
| `From NAME (Slack):` | the Slack bridge |
| the public share link warning | a message through a shared channel link |

Assistant commands (text starting with `/`) are never marked. Prompts Rogerio sends from the app (chat box, queued prompts, the phone with a full-scope token) and `kanban send` from a shell outside any card stay unmarked. When the transcript is not on the master, Jev judges without prompts.

### Restarts

An open approval survives a restart of its master. The broker keeps open requests and their attention requests in `pending.age`; at start it raises them again and keeps waiting from the original creation time, so the timeout is unchanged. A poll that arrives before that finishes waits for it. Answered results are not saved, since a result can carry values; its caller fetches it within a couple of seconds.

kv waits out a master that does not answer: on a refused connection, or HTTP 502/503, it prints `the master ... is not answering (...), probably restarting; waiting up to 2 min...` and retries with backoff (1, 2, 4, 8, then 10 seconds) for up to 2 minutes. A GET is always retried; a POST only when the connection was refused, so a request that may have reached the master is never sent twice. `kv exec-provider` does not wait: OpenClaw gets `UNREACHABLE` at once.

### What the human sees

The notification (Mac, Pushover, the phone app) has two lines:

- Title: who wants what, e.g. "Kanban Chat Claude wants AWS lw-dev access", "... wants to use the Slack user token", "... wants to change the AWS lw-dev rules", "... wants to use the Slack user token for 2 days" (a lease). Outside a card it reads "A process outside any card wants ...".
- Body: the agent's `--reason` and nothing else. A missing reason, or one that reads like a command or has under four words, shows "No reason given." instead.

Secrets are named by their label: the `label` field when set (`kv label NAME "..."`, `kv add --label`), else one derived from the name (`aws:lw-dev` is "AWS lw-dev", `aws:lw-prod:read` is "AWS lw-prod read-only", `SLACK_USER_TOKEN` is "Slack user token").

Clicking the Mac notification opens the card and a sheet with every detail; on the phone the request's Details page shows the same. The details are the `vault` field of the attention request (`VaultApprovalDetails` in KanbanCodeRemoteKit): card, secrets with tier, the action, the proposed values of an edit, why the vault asks (tier, rate limit, Jev's verdict), the command, the working directory, the reason, the lease the card approval grants, and the process ancestry. `AttentionCopy` builds the title and body; questions and plan approvals use the same title style ("<card> is asking you a question", "<card> wants you to approve a plan", "<card> needs your permission").

When it reaches you: the Mac notification posts at once and the Dock icon shows the number of open requests. The phone (Pushover) gets one high priority message when the request is still open after the alert delay (Settings > Notifications, 3 min by default), or at once when the Mac is away. A macOS banner set to Temporary closes after 5 seconds, so Settings > Notifications warns when Kanban Code's alert style is not Persistent. When the request's card is open on screen (Kanban in front, its terminal or chat showing), a vault approval opens its detail sheet in the app instead of a notification; questions, plans and permission prompts show in the chat or terminal and get no notification. A sheet still open after the alert delay goes to the phone too, and the Mac notification posts once Kanban leaves the front. Sheets show one at a time: the next waits in line, the open one says how many wait after it, and a request answered elsewhere, withdrawn or timed out closes its sheet and the next one opens. The Dock count includes requests shown only in the app. Every raise, delivery decision and send result is in `~/.kanban-code/logs/kanban-code.log` under `[attention]`.

### Reasons

The reason is the only text the human reads before deciding, so it must be one short plain sentence saying what the agent wants to do and why, e.g. `--reason "Deploy the langwatch staging app to check the fix for the login bug"`. kv refuses (exit 2, before asking the master) a reason that is missing where required (`kv request`), shorter than four words, longer than one sentence (200 characters or a newline), or that reads like a command (starts with a command name, has flags or shell operators). `--reason` is optional for `kv run`, `env`, `get`, `aws`, `add`, `tier`, `rules`, `label`; `KV_REASON` in the environment stands in for it, which is how `kv aws` from `credential_process` gets one. When a request reaches the human without a usable reason, the pending message tells the agent how to write one next time.

## kv

`kv` talks to `http://127.0.0.1:<remote control port>` (`KANBAN_VAULT_URL` overrides it). It needs no token. Exit code 77 means denied.

`kanban vault ...` is the same command as `kv ...`: same arguments, output and exit code.

```
kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]
kv env .env.vault -- <cmd> [args..]
kv get NAME [--reason "..."]
kv request NAME[:scope] [NAME..] --reason "..."
kv aws <profile> [--reason "..."]
kv add NAME [--tier t] [--rules "..."] [--label "..."] [--reason "..."]   value on stdin
kv ls | kv log | kv leases | kv status   (status also says who the master takes you for)
kv tier NAME <tier> [--every-use-asks|--leases] | kv rules NAME "..." | kv label NAME "..."  [--reason "..."]   asks Rogerio
kv tiers <tier> [NAME..] [--value-prefix P].. [--every-use-asks|--leases] --reason "..."   one approval for all
kv import [--apply]
kv exec-provider                             OpenClaw exec SecretRef provider
```

`kv exec-provider` speaks OpenClaw's exec provider protocol (`{"protocolVersion":1,"ids":[...]}` on stdin, `{"values":{...},"errors":{...}}` on stdout); each id is a vault secret name. It never waits on a human: a secret that needs approval comes back as `NEEDS_APPROVAL` and its request stays open for the next `openclaw secrets reload`.

`.env.vault` holds names only: `KEY={{vault:NAME}}`. Lines with plain values pass through.

### AWS

AWS profiles are vault entries named `aws:<profile>` that carry a role (`roleArn`, optional session policies) and the name of the long-lived key secret (tier never, value `{"accessKeyId","secretAccessKey"}`). `kv aws <profile>` makes the master call STS AssumeRole (or GetSessionToken without a role) for one hour and prints the `credential_process` JSON. Use it from `~/.aws/config`:

```
[profile lw-dev-vault]
credential_process = /Users/<you>/.local/bin/kv aws lw-dev
region = eu-central-1
```

`aws:lw-prod:read` adds the ReadOnlyAccess session policy to the prod role.

## Bash hook

Kanban Code installs a `PreToolUse` hook on Bash (`~/.kanban-code/vault-hook.sh`) for Claude Code (`~/.claude/settings.json`) and for Codex (`~/.codex/hooks.json`, run as `vault-hook.sh --codex`). Codex runs a user hook only once its definition is trusted, so the installer also writes `[hooks.state."<hooks.json>:pre_tool_use:<n>:0"] trusted_hash` into `~/.codex/config.toml` with the hash Codex computes; Codex answers carry `permissionDecision: "allow"`, which Codex needs next to `updatedInput` and which does not skip its approvals or sandbox. Under Codex's `workspace-write` sandbox kv cannot reach the master on loopback, so commands run without the vault env; card sessions run Codex without the sandbox. rush sessions run `claude -p`, which loads the same Claude Code hook. In a project with a `.env.vault` (searched from the session's directory up to the repository root; in a linked git worktree without its own, the same folder of the main checkout), `kv hook` rewrites the command to:

```
__kv_env="$(kv env /path/.env.vault --export --command-b64 <command>)" || exit $?
eval "$__kv_env"; unset __kv_env
<the original command>
```

so the shell loads the secrets first and `cd` and shell syntax behave as written. In this mode secrets that need a human are skipped (the command runs without them and kv says how to ask), Jev's allow is reused for 10 minutes per card and secret, and these releases do not count toward the rate limit. If the master cannot be reached, the command runs without the vault env.

## Where secrets live

Every `.env`, `.env.local` and `.env.*` under `~/Projects` on the Mac and the box holds plain config only. Its secrets are references in a gitignored file next to it:

| Plaintext file | References |
|------|---------|
| `.env`, `.env.local`, `.env.development`, `.env.portless` | `.env.vault` (one per folder; the later file wins on a shared key) |
| any other `.env.X` | `.env.X.vault` |
| `.env` that is a production file (`save-to-memory`, `pinacle`) | `.env.prod.vault`; `.env.vault` there holds the dev secrets only |

Consumers:

- Claude Code and Codex Bash commands: the hook above.
- Interactive zsh outside Claude Code: `~/.zshrc` wraps `pnpm npm npx yarn bun make uv uvx node python python3 tsx deno` the same way (hook mode, in a subshell).
- Deploys that copy a `.env` to the host (`rchaves-platform`, `save-to-memory` `scripts/deploy.sh`): the script appends the secrets with `kv env <file> -- printenv` into a temporary copy and sends that.
- Anything else: `kv env .env.vault -- <cmd>`, or `kv env .env.X.vault -- <cmd>` for a named env file.

AWS on the Mac: `~/.aws/credentials` holds only the `[default]` canary; every profile in `~/.aws/config` (`lw-dev`, `lw-staging`, `lw-artifacts`, `lw-prod`, `lw-prod-read`, `lw-root-tf`, `sf-dev`, `sf-prod`, `sf-prod-read`) uses `credential_process = kv aws <profile>`, as on the box.

Plaintext that stays, and why:

- Production services on the box read their own env files at runtime: `/opt/rchaves-platform/.env`, `/opt/save-to-memory/.env`, `/opt/inbox_narrator/.env`, `/root/.openclaw/setup/hindsight-db/.env`, `gateway.auth.token` in `/root/.openclaw/openclaw.json`.
- Commented-out env lines and `.env.worktree-backup` copies are gone; their values are in the vault (canary tripwires such as `CANARY_LANGWATCH_API_KEY` stay as they are).
- LangWatch dev secrets its tooling writes into `.env` when missing (`LW_GATEWAY_INTERNAL_SECRET`, `LW_GATEWAY_JWT_SECRET`, `LW_VIRTUAL_KEY_PEPPER`, `LANGY_INTERNAL_SECRET`, `LWQL_*_PASSWORD`): local random values, kept in the file.
- Local DSNs with throwaway passwords, URLs, paths and ids.
- Tool credential stores read by the tools themselves: `~/.ssh`, `~/.config/gh`, `~/.git-credentials`, `~/.config/gcloud`, `~/.config/stripe`, Claude and Codex logins, local CA keys (`~/.portless`, `~/.minikube`, `~/.docker`).
- Keys inside code, fixtures, notebooks, logs and transcripts (`~/.claude/projects`, `file-history`, `paste-cache`): content, not config; scrubbing them is a separate step.

## Pasted secrets

The card chat composer, the queued prompt editor, channel composers and the iPhone composer check a prompt before sending it (`SecretDetector` in KanbanCodeRemoteKit, a port of LangWatch's redaction rules). When it holds a credential they offer to save it: one editable name per secret, taken from `NAME=value` / `NAME: value` / `"NAME": "value"` or the vendor (`OPENAI_API_KEY`, `GITHUB_TOKEN`...), with `_2`, `_3` when the vault already has that name. Yes adds each as a judged secret and sends the prompt with `{{vault:NAME}}` in its place plus a line telling the agent to use `kv run NAME -- <cmd>`; No sends it unchanged. On the Mac, Return or y is Yes, Esc or n is No. Placeholders (`sk-xxxx...`, `<your-key>`, AWS's `...EXAMPLE`) never ask.

rush's own message boxes (a Session's box and the Prompt) get the same check from the `kanban-vault` rush plugin in `plugins/rush/kanban-vault`, a Go port of the same rules. It answers rush's `ui.intercept` with an ask, saves with `kv add NAME --tier judged` through the manifest's `exec`, and rewrites the message in place so paste chips stay chips. `make rush-plugins` (`Scripts/rush-plugins-install.sh`) builds it into rush's plugin folder and runs `rush plugin approve` at a terminal. rush runs installed plugins only on macOS, where it sandboxes them, so the script installs nothing on a Linux machine.

## Remote API

See the routes list in `Sources/KanbanCodeCore/Adapters/RemoteControl/RemoteVaultRoutes.swift`. Listings never carry values. Adding a new secret is allowed to any local caller; replacing a value, changing a tier or rules, or deleting asks Rogerio, except from Settings > Vault in the app.
