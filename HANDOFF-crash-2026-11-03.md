# Handoff: constraint-pass crash while dragging the card detail divider (2026-11-03)

## Goal
Kanban Code crashes when the card detail pane (SwiftUI `.inspector`) is resized horizontally by dragging its divider, most reliably with the History tab open. Make dragging the divider safe. Branch `feat/board-overview`, fork `thraizz/kanban-code`. Upstream (`langwatch`) has no fix: its only new commits are about conversations, and it still contains the code fixed in step 1 below.

## The crash, in all three forms
These are all the same failure. The form depends on where AppKit gives up:

1. `NSGenericException`: *"The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window."* (SIGABRT, or SIGTRAP via `+[NSApplication _crashOnException:]`). Get the message with `/usr/bin/log show --predicate 'process == "KanbanCode" AND eventMessage CONTAINS "Update Constraints"'`. The `.ips` file does not contain it.
2. `EXC_BAD_ACCESS` at `0x10020` in `swift::runtime::AccessSet::insert` ← `swift_beginAccess` ← AppKit `+0x529b50` ← `___NSViewLayout_block_invoke`. The unified log shows the constraint-pass error about 60 ms before each of these. AppKit catches the exception internally, and the unwind leaves a dangling Swift exclusivity record, which the next layout trips over. So treat this form as a symptom of form 1, not a separate bug.
3. The 100% CPU relayout loop at launch (see "Fixed" item 1).

Each crashing stack has `-[NSSplitView mouseDown:]` → `nextEventMatchingMask` → display cycle flush. **Key insight:** during a divider drag, AppKit counts every update-constraints pass under one display-cycle identifier for the whole drag (log: `Marking window … for identifier 965 (limit: 423, count: 429 …)`), because `NSSplitView` runs its own tracking loop. The limit is about the number of views in the window. So anything that re-marks constraints even once or twice per drag step crashes after a few seconds of dragging. Per-step marks have to get to roughly zero, or the drag has to stop going through `NSSplitView`.

## Fixed in this session (uncommitted, built and installed in /Applications)
1. `Sources/KanbanCode/TranscriptTerminalView.swift`, `toolTitle`: removed `.textSelection(.enabled)`. The text is `Text(name).font(bold) + Text(rest).font(regular)`. SwiftUI's `SelectionOverlay` is an NSTextField with a single font, and for mixed-font text it swaps the font on every update. Each swap runs `invalidateIntrinsicContentSize`, which triggers another constraint pass, forever. This was verified with lldb (fields such as `Read(.../TerminalRepresentable.swift)` alternating between `.AppleSystemUIFontMonospaced-Bold 12` and `.SFNS-Regular 13`). **This fixed the crash loop at launch** for card `card_3LbEoBwVn4RRteyrTzPLxggw70p`: CPU went from 100% plus a crash to 0%.
2. `Sources/KanbanCode/SessionHistoryView.swift`: added `flattenFontIntents(in:)` to `styledText`. History rows are markdown text with `.textSelection(.enabled)` and showed the same font swapping (lldb caught rows like "What the repo already has (quick look)" each invalidating about 60 times). Bold is now shown in white instead of a heavier weight, and every run uses the same font. Selection is kept.
3. `Sources/KanbanCode/PromptEditor.swift`: `setFrameSize` no longer measures synchronously. It calls `scheduleRecalcIntrinsicHeight()` only when the width changed. The `layout()` override is removed, and so is the nested `textView.layoutSubtreeIfNeeded()` in `recalcIntrinsicHeight`. Previously it resized frames and invalidated intrinsic size from inside the layout pass. The crashes continued after this change, so it is a cleanup rather than a confirmed fix.
4. `Sources/KanbanCode/ContentView.swift`: `inspectorContent` is wrapped in `.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)`. The crash at 16:33 had `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` ← `NSHostingView.SizeConstraints.update` ← `_willUpdateConstraintsForSubtree` as the marker. This removes that marker but **did not stop the crash** (crashes at 16:35 and 16:38 happened after it).

`swift test` has not been run on these changes.

## Still crashing: what triggers constraint marks now
A 45-second lldb trace with a short drag (`scratchpad/drag.txt`, 5031 marks, 605 of them directly inside mouse handling) grouped by origin:
- 2106 `ObservationGraphMutation.apply` → `NSHostingView.beginTransaction`: some `@Observable` property changes and the window re-renders. The keyPath is unknown; earlier traces showed `BoardStore.dispatch` of `reconciled`, `cardMemoryScanned`, `sessionModelsScanned` and `remoteMachineStateChanged` rebuilding `AppState.cards`. Background dispatches during a drag all count toward the drag's limit.
- 404 `ViewGraph.setRootView` (root view re-set from `beginTransaction`)
- 365 `NSHostingView.updateConstraints` → `_prepareForTwoPassConstraintsUpdateIfNeeded`
- 229 + 124 `NSHostingView.invalidateSafeAreaInsets` / `invalidateSafeAreaCornerInsets` (from `didChangeValueForKey`)
- 199 `NSHostingView.rootTransform` (geometry-in-window observation)
- 126 + 104 toolbar: `AppKitToolbarStrategy.updateVended` / `Toolbar.LocationStorage.updatedVendedItems`, meaning toolbar preferences change during the drag
- 108 + 84 `InteractiveResizeBridge.handleLiveResize`
- 89 `AppKitPlatformViewHost.updateNestedHosts` (focusedValues setter)

Most of these are SwiftUI's normal response to a resize. Trimming them one by one is unlikely to get a long drag under the limit.

## Recommended next step
Stop sending the detail-pane resize through `NSSplitView`. Replace `.inspector(isPresented:)` in `ContentView.boardWithOverlays` (around line 694) with an `HStack { boardView; resizeHandle; inspectorContent.frame(width: detailWidth) }`, where:
- `detailWidth` is an `@AppStorage`/`@SceneStorage` width clamped to 600…1000 (the current `inspectorColumnWidth(min: 600, ideal: 800, max: 1000)`), and
- the handle is a thin view with a `DragGesture` (consider updating the width only on change, plus `.onEnded` persistence) and an `NSCursor.resizeLeftRight` hover cursor.

Each drag event then gets its own display cycle, so the per-cycle counter resets. Before switching, check:
- toolbar placement and Liquid Glass behaviour (see the toolbar section in CLAUDE.md). The inspector may give the detail pane its own toolbar region and safe-area behaviour, and `tbVis.showInspectorToggle` toggles it (ContentView around line 1702).
- `showInspector` binding (ContentView around line 189) and expanded detail mode (`isExpandedDetail`).

Alternative or complementary measure: pause store-driven re-renders during a live resize (`viewWillStartLiveResize`/`viewDidEndLiveResize`) so the 2106 observation-driven marks don't land during a drag. This is weaker than the recommended step.

Still at risk from the font-swap pattern (markdown with mixed fonts plus `.textSelection(.enabled)`), not changed: `BoardOverviewView.swift` around line 282 (`Markdown(answer)`), `CardDetailTabs.swift:44` and `:141` (`Markdown(body)`), `SideChatPanel.swift:241`.

## How to reproduce and diagnose
- Select a card, open the detail pane in History, and drag the divider for a few seconds. The app crashes within about 3–10 s of continuous dragging.
- The launch loop (now fixed) reproduced with `defaults write com.kanban-code.app selectedCardId card_3LbEoBwVn4RRteyrTzPLxggw70p` before launching.
- An exception-type `.ips` file has a `lastExceptionBacktrace` that names the *last* marker. Parse it with the JSON in `~/Library/Logs/DiagnosticReports/KanbanCode-*.ips` (skip the first line).
- To trace live: `lldb -p <pid> --batch -o 'breakpoint set -n "-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]" -G1 -C "bt 50"' -o 'script lldb.debugger.SetAsync(True)' -o 'process continue' -o 'script import time; time.sleep(45)' -o 'process interrupt' -o 'detach'`. **Never `pkill` lldb while it is attached: that kills the app.** It also makes the app very slow, so warn the user. For font-swap checks, break on `-[NSTextField invalidateIntrinsicContentSize]` with `-C "expr -l objc -O -- [(NSTextField *)$arg1 stringValue]"`.
- Install after every change per CLAUDE.md: `make app`, `pkill -TERM -x KanbanCode`, replace `/Applications/KanbanCode.app` using `ditto`, then `open` it.

## Evidence files
- Crash reports from today: `~/Library/Logs/DiagnosticReports/KanbanCode-2026-11-03-{150354,161430,161705,163046,163322}.ips` plus later ones (16:35 SIGSEGV, 16:38 SIGTRAP; the last was also pasted to `/tmp/crashlog`).
- lldb traces in `/private/tmp/claude-501/-Users-aronschuler-dev-projects-opensource-kanban-code/4cfcee62-3623-459b-804e-131b0caecfe4/scratchpad/`: `drag.txt` (marks during drag), `resize2.txt`, `post.txt`, `tf.txt` (font swapping).
- The previous handoff, `HANDOFF-crash-2026-10-30.md`, is partly superseded: 4039bc8 (side-effect-free `sizeThatFits`) was already in the crashing builds and did not fix this.
