Feature: Remote control from other devices and agents
  As a developer away from my Mac
  I want my other devices and agents to drive Kanban Code on the Mac
  So that sessions keep running on the Mac while I pilot them from my LAN or VPN

  # Contract: docs/remote-control.md. Wire types: KanbanCodeRemoteKit.

  Background:
    Given Settings > Remote Control is on
    And its bind addresses are the Mac's LAN and WireGuard addresses

  Scenario: The server is reachable only on loopback and the bind addresses
    Then it listens on 127.0.0.1 and the bind addresses on port 7780
    And it does not listen on any other address, nor on 0.0.0.0
    And when the WireGuard address comes up after the app, the server binds it then

  Scenario: No bind addresses
    Given the bind addresses are empty
    Then it listens on 127.0.0.1 only

  Scenario: Pairing a device
    When I add a device named "laptop" with scope full in Settings > Remote Control
    Then the app shows its token and the kanbancode://pair link once
    And ~/.kanban-code/remote/devices.json keeps only the token's SHA-256

  Scenario: Pairing an agent from the command line
    When I run "kanban remote pair --name openclaw --scope agent" on the Mac
    Then it prints a token and the pairing link

  Scenario Outline: Requests are refused without the right token
    When a request to <path> comes with <credential>
    Then it is refused with <status>

    Examples:
      | path                        | credential           | status |
      | GET /v1/board               | no token             | 401    |
      | GET /v1/board               | a revoked token      | 401    |
      | WS /v1/cards/x/terminal     | an agent token       | 403    |
      | GET /v1/health              | no token             | 200    |

  Scenario: Revoking a device closes its connections
    Given a device streaming a card's terminal
    When I revoke the device in Settings > Remote Control
    Then its sockets close and its next request is refused

  Scenario: A client gets the working set, not the whole history
    Given the Mac has archived cards, All Sessions cards and 40 Done cards
    When a client reads the board
    Then it gets no archived and no All Sessions cards, and the 30 most recent Done cards
    When it asks with all=1
    Then it gets every card

  Scenario: The board follows the Mac live
    Given a client is connected to /v1/events
    Then it gets the whole board first
    When a card moves to Waiting on the Mac
    Then within a second the client gets a cards event with only that card in upserted
    When a card is archived on the Mac
    Then the client gets its id in removed
    When the client sends a resync frame
    Then it gets the whole board again

  Scenario: Streaming a rush card's terminal
    Given a card running on rush
    When a full-scope device opens the card's terminal
    Then the Mac runs "rush open <id>" in a pseudo-terminal sized to that device
    And what I type there reaches that rush host
    And closing the terminal leaves the session running

  Scenario: Streaming a tmux card's terminal
    Given a card running on tmux
    When a full-scope device opens the card's terminal
    Then the Mac runs "tmux attach -t <session>" in a pseudo-terminal

  Scenario: Sending a prompt from another device
    Given a card whose session is in a turn
    When I send "also run the tests" with mode queue
    Then it reaches the session when the turn ends
    When I send "stop, wrong file" with mode now
    Then the turn is interrupted and the text is sent

  Scenario: An agent starts a coding task on the Mac
    Given OpenClaw has an agent token
    When it runs "kanban remote task --project langwatch --worktree 'fix the flaky test'"
    Then a card is created in langwatch with its own worktree and launched on the Mac
    And "kanban remote transcript <card>" shows the conversation as it goes

  Scenario: An agent token cannot open a terminal
    When OpenClaw opens WS /v1/cards/<id>/terminal
    Then it is refused with 403

  Scenario: Forking a card from another device
    Given a card with a conversation, on any master
    When a full-scope device asks to fork the card
    And pick Same worktree or Project root when the card has a worktree
    Then the master that owns the card makes a new card in Waiting with a copy of the conversation
    And the fork keeps the worktree, or runs from the project root, as picked
