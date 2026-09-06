<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 22 in an isolated worktree._

## Next Intended Move

Merge `review-22-shared-checkout-warning` when Christopher asks. Do not push or delete that worktree from here. Continue isolated review items; max three worktrees.

## Working Findings

- Item 22 is implemented on `review-22-shared-checkout-warning` (based on main at f727cb6, which includes item 11). Before an editing launch, the coordinator claims the canonical checkout path, compares it to live editing sessions and in-flight claims, and shows Focus Existing Session / Continue in Same Folder / Cancel. Reviews occupy the checkout; they are not treated as read-only. Linked worktrees stay distinct via symlink-resolved paths. Git lookup is read-only `status --porcelain --branch`. No reset, stash, branch switch, worktree create, or session kill.
- Occupancy uses `CheckoutPath.canonical` (symlink aliases match). `SessionStore.liveEditingSessions` ignores exited rows. Continue reuses the pending claim and does not re-inspect Git. Two overlapping launches park on claims so neither bypasses the warning.
- Targeted tests passed: SharedCheckoutWarningTests, SessionLaunchCoordinatorTests, SessionWorkspaceChooserTests. Debug Console build succeeded (`/tmp/console-review-22-derived`). Item 02/10/16 coordinator cases still pass. Item 18 not started.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
- `XCTUnwrap(try await …)` / `XCTAssertNotNil(try await …)` fail to compile; await first, then unwrap.
