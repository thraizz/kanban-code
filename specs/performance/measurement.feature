Feature: Performance measurement and instrumentation
  As a developer working on Kanban Code
  I want responsiveness measured continuously with low overhead
  So that sluggishness is caught with evidence instead of by feel

  Background:
    Given the Kanban Code application is running

  # ── Signposts ──

  Scenario: Dispatch path is wrapped in signpost intervals
    When an action is dispatched to the store
    Then an os_signpost interval "dispatch" should cover the reducer call
    And a nested interval "effects" should cover effect scheduling
    And the interval metadata should include the action case name
    And signposts should have no measurable cost when Instruments is not recording

  Scenario: Every reconcile phase is covered by a signpost and a log line
    When a reconcile pass runs
    Then each phase should emit a signpost interval and a "[reconcile]" log line
    And the phases should include settings read, links read, tmux, discovery, worktrees,
      branch discovery, PR fetch, reconciler, activity map, dispatch and GitHub issues
    And the sum of the phase durations should account for at least 95% of the TOTAL duration
    And time spent waiting to hop onto the main actor should be logged as its own phase

  # ── Key metrics ──

  Scenario: Input latency is recorded
    When the user presses a key or clicks in the board or card detail
    Then the time from the input event to the next committed frame should be recorded
    And the p50, p95 and max should be written to the log every 5 minutes
    And the p95 target is under 16ms

  Scenario: Board staleness is recorded
    When an external change happens (hook event, tmux session created or killed, session file written)
    Then the time from the change to the affected card reflecting it should be recorded
    And the p50, p95 and max should be written to the log every 5 minutes
    And the p95 target is under 200ms

  # ── Hang watchdog ──

  Scenario: Watchdog captures the stack while the hang is still happening
    Given the main thread has been blocked for 250ms
    Then the watchdog should capture a main-thread stack snapshot immediately
    And it should keep capturing snapshots until the main thread is responsive again
    And a hang only counts toward the hang total once it exceeds 500ms

  Scenario: Modal panels are not counted as hangs
    Given an NSOpenPanel, NSSavePanel or NSAlert is running modally
    When the main thread is inside the modal run loop
    Then the watchdog should not record a hang
    And it should not start a sample

  Scenario: Hang summary is readable without opening sample files
    When a hang is recorded
    Then the hang log line should include the top 5 app frames from the main thread
    And it should include the duration and the last dispatched action

  # ── Regression guard ──

  Scenario: Reducer benchmark fails on regression
    Given a fixture of 1140 links and 827 sessions
    When the reconcile reducer runs on the fixture in a test
    Then it should complete in under 5ms on the CI machine
    And the test should fail if it exceeds the budget

  Scenario: Performance numbers are compared before and after a change
    Given a performance-focused change is made
    Then the PR should include hang count per hour, reconcile TOTAL p50/p90,
      input latency p95 and staleness p95 from before and after the change
