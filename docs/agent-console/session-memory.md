<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 during review-item implementation._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main` after merging 20c: 01–20, 22, 24. Next: 21 (Simulator install/launch), then 23 (keyboard actions). Those are the last remaining slices.

## Working Findings

- P0/P1 complete. 20c: Settings iOS job panel; Open Result/Source, Copy Error, Rerun Failed Tests from validated IDs. No live Simulator smoke.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
