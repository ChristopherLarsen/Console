# Console Home Panel 1 — JIRA My Tickets

## Summary

Build the top-left Home quadrant for Console as a native **My Tickets** panel backed by a real, authenticated JIRA list running in the existing WebKit `WebPage`. The JIRA page must fill the quadrant and remain available for normal browser interaction, while an opaque native SwiftUI card layer presents the ticket list above it. Ticket data is read locally from the DOM that JIRA has already rendered. Do not add JIRA REST calls, cookie extraction, injected `fetch`/XHR requests, AI summarization, user-agent spoofing, or persistent storage of company ticket content.

This work must be completed and verified on the company machine where Christopher can sign into the real JIRA instance. Christopher enters all credentials and completes MFA himself. The implementing model must never request, capture, print, commit, or transmit credentials, cookies, raw DOM, ticket descriptions, or meaningful company data.

## Outcome

When Console opens Home, the top-left quadrant shows Christopher's JIRA tickets as compact native cards in the same order as the configured JIRA **My Tickets** list. He can:

- Reveal the real JIRA page without losing its authentication or navigation state.
- Return to card mode immediately.
- Manually reload the JIRA page and regenerate the cards.
- Click a card to reveal and open that issue in the same JIRA session.
- Distinguish a legitimate empty list from authentication failure or an extraction failure.

The panel must not implement agent launching yet. A later Home panel will connect tickets to agent sessions.

## Current Application Context

Read these files before changing anything:

- `Console/Console/Views/MainView.swift`
  - Home currently renders a placeholder.
  - The center area shares vertical space with a persistent bottom terminal panel.
- `Console/Console/Jira/Views/JiraView.swift`
  - `JiraWebSession.shared` already owns a process-scoped `WebPage`.
  - `JiraView` already loads the URL stored in `webViewJiraURL` and provides browser controls.
  - The process-scoped page preserves live state while navigating between Console destinations.
- `Console/Console/Settings/Views/SettingsView.swift`
  - The user already configures `Web View JIRA URL`.
- `Console/Console/App/AppSettings.swift`
  - Contains the same JIRA URL preference.
- `Console/Console/App/SidebarSelection.swift`
- `Console/Console/Sidebar/Views/SidebarView.swift`

The project targets macOS 26 and already uses the new SwiftUI WebKit `WebPage` and `WebView` APIs. The Xcode project uses filesystem-synchronized groups, so new Swift files under `Console/Console` and test files under `Console/ConsoleTests` are picked up automatically.

## Non-Negotiable Security Boundaries

The company laptop and its network are monitored. The implementation must be straightforward and defensible under review.

### Allowed

- Normal WebKit navigation to the user-configured JIRA page.
- JIRA's normal page resources, authentication redirects, and page-originated traffic.
- `WebPage.callJavaScript` used only to inspect the DOM already rendered in the page.
- A persistent WebKit website data store so JIRA can maintain a normal signed-in browser session.
- In-memory Swift models containing the minimum fields needed for visible cards.
- Synthetic test fixtures containing invented ticket data.

### Forbidden

- Do not read, export, copy, replay, or log WebKit cookies.
- Do not use `URLSession`, `curl`, a shell command, or another client to call JIRA.
- Do not inject `fetch`, `XMLHttpRequest`, GraphQL calls, REST calls, or hidden navigations to API endpoints.
- Do not use undocumented JIRA endpoints.
- Do not set `customUserAgent` or imitate Safari's user agent.
- Do not send JIRA content to Claude, another LLM, an MCP server, analytics, crash reporting, or any external service.
- Do not save ticket content in SwiftData, UserDefaults, files, debug snapshots, or logs.
- Do not commit a real DOM snapshot, screenshot, JIRA URL, issue key, project name, ticket title, employee name, or other company information.
- Do not automatically scroll, page through results, or continuously reload JIRA.
- Do not describe the WebView traffic as identical to Safari. It is normal WebKit traffic but is distinguishable as an embedded browser.

If reliable cards cannot be produced inside these constraints, leave the real JIRA page usable and report the limitation. Do not silently broaden the data-access approach.

## Use Cases

### Normal launch

1. Console opens on Home.
2. The existing persistent JIRA page loads the configured My Tickets list.
3. After the list is actually present in the DOM, Console reads its visible rows locally.
4. The JIRA quadrant displays native cards in JIRA's current order.

### First authentication or expired session

1. Console detects that the JIRA list is not available and that the page is showing authentication or an external SSO step.
2. Card mode yields to the visible WebView.
3. Christopher signs in and completes MFA himself.
4. When JIRA returns to the My Tickets list and its rows become available, Console extracts them and offers card mode.

### Reveal JIRA

1. Christopher chooses **Show JIRA** from the panel header.
2. The opaque card overlay is removed.
3. The same live WebPage becomes interactive; no new browser session is created.
4. Christopher chooses **Show Cards** to restore the overlay.

### Refresh

1. Christopher chooses Refresh.
2. Console performs the same ordinary page reload already supported by `JiraView`.
3. Existing cards remain visible with a refreshing indication until extraction succeeds.
4. New cards replace the old cards atomically.
5. If refresh or extraction fails, retain the prior cards and show that they are stale.

### Open an issue

1. Christopher selects a native card.
2. Console reveals the underlying WebView.
3. The shared WebPage navigates to the absolute JIRA issue URL captured from that row.
4. Back navigation can return to the My Tickets list.

## Proposed Architecture

Keep one JIRA `WebPage`. Do not create one WebView per card or independent authenticated sessions.

Suggested file organization:

```text
Console/Console/Home/Views/HomeView.swift
Console/Console/Home/Views/HomePanelContainer.swift
Console/Console/Jira/Models/JiraTicketSummary.swift
Console/Console/Jira/Services/JiraListExtractor.swift
Console/Console/Jira/Services/JiraPanelController.swift
Console/Console/Jira/Views/JiraPanelView.swift
Console/Console/Jira/Views/JiraView.swift                  (refactor existing)
Console/ConsoleTests/JiraListExtractorTests.swift
Console/ConsoleTests/JiraPanelControllerTests.swift
```

Names may be adjusted to match the codebase, but preserve separation between:

- Web session ownership.
- DOM extraction.
- Panel state and refresh orchestration.
- Native panel presentation.

### Shared web session

Extend or refactor `JiraWebSession.shared` so it remains the sole owner of the live `WebPage`. Both the Home panel and the full JIRA sidebar destination must use that same page. These destinations are mutually exclusive in `MainView`, so the same page can move between their `WebView` presentations without creating two browser sessions.

The shared session may also own or retain the panel controller, but do not create a cycle. It should be possible to navigate away from JIRA and back without losing authentication, the loaded page, cards, or the last successful extraction.

Continue using WebKit's default persistent website data store for the browser session. Do not inspect that data store.

### Ticket model

Use a small, non-persistent value type. A suggested shape is:

```swift
struct JiraTicketSummary: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let priority: String?
    let updatedText: String?
    let issueURL: URL
    let sourceOrder: Int

    var id: String { key }
}
```

Only keep fields that are actually shown. Do not add descriptions, comments, reporters, attachments, or hidden custom fields. Preserve source order exactly.

### Panel state

Model the states explicitly so a selector failure never becomes a false empty state. A suggested state machine is:

```swift
enum JiraPanelState: Equatable {
    case unconfigured
    case loadingPage
    case authenticationRequired
    case extracting
    case loaded(tickets: [JiraTicketSummary], refreshedAt: Date)
    case empty(refreshedAt: Date)
    case stale(tickets: [JiraTicketSummary], refreshedAt: Date, reason: String)
    case unsupportedPage
    case extractionFailed
}
```

Do not put ticket text in errors or state descriptions that could be logged.

### DOM extractor

`JiraListExtractor` should execute one local JavaScript function through `WebPage.callJavaScript`. Have JavaScript return a JSON string and decode it with `JSONDecoder`; do not pass a large untyped graph of JavaScript objects around Swift.

The extractor must:

1. Confirm that the current document represents the expected JIRA list, even if it contains zero rows.
2. Discover the list's semantic column headers.
3. Find issue anchors using their URL shape rather than generated CSS class names.
4. Associate each issue anchor with its nearest semantic row (`tr`, `role=row`, or a verified stable JIRA test attribute).
5. Map cells to the discovered headers so custom column ordering does not scramble status, priority, or updated values.
6. Extract the issue key, summary, optional display fields, and issue URL.
7. Deduplicate by issue key while preserving DOM order.
8. Return a distinct result for:
   - list found with rows,
   - list found and legitimately empty,
   - authentication page,
   - unsupported/not-a-list page,
   - malformed extraction.

Prefer, in order:

1. Semantic HTML and accessibility roles.
2. Stable `data-testid` or other verified JIRA attributes.
3. Issue URL patterns such as `/browse/PROJECT-123`.

Avoid generated CSS class names, positional selectors with unexplained indices, English-only assumptions where reasonable, and traversal based only on the current visual layout.

Do not automatically scroll the WebView to force virtualized rows to load. Extract only the rows JIRA normally makes available for the configured list page.

### Readiness

Main-frame navigation completion does not prove that a client-rendered JIRA list is ready. Do not use one arbitrary multi-second sleep.

Use a bounded readiness strategy, for example:

- Observe WebPage navigation/loading state.
- After the navigation finishes, run a lightweight local readiness check for the list container or authentication UI.
- Retry locally with short delays for a bounded period.
- Stop immediately on success, authentication detection, cancellation, navigation change, or timeout.

These readiness checks must inspect DOM only and must not initiate network requests.

Cancel an in-flight extraction when the page starts another navigation or the configured URL changes. Ensure stale extraction results cannot replace results from a newer page.

### Panel controller

`JiraPanelController` should be `@MainActor` and observable. It coordinates:

- Current panel state.
- Whether cards or the raw page are visible.
- Navigation/readiness observation.
- Manual page reload.
- Extraction cancellation and generation tracking.
- Retention of the last successful cards during refresh failures.
- Card selection and issue navigation.

Do not add a background timer in this phase. Initial extraction after a normal user-configured page load and explicit manual refresh are sufficient.

### SwiftUI panel

Use a `ZStack`:

1. The real `WebView(sharedPage)` fills the entire panel.
2. An opaque native SwiftUI surface sits above it in card mode.

While the card surface is shown:

- Disable hit testing for the underlying WebView.
- Hide the underlying page from accessibility so VoiceOver does not encounter two simultaneous interfaces.
- Keep the WebView attached; do not create a screenshot imitation.

While the raw page is shown:

- The WebView is interactive and accessible.
- Provide a clear **Show Cards** action when extraction has succeeded.
- Preserve ordinary back, forward, and reload behavior, either through shared controls or a compact panel variant.

Suggested card-mode header:

```text
My Tickets · <count>                         Refresh  Show JIRA
```

Suggested compact card content:

```text
PROJECT-123   Ticket summary                         In Progress
              High · updated 38m ago
```

Show key, summary, status, priority, and last-updated text when those columns are available. Missing optional fields must not prevent a card from appearing. Preserve the JIRA list order rather than applying a second Console sort.

Do not add a nonfunctional Start Agent button in this phase. Leave enough card layout room for a future action supplied by the Agent panel.

### Home integration

Replace the Home placeholder in `MainView.centerContent` with a `HomeView`.

The target Home layout is a two-by-two workflow grid:

```text
JIRA My Tickets        Agent Sessions
Reviews Requested      My Merge Requests
```

This assignment owns only the top-left JIRA panel. Do not implement agent or GitLab behavior. If their panels do not yet exist, use visually quiet placeholders or structure the grid so future panels can be inserted without rewriting JIRA.

Account for the bottom terminal reducing Home's available height. The grid must remain usable at the app's declared minimum window size. Prefer a vertically scrollable Home canvas with sensible panel minimum heights over compressing ticket rows until they are unreadable.

## One-Time Discovery on the Authenticated Machine

The exact DOM shape cannot be known reliably from the current repository. Perform a one-time local discovery against the real My Tickets list.

### Procedure

1. Build and launch Console on the company machine.
2. Christopher configures the exact stable My Tickets list URL in Settings.
3. Christopher opens JIRA inside Console and signs in himself.
4. Confirm the visible page is the list, not a board.
5. Run a DEBUG-only structural probe through `WebPage.callJavaScript`.
6. Inspect only the structural result needed to choose selectors.
7. Implement the production extractor.
8. Replace the real structure with synthetic fake HTML in committed tests.
9. Remove the temporary probe or keep it DEBUG-only with strict redaction and no automatic logging.

### Probe redaction rules

The structural probe may report:

- Element tag names.
- Accessibility roles.
- Attribute names.
- Presence and shape of stable test identifiers.
- Column-header labels if necessary to map fields.
- Masked URL patterns such as `/browse/<KEY>`.
- Counts of rows and cells.

It must not report:

- `document.documentElement.outerHTML` or large DOM fragments.
- Text content from ticket rows.
- Actual issue keys, project names, summaries, people, labels, or URLs.
- Cookies, local storage, session storage, request headers, or tokens.

Do not paste raw inspector output into a remote chat. If direct local visual inspection is necessary, perform it locally and record only the generalized selector decisions in code comments or this document.

## User Experience

### Card mode

- Card mode is the default only after a successful extraction.
- The panel clearly identifies itself as JIRA My Tickets.
- Show the ticket count and a local last-refreshed time.
- Clicking a row opens the ticket in the same JIRA WebView.
- Refresh is explicit and visible.
- Cards remain readable and keyboard navigable.

### Browser mode

- Browser mode appears automatically for configuration, authentication, and unsupported pages.
- The user can reveal it at any time.
- Do not place an opaque card overlay over login or MFA flows.
- The session and back-forward history survive switching between Home and the full JIRA destination.

### Failure and empty states

- **No configured URL:** explain that the JIRA My Tickets URL must be set in Settings and provide a Settings action.
- **Authentication required:** show/reveal the actual WebView.
- **Loading:** show progress without discarding prior cards.
- **Legitimately empty list:** show a positive “No open tickets” state only after the list container was positively identified.
- **Unsupported page:** offer **Show JIRA** and explain that Console needs the configured list view.
- **Extraction failure:** retain stale cards if available; otherwise expose the usable WebView. Never present failure as zero tickets.

## Alternatives Considered

### Official JIRA REST/OAuth integration

Structured API data would be more stable than DOM extraction, but this phase intentionally avoids introducing a custom JIRA client, API credentials, scopes, or additional request patterns on a monitored company laptop. It can be reconsidered only with explicit company approval.

### REST calls made inside the authenticated WebView

Rejected for this phase. Same-origin JavaScript could reuse the browser session, but it would add hidden programmatic requests. The chosen design reads only what the real page has already rendered.

### Cookie transfer to URLSession

Rejected. This would expose session material to application code and create a separate client path.

### Claude Code or an Atlassian MCP connector

Rejected for routine ticket retrieval because of latency, cost, and the unnecessary movement of company data through an AI path. AI is not needed to display deterministic ticket fields.

### Screenshot/OCR extraction

Rejected as brittle, inaccessible, and unnecessarily likely to capture sensitive content.

### Web page only, with no cards

This remains the fallback when extraction is unsupported. The native cards are valuable, but keeping JIRA usable is more important than forcing an unreliable parser.

## Edge Cases

- JIRA Cloud versus Data Center markup differences.
- Company-specific JIRA themes, plugins, or custom fields.
- SSO hosted on a different domain.
- MFA or conditional-access pages.
- A list whose columns are reordered or renamed.
- A list with missing priority or updated columns.
- Client-side rendering that completes after main navigation.
- Virtualized rows that are not present in the DOM.
- Pagination or a result count larger than the rendered page.
- Duplicate issue links within one row.
- Links that open in a new window.
- Session expiration while stale cards are visible.
- Navigation away from the My Tickets list.
- URL preference changes while extraction is running.
- App backgrounding or window closure during extraction.
- Terminal expansion leaving very little vertical space for Home.
- JIRA markup changing after an Atlassian release.

Handle these conservatively. Do not guess at data that was not found.

## Side Effects and Data Handling

- A live JIRA page can continue making the same page-originated polling, analytics, and resource requests it would make in an open browser tab. Do not add Console polling on top.
- WebKit's persistent data store will retain normal browser-site data for authentication. Ticket card models themselves remain memory-only.
- Do not include ticket values in `print`, `printDebug`, assertions, crash messages, accessibility identifiers, or analytics.
- Accessibility labels shown to the user may contain the same minimal text visibly present in the card, but must not be logged.
- Ensure card mode disables accessibility exposure of the covered WebView.

## Testing Strategy

### Unit tests with synthetic data

Commit only invented fixture content such as `DEMO-101` and generic summaries.

Test:

- Correct extraction of key, summary, status, priority, updated text, and URL.
- Preservation of DOM order.
- Header-to-cell mapping when columns are reordered.
- Missing optional columns.
- Duplicate links and deduplication.
- Legitimate empty list detection.
- Authentication-page detection.
- Unsupported-page detection.
- Malformed JavaScript/JSON handling.
- Cancellation or generation checks preventing stale results from winning.

Where practical, load synthetic HTML into a nonpersistent `WebPage` and run the actual JavaScript extractor. Keep pure decoding and state-transition logic separately unit-testable.

### UI and integration tests

Use a synthetic local page or injected fake extractor. Do not automate against the company JIRA service in the test suite.

Verify:

- Home places JIRA in the top-left quadrant.
- Card/browser toggling preserves one page/session.
- Card mode blocks WebView hit testing and duplicate accessibility.
- Refresh state retains previous cards.
- Empty, authentication, unsupported, and stale states are distinct.
- Keyboard navigation and VoiceOver order are sensible.
- The layout remains usable with the terminal expanded and at minimum window size.

### Manual verification on the company machine

Christopher must perform login and MFA. Verify without recording sensitive screenshots or logs:

1. The configured My Tickets list loads normally.
2. Extracted card count matches the rows JIRA has rendered.
3. Cards preserve JIRA order.
4. Visible fields match their rows.
5. Show JIRA reveals the same live page.
6. Show Cards returns immediately.
7. Refresh updates cards after an ordinary page reload.
8. Selecting a card opens the correct issue.
9. Expired authentication reveals the login flow.
10. A selector failure does not show “No open tickets.”
11. No ticket data appears in Console logs or newly created repository files.

## Acceptance Criteria

The work is complete only when all of the following are true:

- Home renders a two-column/two-row-capable layout with JIRA in the top-left.
- The real configured JIRA WebView fills the JIRA panel beneath the card surface.
- One shared persistent `WebPage` is used by Home and the full JIRA destination.
- Christopher can authenticate normally inside Console.
- Native cards are generated from the rendered My Tickets list without new programmatic network requests.
- Cards preserve JIRA order and show the agreed minimum fields.
- Browser/card toggling and manual refresh work.
- Authentication, empty, unsupported, stale, and failure states are not conflated.
- Real ticket data is neither logged nor persisted by Console.
- No cookie access, API integration, injected network request, AI call, or user-agent spoofing has been added.
- Synthetic tests cover extraction and state handling.
- The app builds successfully and existing JIRA, terminal, sidebar, command, trigger, provider, and settings behavior remains intact.

## Open Questions to Resolve on the Company Machine

Do not ask for credentials or confidential examples. Resolve these through local structural inspection and direct user confirmation:

1. Is the company instance JIRA Cloud or JIRA Data Center?
2. What exact stable URL opens the My Tickets list?
3. Which semantic roles or stable JIRA attributes identify the list, headers, rows, and fields?
4. Does the list render all relevant rows or virtualize/paginate them?
5. Are the visible columns exactly key, summary, status, priority, and updated, or should sprint/story points replace updated?
6. Which SSO domains appear during authentication, and does the existing WebView handle them without navigation-policy changes?
7. Does moving the shared `WebPage` between Home and the full JIRA view preserve expected scroll and navigation state?

## Implementation Discipline

- Inspect the current branch and preserve unrelated user changes.
- Keep the change bounded to Panel 1 and the minimum Home scaffolding it needs.
- Prefer small components and testable state transitions over one large SwiftUI view.
- Do not weaken security boundaries to make the demo look complete.
- Build and run the macOS app after implementation.
- Run focused JIRA tests, then the relevant existing test suite.
- Review the final diff for company data, URLs, debug output, raw DOM, secrets, or snapshots before handing the work back.

## Card Design Specification

### Design goal

Each card should answer two questions in roughly one second:

1. **What is the ticket?**
2. **Is it the next ticket that needs my attention?**

The card is a compact launcher into the real JIRA issue, not a replacement for the issue page. Optimize for scanning several assigned tickets in a constrained Home quadrant. Do not add fields merely because they exist in JIRA.

### Minimum information hierarchy

Show the following, in this order of importance:

1. **Summary** — the primary text, using at most two lines. This is what the developer recognizes and chooses from.
2. **Issue key** — a short, stable identifier such as the synthetic `DEMO-101`; show it above or immediately before the summary in a visually quieter monospaced or caption style.
3. **Status** — a compact text badge using the exact rendered JIRA status. This distinguishes work that is ready, active, blocked, or awaiting another workflow step without requiring the issue page.
4. **Priority** — optional and visually subordinate. Show it only when the rendered list supplies a usable value. Never infer priority from card order, status, title, labels, or color.
5. **Updated text** — optional, trailing metadata when the rendered list supplies it and space permits. It is a staleness cue, not an exact Console-computed age.

The issue key and summary are required for a valid card. Status, priority, and updated text are progressive enhancements: their absence must collapse cleanly rather than leave empty badge spaces.

### Recommended compact card

Target a normal height of approximately 72–84 points so several tickets remain visible without reducing the summary to one ambiguous line.

```text
┌─────────────────────────────────────────────────────┐
│ DEMO-101                              High priority │
│ Fix background refresh after sign-in                │
│ In Progress                              Updated 2h │
└─────────────────────────────────────────────────────┘
```

Layout rules:

- Use a full-width native button/card with a modest corner radius and restrained border or material contrast.
- Top metadata row: issue key leading; priority trailing when present.
- Middle row: summary, leading aligned, medium emphasis, maximum two lines.
- Bottom metadata row: status leading; updated text trailing when present.
- Keep all metadata secondary to the summary. A badge must not become the largest or brightest element in the card.
- At narrow widths, preserve the issue key, summary, and status. Drop updated text first, then move priority beside status or omit its presentation. Do not horizontally scroll a card.
- Truncate an unusually long summary after two lines. The full summary remains available on the JIRA page opened by the card; do not add a tooltip that creates a second dense reading surface.

If priority is absent, the top row contains only the issue key. If both priority and updated text are absent, retain the same basic alignment but allow the card to become slightly shorter. Avoid placeholder dashes and labels such as `Priority: Unknown`.

### Visual prioritization and ordering

JIRA's rendered list order is authoritative and must be preserved. Console must not silently sort by priority, status, issue key, or update time. This matters because the configured list may already use a team-specific JQL ordering that cannot be reconstructed from the extracted fields.

Use visual cues without changing order:

- Always render the status as text. Color may reinforce it, but color must never carry the meaning alone.
- Prefer a neutral status treatment unless the exact status is recognized by a small, explicit local mapping. Unknown or custom statuses remain neutral and keep their original text.
- Priority should be text-first. A recognized highest/high value may receive a stronger semantic tint; normal, low, custom, or unknown values should remain subdued. Do not copy remote priority icons or depend on image URLs.
- Do not label a ticket **blocked**, **overdue**, or **stale** unless that exact meaning is present in a rendered field. Console has too little context to infer those states safely.

The panel header may show the number of cards currently extracted, but it must not imply that this is JIRA's complete total when pagination or virtualization is present. Prefer `My Tickets · 7 shown` when completeness has not been established locally.

### Card interaction

The entire card is one action. Clicking it, pressing Return, or pressing Space should:

1. Select the ticket.
2. Reveal the same persistent JIRA WebView.
3. Navigate that WebView to the captured issue URL.
4. Move keyboard focus into the revealed JIRA surface or its compact browser controls.

Provide clear hover, pressed, and keyboard-focus treatments. Do not put small competing controls inside the card. Refresh, **Show JIRA**, and future panel-level actions belong in the panel header. Do not add Start Agent, copy-key, overflow, assignment, transition, or comment controls in this phase.

Opening should remain an explicit user action. Do not prefetch the issue, open a hidden page, or generate a preview on hover. If the captured issue URL is invalid or no longer allowed by the navigation policy, keep the card list visible and present a generic local error without including the ticket summary in logs.

### Panel scanning behavior

- Present cards in one vertical list with consistent spacing; do not use a miniature board, columns by status, or a dense table.
- Scroll only the native card list. Keep the panel header and its Refresh / Show JIRA actions fixed when practical.
- Preserve the current scroll position across an ordinary refresh when the same issue keys remain.
- After refresh, replace the collection atomically to avoid cards visibly changing order one by one.
- Do not select or open the first ticket automatically.
- Avoid animations that reorder or fan cards; a subtle content transition is sufficient and should respect Reduce Motion.

### Loading, stale, empty, and failure presentation

- **Initial loading with no prior cards:** show a small number of generic skeleton rows with no ticket-shaped fake text. Do not expose or snapshot the covered WebView.
- **Refreshing with cards:** retain the current cards, disable repeated refresh if necessary, and show a quiet progress indicator in the header. Cards remain usable unless navigation makes their URLs invalid.
- **Stale cards:** retain cards after a refresh/extraction failure and show one panel-level `Could not refresh · showing previous results` message. Do not repeat the warning on every card.
- **Authenticated empty list:** replace the list with a compact positive state such as `No open tickets` only after the extractor positively identified the expected empty list.
- **Authentication required:** reveal the real WebView. Never render stale cards over login, SSO, MFA, or conditional-access UI.
- **Unsupported page or extraction failure with no cards:** provide `Show JIRA`; do not show an empty list or fabricate card fields.
- **Ticket removed during refresh:** remove it with the atomic collection update. Do not retain a ghost card merely because it was previously visible.

### Accessibility

- Implement each card as a native SwiftUI button with a visible keyboard focus ring and a minimum comfortable pointer target.
- Expose one concise accessibility element per card rather than making each badge a separate stop. Read the visible values in this order: issue key, summary, status, priority, updated text.
- Give the card an accessibility action such as `Open in JIRA` while retaining the ticket-specific visible label. The same minimal visible company content may be spoken by VoiceOver but must never be copied into analytics, debug logs, or accessibility identifiers.
- Use generic, stable accessibility identifiers such as a card index or non-content test seam in synthetic tests. Do not embed a real issue key or summary in an identifier.
- Status and priority must remain understandable in monochrome, Increase Contrast, and color-vision-deficiency modes.
- Support larger accessibility text sizes by allowing the card to grow vertically. Do not clip the summary or overlap trailing metadata.
- Respect Reduce Motion and do not use pulsing status indicators.

### Deliberately omitted information

Do not surface the following on the Home card:

- Description, acceptance criteria, comments, or latest comment.
- Reporter, assignee, watchers, or employee avatars; every card is already from **My Tickets**.
- Labels, components, fix versions, sprint, epic, story points, or subtasks.
- Attachments, build state, branch name, commit state, or linked merge requests.
- Created date, exact timestamp, due date, or time tracking unless the product is later redesigned around one of those workflows.
- Project name separate from the issue key.
- AI summaries, inferred next actions, inferred urgency, or sentiment.
- Remote images or icons copied from JIRA.

These omissions reduce visual noise and, more importantly, keep DOM inspection and in-memory company data to the minimum necessary for the launcher. The full issue remains one click away in the authenticated WebView.

### Build-ready acceptance checks for the card

- With only key and summary available, a valid, well-aligned card still renders and opens correctly.
- With every optional field available, the card fits the quadrant without horizontal scrolling or metadata dominating the summary.
- Long synthetic summaries wrap to two lines at normal text size and cards grow safely at accessibility sizes.
- Custom status and priority strings render verbatim with a neutral treatment rather than disappearing or receiving an invented meaning.
- The visual list order exactly matches the extractor's source order.
- Keyboard navigation reaches each card once, and Return and Space perform the same navigation as a click.
- VoiceOver announces one coherent card label and an `Open in JIRA` action.
- Loading, stale, legitimate empty, authentication, unsupported, and extraction-failure states remain visibly distinct.
- No omitted field is newly extracted merely for future use, and no card content is persisted or logged.
