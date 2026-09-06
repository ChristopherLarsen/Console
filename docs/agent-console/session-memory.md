<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 20b._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. On `main`: 01–17, 19, 20a, 22. This worktree (`review-20b-ios-results-parser`) implements 20b; do not merge/push/remove it from here. In flight elsewhere: 18 (Sessions layout), 24 (Brief attribution). Next after 20b merge: 20c (results UI), then 21, 23. Max three isolated worktrees.

## Working Findings

- P0/P1 complete. 20a: serialized iOS Build/Test jobs with structured xcodebuild argv.
- 20b: `IOSResultParser` inspects local `.xcresult` via `xcrun xcresulttool get` (content-availability, build-results, test-results summary/tests). Models carry file URL, line, test identifier, message. Missing/incomplete/corrupt/schema mismatch never promote failure to success. Exit code + structured records decide success; log wording is ignored. No export/upload; no LLM path.
- Item 02 branch remains in the shared Cursor tree. Do not `worktree remove` that path.
- Uncommitted on `main`: `docs/reviews/` and 800×500 overview fact. Do not commit unless asked.

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
