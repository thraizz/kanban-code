Feature: Pi sessions
  As a developer using Pi
  I want Kanban Code to launch, track and read Pi sessions
  So that Pi cards work like the other assistants' cards

  # ── Discovery and transcript ──

  Scenario: Sessions are discovered from Pi's session files
    Given Pi wrote "~/.pi/agent/sessions/--Users-me-project--/2026-09-30T18-12-57-981Z_<id>.jsonl"
    When Kanban Code scans for sessions
    Then a Pi session "<id>" should be listed with the header's cwd as its project
    And its name should be the latest `session_info` name, if any
    And a file with no user or assistant message yet should not be listed

  Scenario: The transcript follows the active branch
    Given a session in which `/tree` continued from an earlier entry
    When the chat view reads the transcript
    Then it should show the entries from the last one written back to the root
    And the abandoned branch should not be shown
    And one reply's steps and tool results should be one assistant bubble

  # ── Launch and resume ──

  Scenario: Launch
    Given a new Pi task, with or without "skip permissions"
    When Kanban Code builds the launch command
    Then the command should be `pi`
    Because Pi has no permission prompts to skip

  Scenario: A model goes in without a separator
    Given an API service for Pi with model "openrouter/moonshotai/kimi-k2.6"
    When Kanban Code builds the launch command
    Then the command should be `pi --model openrouter/moonshotai/kimi-k2.6`
    Because Pi reads everything after `--` as the first prompt

  Scenario: Resume a session
    Given a Pi card linked to session "01a0f385-0bf4-702d-b978-176fd2135394"
    When the card is resumed in its project directory
    Then the command should run `pi --session 01a0f385-0bf4-702d-b978-176fd2135394`
    And the tmux session should be named "pi-d2135394", after the random tail of the id
    Because Pi's ids are version 7 UUIDs that start with their creation time

  Scenario: The prompt waits for the editor
    Given Pi was just started in tmux
    When Kanban Code has a prompt to send
    Then it should wait until the editor frame of two bare "─" rules is drawn
    And then paste the prompt and press Enter

  Scenario: The card links to the file the first prompt creates
    Given Pi was launched in "/work/project"
    When the first prompt is sent
    Then Kanban Code should link the card to the new session file whose header cwd is "/work/project"

  # ── Fork and restore ──

  Scenario: Fork a session
    Given a Pi card
    When the user forks the session
    Then a new file with a new version 7 id should be written next to the original
    And its header should name the original file in `parentSession`

  Scenario: Restore to a turn
    Given a Pi card
    When the user restores the session to a turn
    Then the file should be cut after that turn's last entry, with a `.bkp` copy of the original

  # ── Activity ──

  Scenario: The extension reports activity
    Given Kanban's extension is installed at "~/.pi/agent/extensions/kanban-code.js"
    Then Pi's events should be appended to "~/.kanban-code/hook-events.jsonl" as:
      | Pi event                          | Hook event       | Card state          |
      | session_start                     | SessionStart     | idle                |
      | agent_start                       | UserPromptSubmit | working             |
      | agent_settled                     | Stop             | needs attention     |
      | ui_prompt_start                   | Notification     | awaiting permission |
      | ui_prompt_end                     | UserPromptSubmit or Stop | working or needs attention |
      | session_shutdown (not a reload)   | SessionEnd       | ended               |

  Scenario: Without the extension
    Given Kanban's extension is not installed
    When Kanban Code polls a Pi session
    Then a file written in the last 2 minutes should mean the session is working
