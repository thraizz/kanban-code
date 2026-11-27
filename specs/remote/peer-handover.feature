Feature: A card started on another master
  A card launched from one master on another is offered to it first, and
  released to it once it said yes. The other master finds the card's
  project on its own machine, then starts the card.

  Scenario: The other master is not connected
    Given another master this master cannot call now
    When a card is launched on it or moved to it
    Then it is refused at once, in under 2 seconds
    And the card stays here, not released, in the column it was in
    And the card shows that the other master is not connected, and why its connection went

  Scenario: The other master is asked first
    Given another master that is connected
    When a card is launched on it or moved to it
    Then the card shows that it is being handed over, and stays owned here
    And the other master answers within 10 seconds whether it takes the card
    And it takes it when it is not stopping, reaches this master, has the card's assistant, and has the project or may clone it
    And only once it said yes is a running session ended, its branch pushed and the card released

  Scenario: The other master says no
    Given another master that has no clone of the card's project and may not make one
    When a card is launched on it or moved to it
    Then the card is never released
    And a card that never ran stays in its column, and a running card keeps its session here
    And the card shows that the other master does not take it, with the reason

  Scenario: The other master does not answer the offer
    Given another master that does not answer within 10 seconds
    When a card is launched on it
    Then the card stays here, not released, and shows that the other master did not answer

  Scenario: A project with a git remote
    Given a card of a project whose repository has an origin
    When it is launched on another master
    Then that master uses its clone of the origin, cloning it when it has none
    And starts the card there

  Scenario: A new project with no remote and no commits
    Given a card of a project whose repository has no origin and no commits
    When it is launched on another master
    Then that master makes a new repository of the same name in its projects folder
    And gives it a first commit, so the card can start in a worktree
    And adds it to its projects
    And starts the card there

  Scenario: A later card of that project
    Given the other master made a repository for a project with no remote
    When another card of the project is launched on it
    Then the card starts in that same repository

  Scenario: A project with commits and no remote
    Given a card of a project whose repository has commits and no origin
    When it is launched on another master
    Then that master does not start the card
    And the reason says the project has no git remote, so its files cannot follow

  Scenario: The other master cannot take the card after all
    Given a card launched or moved to another master that took the offer
    When that master cannot adopt it for a reason another try would repeat, such as a clone that fails
    Then it sends the card back to the master that released it
    And the card is owned there again, as it was before the launch
    And a card that never ran returns to the backlog
    And the card shows that the other master could not take it, with the reason
    And the other master stops trying to adopt it

  Scenario: The other master is not ready yet
    Given a card released to another master
    When the adoption fails for a reason that may pass, such as the releasing master being offline
    Then the card stays released
    And the other master tries again

  Scenario: The other master goes away after it took the card
    Given a card released to another master that took the offer
    When that master's connection goes before it picked the card up
    Then the card shows that it moves there once that master is connected again
    And that master adopts it when it connects

  Scenario: A launch right after this master started
    Given this master started a moment ago and is not connected to the other master yet
    When a card is launched on the other master
    Then it is refused at once, saying the other master is not connected
    And nothing waits for a guess about whether the other master can fetch from here
