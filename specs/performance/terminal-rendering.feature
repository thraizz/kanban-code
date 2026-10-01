Feature: Terminal rendering performance
  As a terminal user
  I want the embedded terminal to feel as fast as a native terminal app
  So that typing and output never lag

  Background:
    Given a card with a live tmux session is open in the card detail

  Scenario: Typing latency
    When I type a character
    Then it should appear on screen within 16ms at p95

  Scenario: Heavy output does not block the UI
    Given the session is printing output continuously
    Then the rest of the app should stay responsive
    And terminal draws should take under 4ms per frame at p95
    And escape-sequence parsing should run off the main thread

  Scenario: Only dirty rows are redrawn
    When a few rows change
    Then only those rows should be drawn
    And styled text for unchanged rows should be reused from a cache

  Scenario: GPU rendering if CPU drawing misses the budget
    Given CPU drawing still exceeds the frame budget after the caching changes
    Then the terminal should switch to a GPU-backed renderer
      (SwiftTerm Metal renderer or a libghostty-based view)
    And the switch should keep selection, links and scrollback behavior unchanged

  Scenario: Hidden terminals do not draw
    Given a terminal tab is not visible
    Then it should keep its buffer up to date
    And it should not draw until it becomes visible
