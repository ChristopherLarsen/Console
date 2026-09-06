<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Parent should merge `review-10-session-launch-errors` (item 10) from the isolated worktree. Do not push or delete that worktree. Item 16 (bridge assembly failure) depends on this error-presentation path.

## Working Findings

- Item 10 done in `/Users/christopherlarsen/orca/workspaces/Console/review-10-session-launch-errors` on `review-10-session-launch-errors`. MainView shows `SessionLaunchErrorBanner` for contextual failures; the workspace chooser keeps the pending draft/folder until success or cancel; Start is disabled for unavailable and non-Git Review folders; associations and last-used are written only after `createSession` succeeds.
- Intent picker still owns its own thrown-error UI (item 02 metadata rule unchanged; no source-derived prompts, no `--name`).
- Tests (pass): `SessionLaunchCoordinatorTests`, `SessionWorkspaceChooserTests`. UI: `SessionsUITests/testSyntheticLaunchFailureShowsActionableError` (DEBUG `-uiTestSessionLaunchFailure`). Debug `Console` build succeeded with `-derivedDataPath /tmp/console-review-10-derived`.
- UI test asserts the banner and Settings route on Home; it does not click through Open Settings (host overlay intercepted the tap). Coordinator tests cover `openSessionsSettings()`.

## Dead Ends

- Do not treat the shared Cursor `Console` worktree as source of truth while other review items are in progress.
