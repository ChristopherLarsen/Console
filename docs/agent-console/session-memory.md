<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-07 after bug-hunt campaign fix phase completed._

## Next Intended Move

Campaign is done. Next: Christopher reviews the 13-merge
series on `main` (`efaed4f..c7da875`). Optional: run broader targeted ConsoleTests slices
to shake out cross-merge interactions (LocalCommandExecutor, MenuBarViewModel,
ConsoleApp, RetryHelper auto-merged between branches — each merge build was
green, but full-scheme unit run not repeated at final HEAD).

## Working Findings

- 183 verified bugs fixed; all merged; build green. Full campaign docs were
  deleted 2026-09-07 at Christopher's request (verified-bugs.md content is
  summarized in that session; the durable record is the merge series itself).
- Verification reports were deleted after fix+merge (Christopher's policy);
  whole campaign tree removed after completion.
- Sub-agent pattern that worked: one worktree + branch per cluster, ≤5
  parallel, agents read campaign docs from main checkout (untracked dir not
  in worktrees), orchestrator merges sequentially + deletes reports + cleans
  worktrees/branches.
- H12-F02 enforcement means curated `do shell script` catalog commands now
  prompt for confirmation — intended.

## Dead Ends

- Full UITest suite still forbidden; 2 E2E command-flow tests +
  SpeechPipelineUITests positive control fail identically on pristine HEAD
  (host issue: synthesized clicks never actuate, app.windows unreliable).
- Worktree cleanup gotcha: `git worktree remove` needs the dir to still exist;
  use `--force` after copying untracked artifacts out first.
