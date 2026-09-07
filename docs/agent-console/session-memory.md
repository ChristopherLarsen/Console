<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 23._

## Next Intended Move

Item 23 is on `review-23-keyboard-developer-actions`. Do not merge/push/remove that worktree from this session. Remaining review items were already on main except this last P2. Confirm with Christopher before merging.

## Working Findings

- Item 23: Develop menu + ⌘⇧K overlay picker. Fixed actions route through SessionLaunchCoordinator / IOSBuildCoordinator / SimulatorLaunchModel / workspace opener — no LLM shell strings. Search query is `@State` only.
- Shortcut check: picker is ⌘⇧K. ⌃1–9, ⌘1–9, ⌘`, ⌘⇧F unchanged on Go.
- Console’s main surface is an AX dialog (NSPanel-style). `.sheet` did not appear under UI tests; overlay in ConsoleApp ZStack matches UpdatePromptView. Escape uses a local keyDown monitor (keyCode 53) because TextField/cancelAction did not dismiss the overlay.
- Worktree: `/Users/christopherlarsen/orca/workspaces/Console/review-23-keyboard-developer-actions`.
- Unit: `ConsoleTests/DeveloperActionTests` passed. UI: `NavigationUITests/testDeveloperActionPickerKeyboardAndEscapeLeaveGoShortcutsAlone` passed (menu-bar based; do not require `app.windows.firstMatch`).
- Do not commit `Console/default.profraw`.

## Dead Ends

- Nested `Commands` struct inside `.commands` and SwiftUI `.sheet` on MainView did not present the picker in UI tests.
- `app.windows.firstMatch` fails on this host because the main surface is AXDialog; existing `testLaunchStartsOnHome` hits the same assertion. Use menu bar + identifiers.
- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from `/Users/christopherlarsen/Workspace/Console`.
