<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after review item 20a in an isolated worktree._

## Next Intended Move

Merge `review-20a-ios-job-runner` when Christopher asks. Do not push or delete that worktree from here. 20b (xcresult parser) and 20c (results UI) are not started. Continue isolated review items; max three worktrees.

## Working Findings

- Item 20a is on `review-20a-ios-job-runner`: `IOSBuildJob` states queued/running/succeeded/failed/cancelled/timedOut with an immutable `IOSProjectProfile` snapshot, UUID, timestamps, exit code, result-bundle URL, and bounded output. `IOSBuildCoordinator` builds structured `xcodebuild` argv (executable + args, never `zsh -c`), serializes Console-owned jobs, and uses distinct `*.xcresult` paths. Build and Run Selected Tests are offered. Tests require identifiers or an explicit/saved test plan; a whole UI suite is never implied. Timeouts are configurable; test jobs add `-test-timeouts-enabled` and allowance flags. No signing/provisioning/upload flags. Success is the process exit code, never log wording. Missing/malformed bundles are recorded as paths/exit codes without parsing.
- Not wired into ConsoleApp or Settings; 20c owns the panel. No xcresulttool (20b). No real-device/synthetic-project smoke; unit tests use a fake `ProcessRunning`.
- Targeted tests passed: `IOSBuildCoordinatorTests` (16 cases). Debug Console build succeeded (`/tmp/console-review-20a-derived`).

## Dead Ends

- Shared Cursor worktree contaminates parallel items. Always `git worktree add` from current `main` at `/Users/christopherlarsen/Workspace/Console`.
- `job(id)` without the `id:` label does not compile against `job(id:)`. XCTest methods that `await waitForJob` must be `async`.
