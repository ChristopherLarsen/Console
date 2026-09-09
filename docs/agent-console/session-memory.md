<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-09 after fixing the dead-terminal-after-Claude-exit behavior._

## Next Intended Move

Christopher should manually verify the exit-shell fix with real Claude: start a
session, quit Claude (e.g. `/exit`), confirm the pane returns to a live zsh
prompt with scrollback intact, and that removing the row closes the shell.
Separately: the /vx-issue Codex skill (installed 2026-09-08) is waiting for the
first real GitHub issue to exercise push/deletion paths.

## Working Findings

- Sessions PTY bug fixed: Claude was the PTY child with no shell behind it, so
  quitting Claude left a dead pane. Now `SessionStore.handleProcessTerminated`
  (retained sessions only) calls the new `SessionProcessLaunching.startExitShell`
  (`/bin/zsh --login` in the same view, drawer-equivalent env, no bridge vars,
  cwd = session working directory). SwiftTerm preserves the buffer, so
  scrollback survives and the prompt appears below Claude's output. Row stays
  Exited; closing/removing the row kills the shell. `terminateAll` passes
  `startExitShell: false`. Respawning on later shell exits is intentional
  (pane stays usable until explicitly closed).
- New unit tests in `SessionStoreTests`: exit shell on natural exit, none after
  user terminate, restart on shell exit, none on terminateAll. Fake launchers
  in six test files gained the `startExitShell` no-op/recorder.
- Spec ground truth updated in the same change set: `CONSOLE_TERM_COMM.md` §1
  and `docs/agent-console/overview.md` Sessions row.
- SessionStoreTests builds via `ConsoleTerminalView()` with a dead
  `LocalProcess` — the `process?.running != true` guard makes the respawn path
  testable without real processes.
- Uncommitted-before-this-session leftovers (not mine, untouched):
  `SessionsView.swift` empty-state tweak (button removed, icon `terminal`,
  chevron top-aligned) and the 2026-09-08 session-memory rewrite.
- Personal vx-issue skill at `~/.codex/skills/vx-issue` (+ symlink in
  `~/.agents/skills`); targets ChristopherLarsen/Console (ADMIN), pushes
  verified fixes to main, deletes the fixed issue; parent cleans worktrees.
- Prior campaign: 183 bugs fixed in `efaed4f..c7da875`, all merges green.

## Dead Ends

- Full UITest suite remains forbidden. Earlier evidence: two E2E command-flow
  tests and SpeechPipelineUITests positive control fail identically on pristine
  HEAD (synthesized clicks never actuate; app.windows unreliable).
- This gh version rejects `--slurp` with `--jq`; the issue command uses Python
  to select from paginated JSON.
- Remove owned worktrees only after their task stops; never force removal.