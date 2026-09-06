<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 21._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main` after 20c: 01–20, 22, 24. Item 21 is on branch `review-21-simulator-install-launch` (worktree below). Remaining: 23 (keyboard actions; depends on 21). Do not start 23 in this worktree.

## Working Findings

- Item 21: `SimulatorService` uses structured `xcrun simctl` via ProcessRunner. Sequence is list → boot (if shutdown) → bounded `bootstatus` → install exact `.app` → launch Info.plist/build-settings bundle ID. Product path from `-showBuildSettings`, never DerivedData name guessing. UI sibling on iOS Jobs: device picker, affected-device line, Open Simulator, Install & Launch, Cancel Wait.
- Worktree: `/Users/christopherlarsen/orca/workspaces/Console/review-21-simulator-install-launch`.
- Live Simulator smoke skipped: would boot a real device and is too heavy for this slice. Fake sequence covers list → boot/readiness → install → launch.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on canonical `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
- URL equality on `.app` bundles can fail on trailing slash; compare `standardizedFileURL.path`.
