Feature: Event-driven board updates
  As a user watching agents work
  I want cards to react to changes as they happen
  So that the board never shows stale state for seconds

  Background:
    Given the Kanban Code application is running
    And the assistant hooks are installed

  Scenario: Hook event updates the card immediately
    When an assistant writes a hook event to hook-events.jsonl
    Then only the affected card should be updated
    And the card should reflect the change within 200ms
    And a full reconcile pass should not be required

  Scenario: tmux session changes update the card immediately
    When a tmux session for a card is created or killed
    Then the card should reflect the change within 500ms

  # Not implemented: activity detection reads session file mtimes during the
  # poll and there is no per-session watcher or incremental parse to hook into.
  # Hook events already cover live activity; a watcher would need its own
  # per-file DispatchSource lifecycle, so it is left for a later change.
  Scenario: Session file changes are picked up through file watching
    When a session .jsonl file is written
    Then the change should be detected through a file system watcher
    And only that session should be re-parsed

  Scenario: Polling is a slow fallback
    Given event sources are working
    Then the full reconcile poll should run every 30 seconds at most
    And it should exist only to catch missed events

  Scenario: Fallback when hooks are not installed
    Given the assistant hooks are not installed
    Then the app should poll at the current 3 second interval
    And the settings should show that hooks would make updates faster
