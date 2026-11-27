Feature: Two masters reach each other
  The Mac and the box keep one control connection, dialed by whichever can
  reach the other. A master that cannot dial its peer calls it through that
  connection, so only one of them needs the other's address, and a laptop
  that changes networks reconnects without a setting changed anywhere.
  See docs/peer-connections.md.

  Scenario: Pairing is done on one side
    Given the box issued a peer token for the Mac
    And the Mac has an entry for the box with its address and that token
    And the box has no entry for the Mac
    When the Mac connects to the box for the first time
    Then the box asks the Mac for a token in its hello
    And the Mac issues one with the peer scope and sends it on the connection it dialed
    And the box saves an entry for the Mac: its machine id, its name, that token and no address
    And cards, prompts, handovers, attention, agent sync, vault and scrubber calls go both ways

  Scenario: The box asks again only when it lost its entry
    Given the box has an entry for the Mac
    When the Mac connects again
    Then no token is issued
    When the box's entry for the Mac is removed and the Mac connects again
    Then the Mac issues a new token and revokes the one it issued before

  Scenario: Only a peer token pairs
    Given the box has no entry for the Mac
    When the Mac dials with a token of the full scope
    Then the box refuses the connection, saying it has no peer entry for the Mac
    And no entry is made

  Scenario: A peer that is not connected is not called
    Given the Mac is not connected to the box
    Then the box has no address for the Mac and calls it for nothing
    And the Mac's cards show offline on the box, with why the connection went
    And a launch or a move to the Mac is refused at once with that reason

  Scenario: The Mac changes networks
    Given the Mac is connected to the box
    When the Mac's address goes away (it joined another network)
    Then within 2 seconds the Mac closes the connection it dialed and dials again
    And the box takes the new connection in place of the old one at once
    And the box keeps the same forward port, so a terminal attached through it reconnects there
    And nothing is edited on either machine

  Scenario: The Mac goes to sleep
    Given the Mac is connected to the box
    When the Mac sleeps
    Then the box shows it disconnected within 30 seconds
    And when it wakes it dials again and the box takes the new connection
