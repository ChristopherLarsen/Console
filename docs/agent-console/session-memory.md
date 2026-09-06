<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 during review-item implementation._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main` after merging 20a: 01–17, 19, 20a, 22. In flight: 18 (Sessions layout), 24 (Brief attribution). Next: 20b (xcresult parser). Then 20c, 21, 23. Max three isolated worktrees.

## Working Findings

- P0/P1 complete. 20a: serialized iOS Build/Test jobs with structured xcodebuild argv; no parser/UI yet.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
