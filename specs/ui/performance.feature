Feature: Performance and Virtualization
  As a developer with many sessions and projects
  I want Kanban Code to be blazing fast at all times
  So that it never feels sluggish or wasteful

  Background:
    Given the Kanban Code application is running

  # ── Startup Performance ──

  Scenario: Cold start time
    When I launch Kanban Code from a cold start
    Then the window should appear within 500ms
    And the board should render with cached data within 1 second
    And live data should populate within 3 seconds

  Scenario: Cached data on startup
    Given previous session data was cached
    When the app starts
    Then cached data should render immediately
    And background refresh should update silently
    And the transition from cached to live should be seamless

  # ── Rendering Performance ──

  Scenario: Column virtualization
    Given the "All Sessions" column has 500 cards
    Then only visible cards should be in the render tree
    And cards should be recycled as I scroll
    And frame rate should stay at 60fps during scrolling

  Scenario: Card rendering budget
    Given a card is being rendered
    Then it should take less than 2ms to render
    And layout calculations should be cached
    And re-renders should only happen when data changes

  Scenario: Board with many active sessions
    Given 20 sessions are in "In Progress"
    And 50 sessions are across other columns
    Then the board should render all visible cards smoothly
    And no janky scroll or resize behavior

  # ── Background Process Performance ──

  Scenario: Linking process CPU usage
    Given the background linking process is running
    Then its CPU usage should be under 5% on average
    And it should only wake up on:
      | Event                    | Frequency        |
      | Hook notification        | On each hook     |
      | Periodic poll            | Every 30 seconds with hooks installed, every 3 seconds without |
      | File change detected     | On fs.watch      |

  Scenario: .jsonl scanning is incremental
    Given 200 session .jsonl files exist
    When the background scanner runs
    Then it should only parse files modified since last scan
    And file mtimes should be cached to avoid stat() calls
    And a full re-scan should complete in under 2 seconds

  Scenario: GitHub API calls are batched and cached
    Given 10 sessions have linked branches
    When PR status is checked
    Then a single `gh pr list` should fetch all PRs
    And a single GraphQL query should enrich all open PRs
    And results should be cached for 60 seconds minimum

  Scenario: tmux session listing is cached
    Given tmux is running with 10 sessions
    Then `tmux list-sessions` should be called at most every 5 seconds
    And the result should be shared across all linking operations

  # ── Memory Performance ──

  Scenario: Memory usage with many sessions
    Given 1000 sessions exist across all projects
    Then memory usage should stay under 200MB
    And unused session data should be evicted from memory
    And only visible card data should be fully loaded

  Scenario: Terminal emulator memory
    Given a terminal has 10,000 lines of scrollback
    Then the scrollback buffer should be bounded
    And old content should be paged to disk if needed
    And memory should not grow unbounded

  # ── Search Performance ──

  Scenario: Live filter is instant
    Given 500 sessions are loaded
    When I type in the search bar
    Then results should filter within 16ms (one frame)
    And the search should use an inverted index for speed

  Scenario: BM25 deep search streams results
    Given 500 .jsonl files need to be searched
    When I trigger a deep search
    Then first results should appear within 500ms
    And files should be processed from newest to oldest
    And the search should be cancellable without blocking the UI

  # ── Network Performance ──

  Scenario: Offline resilience
    Given the network is unavailable
    Then all local features should work at full speed
    And GitHub features should show cached data
    And no error dialogs should block the UI
    And reconnection should happen silently in the background

  Scenario: Slow GitHub API
    Given the GitHub API is slow (>5 second response)
    Then the board should remain responsive
    And PR status should show "loading" indicator
    And the slow request should not block other operations
