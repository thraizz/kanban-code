Feature: Activity Detection
  As a developer managing multiple Claude sessions
  I want Kanban Code to accurately detect session activity state
  So that cards are in the right column at all times

  Background:
    Given the Kanban Code application is running
    And Claude Code hooks are installed

  # ── Hook-Based Detection (Primary) ──
  # Hooks are the ONLY way to move a card to "In Progress".
  # Polling never returns .activelyWorking.

  Scenario: Detecting active session via hooks
    Given Claude Code hooks are configured for Kanban Code
    When a UserPromptSubmit hook fires for session "abc-123"
    Then the session's last_activity timestamp should update
    And the session should be considered "actively_working"
    And the card should move to "In Progress"

  Scenario: Session stop detection
    Given a Claude session stops working
    When the Stop hook fires for session "abc-123"
    Then the session should be flagged as "needs_attention"
    And a push notification should be sent (deduplicated within 62 seconds)

  # A subagent sent to the background outlives the turn that started it. The
  # main agent goes back to the prompt and Stop fires, but the work carries on
  # and the transcript gets no lines for it.
  Scenario: Session stops while its subagents keep working
    Given a SubagentStart hook fired for session "abc-123"
    When the Stop hook fires for session "abc-123"
    Then the session should stay "actively_working"
    And the card should stay in "In Progress"
    And the Mac should stay awake

  Scenario: Last subagent finishes
    Given two SubagentStart hooks fired for session "abc-123"
    And the Stop hook fired for session "abc-123"
    When both SubagentStop hooks fire
    Then the session should be flagged as "needs_attention"

  Scenario: Session killed while a subagent runs
    Given a SubagentStart hook fired for session "abc-123"
    And its SubagentStop never fires because the session was killed
    When 2 hours pass
    Then the subagent should stop counting as work

  # A compaction fires SessionStart with source "compact", but the process
  # lives on: its turn and its background subagents carry on through it.
  # Only a real fresh start (startup, resume, clear) resets the session.
  Scenario: Compaction does not reset the session
    Given two SubagentStart hooks fired for session "abc-123"
    And a SessionStart hook fires with source "compact"
    When the Stop hook fires for session "abc-123"
    Then the session should stay "actively_working"
    And both SubagentStop hooks are still expected before it goes idle

  # An idle session compacts on its own before its prompt cache expires,
  # about an hour after its last turn. The compaction writes its summary as
  # a user entry, which is not a turn running.
  Scenario: An idle compaction does not pull a finished card into In Progress
    Given the Stop hook fired for session "abc-123" an hour ago
    And the card's PR is merged
    When the session compacts while idle
    Then the session should stay "needs_attention"
    And the card should stay in "Done"

  # A reconcile pass takes a snapshot of the board and works on it for a
  # while. The activity map must not be part of that snapshot: a session that
  # started working mid-pass would get its spinner turned off when the pass
  # lands its result.
  Scenario: A slow reconcile pass cannot ship a stale activity picture
    Given a reconcile pass started 4 minutes ago
    And a UserPromptSubmit hook fired 1 minute ago for session "abc-123"
    When the pass completes and dispatches its result
    Then the dispatched activity map shows "abc-123" as "actively_working"
    Because the map is computed at the end of the pass, not the start

  Scenario: GitHub PR lookups never block activity detection
    Given the PR refresh needs minutes on a cold gh cache
    When a reconcile pass runs
    Then the pass applies the last completed fetch's data and finishes in seconds
    And the fetch itself runs in the background for a later pass
    And hook events keep moving cards while the fetch runs

  Scenario: Stop followed by new prompt (anti-duplicate notification)
    Given the Stop hook fired for session "abc-123"
    And a UserPromptSubmit fires for the same session within the dedup window
    Then the session should return to "In Progress"
    And subsequent Stop events should be deduplicated

  Scenario: Actively working during long tool calls (sleep 60s)
    Given a UserPromptSubmit hook fired 65 seconds ago
    And the .jsonl file was last modified 60 seconds ago
    Then the session should still be "actively_working"
    Because the 5-minute timeout has not elapsed
    And Claude may be running a long tool call like `sleep 60s`

  Scenario: Fast Ctrl+C detection via jsonl interrupt marker
    Given a UserPromptSubmit hook fired 5 seconds ago
    And the .jsonl file was last modified 5 seconds ago (stale >3s)
    And the last line of the .jsonl contains "[Request interrupted by user]"
    Then the session should be flagged as "needs_attention" immediately
    Because Claude Code writes this synthetic user message on Ctrl+C
    And we can detect it without waiting for the 5-minute timeout

  Scenario: Stale file without interrupt marker stays active (sleep 60s)
    Given a UserPromptSubmit hook fired 65 seconds ago
    And the .jsonl file was last modified 60 seconds ago
    And the last line does NOT contain "[Request interrupted by user]"
    Then the session should still be "actively_working"
    Because Claude may be running a long tool call like `sleep 60s`
    And the 5-minute timeout has not elapsed

  Scenario: 5-minute timeout detects killed process or abandoned session
    Given a UserPromptSubmit hook fired 6 minutes ago
    And the .jsonl file was last modified 6 minutes ago
    Then the session should be flagged as "needs_attention"
    Because the 5-minute timeout matches Claude's own tool timeout
    And this handles killed processes (kill -9) and abandoned sessions

  # ── Polling-Based Detection (Fallback — Never Promotes to In Progress) ──

  Scenario: Session without hooks never appears in In Progress
    Given a Claude session was started from the user's terminal (no hooks)
    When the background process polls the .jsonl file
    And the file was modified within the last 5 minutes
    Then the session should be considered "idle_waiting"
    And the card should appear in "Requires Attention" (NOT "In Progress")
    Because only hooks can confirm a session is actively working

  Scenario: Polling detects inactivity after 5 minutes
    Given a session's .jsonl file has not been modified for 10 minutes
    And no hook events have been received
    Then the session should be considered "needs_attention"
    So the user can triage it: resume, archive, or investigate

  Scenario: Polling detects ended session after 1 hour
    Given a session's .jsonl file has not been modified for 2 hours
    Then the session should be considered "ended"

  Scenario: Polling detects stale session after 24 hours
    Given a session's .jsonl file has not been modified for 2 days
    Then the session should be considered "stale"

  # ── Activity States ──

  Scenario Outline: Activity state determination
    Given a session with the following conditions:
      | Condition             | Value         |
      | Last activity         | <last_activity> |
      | Last hook             | <last_hook>   |
      | File age              | <file_age>    |
    Then the activity state should be "<state>"

    Examples:
      | last_activity | last_hook         | file_age    | state              |
      | 10 seconds    | UserPromptSubmit  | 2 seconds   | actively_working   |
      | 65 seconds    | UserPromptSubmit  | 60 seconds  | actively_working   |
      | 6 minutes     | UserPromptSubmit  | 6 minutes   | needs_attention    |
      | 2 minutes     | Stop              | 2 minutes   | needs_attention    |
      | 2 minutes     | Notification      | 2 minutes   | needs_attention    |
      | 10 seconds    | (none)            | 2 seconds   | idle_waiting       |
      | 10 minutes    | (none)            | 10 minutes  | needs_attention    |
      | 2 hours       | (none)            | 2 hours     | ended              |
      | 2 days        | (none)            | 2 days      | stale              |

  # ── Column Assignment from Activity ──

  Scenario: In Progress requires hook-confirmed active session
    Given a session was last active 30 minutes ago
    But no hooks have confirmed it is actively working right now
    Then it should NOT be in "In Progress"
    And it should be in "Requires Attention" (if within 24h)
    Because "In Progress" is exclusively for hook-confirmed actively working sessions

  Scenario: Recently active but idle session goes to Requires Attention
    Given a session was last active 2 hours ago
    And no activity state has been confirmed by hooks or polling
    Then it should be in "Requires Attention"
    So the user can triage it: resume, archive, or investigate

  Scenario: Only activelyWorking state puts session in In Progress
    Given a session has activityState = "actively_working"
    When the column is assigned
    Then the session goes to "In Progress"
    And a loading spinner appears in the column header

  Scenario: User can archive from Requires Attention to All Sessions
    Given a session is in "Requires Attention"
    When the user clicks "Archive" in the context menu
    Or drags the card to "All Sessions"
    Then the session moves to "All Sessions"
    And it is marked as manuallyArchived
    And it stays in All Sessions even on refresh

  # ── Configurable Timeout ──

  Scenario: Active timeout is configurable
    Given the activity detector is initialized with activeTimeout = 300
    Then sessions with no file activity for 5 minutes are timed out
    And the timeout matches Claude Code's own tool timeout (~5 minutes)

  # ── Idle Timeout ──

  Scenario: Configurable idle timeout
    Given settings has "sessionTimeout.activeThresholdMinutes": 1440
    When a session has been idle for 1440 minutes (24 hours)
    And it has no linked worktree or tmux session
    Then it should be auto-archived to "All Sessions"

  Scenario: Session with worktree is not auto-archived
    Given a session has been idle for 48 hours
    But it has a linked worktree that still exists
    Then it should NOT be auto-archived
    And it should remain in its current column with "idle" indicator
