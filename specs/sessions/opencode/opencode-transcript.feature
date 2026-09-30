Feature: Read OpenCode transcripts
  As a developer reviewing OpenCode work
  I want to read an OpenCode session in the chat view and search it
  So that OpenCode history is as usable as other assistants'

  Scenario: Messages and parts become turns
    Given a session with a user message and several assistant steps
    When the transcript is read
    Then there should be one user turn and one assistant turn
    And reasoning parts should be thinking blocks
    And tool parts should be a tool call and, once it ran, its result
    And step-start and step-finish parts should not be shown

  Scenario: Tool names match the chat view's
    Given a "read" tool part with input "filePath"
    When the transcript is read
    Then the tool call should be named "Read"
    And its input should also carry "file_path"

  Scenario: The chat view follows a live session
    Given the chat view shows an OpenCode card
    When OpenCode writes to the session
    Then the chat view should reload within a few seconds
    Because there is no session file to watch, the database's last write is polled

  Scenario: Search scores only the matching parts
    Given many sessions with large tool outputs
    When the user searches "postgres"
    Then only parts containing "postgres" should be read from the database
    And results should link to the sessions' virtual paths

  Scenario: Branches come from bash commands
    Given a bash tool call "git checkout -b feat/login && git push -u origin feat/login"
    When branch discovery runs for the card
    Then the card should discover branch "feat/login"
