# Console: iOS developer workflow review and implementation backlog

Reviewed 2026-09-06 against `d3f1b25` (clean working tree at review start).

## Implementation status (2026-09-06)

All numbered items **01–24** landed on `main` at `fcc7cb7` and were pushed.
The text below is the original assignment backlog; do not re-open a slice unless
Christopher asks.

Known gaps left unverified (source work shipped; these are not live passes):

- **15:** VoiceOver called out in source only, not a live VoiceOver pass.
- **18:** no live visual check at 800×500 and 1100×700 in light and dark.
- **20c / 21:** no in-repo synthetic iOS project or live Simulator smoke.

Console has useful foundations: persistent terminal views within a session, a reduced local lifecycle bridge, workspace routing, native dashboard cards, and DOM extractors with synthetic test seams. Its biggest product gap is the absence of a structured **select project → build/test → inspect failure → run in Simulator** workflow. Today most of that work must still happen inside an agent terminal or Xcode.

Fix the correctness issues first. Adding more automation on top of unreliable execution, invisible failures, or the wrong workspace will magnify the problems.

## Evidence and limits

This was a source and test-code review of app wiring, commands, sessions, workspace routing, Next, Brief, Home, and Jira/GitLab controllers and views. It was not an exhaustive review of every speech/provider implementation or the vendored terminal library. No company pages, credentials, runtime ticket/MR content, or screenshots were accessed. No app-source changes, commits, full app build, XCTest run, or live UI inspection were performed. Layout suggestions below are code-informed proposals, not claims of visual testing.

Focused synthetic probes strengthened the findings:

- Compiled the actual `ActionExecutor.swift`, `AppleScriptRunner.swift`, `CommandAction.swift`, and `CompletionCheck.swift` with a temporary standalone Swift harness. `seq 1 200000` hung through the shell runner; a synthetic AppleScript returning 524,288 characters hung through the AppleScript runner. Each was stopped at five seconds using only its owned probe process group. Direct execution with concurrently drained output completed in 0.024 and 0.036 seconds, respectively. Their outputs were about 1.29 MB and 0.52 MB.
- Created a temporary, synthetic Git repository and linked worktree without network access. Git could read the worktree's remote, but the `gitdir/config` path used by Console did not exist. The worktree had a `commondir` file, which Console does not follow.
- The actual shell runner returned literal quotes for `echo "hello world"`, confirming that it treats shell syntax as space-separated executable arguments.

Installed tooling reported Xcode 26.6. Local help confirmed `xcresulttool get test-results summary` and `simctl bootstatus`. Apple's [test-results documentation](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results) supports the result-bundle direction in item 20; Git's [worktree documentation](https://git-scm.com/docs/git-worktree) explains the shared configuration relevant to item 11. The recommendations use local tools and do not require new company-service API integrations.

## How to hand this off

Assign one numbered item at a time. Supply this document and the named source/test files. The implementation instructions and acceptance checks are the definition of done; do not ask the implementing model to redesign the whole subsystem.

Common instructions for every task:

1. Read the repo `AGENTS.md`, project charter, security boundaries, and relevant feature spec. Preserve unrelated changes. Do not edit `Console/SwiftTerm/`, commit, or publish anything.
2. Use synthetic fixtures and injected process/network seams. Never test with company DOM or transmit company data. Session prompts and panel content remain memory-only. Persist only configuration that the existing boundary allows.
3. Implement only the listed scope. Add meaningful targeted tests for the failure behavior. Use the existing filesystem-synchronized source/test folders; avoid project-file changes unless a new target is actually needed.
4. After implementation, run the relevant test class/method and one Debug build, serializing xcodebuild. Every test command must be filtered and include `-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600`. Never run the full UI suite.
5. Report changed files, test results, and any unresolved acceptance check. Do not label a simulated or source-only check as a live UI pass.

Example verification recipe, run from the repository's `Console/` subdirectory:

```sh
xcodebuild test -project Console.xcodeproj -scheme ConsoleTests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleTests/SpecificChangedTestClass \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600
```

The two privacy items describe conflicts in the current specifications and implementation. The recommended remediation follows the binding security ledger. A lower-capability model must not decide to weaken that policy. Enabling a different company-data policy requires a separate, explicit owner decision.

## Priority and assignment order

P0 = resolve before further use of affected company-data features. P1 = correctness or lost-work fixes. P2 = usability or new workflow capability.

| ID | Priority | Task | Depends on |
|---|---|---|---|
| 01 | P0 | Make Next's panel-derived recommendations entirely local | — |
| 02 | P0 | Keep contextual ticket/MR metadata out of Claude | — |
| 03 | P1 | Give Next one shared state model and separate its buttons | 01 |
| 04 | P1 | Preserve and enforce dangerous-command confirmation | — |
| 05 | P1 | Prevent process-output deadlocks | — |
| 06 | P1 | Give commands a real Stop and execution timeout | 05, 08 |
| 07 | P1 | Preserve quoted arguments and working directories | 05 |
| 08 | P1 | Route every command launch through one execution owner | — |
| 09 | P1 | Preserve action settings when editing, reordering, and duplicating | — |
| 10 | P1 | Show session-launch errors and preserve retry context | — |
| 11 | P1 | Resolve Git remotes correctly for linked worktrees | — |
| 12 | P1 | Resume cancelled MR extraction and apply changed configuration | — |
| 13 | P1 | Preserve Brief edits across asynchronous work | — |
| 14 | P2 | Make Next honest about freshness and navigate to the chosen item | 01, 03, 12 |
| 15 | P1 | Reveal GitLab authentication and recover after sign-in | 12 |
| 16 | P1 | Let Claude launch when optional bridge assembly fails | 10 |
| 17 | P2 | Honor retry/fallback settings and report completion-check failures | 04, 05, 06, 08, 09 |
| 18 | P2 | Make Sessions usable at small window sizes | — |
| 19 | P2 | Add a saved iOS project execution profile | — |
| 20 | P2 | Add a bounded Build/Test job workflow with result navigation | 05, 06, 07, 19 |
| 21 | P2 | Add explicit Simulator build/install/launch actions | 19, 20 |
| 22 | P2 | Warn before multiple editing sessions share one checkout | 11 |
| 23 | P2 | Add keyboard-first developer actions and a task launcher | 19, 20, 21 |
| 24 | P2 | Make Morning Brief attribution match the developer's work | 13 |

Suggested first batch: 01, 02, 03, 04, 05, 08, 09, 10. Then finish execution/routing fixes before 19–23. Items 05, 06, and 20 contain process-lifecycle work: keep their supplied boundaries and tests, and request a stronger review of the finished implementation. Item 20 is explicitly divided into three separate assignments.

---

## 01 — Keep Next recommendations local

**Evidence:** [NextContextBuilder.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/Services/NextContextBuilder.swift:151) serializes MR titles, project and author names, ticket keys/summaries, and session summaries. [NextTaskService.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/Services/NextTaskService.swift:76) sends that text to the selected LLM client. [NextButtonModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/ViewModels/NextButtonModel.swift:101) gathers those values from the live panel controllers. This is an actual outbound code path, not a claim that a particular user's data was transmitted. The service's “explicit user-triggered” comment is also inaccurate because entering Next calls the check automatically.

**Implement:** Make `NextContextBuilder.fallbackTask` the normal selector, or rename it to reflect that role. Remove the LLM call from the panel-derived Next path and remove its dependency on an AI key/provider. Keep the existing priority policy initially so this task changes data handling without also changing prioritization. Preserve local ticket/MR deep links and session selection. Remove or retire prompt-rendering code that has no remaining authorized caller; update the tests that currently assert panel text appears in AI prompts.

**Acceptance:** With no provider configured, synthetic reviews/tickets still produce a recommendation. A provider spy receives zero requests when Next opens or refreshes, regardless of provider type. Synthetic sensitive markers cannot appear in any Next request, log, persisted record, or analytics payload. Existing card priority tests still pass.

**Tests:** `NextContextBuilderTests`; new `NextButtonModelTests` with injected selection/refresh dependencies. Relevant policy: [security-boundaries.md](/Users/christopherlarsen/Workspace/Console/docs/agent-console/security-boundaries.md).

## 02 — Keep contextual source metadata out of Claude

**Evidence:** [StarterPromptBuilder.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/StarterPromptBuilder.swift:20) interpolates ticket/MR identifiers, titles, and URLs into starter prompts. [SessionLaunchCoordinator.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionLaunchCoordinator.swift:276) automatically submits them after `sessionStarted`. [SessionIntentModels.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Models/SessionIntentModels.swift:43) generates names from issue keys/MR numbers, and [SessionStore.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionStore.swift:274) passes the name as `--name` to Claude. Memory-only storage inside Console does not prevent the prompt from reaching an external model or the child CLI's own storage.

**Implement:** Treat WebView-derived context as local routing/display data. Contextual launches may choose a local folder and open an idle session, but they must not generate or send source-derived prompts. Separate the local display name from a generic child-process name, or omit `--name`; keep the two UUID identities unchanged. Do not propagate source metadata through args, environment, fallback prompts, automatic submissions, or session summaries sent to another provider. Explain in the launcher that work context must be entered explicitly by the developer. Disabling only automatic start is insufficient because the manual starter button sends the same data.

**Acceptance:** Synthetic sentinel key/title/URL stays available for permitted in-app display but is absent from captured launcher argv/environment and terminal-send bytes, on both manual and automatic paths. General sessions remain usable. Regression tests cover toolbar, card, and retained-page prepopulation entry points.

**Tests:** `SessionLaunchNamingTests`, `SessionLaunchCoordinatorTests`, `SessionStoreTests`. Update conflicting wording in `CONSOLE_TERM_COMM.md` to agree with [security-boundaries.md](/Users/christopherlarsen/Workspace/Console/docs/agent-console/security-boundaries.md); do not invent a personal/company hostname allowlist as a workaround.

## 03 — Give Next one observable state and separate action targets

**Evidence:** [NextView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/Views/NextView.swift:11) owns a `NextButtonModel`, and [NextTaskCardView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/Views/NextTaskCardView.swift:15) creates another. The page's automatic check and “Determine Next Task” button update a model the visible card never reads. The card's ready-state navigation button also contains its own refresh button.

**Implement:** Let the destination own one model and pass it into the card. Make the card render that model; remove its private model and duplicate check wiring. Place Refresh and Open as sibling controls, with explicit accessibility labels. Define the model lifetime at destination/app scope so the five-minute cache is real, and cancel or invalidate outstanding checks using one owner.

**Acceptance:** Opening Next shows Checking then the result on the card. Either refresh affordance causes exactly one check and updates the same card. Refresh does not navigate. Clicking the result does navigate. Re-entering within the freshness window does not trigger duplicate work. No placeholder `SessionStore()` is silently created when an environment dependency is missing.

**Tests:** model tests with a suspended fake check; a new targeted `NextUITests` method using synthetic sources and no real provider.

## 04 — Preserve command confirmation through Save, Test, and Run

**Evidence:** [CommandCreationViewModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/ViewModels/CommandCreationViewModel.swift:182) reconstructs a `Command` without `requiresConfirmation`, whose initializer defaults to false. [CommandCreationView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Views/CommandCreationView.swift:453) does the same for Test. [LocalCommandExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/LocalCommandExecutor.swift:48) trusts that boolean. Validation can return `.requiresConfirmation`, but Save only rejects `.failure`; the requirement is not copied onto the new command.

**Implement:** Track the generated confirmation requirement in the editable draft. Carry it into saved and test commands. Revalidate the edited draft before Test/Save and immediately before execution, translating a dangerous result into the existing authorization flow. Preserve the user's existing confirmation preference and an already-granted authorization for the same unchanged draft; avoid asking twice. Do not expand the shell allowlist in this task.

**Acceptance:** A synthetic dangerous AppleScript command marked for confirmation retains the flag after Save and Test. Adding a dangerous operation through the editor also triggers authorization. Denial produces zero executor calls. Editing an already-authorized draft invalidates that authorization. Safe commands do not gain unnecessary dialogs.

**Tests:** new `CommandCreationViewModelTests` and focused `LocalCommandExecutorTests` using an injected authorization spy; never run the dangerous payload.

## 05 — Drain child-process output while the process is running

**Evidence:** [ActionExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/ActionExecutor.swift:135) reads stdout/stderr only inside the termination handler. [AppleScriptRunner.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/AppleScriptRunner.swift:220) calls `waitUntilExit()` before reading either pipe. A child that fills a pipe blocks before it can exit. Both paths were reproduced with the actual source as described above.

**Implement:** Use one reusable asynchronous process service with an invocation object owning the child and both pipes. Install handlers before launch; drain stdout and stderr concurrently from process start; collect completion only after termination and both EOFs. Keep process waiting off the main actor. Reuse the design in [ProcessRunner.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Updates/ProcessRunner.swift:21) where useful, but do not assume its cancellation behavior is already complete. Bound retained output or explicitly spool permitted command output to a user-controlled run log; report truncation rather than allowing unlimited memory growth.

**Acceptance:** More than 1 MB on stdout alone, stderr alone, and both simultaneously completes correctly. Empty output, a nonexistent executable, and a fast nonzero exit all finish exactly once. AppleScript execution leaves the main actor responsive. The tests themselves have hard timeouts and clean up only their own processes.

**Tests:** new standalone `ProcessRunnerTests` and `ActionExecutorTests`; synthetic processes only. Keep cancellation semantics for item 06.

## 06 — Make Stop and execution timeouts stop the owned process

**Evidence:** [LocalCommandExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/LocalCommandExecutor.swift:32) sets a boolean checked between actions. It cannot interrupt the current child process or completion wait. `timeoutMS` is used for completion checks, not to limit action execution. Neither command process path has an action deadline.

**Implement:** Store a cancellable execution task/run ID in the shared owner from item 08. Pass cancellation and a deadline into the process service from item 05. On cancel/timeout, terminate the owned child and, after a bounded grace period, force-stop that invocation if still alive. Account for its owned descendants without ever killing unrelated Xcode/Simulator/user processes. Handle cancellation before launch as well as during launch and execution; an already-cancelled job must not spawn later. Make completion polling and post-action sleeps cancellation-aware.

**Acceptance:** Stop interrupts a long-running synthetic command promptly; no later action or fallback starts. An action with a short timeout terminates and reports Timeout. Cancel-before-launch creates no child. A TERM-resistant fixture is force-stopped within the documented grace period. The next command can run normally, and cancellation of an old run cannot affect it.

**Tests:** `ProcessRunnerTests`, `LocalCommandExecutorTests`, new `CompletionCheckerTests`.

## 07 — Preserve shell arguments and select a working directory explicitly

**Evidence:** [ActionExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/ActionExecutor.swift:112) splits payloads on literal spaces and launches `/usr/bin/env`. Quotes remain literal, paths containing spaces break, and `cd`, pipes, redirection, and variable expansion do not have shell semantics. The model already defines `ShellPayload(command,args,workingDirectory)` but this execution path does not use it.

**Implement:** Prefer executable plus argument array plus working directory as the stored execution contract. Add backward-compatible decoding for existing string commands. Parse only a documented safe subset of legacy quoted arguments, and present a clear validation error for unsupported shell operators instead of changing their meaning silently. Update validation to use the same parsed representation as execution. Do not blindly replace the implementation with `zsh -c`; that changes the meaning and authorization requirements of every saved command. Give iOS jobs structured argv directly.

**Acceptance:** Paths and scheme names with spaces, empty quoted arguments, escaped quotes, and Unicode arrive as exact argument values. The chosen working directory is respected. Legacy simple commands still run. Unsupported operators produce a clear error before launch. Tests inspect captured argv/cwd rather than invoking user tools.

**Tests:** new `ShellPayloadTests` and `ActionExecutorTests`; relevant source: [CommandAction.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Models/CommandAction.swift:77).

## 08 — Give all command entry points the same execution owner

**Evidence:** [CommandListView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Views/CommandListView.swift:299), [CommandCreationView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Views/CommandCreationView.swift:453), and [RecentCommandsController.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/RecentCommandsController.swift:23) create temporary `LocalCommandExecutor` instances. The stop notification in [MenuBarViewModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/MenuBar/ViewModels/MenuBarViewModel.swift:56) reaches only the app-owned instance. The shared executor also has no guard against overlapping executions, so two invocations can overwrite its shared cancellation/result flags.

**Implement:** Inject the existing app-owned executor into command-list Test, command-creation Test, recent-command Run, voice, and App Intents. Return a run ID and per-run result to each caller. Initially allow one app command execution at a time; return a visible “A command is already running” result for a second request rather than silently queueing automation. Keep this owner independent of Claude PTYs and the global zsh drawer. Have one completion/logging path, without double-counting test or failed runs.

**Acceptance:** The global Stop action reaches commands launched from each entry point. A second launch cannot reset cancellation or set `isExecuting` false while the first is still active. The initiating UI receives its own result, not the result of a later run. One run emits one completion notification/log entry under the existing logging policy.

**Tests:** injected executor-spy tests at entry points and overlapping-run tests in `LocalCommandExecutorTests`.

## 09 — Preserve all action settings when editing and duplicating

**Evidence:** [CommandCreationViewModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/ViewModels/CommandCreationViewModel.swift:146) rebuilds an action from only ID/type/payload/order; [CommandCreationViewModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/ViewModels/CommandCreationViewModel.swift:265) does the same. Delay, timeout, retry settings, completion checks, and fallback actions silently return to defaults. [CommandListView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Views/CommandListView.swift:312) copies timing/retry values but drops completion checks and fallback actions.

**Implement:** Since `CommandAction` is a value type with mutable fields, mutate just `payload` or `order` on a copy. For duplication, copy the entire value and replace only the action UUID as needed. Preserve command-level configuration; a duplicate may receive a new command UUID/name, but its behavior must be identical.

**Acceptance:** Construct an action with nondefault values in every field. Payload editing changes only payload; removal/reordering changes only necessary orders; duplication preserves every behavioral field and assigns distinct IDs. Include round-trip persistence coverage.

**Tests:** `CommandCreationViewModelTests`, `CommandListTests`, or a pure action-copy helper test.

## 10 — Display session launch failures and keep retry context

**Evidence:** [SessionLaunchCoordinator.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionLaunchCoordinator.swift:55) records `lastFailureMessage`, but no view reads it. [MainView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Views/MainView.swift:40) suppresses chooser failures with `try?`. `confirmWorkspaceChoice` clears `pendingChoice` before attempting the launch. Workspace associations and last-used preferences are also written before successful session creation.

**Implement:** Add one error presentation at `MainView` for contextual launches, and explicit error state inside the chooser. Preserve the pending draft and selected folder until a successful launch or user cancellation. Disable Start for an invalid workspace, including a non-Git folder for Review. Commit learned routing/last-used state only after successful creation. Clear obsolete errors on a successful new attempt and expose a route to Sessions settings for executable/folder problems.

**Acceptance:** Missing Claude, disappearing folder, non-Git review folder, and injected launcher failure each produce an actionable error. Retry retains the draft. Cancel dismisses it. Failed launches do not learn routing preferences or navigate as if successful. Existing direct picker error handling remains intact.

**Tests:** `SessionLaunchCoordinatorTests`, targeted chooser tests with fake launcher, and one synthetic UI failure case.

## 11 — Fix remote lookup for linked worktrees

**Evidence:** [RepositoryIdentityResolver.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/RepositoryIdentityResolver.swift:51) follows a `.git` pointer then reads `<gitdir>/config`. Standard linked worktrees keep shared repository configuration in the common directory. The synthetic worktree experiment reproduced that mismatch. `remoteURLs(inConfig:)` also accepts any line beginning with `url`, without tracking whether it is a `[remote "..."]` section.

**Implement:** Read effective local remote configuration through a bounded local Git command such as `git -C <folder> config --get-regexp '^remote\..*\.url$'`, using structured arguments and no network. Alternatively, explicitly implement `commondir` and section-aware parsing, but the Git command avoids duplicating config/include semantics. Keep lookup asynchronous and cache only as necessary; do not block the UI. Return only normalized identities to the resolver, and never log remote strings or embedded credentials.

**Acceptance:** Real temporary fixtures cover normal repos, linked worktrees, relative gitdir pointers, submodules where feasible, and config includes. A nonremote `url` value must not cause a match. Missing Git/config returns no match safely. Exact-one and ambiguous-match behavior remains as currently specified.

**Tests:** extend `SessionLaunchNamingTests` with actual temporary local Git layouts instead of only hand-created `.git/config` directories. Do not change the workspace fallback policy in this task.

## 12 — Recover MR extraction after navigation and configuration changes

**Evidence:** [MergeRequestsPanelView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/CodeHost/Views/MergeRequestsPanelView.swift:59) cancels work when Home disappears. [CodeHostListPanelController.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/CodeHost/Services/CodeHostListPanelController.swift:75) sets `hasStarted` once, then on later appearances only calls `reevaluateConfiguration`, which does not resume a cancelled loading/extracting task. A URL edited while Home is unmounted can also leave the retained controller using its previous configuration.

**Implement:** Give the controller explicit suspended/needs-extraction state. On appearance, compare the effective normalized URL against the previously applied URL, invalidate old-source state if changed, and resume incomplete work. Snapshot generation IDs before starting tasks; ignore results from older generations after every await. Reset `isRefreshing` on all exits, including removal/invalidity of configuration. Avoid duplicate first-load refreshes in `MergeRequestListSession.refreshBoth`.

**Acceptance:** Navigate away during a suspended load, then back: it completes or offers a clear retry, never remains a skeleton forever. Change list A to B while Home is absent: B loads on return, and A's late result cannot win. Clearing configuration stops the spinner. Reopening an already-complete unchanged panel preserves its page and cards.

**Tests:** `CodeHostListPanelControllerTests` with controllable page-loader/extractor continuations and generation assertions.

## 13 — Preserve Brief edits when regeneration or AI refinement finishes

**Evidence:** [BriefViewModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Brief/ViewModels/BriefViewModel.swift:76) captures `current` before awaiting AI and then writes a refinement of that old value. [BriefGenerationService.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Brief/Services/BriefGenerationService.swift:58) snapshots stored tasks before awaiting the activity collector. The editor remains usable while those operations are pending, so a late response can overwrite newer edits or restore a deleted task. Regenerate and Refine also have separate busy flags and may overlap.

**Implement:** Track a brief/day operation generation and task-edit revision. At completion, merge generated yesterday-lines into the latest brief for the same day; preserve current manually edited tasks. Read the latest stored version before saving. Superseded operations must not update either disk or UI. Define whether Regenerate supersedes Refine or serialize them; make that behavior visible. Keep cancellation tied to the operation rather than relying on weak references.

**Acceptance:** Suspend generation, edit/add/delete a task, release generation: edits survive in UI and after reload. Repeat for refinement and for overlapping regenerate/refine completions arriving in either order. A previous day's delayed operation cannot replace today's displayed brief.

**Tests:** `BriefStoreAndServiceTests`, new `BriefViewModelTests` with injected suspended collector/refiner and isolated storage.

## 14 — Make Next recommendations honest and open the exact item

**Evidence:** [NextButtonModel.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/ViewModels/NextButtonModel.swift:101) discards source status and freshness: retained MR rows may be stale, while Jira tickets are taken from whatever state last existed. Empty/unavailable sources can end up presented as “Nothing needs you right now.” [NextTaskCardView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Next/Views/NextTaskCardView.swift:212) ignores a ticket's `targetURL` and opens the generic Jira destination. In the current AI implementation, the prompt also omits MR URLs while the parser requires them; item 01 removes that broken dependency rather than trying to infer URLs.

**Implement:** Carry source availability, last successful extraction time, and any known failure into the local snapshot. Distinguish “No work in the loaded lists” from “Could not check these sources.” Select local candidates with stable IDs, keep the existing priority order, and verify the target still exists when clicked. Use the exact captured URL with the retained Jira/MR page. If a session is gone or a source is unavailable, offer Refresh/Open source instead of opening an unrelated session. Invalidate a cached suggestion when its referenced session disappears or changes out of an actionable state.

**Acceptance:** A signed-out/unconfigured/failed source never produces an unqualified all-clear. Known stale data is labelled once. Selecting a synthetic ticket opens its exact issue. Missing session IDs do not select another session. No new background reload timer or API client is added.

**Tests:** `NextContextBuilderTests`, `NextButtonModelTests`, navigation-helper tests.

## 15 — Reveal GitLab sign-in and recover the card view

**Evidence:** [CodeHostListPanelController.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/CodeHost/Services/CodeHostListPanelController.swift:278) passes authentication through `retainOr`, preserving loaded cards as stale without switching `presentation` to browser. [MergeRequestsPanelView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/CodeHost/Views/MergeRequestsPanelView.swift:247) explicitly requires another Show GitLab click. There is no controller observation that resumes extraction after the user completes an ordinary browser sign-in.

**Implement:** Treat authentication separately from ordinary extraction failure. Reveal the retained WebView, make it interactive/accessibility-visible, and display a generic sign-in notice outside its content. Keep prior rows only in memory, hidden while authentication is underway. Observe appropriate navigation completion and perform bounded DOM-only readiness checks, including an explicitly empty list; after successful extraction restore/offer cards according to the existing presentation contract. A same-origin unsupported page should remain usable. No credentials, cookies, network probes, timers that reload pages, or hidden pagination.

**Acceptance:** Loaded cards → authentication result reveals the login WebView, including in VoiceOver. A synthetic completed-sign-in navigation with rows or a recognized empty list updates card availability. New navigation cancels old extraction. Ordinary extraction failure still retains labelled stale cards.

**Tests:** `CodeHostListPanelControllerTests` plus synthetic WebKit integration fixtures.

## 16 — Degrade bridge failure gracefully and avoid phantom sessions

**Evidence:** [SessionStore.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionStore.swift:219) appends/selects a session before `materializePluginRoot()`. If assembly fails, the catch changes activity to Error and throws before launching Claude. The error says the terminal will still work, but no process was launched. Repeated attempts can create multiple phantom rows.

**Implement:** Separate optional instrumentation preparation from process creation. When the bridge/plugin cannot be prepared, launch the ordinary resolved Claude executable without unusable plugin/bridge arguments, mark instrumentation unavailable, and show a small actionable status warning. Only claim a session was launched after the launcher accepts the launch; roll back token/row/selection state on a genuine launch failure. Apply item 02's source-data rule in the fallback path as well. Never auto-submit into an unready terminal.

**Acceptance:** Injected plugin assembly failure still launches one usable uninstrumented session. A genuine launch failure leaves no ghost row or token and preserves the previous selection. Repeated Retry produces at most one new session on eventual success. No path claims the bridge is active before a validated event arrives.

**Tests:** `SessionStoreTests`, `SessionsPackagingTests`, `SessionLaunchCoordinatorTests`; fake launcher and assembler seams.

## 17 — Make runtime behavior match saved retry/fallback/check settings

**Evidence:** [LocalCommandExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/LocalCommandExecutor.swift:73) executes each action once and does not use retry/fallback fields. [CommandExecutor.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Command/Services/CommandExecutor.swift:118) contains those features, but runtime call sites use `LocalCommandExecutor`. A failed completion check sets `overallSuccess=false` without a failed log entry, so the banner can say “Unknown error” while all action rows appear successful.

**Implement as two small assignments:** (a) Extract a pure per-action attempt policy and apply it in the live executor: bounded retries, defined meaning of `maxRetries`, optional fallback, and cancellation checks before every attempt. Validate fallback actions too. (b) Add an explicit completion-check result to execution logs with check type, elapsed time, and timeout/failure state. Do not turn retry on by default for non-idempotent commands. Keep the existing stop-on-error/continue preference.

**Acceptance:** A fake action failing twice then succeeding gets the configured number of attempts. A fallback runs only after exhaustion, and never after cancellation. Zero/negative/out-of-range retry values are rejected or normalized by a documented rule. Completion timeout produces a failed row and an actionable message, not “Unknown error.”

**Tests:** new execution-policy unit tests plus `CommandLoggingTests` and `LocalCommandExecutorTests`. Remove duplicate unused policy only after checking all references.

## 18 — Give the selected session terminal enough space

**Type:** UI recommendation requiring visual verification.

**Evidence:** [SessionsView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Views/SessionsView.swift:11) fixes the right-hand list at 260 points. [MainView.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Views/MainView.swift:29) permits an 800-point window, with a sidebar and an independently expanded 250-point bottom terminal. The selected Claude terminal can receive only a few hundred points of width and very little height. No terminal-focused presentation is offered.

**Implement:** Make the session list collapsible and resizable within bounded limits. Add an explicit “Focus Session” toggle that temporarily collapses the global drawer and session list, saving their previous visibility/sizes and restoring them on exit. Keep both underlying terminal views/processes alive. Do not automatically change the developer's layout just because an agent starts. Show the selected folder/path in a tooltip and the list's visible state using the existing shared color helper.

**Acceptance:** Inspect synthetic sessions at 800×500 and 1100×700 in light/dark appearance. Focus mode leaves a usable terminal, keyboard focus stays on the selected session, and switching/focus toggling preserves scrollback and process identity. Controls remain keyboard accessible; hidden lists do not leave duplicate accessibility elements.

**Tests:** one targeted `SessionsUITests` case for focus/restore, plus manual synthetic visual checks. No full UI suite.

## 19 — Add a saved iOS execution profile per workspace

**Type:** New functionality; first step toward actual iOS automation.

**Evidence:** [SessionIntentModels.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Models/SessionIntentModels.swift:125) stores only workspace ID, name, and folder. [ActionCatalog.json](/Users/christopherlarsen/Workspace/Console/Console/Console/Resources/Catalog/ActionCatalog.json:2650) has a fixed `platform=macOS` CLI example. App source has no structured scheme/test-plan/simulator model or build coordinator.

**Implement:** Add a separate `IOSProjectProfile` keyed by `SessionWorkspace.id`: selected `.xcworkspace` or `.xcodeproj`, scheme, configuration, optional test plan, and Simulator UDID. Discover candidates within a bounded workspace search that excludes dependencies/build output; prefer a user-selected workspace rather than guessing between multiple valid choices. Use bounded `xcodebuild -list -json`, `-showTestPlans`, and destination discovery as supported by the selected project. Keep discovery asynchronous and show progress/errors. Store local user-selected configuration only; no signing credentials or source content.

**Files:** new `IOSWorkflow/Models/IOSProjectProfile.swift`, `Services/IOSProjectDiscovery.swift`, `Services/IOSProjectProfileStore.swift`, and a small Settings section. Use the command/process abstraction; do not build a second shell parser.

**Acceptance:** One project, multiple projects, workspace plus Pods project, spaced paths, invalid saved scheme, and missing simulator all have predictable selection/repair behavior. A discovery failure cannot replace a previously valid profile with empty values.

**Tests:** JSON parser fixtures, profile migration/store tests, argv tests with a fake process runner. Do not launch a real build merely to test discovery.

## 20 — Add Build/Test jobs and actionable results

**Type:** New functionality. Assign the following slices separately; do not give the whole item to a weaker model in one turn.

**20a — Job runner:** Add `IOSBuildJob` states `queued/running/succeeded/failed/cancelled/timedOut`, immutable profile snapshot, UUID, timestamps, exit code, result-bundle URL, and bounded output. `IOSBuildCoordinator` constructs structured `xcodebuild` argv from item 19. Offer Build and Run Selected Tests. Require explicit test identifiers/test-plan selection; never silently choose a whole UI suite. Serialize Console-owned builds on this machine and use distinct result-bundle paths. Keep build and test timeouts configurable and add test-runner timeout flags. No signing/provisioning/upload automation.

**20b — Results parser:** After execution, inspect the produced `.xcresult` with the installed `xcresulttool` subcommands. Parse a bounded summary of build issues/test failures into models with file URL, line, test identifier, and message when available. Handle missing/incomplete/corrupt bundles and schema mismatches without converting failure into success. Exit status and result records determine success; never infer success from an agent's natural-language summary.

**20c — Results UI:** Add a compact project job panel with progress, Stop, elapsed time, result state, first actionable issue, and expandable output. Actions: Open Result in Xcode, Open Source Location, Copy Error, and Rerun Failed Tests. The last action uses only validated failed-test identifiers from the selected job. Do not automatically send errors or source snippets to an LLM.

**Acceptance:** Fake successful build, compile failure, failing selected test, cancellation, timeout, missing bundle, malformed JSON, and two queued builds all produce correct states. Failure opens the correct available source/result location. Rerun targets only failed tests. One synthetic iOS project is used for an explicitly targeted end-to-end smoke test after the unit tests pass.

**Files/tests:** new `IOSWorkflow/Services/IOSBuildCoordinator.swift`, `IOSResultParser.swift`, `Views/IOSBuildJobView.swift`, and corresponding tests. See Apple's [results documentation](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results). Keep job output local and follow the workspace's applicable data policy; result bundles may contain screenshots/logs and must never be uploaded automatically.

## 21 — Add Simulator selection, install, and launch

**Type:** New functionality; depends on a successful selected build.

**Implement:** Add `SimulatorService` using structured `xcrun simctl` calls. List available devices as typed values, select an explicit UDID, boot that device if needed, wait with bounded `bootstatus`, install the successful job's exact `.app`, and launch its bundle ID. Obtain product path and bundle ID from build metadata/Info.plist, never by guessing app names. The UI should show which device will be affected and offer Open Simulator. Do not erase/shutdown other devices or fall back silently to whichever device happens to be booted.

**Acceptance:** Unavailable runtime, missing app, failed build, boot timeout, install failure, and launch failure each stop at the right step with a useful message. A successful fake sequence is list → boot/readiness → install → launch for one UDID. A user can cancel waiting without affecting an unrelated simulator. Finish with one deliberate synthetic-project live smoke test.

**Files/tests:** new `IOSWorkflow/Services/SimulatorService.swift`, small device picker, `SimulatorServiceTests` with fake process outputs.

## 22 — Prevent accidental concurrent editing of one checkout

**Type:** Workflow improvement; current same-folder launches are intentional capability, not proof of file corruption.

**Evidence:** [SessionLaunchCoordinator.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionLaunchCoordinator.swift:191) launches directly in the configured workspace and [SessionStore.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Sessions/Services/SessionStore.swift:185) supports multiple sessions there. There is no common working-copy ownership check, branch/dirty-state display, or conflict warning.

**Implement the small first slice:** Before an editing session starts, compare its canonical working directory to live editing sessions. If another uses the same checkout, offer Focus Existing Session, Continue in Same Folder, or Cancel. Show local branch/dirty state so the developer can decide. Reviews should not be assumed harmless merely because their prompt says read-only; classify session intent conservatively. Do not reset, stash, switch branches, auto-create worktrees, or kill existing sessions in this slice. Treat two linked worktrees as distinct checkouts, even though they share a repository.

**Acceptance:** Two editing sessions targeting one canonical directory get the warning. Symbolic-link aliases match; separate linked worktrees do not. Exited sessions do not block. Focusing an existing session launches nothing. Continuing requires the explicit choice and preserves uncommitted files. Recheck immediately before launch to avoid two simultaneous launch requests bypassing the warning.

**Tests:** coordinator tests with canonical-path fixtures and fake local Git state. Automatic worktree creation can be designed later as a separate task.

## 23 — Add keyboard-first developer actions

**Type:** UI/workflow improvement.

**Implement:** Add a native searchable action picker opened by an available shortcut after checking the existing Go/session shortcuts. Start with a fixed set: Focus Current Session, New General Session, Open Workspace in Xcode, Build Selected Profile, Run Selected Tests, Open Latest Result, Run in Selected Simulator. Each action declares availability and a plain reason when disabled. Route through the same coordinators as buttons; do not generate shell strings with an LLM. Show workspace/scheme/device context in the selected action preview. Add accessible menu commands first, then the searchable picker.

**Acceptance:** Keyboard-only selection and Escape work; existing numbered navigation shortcuts keep their meaning. Build/Test are unavailable without a valid profile and explain why. The action preview and executed profile match. Repeated invocation obeys the job concurrency rules. No task content is persisted as search history.

**Files/tests:** new `IOSWorkflow/Models/DeveloperAction.swift`, `Views/DeveloperActionPicker.swift`, small `ConsoleApp` command integration, availability/routing unit tests, one targeted navigation UI test.

## 24 — Make the Morning Brief describe the developer's own activity

**Type:** Functionality improvement with a concrete attribution gap.

**Evidence:** [BriefActivityCollector.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Brief/Services/BriefActivityCollector.swift:40) runs `git log --no-merges` over each workspace without an author filter. [BriefComposer.swift](/Users/christopherlarsen/Workspace/Console/Console/Console/Brief/Services/BriefComposer.swift:4) drops authors/commit IDs and keeps only repository basename, subject, and commit date. A shared repository can therefore contribute teammates' commits to a report presented as what the developer did. Linked worktrees or repositories with the same basename also cannot be reliably deduplicated.

**Implement:** Add explicit local author identity selection per workspace, defaulted from local Git configuration but shown for confirmation. Support multiple email aliases. Gather commit IDs and author identity locally; filter exact selected identities and deduplicate by canonical repository identity plus commit hash. Provide a date-range selector with “Yesterday” and a manually chosen range so Monday reports need not be stuck on Sunday. Show the actual range and source repositories. Do not add Jira/GitLab ingestion or automatic AI refinement.

**Acceptance:** A synthetic repo with two authors reports only the selected author; aliases work; repeated commits across linked worktrees appear once; same-basename independent repositories remain distinct; day boundaries respect the selected calendar/time zone. Existing hand-edited Today tasks survive regeneration, including while collection is pending.

**Tests:** `BriefComposerTests`, `BriefStoreAndServiceTests`, new collector tests with temporary local commits and controlled dates. Use an isolated BriefStore directory.
