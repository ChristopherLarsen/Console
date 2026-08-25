# Console — Build & Test Manual

All `xcodebuild` commands run from `Console/` — the directory that contains
`Console.xcodeproj` (repo root is one level up).

## Targets & schemes

Targets: `Console`, `ConsoleTermBridge`, `SwiftTerm`, `ConsoleTests`,
`ConsoleUITests`. Schemes mirror the target names. Configs: Debug, Release.

## Build

```bash
cd Console   # repo subdir containing Console.xcodeproj
xcodebuild build -project Console.xcodeproj -scheme Console -destination 'platform=macOS'
```

Debug build succeeds as of 2026-08. Serialize builds: one xcodebuild at a time
on this machine; check for in-flight builds before starting another (bounded
wait, e.g. `for i in {1..20}; do pgrep -x xcodebuild >/dev/null || break; sleep 15; done`).

## Testing rules

1. **Prefer unit tests (`ConsoleTests`) whenever they can prove the change.**
2. **NEVER run the full `ConsoleUITests` suite** and never test the `Console`
   scheme unfiltered (it pulls in UITests). UI tests launch the real app per case.
3. Every `test` action that can reach `ConsoleUITests` MUST carry `-only-testing:`.

### Unit tests

```bash
# Whole unit-test scheme is acceptable; it does not launch the app UI suite.
xcodebuild test -project Console.xcodeproj -scheme ConsoleTests -destination 'platform=macOS'

# Preferred for iteration — one class:
xcodebuild test -project Console.xcodeproj -scheme ConsoleTests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleTests/CommandMatcherTests

# One method:
... -only-testing:ConsoleTests/CommandMatcherTests/<testMethodName>
```

### UI tests (targeted only)

```bash
xcodebuild test -project Console.xcodeproj -scheme ConsoleUITests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleUITests/NavigationUITests/testLaunchStartsOnHome
```

Map changed surface → UITest class: sidebar → `NavigationUITests`, settings →
`SettingsUITests`, sessions → `SessionsUITests` / `HomeSessionsUITests`, menu
bar → `MenuBarUITests`, permissions → `PermissionsFlowUITests`, notes →
`NoteDictationUITests`, speech → `SpeechPipelineUITests`, triggers →
`TriggersUITests`, commands → `CommandsUITests` / `CommandExecutionUITests`.

Run the entire UITest suite ONLY when Christopher explicitly asks.

## Known baseline state (verify before blaming your change)

- **Flaky:** `EndToEndIntegrationTests.testFieldDictation_ActivatesAndReleasesCleanly()`
  fails roughly half of runs.
- **Deterministically red:** ~6 of 32 `ConsoleUITests` cases failed at last full
  audit (incl. `NavigationUITests.testJiraSidebarAndSettingsURLField`).

If a suite fails identically on pristine `main` (stash your work, re-run once),
record it as pre-existing, exclude it from your narrow verification runs via
`-only-testing:` selections, and REPORT it. Do not fix drive-by, do not let it
fail every slice.

## Hosted-app test safety (macOS)

Unit/UI tests host the real app: it opens on screen each run. A trapping test
(`precondition`/`fatalError`/uncaught NSException) makes the runner relaunch it
repeatedly — looks like a hang. Guards:

- Bound every wait; never loop indefinitely on `pgrep`.
- Give slow suites self-terminating timeouts:
  `-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600`
  (and `-default-test-execution-time-allowance 120` for known-slow suites).
- After a suspicious stall, check `~/Library/Logs/DiagnosticReports/` for fresh
  `.ips` files naming the host binary before assuming deadlock.
- Never terminate `/Applications` apps or anything you did not launch; only
  agent-launched test hosts (verified by exact PID) may be stopped.

## Adding files

Filesystem-synchronized Xcode groups: drop new `.swift` files under
`Console/Console/` (app) or `Console/ConsoleTests/` (unit tests) and they are
picked up automatically. No project-file surgery required.

## CatalogGenerator (dev-only CLI)

```bash
./Scripts/generate-catalog.sh all        # or: build | discover | generate | validate | review
```

Output `ActionCatalog.json` is committed and bundled with the shipping app.
The tool itself never ships. See `CatalogGenerator/README.md`.
