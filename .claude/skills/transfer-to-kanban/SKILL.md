---
name: transfer-to-kanban
description: Move this Claude Code CLI session into Kanban Code, where it continues as a card in a Kanban Code terminal. Use when the user asks to transfer, move, hand off or continue this session in Kanban Code (or "on the board", "in kanban").
allowed-tools: Bash(kanban import:*)
---

# Transfer this session to Kanban Code

This session's id is `${CLAUDE_SESSION_ID}`.

Kanban Code puts the session's card on the board and waits. Once this
`claude` process exits, it resumes the same session (same transcript, same
working directory) in a Kanban Code terminal and brings the app to the front.
It waits for the exit because two processes writing one transcript would
corrupt it.

## Steps

1. Run the import with the id above. If that is not an id like
   `854054b6-24ff-45e2-bdb9-8feb1f70caf1` (an older Claude Code leaves the
   placeholder in), run plain `kanban import`: it finds the Claude Code
   session it runs under.

   ```bash
   kanban import ${CLAUDE_SESSION_ID}
   ```

   If `kanban` is not on the PATH, stop and tell the user to open Kanban Code
   and use **File › Import Claude Code Session…** with the id above, after
   quitting this session.

2. Answer from what it printed, then end your turn. Do no further work in this
   session.

   - **"…still runs in a terminal: quit it there (/exit)…"**: tell the user the
     card is on the board, and that it continues in Kanban Code as soon as they
     quit here with `/exit` (or Ctrl-D). Anything they type here before
     quitting is still part of the conversation Kanban Code resumes.
   - **"…already runs in Kanban Code…"**: this session is already a Kanban Code
     card; nothing to move.
   - **An error**: report it as printed. "Kanban Code did not process the
     subagent command within 120 seconds" means the app, or its window, is not
     up: ask the user to open Kanban Code and run the skill again.

Keep the answer to two or three lines: the card id, and what the user does next.
