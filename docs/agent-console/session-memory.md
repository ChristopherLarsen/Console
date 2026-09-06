<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 during review-item implementation._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main` after merging 18: 01–19, 20a, 20b, 22, 24. In flight: 20c (results UI). After 20c: 21, then 23. Max three isolated worktrees.

## Working Findings

- P0/P1 complete. 18: collapsible/resizable session list and Focus Session (⌘⇧F); item 22 sheets kept. Live 800×500 / 1100×700 light/dark visual check was not performed.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
