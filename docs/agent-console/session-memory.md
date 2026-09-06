<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Parent should merge `review-01-next-recommendations-local` (item 01) from the isolated worktree. Do not push or delete that worktree. Item 03 (one Next model, split Refresh/Open) depends on this local selector.

## Working Findings

- Item 01 done: Next recommendations are fully local. `NextContextBuilder.recommendedTask` is the selector (same priority as the old fallback). `NextTaskService` and `promptText` are gone. `NextButtonModel.check` / `checkIfNeeded` no longer take an AI provider; they refresh, snapshot, and pick locally. Views no longer show a needs-provider state.
- Check API now has an injectable `refresh` + `snapshot` seam. Optional `llmClient` is accepted and discarded so a spy can prove zero outbound requests.
- Card still shows a `fromAI` badge; the local path always sets `fromAI: false` ("local"). Item 03 can drop that associated value.
- `NextTaskResponseParser` remains because `recommendedTask` still uses `maxLines` / `maxLineLength`. It has no production AI caller after this change.
- Isolated worktree used for compile/test: `/Users/christopherlarsen/orca/workspaces/Console/review-01-keep-next-local` on branch `review-01-next-recommendations-local`. The Cursor workspace worktree was not isolated — other review items were mid-edit there and broke `ConsoleTests` compiles (`pendingStarterPrompt` / `launchArguments name`). Do not treat that workspace as the item 01 source of truth.
- Tests (pass): `NextContextBuilderTests`, `NextButtonModelTests`. Debug `Console` build succeeded with `-derivedDataPath /tmp/console-review-01-derived`.

## Dead Ends

- Running `ConsoleTests` in the shared Cursor worktree while other items are in-progress fails to compile unrelated session tests. Use a clean worktree from `d3f1b25` for item 01 verification.

---
