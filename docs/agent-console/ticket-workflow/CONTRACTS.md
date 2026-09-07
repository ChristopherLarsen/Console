# TicketWorkflow — Shared Contracts (frozen by lead)

Workers implement against these types under
`Console/Console/TicketWorkflow/`. Do **not** widen shared enums/structs
without lead approval. Return only your package’s incremental files.

## Ownership

| Package | Owns | Must not touch |
|---|---|---|
| A — Domain | Reducer, default template, pure tests | App wiring, UI, Keychain, WebKit, IOSWorkflow |
| B — Durable progress | HMAC identity, Keychain secret, storage DTO, load/save | Reducer rules (consume A), UI, jobs |
| C — Job evidence | Adapters from `IOSBuildCoordinator` → workflow evidence events; source fingerprint helper | Competing profile store; rewrite ProcessRunner |
| D — Results bridge | Map `IOSResultSummary` → presentation/evidence helpers for workflow UI | Reimplement xcresult parsing |
| E — Simulator bridge | Map `SimulatorService` / launch model → step action results | Device erase, silent UDID choice |
| F — Jira observations | Detail-status extractor + typed observation | List extractor rewrite; REST |
| G — UI | Ticket Work list/detail, checklist, template editor, synthetic UITests | SidebarSelection hotkeys; Next; SessionStore |
| H — Integration (lead) | App ownership, navigation, session association, Next targets, coordinator | — |

## Reuse (already on main)

- `IOSProjectProfile` / `IOSProjectProfileStore`
- `IOSBuildCoordinator`, `IOSBuildJob`, `IOSTestSelection`
- `IOSResultParser` / `IOSResultSummary`
- `SimulatorService` / `IOSSimulatorLaunchModel`
- `ProcessRunning.run(executablePath:arguments:workingDirectory:deadline:)`
- `SessionStore.lifecycleObserver` — add **subscriber** fan-out; do not replace the single observer without lead

## Privacy sentinels (tests)

Use invented markers such as `SENSITIVE_TICKET_KEY`, `SENSITIVE_TITLE`,
`SENSITIVE_STATUS` in fixtures. Assert they never appear in durable DTOs,
job argv, env, accessibility identifiers, or logs.

## Synthetic fixtures

Jira detail pages: HTML under `Console/ConsoleTests/Fixtures/JiraDetail/`
(scrub hostnames). iOS smoke: lead schedules a small fixture project later;
workers use fakes.

## Verification (lead-scheduled only)

```bash
cd Console
xcodebuild test -project Console.xcodeproj -scheme ConsoleTests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleTests/<YourTestClass> \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600
```

Never run the full UI suite. Do not commit.
