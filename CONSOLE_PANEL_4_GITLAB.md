# Console Home Panel 4 — GitLab My Merge Requests

## Summary

Build the bottom-right Home quadrant for Console as a native **My MRs** panel backed by Christopher's real, authenticated GitLab authored-merge-request list running in WebKit. A live GitLab `WebView` fills the panel while an opaque SwiftUI card layer presents the rendered merge requests above it. Read only the DOM GitLab has already produced. Do not add GitLab REST/GraphQL calls, cookie extraction, injected network requests, AI summarization, user-agent spoofing, automatic pagination, or persistent storage of company merge-request data.

## Development Target

Build and verify this panel against **Christopher's personal gitlab.com account**, not the company machine. The GitLab fixtures still need creating — see *Prerequisites Before Kickoff*.

Almost all of this assignment is buildable on any machine: the shared two-page session store, the state machine, extraction, card layout, Home integration, and every synthetic test.

What the personal account does **not** settle is selectors. gitlab.com runs the current SaaS release; a self-managed company GitLab may be several releases behind, with different markup, feature flags, and themes. Selector work therefore has two phases — see *DOM Discovery* below.

Panel 4 has one advantage over Panel 3 here: an authored-MR list is easy to populate on a personal account, because Christopher opens the MRs himself. No second account or collaborator is required. If Panel 3's review-queue fixtures prove impractical, Panel 4 remains fully exercisable and is the better place to establish the shared foundation.

When the panel is eventually pointed at the company instance, Christopher signs in and completes MFA himself. The implementing model must never request, capture, print, commit, or transmit company credentials, cookies, raw DOM, project paths, MR titles, branches, reviewers, or other company information.

## Prerequisites Before Kickoff

1. **Create the GitLab fixtures.** Synthetic projects under Christopher's personal namespace with authored MRs covering: draft and non-draft; pipeline failed, running, passed, and absent; changes-requested and approved review states; the **same MR IID in two different projects**; a very long title; a title-only MR with every optional field absent. Pipeline states require a `.gitlab-ci.yml` that can be made to pass and fail deliberately. Document the result in `CONSOLE_GITLAB_FIXTURES.md`, mirroring `CONSOLE_JIRA_FIXTURES.md`.
2. **A clean working tree.** The Sessions and terminal-bridge work is in flight and untracked; Sessions is the top-right Home quadrant and touches the same `HomeView`/`HomePanelContainer` files. Land or stash it first.
3. **A green test baseline.** As of this writing the baseline is red: `ConsoleTests` is flaky (`EndToEndIntegrationTests.testFieldDictation_ActivatesAndReleasesCleanly()`) and `ConsoleUITests` fails 6 of 32 deterministically.
4. **Verify the two-page session assumption.** Confirm that two retained `WebPage` instances sharing one persistent `WKWebsiteDataStore` really do share a gitlab.com login while keeping independent navigation histories. Both GitLab plans depend on it, and it is testable today. If it does not hold, both need rework before either starts.

Panel numbering follows the agreed workflow:

```text
Panel 1: JIRA My Tickets       Panel 2: Agent Sessions
Panel 3: MRs to Review         Panel 4: My MRs
```

## Outcome

The bottom-right Home quadrant shows Christopher's open authored merge requests as native cards in GitLab's current order. The panel helps him see what is still moving toward delivery without using AI or a second API client. Christopher can:

- Reveal the real GitLab authored-MR page without losing its browser state.
- Return to native card mode.
- Manually reload the list and regenerate cards.
- Open any MR in the same authenticated WebKit session.
- See only delivery signals visibly present in the GitLab list, such as draft, pipeline, review, or updated state.
- Distinguish no open MRs from authentication and extraction failure.

Do not add merge, rebase, retry-pipeline, checkout, comment, or agent actions in this phase. A later workflow can connect a JIRA ticket, agent session, branch, and authored MR.

## Current Application Context

Read before editing:

- `CONSOLE_PANEL_1_JIRA.md`
  - Defines the authenticated-WebView/native-card pattern and security posture.
- `CONSOLE_PANEL_3_GITLAB.md`
  - Defines the sibling review panel and shared GitLab session foundation.
- `Console/Console/Views/MainView.swift`
- `Console/Console/Home/Views/HomeView.swift` — **already exists** (commit `fd92eb4`)
  - Defines the `HomePanel` enum (`jiraTickets`, `sessions`, `gitLabReviews`, `gitLabAuthored`), the four-quadrant grid, titles, service labels, and accessibility identifiers.
  - `HomePanelGitLabMyMRs` is the established accessibility identifier for this panel, and its title is already `My MRs` with service label `GitLab`. Reuse both.
  - Layout constants live in a private `Layout` enum: 12pt edge padding and grid spacing, 160pt minimum panel width and height.
- `Console/Console/Home/Views/HomePanelContainer.swift` — **already exists**
- `Console/Console/Home/Views/HomePanelPlaceholder.swift` — **already exists**; replace it in the bottom-right quadrant only.
- `Console/Console/MergeRequests/Views/MergeRequestsView.swift`
  - Currently has one generic `MergeRequestsWebSession.shared.page` and one URL.
- `Console/Console/Settings/Views/SettingsView.swift`
- `Console/Console/App/AppSettings.swift`
- `Console/Console/App/SidebarSelection.swift`
- `Console/Console/Sidebar/Views/SidebarView.swift`

The project targets macOS 26 and uses SwiftUI WebKit `WebPage`/`WebView`. Source and test folders are filesystem-synchronized Xcode groups.

`ConsoleApp.swift` declares `.defaultSize(width: 1100, height: 700)` and **no `.defaultMinSize`**. There is no declared minimum window size to design or test against; either add one or verify against the 160pt panel minimums in `HomeView.Layout`.

Panel 1 (JIRA, top-left) and Panel 2 (Sessions, top-right) are both in progress. Coordinate on shared Home files rather than rewriting them.

## Shared GitLab Foundation and Coordination Contract

Panel 3 and Panel 4 appear simultaneously. They require two retained pages with independent URLs and navigation histories, but both pages must share one persistent WebKit website data store for the normal GitLab login session.

Search the current branch before creating shared types. If Panel 3 already introduced a `GitLabWebSessionStore`, common model, extractor, controller, card component, or browser component, reuse and extend those types. Do not create a second singleton or a competing data store.

The shared foundation must be equivalent to:

```swift
enum GitLabListKind: String, CaseIterable, Sendable {
    case reviewsRequested
    case authored
}

@MainActor
final class GitLabWebSessionStore {
    static let shared = GitLabWebSessionStore()

    let reviewsPage: WebPage
    let authoredPage: WebPage
}
```

If Panel 4 is implemented first, establish this complete two-page foundation so Panel 3 can adopt it without migration. Use one explicit shared persistent `WKWebsiteDataStore`; never inspect or copy its cookies.

The existing full **Merge Requests** sidebar destination should remain usable and eventually switch between the two shared pages with a **To Review / My MRs** selector. Panel 4 must not collapse both lists into one navigation history.

## Configuration

Use the same two settings keys defined for Panel 3:

- `webViewGitLabReviewsURL`
- `webViewGitLabMyMergeRequestsURL`

Panel 4 owns the authored URL. The configured value must be the exact stable list URL Christopher normally uses to view his open merge requests. Do not synthesize query parameters or use an API to discover it.

Preserve the legacy `webViewMergeRequestsURL` preference. If migration is needed, keep it conservative and user-visible; never log private GitLab URLs or silently overwrite the two new values.

## Non-Negotiable Security Boundaries

Two different kinds of constraint apply, and conflating them causes needless friction during development.

**Implementation constraints** define the product and never relax. Console must not acquire a REST or GraphQL client, cookie access, injected requests, a spoofed user agent, an AI data path, or MR persistence — regardless of which GitLab it is pointed at. These hold while developing against gitlab.com, because the shipped app will be pointed at the company instance.

**Company-data constraints** govern handling of company content specifically. They apply in full whenever Console is pointed at the company GitLab. They do **not** apply to synthetic fixtures in Christopher's personal namespace: that content is invented, so it may be freely read, screenshotted, discussed, and committed to tests.

### Allowed

- Ordinary WebKit navigation to the configured GitLab authored-MR list.
- Normal GitLab page resources, authentication redirects, SSO/MFA, and page-originated traffic.
- `WebPage.callJavaScript` used only to read the rendered DOM.
- Two retained pages sharing one persistent WebKit website data store.
- Minimal in-memory card models.
- Synthetic fake GitLab data in tests.

### Forbidden

- No cookie, token, storage, header, or credential access.
- No REST or GraphQL integration.
- No `URLSession`, `curl`, `glab`, shell process, or other data client.
- No injected `fetch`, `XMLHttpRequest`, GraphQL, REST, or hidden endpoint navigation.
- No custom/spoofed Safari user agent.
- No Claude, LLM, MCP, analytics, crash reporting, or external transmission of **company** GitLab data. (Company-data constraint; synthetic fixtures are exempt.)
- No persistence of MR data in SwiftData, UserDefaults, files, snapshots, or logs. Committed test fixtures must be synthetic — which the personal-namespace fixtures are.
- No automatic scrolling, pagination, polling, or continuous refresh.
- No merge, rebase, pipeline, comment, checkout, or branch mutations.

The raw authenticated GitLab page is the required fallback if extraction cannot be reliable within these constraints.

## Use Cases

### Normal launch

1. Home opens and the shared authored page loads the configured My MRs list.
2. Console waits until the list is locally present in the DOM.
3. It extracts the rendered rows and presents cards in GitLab order.

### Authentication

1. If GitLab or SSO requires authentication, reveal a GitLab WebView.
2. Christopher signs in and completes MFA himself.
3. The shared website data store supplies the resulting normal browser session to both GitLab pages.
4. Once the authored list renders, enable card mode.

### Reveal and return

- **Show GitLab** exposes the real authored page.
- **Show Cards** restores the opaque native surface when a successful extraction exists.
- Do not create another page or reload merely to toggle presentation.

### Manual refresh

1. Christopher chooses Refresh.
2. Reload the ordinary configured authored-MR list URL.
3. Retain old cards during load/extraction.
4. Atomically replace them after success, or mark them stale after failure.

### Open an MR

1. Christopher selects a native card.
2. Reveal the authored WebView and navigate to the captured MR URL.
3. Back navigation returns to the authored list, or Refresh explicitly reloads the configured list.

## Proposed Architecture

Panel 4 should reuse the shared files created for Panel 3. Add only authored-panel-specific presentation or behavior where the actual UX differs.

Expected shared organization:

```text
Console/Console/GitLab/Models/GitLabMergeRequestSummary.swift
Console/Console/GitLab/Services/GitLabWebSessionStore.swift
Console/Console/GitLab/Services/GitLabMergeRequestListExtractor.swift
Console/Console/GitLab/Services/GitLabListPanelController.swift
Console/Console/GitLab/Views/GitLabMergeRequestCardView.swift
Console/Console/GitLab/Views/GitLabMergeRequestsBrowserView.swift
Console/Console/GitLab/Views/GitLabMyMergeRequestsPanelView.swift
Console/Console/Home/Views/HomeView.swift                              (exists — extend)
Console/ConsoleTests/GitLabMergeRequestListExtractorTests.swift
Console/ConsoleTests/GitLabListPanelControllerTests.swift
```

### Merge-request model

Reuse the common memory-only `GitLabMergeRequestSummary`. MR IID is only project-local, so use the normalized MR URL or project-path/IID composite for identity.

The common model may include:

```swift
struct GitLabMergeRequestSummary: Identifiable, Equatable, Sendable {
    let id: URL
    let iidText: String?
    let title: String
    let projectDisplayName: String?
    let authorDisplayName: String?
    let isDraft: Bool
    let pipelineDisplayState: String?
    let reviewDisplayState: String?
    let updatedText: String?
    let mergeRequestURL: URL
    let sourceOrder: Int
}
```

For My MRs, emphasize only signals visible in the list:

- Project display name and MR IID.
- Title.
- Draft state.
- Pipeline display state.
- Review/approval display state.
- Last-updated text.

Christopher is the author, so do not waste card space repeating his name unless the actual list makes it necessary for disambiguation. Do not inspect descriptions, diffs, comments, unresolved threads, commit messages, branches, approver identities, source code, or conflict details unless they are already explicitly rendered in the configured list and separately approved for display. Missing status must remain unknown, not inferred as healthy.

### State model

Reuse the explicit common state machine:

```swift
enum GitLabListPanelState: Equatable {
    case unconfigured
    case loadingPage
    case authenticationRequired
    case extracting
    case loaded(items: [GitLabMergeRequestSummary], refreshedAt: Date)
    case empty(refreshedAt: Date)
    case stale(items: [GitLabMergeRequestSummary], refreshedAt: Date, reason: String)
    case unsupportedPage
    case extractionFailed
}
```

Never include extracted content or URLs in errors, logs, accessibility identifiers, or debug descriptions.

### DOM extraction

Reuse one generalized extractor for both GitLab list kinds. It should receive `GitLabListKind.authored`, inspect only the rendered page, return a JSON string, and decode into typed Swift values.

The extractor must:

1. Positively identify an authored merge-request list, including a valid empty list.
2. Find MR anchors through the stable `/-/merge_requests/<iid>` path shape.
3. Associate anchors with verified semantic list items/rows.
4. Extract only visible fields required by cards.
5. Preserve GitLab's DOM order.
6. Deduplicate by normalized MR URL.
7. Distinguish items, legitimate empty, authentication, unsupported page, and malformed extraction.

Prefer semantic HTML, accessibility roles, stable `data-testid` attributes, and URL shape. Avoid generated class names, positional selectors without evidence, and English-only assumptions where practical.

Do not infer authored ownership from DOM if the configured URL itself is the source of that filter. Do not crawl into individual MRs to fill missing fields.

### Readiness and cancellation

GitLab list content may arrive after main navigation. Use bounded local readiness checks, not one arbitrary sleep. These checks inspect DOM only.

Cancel when navigation changes, URL configuration changes, a newer extraction starts, or the panel is torn down. Generation-check results so the review panel and authored panel cannot overwrite one another.

### Controller

Use one `GitLabListPanelController` instance configured with `.authored` and `authoredPage`. It manages:

- State and in-memory last-successful cards.
- Card/browser mode.
- Navigation readiness and extraction.
- Manual reload of the configured list.
- Stale-result protection.
- Card selection and MR navigation.

Keep it independent from Panel 3's controller while reusing implementation. Do not add a timer.

### SwiftUI presentation

Use a `ZStack`:

1. `WebView(sharedStore.authoredPage)` fills the entire panel.
2. An opaque native SwiftUI card surface covers it in card mode.

Card mode disables hit testing and accessibility exposure for the covered WebView. Browser mode re-enables them. Keep the page attached and do not use screenshots.

Suggested panel:

```text
My Merge Requests · <count>                 Refresh  Show GitLab

Project Name · !456
Merge request title                                      Draft
Pipeline failed · Changes requested · updated 45m ago
```

Only show `Pipeline failed`, `Changes requested`, approval information, or similar signals when the configured list explicitly provides them. Omit unavailable fields rather than inferring them.

Do not add a merge button or other mutation controls. The safe action is opening the real MR page.

## Home Integration

Panel 4 belongs in the bottom-right quadrant:

```text
JIRA My Tickets        Agent Sessions
Reviews Requested      My Merge Requests
```

`HomeView` and `HomePanelContainer` already exist (commit `fd92eb4`) with the quadrant, title, and accessibility identifier already defined for this panel — extend them. Do not overwrite Panel 1, Panel 2, or Panel 3. The Home canvas must remain usable when the bottom terminal is expanded; prefer scrolling and sensible minimum heights over compressed rows. Note that the app declares no minimum window size today.

## Full Merge Requests Destination

Preserve the sidebar destination and upgrade it carefully if needed:

- Add a compact **To Review / My MRs** selector.
- Render the selected shared page.
- Do not create a third page.
- Preserve each page's own navigation history when switching.
- A card-opened MR should appear in the corresponding page when that list is selected.

If Panel 3 has already implemented this selector, reuse it without changing its storage keys or session ownership.

## DOM Discovery

Selector work happens in two phases. Phase 1 is where the extractor is built; Phase 2 only validates it.

### Phase 1 — Personal gitlab.com (no restrictions)

1. Build and launch Console on any machine.
2. Configure the authored-MR list URL from `CONSOLE_GITLAB_FIXTURES.md`.
3. Sign into gitlab.com normally.
4. Confirm the page is the authored open-MR list.
5. Inspect the DOM freely — Web Inspector, full `outerHTML`, screenshots, pasting markup into chat. This content is synthetic.
6. Verify the generalized extractor supports `.authored` without breaking `.reviewsRequested`.
7. Commit synthetic fixtures derived from this DOM, scrubbing the account namespace from committed HTML.
8. Write the full unit-test suite. All of it can pass here.

Design selectors for **structural generality**. Prefer semantic elements, accessibility roles, stable `data-testid` attributes, and the `/-/merge_requests/<iid>` URL shape over anything specific to the current SaaS rendering.

### Phase 2 — Company GitLab (redacted probe only)

Only once Phase 1 is complete and passing.

1. Build and launch Console on the company machine.
2. Christopher configures his exact My MRs list URL and signs in himself.
3. Confirm the page is the authored open-MR list.
4. Run the DEBUG-only structural probe through `WebPage.callJavaScript`.
5. Compare its **shape** against the Phase 1 assumptions.
6. If they match, the extractor ships unchanged. If they diverge, generalize — do not fork into a company-specific path.
7. Remove the probe or keep it DEBUG-only with strict redaction and no automatic output.

Expect divergence to be more likely than for JIRA: gitlab.com is always current, while a self-managed company instance may be several releases behind. Delivery-signal rendering (pipeline, approvals, review state) is especially prone to change between releases.

### Probe redaction rules

These apply to **Phase 2 only**. Phase 1 needs no redaction.

The probe may expose tag names, roles, attribute names, stable test-identifier shapes, masked MR URL patterns, and row/field counts. It must not expose raw DOM, titles, paths, IDs, names, branches, URLs, cookies, tokens, storage, headers, or page text. Do not paste raw company output into a remote chat.

## User Experience and Failure States

- **Unconfigured:** identify the missing My MRs URL and link to Settings.
- **Authentication required:** reveal GitLab for normal user-driven login.
- **Loading/extracting:** retain old cards with a progress indication.
- **Empty:** show “No open merge requests” only after positively identifying the authored list.
- **Unsupported page:** reveal GitLab and explain that the configured URL must be the My MRs list.
- **Extraction failed:** keep stale cards when available; never represent failure as zero.
- **Raw GitLab:** always available as the reliable fallback.

## Alternatives Considered

- **GitLab REST/GraphQL:** structurally superior but rejected for this phase because it adds a custom programmatic client.
- **Same-origin API calls from WebKit:** rejected because they add hidden requests.
- **Cookie reuse outside WebKit:** rejected because it exposes session material.
- **`glab` CLI:** rejected as another API and credential path.
- **Claude/MCP summaries:** rejected **as a runtime data path** for deterministic retrieval, due to data movement, cost, and latency. This says nothing about using tooling to manage fixtures during development; Console itself must never call it.
- **Inspecting each MR detail page:** rejected because it adds navigation/traffic and extracts more company data than needed.
- **Screenshot/OCR:** rejected as brittle and sensitive.
- **Raw GitLab only:** retained as the fallback.

## Edge Cases

- GitLab.com versus company self-managed GitLab.
- Different GitLab versions, feature flags, themes, or plugins.
- SSO/MFA redirects.
- Draft and ready-for-review state formatting.
- Pipeline/review state represented only by icons or accessibility text.
- Approval data absent from the list.
- Multiple projects using the same IID.
- Pagination and virtualized rows.
- Duplicate MR links inside each list item.
- The authored page currently showing an MR detail rather than the list.
- Session expiration with stale cards.
- Panel 3 and Panel 4 loading simultaneously.
- Shared authentication with independent navigation.
- Two live pages increasing memory and normal page-originated traffic.
- GitLab UI changes after an upgrade.

## Side Effects and Data Handling

- Two live GitLab pages behave like two open browser tabs and may each make normal page-originated requests. Do not add Console polling.
- WebKit retains normal site data for authentication. Native MR summaries remain memory-only.
- Do not log extracted values through `print`, `printDebug`, assertions, errors, crash reports, or accessibility identifiers.
- Visible accessibility labels may contain the same minimal card text, but must not be logged.
- Card mode must hide the covered WebView from accessibility.

## Testing Strategy

Use only synthetic fake projects and merge requests. DOM captured from Christopher's personal namespace during Phase 1 qualifies — those projects and MRs are invented — provided the account namespace is scrubbed from committed HTML. Captured markup is preferable to hand-written fixtures because it is real GitLab structure rather than a guess at it.

### Unit tests

- Extract identity, project display name, IID, title, draft, optional pipeline/review state, and update text.
- Preserve order and deduplicate links.
- Keep same-IID MRs from separate projects distinct.
- Handle missing optional delivery signals without inference.
- Distinguish legitimate empty, authentication, unsupported, and malformed pages.
- Ensure Panel 3 and Panel 4 extraction generations remain isolated.
- Ensure errors/debug descriptions contain no extracted values.

Run the actual JavaScript against synthetic HTML in a nonpersistent `WebPage` where practical.

### UI/integration tests

- Panel 4 occupies bottom-right.
- Card/browser toggling retains one authored page.
- Covered WebView cannot receive input and is not duplicated in accessibility.
- Manual refresh retains old cards until success.
- Two GitLab pages share one data store but maintain separate navigation.
- Full sidebar selector presents the expected shared page.
- Layout survives terminal expansion, and whatever minimum window size this work declares. If no `.defaultMinSize` is added, test against the 160pt panel minimums in `HomeView.Layout` instead — the app declares no window minimum today.

### Manual verification — personal gitlab.com

Do this first; it covers everything except company selectors. No redaction needed. Verify against `CONSOLE_GITLAB_FIXTURES.md`:

1. The authored list loads and renders cards in GitLab's order.
2. The same-IID-in-two-projects fixtures produce two distinct cards.
3. Draft, pipeline, and review cues appear only where GitLab renders them; absent states show nothing rather than a positive conclusion.
4. A pipeline deliberately failed then re-run passes through failed, running, and passed presentations.
5. A title-only MR still produces a valid, navigable card.
6. Show GitLab, Show Cards, Refresh, and card selection behave as specified.
7. Panel 3's page remains independent and authenticated.

### Manual verification — company instance

Christopher completes all authentication. Without recording sensitive screenshots or logs:

1. My MRs list loads normally.
2. Cards match rendered rows and preserve order.
3. Visible delivery signals match GitLab and missing signals are omitted.
4. Show GitLab and Show Cards preserve the live page.
5. Refresh updates cards from the configured list.
6. Selecting a card opens the correct MR.
7. An empty list is distinct from failure.
8. Panel 3 remains independent and authenticated.
9. No company data appears in logs, files, fixtures, tool output, or the final diff.

## Acceptance Criteria

- Panel 4 is the bottom-right Home quadrant labeled **My Merge Requests** or **My MRs** consistently.
- Its real authenticated authored-MR WebView fills the panel beneath native cards.
- It uses the shared two-page GitLab foundation and does not duplicate session/data-store ownership.
- Native cards come only from the rendered authored-list DOM.
- Cards preserve GitLab order and show only explicitly available delivery signals.
- Browser/card mode, manual refresh, navigation, stale handling, and authentication work.
- Empty/authentication/unsupported/failure states are distinct.
- No API/GraphQL integration, cookie access, CLI ingestion, AI call, persistence, polling, mutation, or user-agent spoofing exists.
- Synthetic tests pass, Panel 3 remains compatible, and existing Console behavior is intact.
- The app builds and runs successfully.

## Open Questions

### Answerable now, on personal gitlab.com

1. Does one shared persistent website data store authenticate both pages while keeping their histories independent? **This is a prerequisite — answer it before writing either GitLab panel.**
2. Which semantic roles or stable attributes identify authored list rows and fields on current gitlab.com?
3. Which delivery signals does the authored list actually render: draft, pipeline, approvals, review changes, conflicts, update time?
4. Are those signals exposed as accessible text, or only as icons? If only icons, the delivery-signal card contract needs revisiting before implementation.
5. Does the page paginate or virtualize results?
6. Should the card favor last-updated time or another visible delivery signal when space is tight? Decide this against real fixture rendering, not in the abstract.

### Must be confirmed on the company instance

1. Which GitLab version and deployment type is in use? **Unresolved, and it determines how much of Phase 1's selector work survives.**
2. What exact stable URL is Christopher's open authored-MR list?
3. Do the Phase 1 selectors hold, and can any divergence be generalized rather than forked?
4. Are the same delivery signals rendered, or does the company instance show a different set?
5. Which SSO domains appear during authentication?

## Implementation Discipline

- Preserve unrelated user changes.
- Search for and reuse Panel 3's shared GitLab infrastructure.
- Never expose **company** GitLab content in tool calls, logs, commits, fixtures, screenshots, or chat. Content from Christopher's personal namespace is synthetic and is the intended fixture source — see *Non-Negotiable Security Boundaries* for the distinction.
- Keep scope to shared GitLab infrastructure, Panel 4, and minimum Home/Settings/sidebar integration.
- Build and run the macOS app.
- Run focused GitLab tests and the relevant existing suite.
- Inspect the final diff for **company** data, secrets, URLs, raw DOM, debug probes, duplicated session stores, and unintended mutation actions. Synthetic fixture data and markup from the personal namespace are expected in the diff and are not findings.

## Card Design Specification

### Product question

Each **My MRs** card should answer one question at a glance: **what, if anything, is preventing this authored merge request from moving toward delivery?** This is a monitoring surface for Christopher's own work, not another review inbox. It should prioritize author-action and delivery-health signals over people, activity detail, or GitLab metadata.

Panel 3 answers “what should I review?” Panel 4 instead answers:

1. Which merge request is this?
2. Is it intentionally not ready because it is a draft?
3. Is there a visible delivery blocker or author action, such as changes requested or a failed pipeline?
4. Is work still in progress, such as a running pipeline or pending review?
5. How recently did it move?

Do not invent a single health score. GitLab signals can be incomplete, and absence of a rendered warning is not evidence that an MR is mergeable.

### Recommended information hierarchy

Use three compact visual rows. The whole card is one navigation target.

```text
┌────────────────────────────────────────────────────────────┐
│ ConsoleApp · !456                                  DRAFT   │
│ Fix login regression after token refresh                    │
│ ⓧ Pipeline failed   △ Changes requested        Updated 45m │
└────────────────────────────────────────────────────────────┘
```

1. **Context row — project display name and MR IID**
   - Use the project display name followed by the project-local IID, exactly as represented by the rendered list.
   - Keep this subdued and single-line; truncate the project name before hiding the IID.
   - Place a **Draft** badge at the trailing edge only when draft is explicitly visible.
   - Do not repeat Christopher's name or avatar. Authorship is already guaranteed by this panel's configured list.

2. **Primary row — MR title**
   - Make the title the strongest text on the card.
   - Allow two lines before truncation. A one-line-only title loses the distinguishing part of many similarly prefixed MRs.
   - Do not prepend status words that already appear as badges.

3. **Delivery row — blockers/progress plus recency**
   - Show up to three compact, text-bearing status cues selected from fields actually rendered by GitLab.
   - Keep last-updated text trailing and visually secondary. It is useful for spotting stalled work but must not displace a blocker.
   - When horizontal space is insufficient, preserve blocker cues first, then recency, and drop positive/neutral cues before truncating meaningful text.

### Delivery-signal priority

Normalize only well-understood, explicitly rendered GitLab states into a small presentation vocabulary. Preserve an unfamiliar visible state as neutral text or omit it; never guess its meaning.

Render cues in this priority order:

1. **Author action:** changes requested or another explicit author-action state.
2. **Delivery blocker:** pipeline failed or an explicitly rendered conflict/blocking state.
3. **Intentional hold:** draft.
4. **In progress:** pipeline running or another explicit active state.
5. **Waiting on others:** review/approval pending, when explicitly visible.
6. **Positive:** approved or pipeline passed, when explicitly visible and space remains.

If several signals exist, retain the highest-priority distinct cues rather than collapsing them into “Blocked.” For example, **Pipeline failed** and **Changes requested** communicate two different next actions. Never render “Ready,” “Healthy,” “Mergeable,” “Approved,” “No conflicts,” or “All checks passed” unless that exact conclusion is supported by a field visibly present in the authored list.

Draft belongs in the top-row badge so it remains visible without consuming the delivery row. If the DOM only supplies draft as part of the title, normalize it once and do not repeat it.

### Compact and constrained layouts

The normal card should target roughly three text rows plus card padding. The panel scrolls vertically; cards should not shrink until content becomes unreadable.

At narrow widths:

- Keep project/IID and the two-line title.
- Keep the single highest-priority blocker or progress cue.
- Move updated text below the cue only if it remains useful; otherwise omit it.
- Do not replace meaningful status text with icon-only controls.
- Do not use a horizontally scrolling card.

If only title and MR URL are reliably extracted, show a valid minimal card containing the title and any available project/IID context. Missing pipeline or review fields mean **unknown/not shown**, not success.

### Visual language

- Use restrained semantic color plus a symbol and text. Color must reinforce meaning, never carry it alone.
- Reserve red for explicit failed/blocking states and amber for explicit author attention. Use a quiet blue or neutral treatment for running/waiting and green only for an explicit positive state.
- Keep the Draft treatment neutral; draft is an intentional lifecycle state, not an error.
- Use one consistent badge/chip component shared with Panel 3, while allowing Panel 4 to choose a different signal priority.
- Avoid a stack of filled pills. One top-row Draft badge and a lightweight inline delivery row will remain calmer and scan faster.

### Card interaction

- The entire card is a button. Selection reveals the retained authored-MR WebView and navigates to the captured MR URL in that same authenticated page.
- Provide standard hover, pressed, keyboard-focus, and selected states without changing the card's data or making a network request.
- Pressing Return or Space while the card is focused performs the same open action.
- Do not put merge, approve, rebase, retry-pipeline, comment, checkout, copy-branch, or overflow mutation controls on the card.
- Keep **Refresh** and **Show GitLab** at panel level, not repeated per card.
- Preserve GitLab's authored-list ordering. Do not reorder by Console's status priority in this phase; the priority applies only to signal placement within each card.

### Accessibility

- Expose each card as one clearly named button, not as a collection of separately focusable decorative badges.
- Build the accessible label from the same minimal visible values: project/IID, title, draft if present, visible delivery cues, and updated text.
- Use a concise value or hint such as “Open merge request in GitLab.” Do not include hidden DOM content.
- Ensure status symbols are hidden from accessibility when adjacent text already announces the same state.
- Support macOS text-size changes: allow the title and delivery row to grow vertically rather than clipping, and preserve a minimum target height of 44 points.
- Maintain sufficient contrast in light, dark, increased-contrast, and differentiate-without-color modes; retain visible keyboard focus.
- Keep the covered WebView removed from the accessibility tree while cards are displayed, as required by the panel architecture.

### Deliberately omitted content

The authored card should not display or retrieve:

- Christopher's author name/avatar.
- Description excerpts, comments, unresolved-thread text, diff summaries, commit counts, or source code.
- Source and target branches, labels, milestones, assignees, or reviewer avatar stacks.
- Exact approver/reviewer identities unless a later, separately designed workflow proves they are essential.
- Pipeline job details, failure logs, conflict details, or inferred remediation.
- Relative “stale” warnings invented by Console from elapsed time.
- AI summaries, recommendations, or guessed next actions.

These fields either duplicate the panel's authored context, create visual noise, reveal more company information than needed, require opening individual MRs, or cannot be reliably populated from the rendered list. The card is a delivery-health index; GitLab remains the detail surface.

### Card and panel states

- **Loading with prior cards:** retain cards, dim only the panel-level refresh affordance as appropriate, and show a small refresh progress indicator. Do not pulse every card.
- **Stale cards:** keep cards fully navigable and show one panel-level “Not refreshed” notice. Do not place warning badges on every MR.
- **Empty:** show “No open merge requests” only after positively identifying a valid authored list.
- **Authentication/unsupported/extraction failure:** show the panel-level recovery state and reveal action defined above; never substitute an empty card list.
- **Partial row:** render a card only when it has a validated MR URL and usable visible title. Omit unsupported optional fields. Do not fabricate private identifiers or titles.
- **Duplicate links:** one card per normalized MR URL, using the first verified row in GitLab order.
- **Long or localized text:** allow the title to wrap; truncate low-priority context and cues. Do not rely on English text alone for extraction or state identity.

### Build-ready field contract

The existing memory-only `GitLabMergeRequestSummary` is sufficient for the recommended first version. Panel 4 consumes it as follows:

| Field | Card treatment | Required |
|---|---|---|
| `mergeRequestURL` / `id` | Card navigation and identity; never displayed raw | Yes |
| `title` | Primary, up to two lines | Yes |
| `projectDisplayName` | Subdued context | No |
| `iidText` | Subdued context; preserve when space is tight | No |
| `isDraft` | One neutral trailing badge | Derived only from explicit visible state |
| `pipelineDisplayState` | Delivery cue, normalized conservatively | No |
| `reviewDisplayState` | Delivery cue, normalized conservatively | No |
| `updatedText` | Trailing recency text | No |
| `authorDisplayName` | Not shown in Panel 4 | No |

Do not expand the model merely to make the card appear richer. A new field is justified only after Phase 1 DOM discovery confirms that it is visibly present in the configured list and it materially changes an iOS developer's delivery decision — and it must degrade cleanly if the company instance turns out not to render it.

### Synthetic design fixtures and acceptance checks

Use synthetic data to verify at least these cards:

1. Draft with no other visible state.
2. Ready-for-review MR with a running pipeline.
3. Pipeline failed and changes requested simultaneously.
4. Explicit approval with a passed pipeline.
5. Title-only minimal card with all optional values absent.
6. Very long localized project name, title, and status text.
7. Same IID in two different projects.
8. Stale panel retaining previously loaded cards.

The design is accepted when a developer can scan the panel and identify author action, delivery blockers, waiting work, and recently completed progress without reading branch names, avatars, descriptions, or opening each MR—and when missing rendered data never appears as a positive delivery conclusion.
