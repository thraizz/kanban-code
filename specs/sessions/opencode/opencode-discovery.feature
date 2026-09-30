Feature: Discover OpenCode sessions
  As a developer using OpenCode
  I want my OpenCode sessions to appear on the board
  So that I can see and resume them like other sessions

  Background:
    Given OpenCode stores its sessions in "~/.local/share/opencode/opencode.db"
    And Kanban Code reads that database read-only

  Scenario: Top-level sessions become cards
    Given the database has a session with no parent and no archive time
    When discovery runs
    Then a session with assistant "opencode" should be discovered
    And its project path should be the session's directory
    And its name should be the session title

  Scenario: Subagent and archived sessions are left out
    Given the database has a session with a parent session
    And the database has an archived session
    When discovery runs
    Then neither session should be discovered

  Scenario: A placeholder title is not a name
    Given a session titled "New session - 2026-09-30T08:00:00.000Z"
    When discovery runs
    Then the session should have no name
    And its card should be titled by its first prompt

  Scenario: The first prompt skips injected text
    Given a session's first user message starts with a synthetic text part
    When discovery runs
    Then the first prompt should be the first non-synthetic text

  Scenario: No database is no sessions
    Given OpenCode was never run on this Mac
    When discovery runs
    Then no OpenCode sessions should be discovered
    And no error should be reported
