# Console — Code Conventions

Learned from the existing codebase. Match what is there before inventing.

## Structure

- Feature-folder organization under `Console/Console/<Feature>/` with
  `Models/`, `Services/`, `ViewModels/`, `Views/` subfolders. Cross-cutting
  app wiring lives in `Console/Console/App/`; shared UI in `Views/Components/`
  and `Extensions/`.
- New feature work follows the same split: pure models and testable services
  stay out of views; view models are `@Observable` / `@MainActor`.

## Swift / SwiftUI style

- macOS 26 SwiftUI. Modern observation (`@Observable`), environment injection
  from `ConsoleApp` / `AppDependencies` — no singletons except the documented
  web sessions (`JiraWebSession.shared`, GitLab session store).
- Value types for data models; explicit state machines as enums
  (e.g. panel states: `unconfigured/loadingPage/authenticationRequired/
  extracting/loaded/empty/stale/unsupportedPage/extractionFailed`) — a selector
  failure must never masquerade as a legitimate empty list.
- DOM extractors: one local JS function via `WebPage.callJavaScript`, returning
  a JSON string decoded with `JSONDecoder`. Prefer semantic HTML/accessibility
  roles → stable test attributes → URL shape. Avoid generated CSS classes.
- Bounded readiness polling (short retries, stop on success/auth/cancel/
  timeout) — never one arbitrary sleep, never unbounded waits.
- Cancellation/generation tracking so stale extraction results can't win.

## Naming

- Descriptive, unhurried names matching neighbors (`SessionLaunchCoordinator`,
  `MergeRequestListExtractor`, `HomeSessionsPanelView`). Suffix by role:
  `*View`, `*ViewModel`, `*Service`, `*Controller`, `*Manager`, `*Tests`.
- Accessibility identifiers are stable strings agreed in specs
  (`HomePanelJiraTickets`, `HomePanelSessions`, `SessionRow.<name>`,
  `HomeSessionCard.<name>`). Reuse them; never invent new ones for existing
  surfaces; never embed user/company content in identifiers.

## UI grammar

- Home cards follow `Design/HomeCards/DESIGN_PROMPT.md` §3: 28pt panel headers
  (13pt semibold title + quiet service/count run + icon-only actions), cards
  44pt minimum growing to content, 6pt state dots, tinted-text states (never
  filled capsules for status), max two artifact chips + `+N` overflow, reserved
  trailing action slot on the title row.
- Whole card = one button. No nested controls inside cards.
- Preserve source-list order from JIRA/GitLab; Console never re-sorts.
- Missing optional fields collapse cleanly — no placeholder dashes.

## Tests

- Unit-test pure logic exhaustively (parsers, reducers, presentation helpers,
  matchers). Synthetic fixtures only; committed fixture content is invented.
- UITests only for launch/UI/navigation behavior unit tests cannot see, run
  targeted (see build-and-test.md).

## Comments & commits

- Comment only non-obvious intent (the repo does carry explanatory comments,
  e.g. WindowCloseInterceptor rationale). No narration comments.
- Commit messages: short imperative summary ("Add Next sidebar card that
  decides what to do next", "Remove GitHub code-host support; GitLab only").
- Never commit unless asked; keep changes bounded to the task's surface.
