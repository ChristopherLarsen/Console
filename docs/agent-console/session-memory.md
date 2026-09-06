<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Parent should merge `review-16-bridge-failure-degrade` (item 16) from the isolated worktree. Do not push or delete that worktree. Do not start item 18 (Sessions layout).

## Working Findings

- Item 16 done in `/Users/christopherlarsen/orca/workspaces/Console/review-16-bridge-failure-degrade` on `review-16-bridge-failure-degrade`. Plugin assembly is optional: a throwing assembler still launches the resolved Claude executable with `--session-id` only, `bridgeStatus = .unavailable`, and a session-pane warning. Genuine `launcher.launch` failures roll back the row, token, and previous selection. Item 10 launch-error presentation is unchanged. Item 02 source-data rule holds on the uninstrumented path (no `--name`, no argv/env/send leak, no auto-submit).
- Seams: `ConsoleClaudePluginAssembling` plus existing `SessionProcessLaunching`. `SessionCreationError.pluginAssemblyFailed` remains the warning copy; `createSession` no longer throws it.
- Tests (pass): `SessionStoreTests`, `SessionsPackagingTests`, `SessionLaunchCoordinatorTests`. Debug `Console` build succeeded with `-derivedDataPath /tmp/console-review-16-derived`.

## Dead Ends

- Do not treat the shared Cursor `Console` worktree as source of truth while other review items are in progress.
