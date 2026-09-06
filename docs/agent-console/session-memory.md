<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Parent should merge `review-03-next-shared-state` (item 03) from the isolated worktree. Do not push or delete that worktree. Item 14 (freshness labeling / exact URL navigation) depends on 01+03+12.

## Working Findings

- Item 03 done: one app-scoped `NextButtonModel` injected from `ConsoleApp`. `NextView` passes that instance into `NextTaskCardView`; the card no longer owns a private model. Refresh and Open are sibling controls with labels "Refresh next task" / "Open next task". Missing `SessionStore` snapshots empty sessions instead of allocating a placeholder. Outstanding checks cancel from the app terminate observer.
- Local-only item 01 path is preserved: `recommendedTask`, injectable refresh/snapshot, provider spy still discarded.
- UITest `NextUITests.testSharedModelShowsCheckingThenResultAndSplitsRefreshFromOpen` uses `-uiTestSelectNext` + `-uiTestNextSyntheticSources`. Content clicks were intercepted by an overlapping Codex window; DEBUG Go menu "Refresh Next Task" / "Open Next Task" invoke the same model actions. Check count is a DEBUG accessibility value. XCTest idle-wait swallows the Checking spinner; unit tests cover suspended duplicate checks.
- Isolated worktree: `/Users/christopherlarsen/orca/workspaces/Console/review-03-next-shared-state` on `review-03-next-shared-state`.

## Dead Ends

- XCUI `tap`/`click` on Next Refresh/Open hit Codex's full-size interrupting window; menu-bar Go items worked. Do not treat a content-click failure as a missing sibling control when the accessibility tree already shows both buttons.
