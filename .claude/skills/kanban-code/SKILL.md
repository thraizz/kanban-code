---
name: kanban-code
description: Inspect cards, delegate work to subagents, orchestrate Claude sessions, and message other agents' cards. Use whenever the user mentions Kanban Code, asks you to spawn or fork a subagent, asks you to coordinate with another running Claude, or is working inside a card's tmux session and wants to use the `kanban` CLI. Covers subagents, parent/child messages, handles, and steering other cards.
---

# Kanban Code — Agent Skill

You're a Claude running inside a **Kanban Code card's tmux session**. Every card has its own tmux session; you can see and message other cards via the `kanban` CLI.

## Quick reference

```
kanban list                          # all active cards
kanban show <card>                   # details for a card
kanban sessions                      # all live tmux sessions
kanban subagent spawn --handle x "goal"   # delegate to a fresh child session
kanban subagent fork --handle y "goal"    # delegate with a copy of your transcript
kanban subagent list                 # your children, with context usage + pane peek
kanban subagent model <card> opus    # switch an owned child to another model
kanban parent dm "progress update"   # report to the card that owns you
kanban send <card> "msg" --mode ...  # steer (default) | queue | interrupt
```

All commands accept `-j/--json` for machine-readable output.

## Identity

- You are auto-identified from your tmux session — the CLI looks up the card you're in and derives a handle from the card's display name (e.g. `Alice card` → `@alice_card`, truncated to 24 chars). Dashes you typed survive, so `alice-card` stays `@alice-card`.
- Handles disambiguate on collision (`@alice_card_2`, `@alice_card_3`…).
- You don't register your handle — it's derived at send time (a subagent's handle is the `--handle` its parent gave it).

## Subagents

Subagents are ordinary Kanban Code cards with their own tmux session, transcript, and
auto-compaction. Unlike Claude Code's built-in subagents they can compact themselves, so
they are the right tool for long delegated work. Run these from your own card's session.

```
kanban subagent spawn --handle parser-bug "investigate the failing parser test"
kanban subagent fork  --handle cache-path "same task, try the cache instead"
kanban subagent fork  --from parser-bug --handle other-angle "retry from a different angle"
kanban subagent list                       # active + archived children, with a live pane peek
kanban subagent dm parser-bug "any progress?"
kanban subagent model parser-bug opus      # switch it to another model
kanban subagent archive parser-bug
kanban subagent resume parser-bug          # bring an archived child back
```

- **`--handle` is required.** It becomes the child's card name and its `@handle`, so
  DMs read `[DM from @parser-bug]` instead of a slug of your goal text.
- **`spawn` starts clean** (~30k context). **`fork` copies your transcript**, so the child
  starts as expensive as you are. Prefer `spawn` unless the child genuinely needs your history.
- **`--from <card>`** forks one of your existing children instead of yourself. The copy
  becomes that child's sibling, still owned by you, so it works at depth limit 1.
- **`--assistant claude|codex|gemini`** switches assistant (a fork migrates the transcript).
  **`--model sonnet`** picks the model. **`--context-threshold 250k`** sets a per-child
  compaction schedule that escalates like the global one: a queued nudge at 250k, a
  steered reminder at 350k, and an interrupt with `/compact` at 450k.
- **A child inherits your model** when you don't pass `--model`, so an Opus card does not
  quietly hand its work to a cheaper model. Switching assistants drops the inheritance.
- **`kanban subagent model <card> <model>`** switches a running child. On Claude it
  submits `/model <name>`, accepts the "Switch model?" confirmation for you, and records
  the choice so a later `resume` keeps it. Codex takes no model name on `/model`, so it
  opens a picker instead and you finish the selection yourself. Either way the child's
  pane comes back so you can see what actually happened.
- **Depth is capped** (default 1). A child that tries to spawn its own child gets a clear error.
- **`kanban subagent send <card> "..." --mode steer|queue|interrupt`** delivers to a child
  the same three ways `kanban send` does.
- Multi-line goals: `kanban subagent spawn --handle x - <<'EOF' … EOF`.

As a child, report with `kanban parent dm "<message>"`. Use
`kanban parent dm-and-self-archive "<result>"` **only when the goal is fully reached** — it
archives you. If the parent wants you to stay available for follow-ups, keep using plain `dm`.

These messages are pasted straight into the other card's tmux session; there is no DM history,
so the receiving agent's transcript is the only record. A card without a live session misses them.

Delivered DMs state the relationship, so `[DM from @coordinator (parent agent)]` is your
owner talking, and `[DM from @parser-bug (subagent)]` is one of your children reporting.

## Related CLI features

- `kanban sessions` — all live tmux sessions with card associations. Useful for sanity-checking who's online before messaging a card.
- `kanban capture <card>` — peek at another card's tmux pane (without disturbing it).
- `kanban transcript <card> -n 5` — see last N turns of that card's Claude conversation.
- `kanban export [card] [--out file.md]`: the whole session as Markdown, the same text the app's "Copy conversation as Markdown" gives (user and assistant messages). No card means your own; also takes a `@handle` or a Claude session id. Prints to stdout unless `--out`.
- `kanban send <card> "msg"` — send a prompt directly to a card's tmux session Use it to talk to a card that is neither your parent nor your child.
  - `--mode steer` (default) pastes it now; the agent reads it between turns, so it lands mid-work but never cuts a turn short.
  - `--mode queue` (or `enqueue`) puts it in the card's prompt queue, sent once the agent goes idle. Use it when the message is "next up", not "right now".
  - `--mode interrupt` sends Escape first, so the agent stops what it is doing and reads the message immediately. Reserve it for genuine stop-work situations.
  - The same three modes back the auto-compact thresholds in Settings → Self-Compact.
- `kanban relink <card> <session-id>` — point a card at a different transcript when it is stuck on a stale session. Never moves or deletes a `.jsonl`.
- `kanban self-compact - <<'EOF' … EOF` — compact your own session and hand yourself a post-compact continuation message. Always pass that handoff; without it you wake up with only the digest.
- Read `kanban --help` in full. Do not pipe it through `head` or `tail`; the command list continues past the first screen.

## Secrets (kv)

Secrets live in the Kanban Code vault; use `kv` instead of reading `.env` files (docs/vault.md in the Kanban Code repo).

- `kv run NAME [NAME..] --reason "..." -- <cmd>` runs a command with the secrets in its env. `kv request NAME --reason "..."` asks once for the card's whole task. `kv aws <profile>` gives AWS credentials. `kv ls` lists names and tiers.
- Some releases wait for Rogerio's approval. His phone shows "<your card> wants to use <secret>" and, under it, only your `--reason`. Write it as one short plain sentence a human understands: what you want to do and why. Good: `--reason "Deploy the langwatch staging app to check the fix for the login bug"`. Bad: `--reason "change aws:lw-dev: rules"` (too terse), `--reason "kubectl apply -f x.yaml"` (a command; the command is shown separately). kv refuses reasons like the bad ones with exit code 2.
- Exit code 77 means denied. Do not retry the same request in a loop; ask with a better reason or tell the user.

## What NOT to do

- Don't spam — every message pastes into the other card's pane and lands in its current turn. Keep it relevant.
