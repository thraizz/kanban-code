Feature: Technology Decisions
  As the architect of Kanban Code
  I want to document the technology choices and their rationale
  So that implementation proceeds with a clear technical vision

  # ── Primary Framework ──

  Scenario: Full Swift for the native macOS app
    Given the requirements are:
      | Requirement          | Why Swift                                     |
      | Liquid glass design  | SwiftUI has first-class support for materials  |
      | Native performance   | No bridge overhead, native Metal rendering     |
      | System tray          | NSStatusItem is native API                     |
      | Terminal emulator    | libghostty (GhosttyKit), native Metal views    |
      | Drag and drop        | NSPasteboard, SwiftUI .draggable/.droppable    |
      | File system access   | Foundation APIs, no sandbox restrictions        |
      | Process management   | Foundation.Process for shell commands           |
      | Keyboard shortcuts   | Native NSEvent key handling                    |
    Then Swift/SwiftUI should be the primary technology

  Scenario: Swift handles shell/process operations well
    Given concerns about bash-heavy operations:
      | Operation         | Swift Approach                            |
      | tmux management   | Foundation.Process with /bin/sh -c        |
      | gh CLI calls      | Foundation.Process with JSON parsing      |
      | SSH commands       | Foundation.Process wrapping ssh           |
      | Git operations     | Foundation.Process wrapping git           |
      | File watching      | DispatchSource.makeFileSystemObjectSource |
      | JSON parsing       | Codable with Foundation                   |
      | .jsonl streaming   | AsyncSequence + FileHandle                |
    Then Swift is capable for all shell operations

  Scenario: No Electron, no web views, no bridges
    Then the app should NOT use:
      | Technology    | Why Not                                    |
      | Electron      | Memory hog, not native, no liquid glass    |
      | Tauri          | Still a web view, bridging overhead        |
      | React Native   | Not mature on macOS, bridging issues       |
      | TypeScript     | Would need a bridge, performance penalty   |
    And every pixel should be rendered by SwiftUI/AppKit

  # ── Helper Processes ──

  Scenario: Shell scripts for hook handlers
    Given Claude Code hooks execute shell commands
    Then hook handlers should be bash scripts (like claude-pushover)
    And they should communicate with the main app via:
      | Method             | Use Case                              |
      | Coordination file  | Update links.json with hook data      |
      | Unix signals       | Wake up the background process        |
    And the scripts should be minimal (just write to links.json)

  Scenario: Remote shell wrapper stays as bash
    Given the fake shell must be named "zsh" and behave like a shell
    Then the remote shell wrapper should remain a bash script
    And it should be identical in pattern to claude-remote's approach
    And it should be bundled with the app and symlinked at setup time

  # ── Key Libraries ──

  Scenario: Terminal emulator library
    Then the embedded terminal should use a native Swift terminal library
    And it should support:
      | Feature          | Minimum Requirement         |
      | True color       | 24-bit RGB                  |
      | Unicode          | Full Unicode + emoji        |
      | Performance      | GPU-accelerated rendering   |
      | Scrollback       | Configurable buffer size    |
      | Mouse events     | Click, scroll, select       |
      | Selection/copy   | Native macOS text selection  |

  Scenario: BM25 search engine
    Given search must be fast across 1000+ .jsonl files
    Then the BM25 implementation should be in Swift
    And it should use:
      | Technique           | Purpose                         |
      | AsyncSequence       | Stream .jsonl lines without blocking |
      | Actor isolation      | Thread-safe scoring state        |
      | Structured concurrency | Parallel file processing       |
    And the search should be cancellable via Task.cancel()

  # ── Testing Strategy ──

  Scenario: Testing approach
    Then the project should use:
      | Layer           | Testing Framework    | Approach              |
      | Domain          | XCTest               | Pure unit tests       |
      | Use cases       | XCTest               | Mock adapters         |
      | Adapters        | XCTest               | Integration tests     |
      | UI              | XCUITest             | UI automation         |
      | Shell scripts   | bats-core            | Script testing        |
    And tests should be fast (domain + usecases < 5s)

  # ── Build and Distribution ──

  Scenario: Build system
    Then the project should use:
      | Tool              | Purpose                          |
      | Swift Package Manager | Dependency management          |
      | Xcode             | Build, sign, archive             |
      | Makefile           | Common dev commands              |
    And `make build` should produce a .app bundle
    And `make test` should run all tests

  Scenario: Distribution
    Then the app should be distributable via:
      | Method          | For                              |
      | .app bundle     | Direct download from GitHub      |
      | Homebrew cask   | `brew install --cask kanban`     |
    And the app should be signed and notarized for Gatekeeper
