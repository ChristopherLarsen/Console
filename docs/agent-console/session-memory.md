<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 14 in an isolated worktree._

## Next Intended Move

Merge `review-14-next-honest-navigation` when Christopher asks. Do not push or delete that worktree from here. Continue isolated review items; max three worktrees.

## Working Findings

- Item 14 is implemented on `review-14-next-honest-navigation`: Next snapshots carry source availability, last successful extraction, and failure. Signed-out/unconfigured/failed sources yield "Could not check these sources", not an unqualified all-clear. Loaded empty lists say "No work in the loaded lists". Stale picks get one "Showing previous results" label.
- Open verifies the candidate still exists. Synthetic tickets use `JiraDeepLink` + the captured issue URL on the retained Jira page. Missing session IDs never match another session by name; Open source / Refresh is offered instead. Cached session recommendations reselect locally when the session disappears or leaves needs-you. No LLM path, no new timer or API client. Item 03's single model and sibling Refresh/Open remain.
- Targeted tests passed: NextContextBuilderTests, NextButtonModelTests, NextTaskNavigationTests. Debug Console build succeeded (`/tmp/console-review-14-derived`).

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
