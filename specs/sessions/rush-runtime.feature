Feature: rush session runtime
  As a developer running Claude Code cards
  I want a card's Claude session to run on a rush host instead of tmux
  So that it keeps running in the background and shows as rush in the card

  # The session name of a rush card is `rush-<id>`, where the id is the
  # first 8 hex characters of the Claude session id. Every layer routes by
  # that name alone: the app, the kanban CLI and the card terminal. rush was
  # named agtop before; hosts started then keep the name `agtop-<id>`.

  Background:
    Given rush is installed
    And Settings > Assistants > Claude Code > "Run sessions in" is "rush"

  Scenario: Launching a card on rush
    When I launch a card with a prompt
    Then Kanban Code runs "rush session start" with a new session id, the prompt and its images
    And it passes the absolute path of claude with "--binary"
    And the hosted Claude gets KANBAN_CARD_ID set to the card
    And the card's session name is "rush-<id>", also given to the host as "--meta kanban_session=rush-<id>"
    And the card links the transcript at ~/.claude/projects/<cwd>/<session id>.jsonl without polling for it

  Scenario: A host rush restarts later still finds claude
    Given a card running on rush, started from an app whose PATH finds claude under nvm
    When rush restarts the host from a process with a bare PATH
    Then the host runs the claude path it was started with

  Scenario: Cards from before the rename keep working
    Given a card whose session name is "agtop-<id>"
    And its host was started without "kanban_session" in its meta
    When the board scans sessions
    Then the host is listed as "agtop-<id>" and the card stays live
    And messages, the terminal and vault callers reach that host as before

  Scenario: Settings and remote boards keep the old wire name
    Given Claude Code runs on rush
    Then the settings file stores the runtime as "agtop"
    And remote boards send a rush card's runtime as "agtop" and its queued prompt ids as "agtop-<n>-<hash>"
    And "rush" is read as the same runtime and prompt id prefix

  Scenario: Launching with a worktree
    When I launch a card with a worktree named "fix-login"
    Then Kanban Code creates the worktree at <repo>/.claude/worktrees/fix-login
    And rush starts in that worktree

  Scenario: Resuming a card on rush
    Given a card whose Claude session ended
    When I resume it
    Then tmux sessions of that Claude session are stopped
    And Kanban Code runs "rush session start --resume" for it
    And a live host is reused as it is

  Scenario: The card terminal shows one rush session
    Given a card running on rush
    When I open the card
    Then the terminal runs "rush open <id>" ("agtop open <id> --solo" where only agtop is installed)
    And it shows that session alone, with no agent list and no header
    And the scroll wheel goes to rush, not to tmux copy-mode
    And quitting rush opens it again, the host keeps running

  Scenario: Messages reach a rush session
    Given a card running on rush
    When a queued prompt, a DM or a channel message is sent to it
    Then it is delivered with "rush session send", which rush queues while a turn runs
    And an interrupting send uses "--now"
    And images are sent as files with "--image"

  Scenario: An idle rush session stays live
    Given a card running on rush
    When rush stops Claude after its idle timeout and the SessionEnd hook fires
    Then the card keeps its terminal, because the host is still alive
    And the next message starts Claude again with --resume

  Scenario: Self-compact from inside a rush session
    Given a card running on rush
    When the session runs "kanban self-compact 'carry on'"
    Then the CLI interrupts the turn, sends "/compact" and then "carry on" through rush

  Scenario Outline: Cards that stay on tmux
    Given <case>
    When the card launches or resumes
    Then it runs on tmux

    Examples:
      | case                                          |
      | a Codex or Gemini card                        |
      | a card that runs on a remote machine          |
      | a launch with a command edited in the dialog  |
      | rush is not installed (an error says so)      |

  Scenario: A command template wraps rush's Claude
    Given the Claude launch command is "langwatch ${cli_command}"
    When a card launches on rush
    Then rush runs a script that execs "langwatch claude" with rush's arguments

  Scenario: Extra terminals stay on tmux
    Given a card running on rush
    When I open a new terminal tab on it
    Then that tab is a tmux shell
