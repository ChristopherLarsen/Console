<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 18 in an isolated worktree._

## Next Intended Move

Merge `review-18-sessions-small-window` when Christopher asks. Do not push or delete that worktree from here. Item 23 is next in the iOS workflow set; do not start it from this worktree.

## Working Findings

- Item 18 is on `review-18-sessions-small-window` (based on main at da894cc, which includes item 22). The session list is collapsible and resizable (180–360pt, preferred width survives a tight first layout). Focus Session (Go menu ⌘⇧F plus header button) overlays a collapsed list and global zsh drawer without mutating stored sizes; exit restores them. Neither PTY is killed. Session activity never enters focus.
- Item 22 sheets on MainView are unchanged. Selected folder path is a tooltip; list/header state uses `DisplayedSessionState.tint`.
- Targeted tests passed: SessionWorkspaceLayoutTests; SessionsUITests.testFocusSessionHidesListAndRestoresIt. Debug Console build succeeded (`/tmp/console-review-18-derived`). Live 800×500 / 1100×700 light/dark visual inspection was not performed.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
- `XCTUnwrap(try await …)` / `XCTAssertNotNil(try await …)` fail to compile; await first, then unwrap.
- `.commands` is a Scene modifier; putting it on MainView does not compile. Focus Session belongs in ConsoleApp's Go menu.
- XCUI tap on the header Focus button can miss when another full-screen window (Orca) is interrupting; the UI test uses the Go menu / ⌘⇧F.
