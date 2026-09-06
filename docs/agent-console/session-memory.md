<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Parent should merge `review-08-single-execution-owner` (item 08) from the isolated worktree. Do not push or delete that worktree. Item 06 (Stop/timeouts that kill the child) depends on this owner: pass cancel/deadline into the process service from 05 using `activeRunID` / `cancelExecution()`. Do not start 06 or 09 here.

## Working Findings

- Item 08 done: all command entry points use the app-owned `LocalCommandExecutor`. Temporary `LocalCommandExecutor()` instances are gone from list Test, creation Test, and recent Run. Voice and App Intents already used the shared owner; they now receive `CommandRun` (run ID + per-run result).
- Occupancy: one app command at a time. A second `execute` returns `alreadyRunning` with message "A command is already running", without resetting `cancelled` or clearing `isExecuting`/`activeRunID` of the first run. Busy rejects do not update `lastResult` or increment `completedRunCount`.
- Completion/logging: executor `endRun` is the single completion path (banner/sound). Voice logs once from the returned `CommandRun` via `recordVoiceExecutionLog`; busy results are not logged. Test/intent/recent do not write `CommandLogFileManager`.
- Confirmation-through-Save/Test/Run (04) and concurrent pipe draining (05) preserved. Cancellation remains a boolean plus `activeRunID` for 06.
- Isolated worktree: `/Users/christopherlarsen/orca/workspaces/Console/review-08-single-execution-owner` on `review-08-single-execution-owner`.
- Tests (pass): `LocalCommandExecutorTests`, `CommandEntryPointTests`. Debug `Console` build succeeded with `-derivedDataPath /tmp/console-review-08-derived`.

## Dead Ends

- Shared `onExecutionComplete` on the executor would log Test/recent runs as voice completions. Removed; callers use the returned `CommandRun`.
