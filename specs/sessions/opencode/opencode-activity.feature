Feature: Detect OpenCode activity
  As a developer monitoring OpenCode work
  I want OpenCode cards to show when they work, wait, or need me
  So that they move through the board like other cards

  Background:
    Given Kanban Code's plugin is installed at "~/.config/opencode/plugins/kanban-code.js"
    And the plugin appends events to "~/.kanban-code/hook-events.jsonl"

  Scenario Outline: Plugin events drive the card state
    Given OpenCode emits "<opencode event>"
    When the plugin writes "<hook event>" for the session
    Then the card should be marked <state>

    Examples:
      | opencode event          | hook event       | state          |
      | session.created         | SessionStart     | idleWaiting    |
      | session.status busy     | UserPromptSubmit | activelyWorking|
      | permission.asked        | Notification     | needsAttention |
      | permission.replied      | UserPromptSubmit | activelyWorking|
      | session.idle            | Stop             | needsAttention |
      | session.deleted         | SessionEnd       | ended          |

  Scenario: Subagent sessions send no events
    Given OpenCode starts a subagent session with a parent
    Then the plugin should write no events for it

  Scenario: A long tool run stays working
    Given the plugin last reported "UserPromptSubmit" 10 minutes ago
    And the session was written to the database seconds ago
    When activity polling runs
    Then the card should stay activelyWorking

  Scenario: Without the plugin the database is the signal
    Given the plugin is not installed
    And the session's last database write was less than 2 minutes ago
    When activity polling runs
    Then the card should be marked activelyWorking

  Scenario: Other assistants' events are ignored
    Given a Claude hook event with a Claude transcript path
    When the OpenCode activity detector handles it
    Then no OpenCode state should change

  Scenario: An outdated plugin is refreshed at startup
    Given an older version of Kanban Code's plugin is installed
    When Kanban Code starts
    Then the plugin should be rewritten to the current version
    But a plugin file that is not Kanban Code's should never be touched
