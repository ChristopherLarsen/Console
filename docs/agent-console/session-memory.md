<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 20c._

## Next Intended Move

Continue `docs/reviews/2026-09-06-ios-workflow-review.md`. This worktree (`review-20c-ios-results-ui`) implements 20c; do not merge/push/remove it from here. Next after 20c merge: 21 (Simulator), then 23 (keyboard launcher). Do not start those here. Max three isolated worktrees.

## Working Findings

- P0/P1 complete. 19/20a/20b are on this branch's base (`d061847`).
- 20c: Settings hosts compact `IOSBuildJobView` over injected `IOSBuildCoordinator`. Presentation + actions in `IOSBuildJobPanelModel`. Open uses `NSWorkspace` (no shell). Copy goes to pasteboard only — no LLM path. Rerun submits only validated failed-test identifiers (`Target/Suite/...`), never the original test plan, wildcards, or log-derived names. Bundles stay local.
- Unit tests: `IOSBuildJobViewTests` (19 cases) cover success, compile failure, failing selected test, cancel, timeout, missing bundle, malformed JSON, two queued jobs, open result/source, copy, rerun IDs, Stop.
- No synthetic iOS project in-repo. Live smoke would be a full Simulator `xcodebuild` and is too heavy; not run.
- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from `/Users/christopherlarsen/Workspace/Console`.

## Dead Ends

- Do not run an unfiltered Console scheme test or the full UITest suite.
- Do not `worktree remove` the shared Cursor tree or item 02 path.
