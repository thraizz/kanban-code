Feature: Reconcile pipeline performance
  As a user with hundreds of cards and sessions
  I want reconciliation to be cheap and run off the main thread
  So that the board stays responsive and up to date

  Background:
    Given 1140 cards and 827 discovered sessions

  Scenario: Session lookup by id is constant time
    When the reducer matches cards to sessions
    Then sessions should be looked up through a dictionary keyed by session id
    And the dictionary should be built once per reconcile pass
    And there should be no linear scan over sessions per card

  Scenario: Merge is computed off the main thread
    When a reconcile pass runs
    Then discovery, merging and activity computation should run off the main actor
    And the main actor should only receive a list of changed cards
    And applying the changes on the main actor should take under 5ms

  Scenario: Unchanged cards are skipped cheaply
    Given most cards did not change since the last pass
    When the merged result is applied
    Then unchanged cards should be detected through a version or hash
      instead of comparing every field of Link and KanbanCodeCard
    And SwiftUI should not re-render unchanged cards

  Scenario: Large structs are not copied in hot loops
    When the reducer iterates over cards or sessions
    Then Session and Link values should not be copied per iteration
    And the instruments trace should show no Session copy frames in the top 20

  Scenario: Full reconcile pass is fast
    When a reconcile pass runs with warm caches
    Then TOTAL should be under 500ms at p90
    And under 1 second at max over an hour

  Scenario: Reconcile pass does not overlap itself
    Given a reconcile pass is still running
    When the next pass is due
    Then it should be coalesced into one pass that runs after the current one finishes
