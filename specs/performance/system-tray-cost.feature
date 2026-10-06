Feature: System tray update cost
  As a user with the menu bar icon enabled
  I want the tray to update without touching the main thread heavily
  So that it never causes a hang

  Background:
    Given the Kanban Code application is running
    And the system tray is enabled

  Scenario: Tray menu is rebuilt only when its contents change
    When the board state changes
    Then the tray menu should be rebuilt only if the items it shows changed
    And otherwise the existing NSMenu should be kept

  Scenario: Active-session helper is tracked without listing all apps
    When the tray decides whether to start or stop the active-session helper
    Then it should use the helper's stored process id
    And it should not call NSWorkspace.runningApplications on the main thread

  Scenario: Orphaned helpers are cleaned up off the main thread
    When the app starts
    Then orphaned active-session helpers from earlier runs should be found on a background task
    And they should be stopped once, not on every tray update

  Scenario: Tray update budget
    When the tray updates
    Then the update should take under 1ms on the main thread
