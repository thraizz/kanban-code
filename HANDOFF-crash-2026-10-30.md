# Handoff: Kanban Code crash in AppKit constraint update (2026-10-30)

## Goal
Fix the crash where Kanban Code dies on the main thread inside AppKit's constraint update pass, and the long main-thread stalls in `SelectableMarkdownText` that led up to it. Work in this fork (`thraizz/kanban-code`, local HEAD `87e0236`).

## What happened
- **App:** KanbanCode 0.1.1 on macOS 26.5.1 (25F80). The crash was at 2026-10-30 22:25:55 +0100, in pid 56192.
- **Crash report:** `~/Library/Logs/DiagnosticReports/KanbanCode-2026-10-30-222555.ips`
- **Exception:** `EXC_BREAKPOINT` / `SIGTRAP`, raised by `+[NSApplication _crashOnException:]`, so an uncaught `NSException` was thrown on the main thread.
- **Stack** (faulting thread, `com.apple.main-thread`), top to bottom:
  ```
  +[NSApplication _crashOnException:]
  -[NSView _updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:]   (x8, recursing)
  -[NSISEngine withBehaviors:performModifications:]
  -[NSView updateConstraintsForSubtreeIfNeeded]
  -[NSWindow(NSConstraintBasedLayoutInternal) updateConstraintsIfNeeded]
  NSDisplayCycleFlush
  CA::Transaction::commit()
  ... runloop ...
  SwiftUI runApp -> KanbanCodeApp.$main() (App.swift)
  ```
  No frame from the app itself is on the crashing stack, because the work happens inside AppKit's display-cycle constraint pass.
- **The exception message was not captured.** The `.ips` file has no `asi` text, and the unified log had nothing for the process in that window. This stack usually comes with AppKit's *"The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window"*: a layout feedback loop. That is an inference and has not been confirmed. Capturing the real message is step 1 below.

## Evidence from the app's own logs (`~/.kanban-code/logs/`)
- In the minutes before the crash, `main-thread-hangs.log` recorded stalls in pid 56192 at 21:20:21–21:20:26Z. All of them had `lastAction=selectCard` and a top5 dominated by `SelectableMarkdownText`:
  - `SelectableMarkdownText.sizeThatFits(_:nsView:context:)`
  - `SelectableMarkdownText.WrappingTextView.configure(content:appearance:highlight:links:lineLimit:)`
  - `initializeWithCopy for TerminalTranscriptRow` / `ChatTextContent` (copying large transcript rows during layout)

  The sample files are under `main-thread-samples/main-thread-stall-2026-10-30T21-20-2*-pid56192.sample.txt`.
- **Stalls are chronic, not a one-off.** The hang log holds about 3000 `SAMPLE START` entries and 100–170 summaries per day since 2026-10-26. The most common summaries:

  | Count | Top frame | lastAction |
  |---|---|---|
  | 371 | async thunk | `sessionModelsScanned` |
  | 194 | async thunk | `reconciled` |
  | 181 | async thunk | `remoteMachineStateChanged` |
  | 156 | `KanbanCodeCard.__derived_struct_equals` | `reconciled` (whole-card equality on every reconcile) |
  | 111 / 101 / 97 | closures #8, #9, #4 in `ContentView.boardWithHandlers.getter` | — |

  These are a separate performance problem. Worth a look, but they don't cause the crash.
- **Ruled out:** at the time of the crash `settings.json` had just been edited externally, adding an ssh machine "osaka" to `boxd.sshMachines`. The restarted app (pid 11411) reads that file fine and lists the machine, and the crash stack is pure view layout. Treat that edit as unrelated unless step 1 says otherwise.

## Prime suspect: `Sources/KanbanCode/SelectableMarkdownText.swift`
The file's own comments say sizing must be a pure measurement:
> `fittingSize(forWidth:)`: "A pure measurement: it must never touch the live text view. ... The view itself is rendered from `setFrameSize`, at the width that won."

But `sizeThatFits` (line ~37) calls `nsView.configure(...)` before measuring, and `configure` (line ~109) ends with `self.render(width: self.bounds.width)`. `render` (line ~202) mutates the live view:
- it sets `textContainer.size`
- it calls `textStorage.setAttributedString(...)`
- it restores `selectedRanges`

The `WrappingTextView` is `isVerticallyResizable = true`, so replacing the text storage lets NSTextView resize its own frame. That feeds `setFrameSize` (line ~225), which calls `render` again and `reportOverflow`, which schedules `onHeightOverflow` on the next runloop turn. All of that happens while SwiftUI or AppKit is in the middle of sizing and constraint passes. That's the classic way to get "needs another Update Constraints pass" recursion, and it would also explain the `selectCard` stalls: selecting a card with a long or table-heavy transcript makes `configure`/`render` run once per sizing probe.

## Suggested fix direction (verify first, these are not tested)
1. **Capture the exception message.** Run a Debug build from Xcode with a symbolic breakpoint on `objc_exception_throw`, or run `log stream --level debug --predicate 'process == "KanbanCode"'` while reproducing. Confirm it is the update-constraints-pass exception.
2. **Make `sizeThatFits` side-effect free.**
   - Store the new content and appearance without rendering. Split `configure` into "update inputs + invalidate memos" and "render", and call only the first one from `sizeThatFits`.
   - Then answer from `fittingSize(for:)`. Rendering stays in `updateNSView` and `setFrameSize`.
3. **Stop the text view from resizing itself.** SwiftUI owns the frame. Consider `isVerticallyResizable = false`, or guard `setFrameSize` → `render` against re-entrancy (a `isRendering` flag), so `setAttributedString` can't trigger another frame change while layout is in progress.
4. **Keep `onHeightOverflow` out of any pass that is still in progress.** It's already async, but make sure it can't oscillate between two heights: compare against the last reported value with a tolerance, and stop after a bounded number of reports.
5. Existing tests to extend: `Tests/KanbanCodeTests/SelectableMarkdownTextTests.swift`, `ChatTextHeightTests.swift`, `ChatCardTextParityTests.swift`. Add a test that calls `sizeThatFits` repeatedly at varying widths and asserts that the text storage, `renderedWidth` and frame stay unchanged.

## Repro hints
- Have a card with a long transcript containing markdown tables and code blocks: the TerminalTranscriptRow / ChatTextContent path.
- Select it (`selectCard`) and switch between cards quickly, or resize the window or detail pane while it's visible.
- Watch `~/.kanban-code/logs/main-thread-hangs.log` for `SelectableMarkdownText` in the summaries. A crash should follow under enough churn.

## Done when
- The exception message is confirmed and fixed at the source.
- `sizeThatFits` no longer mutates the view, enforced by a test.
- Selecting long transcript cards produces no `SelectableMarkdownText` entries in `main-thread-hangs.log`.
- No crash after repeated card switching and window resizing.
