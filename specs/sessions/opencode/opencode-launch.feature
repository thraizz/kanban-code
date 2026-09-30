Feature: Launch and resume OpenCode sessions
  As a developer using OpenCode
  I want Kanban Code to start and resume OpenCode in a tmux pane
  So that OpenCode cards work like the other assistants' cards

  Scenario: Launch with skipped permissions
    Given a new OpenCode task with "skip permissions" on
    When Kanban Code builds the launch command
    Then the command should be `env OPENCODE_PERMISSION='{"*":"allow"}' opencode`
    Because OpenCode's TUI has no auto-approve flag, and a bare "allow" string makes it exit at startup

  Scenario: Resume a session
    Given an OpenCode card linked to session "ses_abc"
    When the card is resumed
    Then the command should run `opencode --session ses_abc`
    And the tmux session should be named after the random tail of the id, not its time-ordered start

  Scenario: A model goes in without a separator
    Given an API service for OpenCode with model "openrouter/anthropic/claude-sonnet-4.5"
    When Kanban Code builds the resume command
    Then the command should be `opencode --model openrouter/anthropic/claude-sonnet-4.5 --session ses_abc`
    Because OpenCode reads everything after `--` as a positional argument

  Scenario: The prompt waits for the input box
    Given OpenCode was just started in tmux
    When Kanban Code has a prompt to send
    Then it should wait until the footer shows "ctrl+p" and no "esc interrupt"
    And then paste the prompt and press Enter
    Because text sent while the TUI is still booting is lost

  Scenario: The card links to the session the first prompt creates
    Given OpenCode was launched in "/work/project"
    When the first prompt is sent
    Then Kanban Code should link the card to the newest top-level session created in "/work/project" since the launch
    And give it the virtual path "~/.local/share/opencode/session/<id>"

  Scenario: Fork and restore are refused
    Given an OpenCode card
    When the user forks the session or restores it to a turn
    Then Kanban Code should report that OpenCode sessions do not support it yet
    And the OpenCode database should not be written
