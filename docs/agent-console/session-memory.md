<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 during review-item implementation._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main` after merging 16: 01–05, 08, 10, 12, 03, 16. In flight: 06 (Stop/timeouts), 13 (Brief edits). Next slice: 11 (git remotes for worktrees). Not 07/09 in parallel with 06. Max three isolated worktrees.

## Working Findings

- 01 local Next; 02 ticket/MR out of Claude; 03 one Next model; 04 confirmation; 05 pipe drain; 08 one execution owner; 10 launch errors; 12 MR extraction resume; 16 optional bridge degrade, no phantom sessions.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
