Feature: Main thread budget
  As a terminal user who expects instant feedback
  I want the main thread to only handle input, layout and drawing
  So that the app never stutters while background work runs

  Background:
    Given the Kanban Code application is running

  Scenario: No hangs during normal use
    Given a board with 1000+ cards and 20 live tmux sessions
    When I use the app for one hour
    Then no main-thread hang over 500ms should be recorded
    And no more than 5 hitches over 100ms should be recorded

  Scenario: No blocking file I/O on the main thread
    When any view or main-actor code needs file contents
    Then the read should run on a background task
    And the main thread should only receive the parsed result
    And this applies to ContextUsageReader.read, ProjectDiscovery.findUnconfiguredPaths,
      JSONL parsing and settings or links reads

  Scenario: No synchronous IPC on the main thread
    When the app needs information from another process or system service
    Then it should not call a synchronous API on the main thread
    And this includes NSWorkspace.runningApplications, LaunchServices lookups,
      Process.waitUntilExit and running tmux, git or gh commands

  Scenario: Per-frame work stays inside one frame
    When a single action is dispatched
    Then the reducer plus the resulting SwiftUI update should finish within 8ms
    And work that does not fit should be computed off the main thread first

  Scenario: Main-thread rules are enforced in debug builds
    Given a debug build
    When a known blocking API is called on the main thread
    Then a runtime warning should be logged with the call site
