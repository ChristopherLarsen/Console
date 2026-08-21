# Console Home Panel 3 — GitLab Merge Requests to Review

## Summary

Build the bottom-left Home quadrant for Console as a native **MRs to Review** panel backed by a real, authenticated GitLab merge-request list running in WebKit. A live GitLab `WebView` must fill the panel while an opaque native SwiftUI card layer presents the merge requests above it. Read only the merge-request rows GitLab has already rendered in the DOM. Do not add GitLab API calls, cookie extraction, injected `fetch`/XHR requests, AI summarization, user-agent spoofing, automatic pagination, or persistent storage of company merge-request content.

This work must be completed and verified on the company machine where Christopher can sign into the real GitLab instance. Christopher enters credentials and completes MFA himself. Never request, capture, print, commit, or transmit credentials, cookies, raw DOM, project paths, merge-request titles, source branches, employee names, or other company data.

Panel numbering follows the agreed Home flow:

```text
Panel 1: JIRA My Tickets       Panel 2: Agent Sessions
Panel 3: MRs to Review         Panel 4: My MRs
```

## Outcome

The bottom-left Home quadrant shows the open GitLab merge requests for which Christopher is expected to review or approve. It preserves GitLab's list order and exposes only information already visible in that list. Christopher can:

- Reveal the real GitLab page without losing authentication or navigation state.
- Return to native card mode immediately.
- Manually reload the configured review list and regenerate cards.
- Select a card to reveal and open that merge request in the same WebKit session.
- Distinguish a legitimate empty review queue from authentication, unsupported-page, and extraction failures.

Do not implement approve, comment, merge, checkout, or AI-review actions in this phase. Those actions require separate product and security decisions.

## Current Application Context

Read these files and the JIRA panel handoff before editing:

- `CONSOLE_PANEL_1_JIRA.md`
  - Establishes the authenticated-WebView/native-card security pattern.
- `CONSOLE_PANEL_4_GITLAB.md`
  - Defines the sibling My MRs panel and shared GitLab session contract.
- `Console/Console/Views/MainView.swift`
  - Home is currently a placeholder unless Panel 1 has already introduced `HomeView`.
- `Console/Console/MergeRequests/Views/MergeRequestsView.swift`
  - `MergeRequestsWebSession.shared` currently owns one process-scoped `WebPage`.
  - The view currently loads one generic URL stored in `webViewMergeRequestsURL`.
- `Console/Console/Settings/Views/SettingsView.swift`
  - Contains the current generic Merge Requests URL field.
- `Console/Console/App/AppSettings.swift`
- `Console/Console/App/SidebarSelection.swift`
- `Console/Console/Sidebar/Views/SidebarView.swift`

The project targets macOS 26 and uses SwiftUI WebKit `WebPage` and `WebView`. New files under the filesystem-synchronized source and test directories are automatically included in their targets.

## Shared GitLab Foundation and Coordination Contract

The two GitLab panels are visible at the same time and cannot render two different lists from one `WebPage`. They need two retained pages that share the same persistent WebKit website data store and authentication cookies.

Before creating anything, search the branch for an existing shared GitLab implementation. Reuse it if Panel 4 or another model has already established it.

The shared design must provide the equivalent of:

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

Both pages must be configured with the same persistent `WKWebsiteDataStore`. Do not create separate cookie stores, extract cookies, or attempt to copy authentication between pages. Signing into GitLab normally in one page should make the browser session available to the other through the shared data store.

Panel 3 is the canonical owner of the shared foundation if it is implemented first. If Panel 4 was implemented first, extend its foundation instead of renaming or duplicating it. Do not leave both `MergeRequestsWebSession` and a competing GitLab singleton owning overlapping pages.

The full **Merge Requests** sidebar destination should eventually provide a small selector for **To Review** and **My MRs**, rendering the corresponding shared page. Keep that sidebar usable while implementing Panel 3. Do not force the two pages into one back-forward history.

## Configuration

Two stable GitLab list URLs are required:

- `webViewGitLabReviewsURL` — exact GitLab list showing merge requests Christopher needs to review.
- `webViewGitLabMyMergeRequestsURL` — exact GitLab list showing Christopher's open authored merge requests.

Panel 3 owns the first URL but must use naming compatible with Panel 4. Add clear Settings fields if they do not exist. Preserve the existing `webViewMergeRequestsURL` preference as a legacy value; do not delete or overwrite it without an explicit migration. Do not log any configured URL because it may contain a private GitLab host, group, project, username, or filter parameters.

Do not programmatically construct or modify GitLab query parameters in this phase. Christopher will configure the exact list URL he normally uses in the browser.

## Non-Negotiable Security Boundaries

### Allowed

- Normal WebKit navigation to the configured GitLab list.
- GitLab's normal page resources, redirects, SSO, MFA, polling, and page-originated traffic.
- `WebPage.callJavaScript` used only to inspect the DOM already rendered by GitLab.
- Two retained GitLab pages sharing WebKit's persistent browser data store.
- In-memory Swift models containing only fields displayed on native cards.
- Synthetic fake GitLab HTML and merge requests in tests.

### Forbidden

- No cookie, local-storage, session-storage, token, or request-header access.
- No GitLab REST or GraphQL API client.
- No `URLSession`, `curl`, `glab`, shell command, or other client for panel data.
- No injected `fetch`, `XMLHttpRequest`, GraphQL, REST, or hidden endpoint navigation.
- No undocumented GitLab endpoints.
- No custom or spoofed Safari user agent.
- No Claude, LLM, MCP, analytics, crash-reporting, or external-service transmission of GitLab data.
- No persistence of MR content in SwiftData, UserDefaults, files, snapshots, logs, or test fixtures.
- No automatic scrolling, pagination, continuous reload, or background refresh timer.
- No automatic approve, comment, merge, checkout, or branch operations.

If DOM extraction cannot be made reliable under these constraints, keep the authenticated GitLab WebView usable and report the limitation.

## Use Cases

### Normal launch

1. Home opens and the shared review page loads the configured To Review list.
2. After the GitLab list has rendered, Console locally extracts the available rows.
3. The panel shows native cards in the same order as GitLab.

### Authentication

1. If the list is unavailable because GitLab or SSO requires authentication, reveal the raw review WebView.
2. Christopher signs in and completes MFA himself.
3. The shared website data store makes the authenticated session available to the authored page as well.
4. When the review list is rendered, card mode becomes available.

### Reveal and return

1. **Show GitLab** removes the opaque card overlay and enables the underlying WebView.
2. **Show Cards** restores native cards without replacing the page.

### Manual refresh

1. Christopher chooses Refresh.
2. Reload the ordinary configured GitLab list page.
3. Retain prior cards with a refreshing indicator.
4. Replace them only after a complete successful extraction.
5. If refresh fails, show prior cards as stale.

### Open an MR

1. Christopher selects a card.
2. Reveal the review WebView and navigate it to that MR's captured absolute URL.
3. Back navigation returns to the review list, or Refresh explicitly reloads the configured list URL.

## Proposed Architecture

Suggested shared and panel-specific files:

```text
Console/Console/GitLab/Models/GitLabMergeRequestSummary.swift
Console/Console/GitLab/Services/GitLabWebSessionStore.swift
Console/Console/GitLab/Services/GitLabMergeRequestListExtractor.swift
Console/Console/GitLab/Services/GitLabListPanelController.swift
Console/Console/GitLab/Views/GitLabReviewsPanelView.swift
Console/Console/GitLab/Views/GitLabMergeRequestsBrowserView.swift
Console/Console/Home/Views/HomeView.swift
Console/ConsoleTests/GitLabMergeRequestListExtractorTests.swift
Console/ConsoleTests/GitLabListPanelControllerTests.swift
```

The exact names may change, but Panel 3 and Panel 4 must reuse the same model, extractor infrastructure, session store, state machine, browser chrome, and card components where appropriate. Panel-specific field emphasis and labels can differ.

### Merge-request model

MR internal numbers are only unique inside a project. Identity must use the normalized absolute MR URL or a composite project-path/IID value, never IID alone.

A suggested memory-only model is:

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

Only retain fields actually displayed and already available in the list DOM. Do not scrape descriptions, diffs, comments, discussions, approver identities, source code, commit messages, or hidden metadata.

For Panel 3, emphasize:

- Project display name, if shown.
- MR IID, if shown.
- Title.
- Author, if shown.
- Draft state.
- Pipeline/review state only if GitLab visibly renders it in the list.
- Last-updated text, if shown.

### State model

Use explicit states equivalent to:

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

Errors must not contain project names, employee names, MR titles, URLs, or other company data.

### DOM extraction

Create one generalized GitLab list extractor that can serve both list kinds. Supply the page and `GitLabListKind`, and return a JSON string decoded into Swift value types.

The extractor must:

1. Positively identify a GitLab merge-request list container, even when empty.
2. Locate MR anchors using the stable URL shape containing `/-/merge_requests/<iid>` rather than generated CSS class names.
3. Associate each anchor with its nearest verified semantic list item, row, or stable GitLab test element.
4. Read only visible row data needed by the card.
5. Deduplicate by normalized MR URL while preserving DOM order.
6. Return distinct outcomes for list-with-items, legitimate empty list, authentication, unsupported page, and extraction failure.

Prefer semantic elements, accessibility roles, stable `data-testid` attributes, and MR URL patterns. Avoid generated CSS classes, unexplained positional selectors, and English-only assumptions where feasible.

Do not derive confidential project data merely because more of it is available in the URL unless the card genuinely needs a display name. Never log the URL.

### Readiness and cancellation

GitLab may render or update the list after main navigation completes. Use bounded local DOM readiness checks rather than one arbitrary sleep. Checks may retry for a short bounded period but must not initiate network requests.

Cancel extraction when navigation starts, the configured URL changes, the view is torn down, or a newer extraction supersedes it. Use generation tracking so an old page result cannot replace a newer list.

### Panel controller

Use one observable `@MainActor` controller instance per list kind. It owns:

- Panel state and last successful in-memory items.
- Card-versus-browser presentation.
- Loading/readiness/extraction orchestration.
- Manual reload.
- Stale-result protection.
- Card selection and navigation.

Do not add a polling timer.

### SwiftUI presentation

Use a `ZStack` with the shared review `WebView` filling the panel and an opaque native card surface above it.

In card mode:

- Disable WebView hit testing.
- Hide the covered WebView from accessibility.
- Keep the page attached.
- Provide Refresh and **Show GitLab** actions.

In browser mode:

- Enable WebView interaction and accessibility.
- Provide **Show Cards** after a successful extraction.
- Preserve back, forward, and reload controls.

Suggested header and card:

```text
Reviews Requested · <count>                 Refresh  Show GitLab

Project Name · !123
Merge request title                                      Draft
Author Name · Pipeline passed · updated 2h ago
```

Omit unavailable optional fields rather than guessing. Preserve GitLab order.

## Home Integration

Panel 3 belongs in the bottom-left quadrant. Reuse the `HomeView` and panel container introduced by Panel 1 if present. Do not replace another model's Home layout or implement the other quadrants.

The target arrangement is:

```text
JIRA My Tickets        Agent Sessions
Reviews Requested      My Merge Requests
```

Account for the bottom terminal reducing available height. Use a scrollable Home canvas or panel minimum heights rather than crushing MR rows.

## One-Time Discovery on the Company Machine

The exact GitLab DOM must be discovered locally against the real configured review list.

1. Build and launch Console on the company machine.
2. Christopher configures the exact To Review list URL.
3. Christopher signs into GitLab and completes MFA himself.
4. Confirm the visible page is the intended MR list.
5. Run a temporary DEBUG-only structural probe through `WebPage.callJavaScript`.
6. Record only generalized selector decisions.
7. Build production extraction from those decisions.
8. Commit only synthetic fake GitLab fixtures.
9. Remove the probe or retain it DEBUG-only with strict redaction and no automatic output.

The probe may return element tags, roles, attribute names, stable test-identifier shapes, masked `/-/merge_requests/<iid>` URL patterns, and row/field counts. It must not return raw DOM, text content, real IDs, paths, names, titles, branches, URLs, tokens, cookies, storage, or headers. Never paste raw inspector output into a remote model conversation.

## User Experience and Failure States

- **Unconfigured:** explain which URL is missing and provide a Settings action.
- **Authentication required:** reveal the actual WebView for user-driven login.
- **Loading/extracting:** retain old cards when possible.
- **Empty:** show “No merge requests waiting for your review” only after positively identifying the empty list.
- **Unsupported page:** offer Show GitLab and explain that the configured URL must be the review list.
- **Extraction failed:** keep stale cards if available and never report false zero.
- **Raw page:** always remains a usable fallback.

## Alternatives Considered

- **GitLab REST/GraphQL API:** more structured, but rejected for this phase because it adds a custom client and programmatic request path.
- **Authenticated JavaScript API calls inside WebKit:** rejected because they add hidden requests beyond the rendered page.
- **Cookie transfer:** rejected because it exposes session material.
- **`glab` CLI:** rejected as a separate API client and credential path for panel ingestion.
- **Claude/MCP:** rejected for deterministic retrieval due to data movement, latency, and AI cost.
- **Screenshot/OCR:** rejected as brittle and likely to capture sensitive code-review information.
- **Raw GitLab only:** retained as the mandatory fallback.

## Edge Cases

- GitLab.com versus a self-managed company GitLab version.
- Company themes, plugins, feature flags, and gradual UI rollouts.
- SSO/MFA on another domain.
- Lists filtered by reviewer, assignee, approval rules, or custom dashboard state.
- Draft MR formatting.
- Pipeline and review states expressed only as icons or accessibility labels.
- Pagination or virtualized rows.
- Multiple projects with the same MR IID.
- Duplicate links inside a row.
- Clicking an MR moves the underlying page away from the list.
- Session expiration while cards are visible.
- The other GitLab panel authenticating or navigating at the same time.
- Two live WebKit pages increasing memory and page-originated network activity.
- GitLab markup changing after an upgrade.

## Testing Strategy

Use only synthetic fake GitLab content in committed tests.

### Unit tests

- Extract MR identity, IID, title, project, author, draft, optional status, and update text.
- Preserve DOM order.
- Distinguish empty, authentication, unsupported, and malformed pages.
- Deduplicate repeated MR links.
- Keep same-IID MRs from different projects distinct.
- Handle missing optional fields.
- Reject stale extraction generations.
- Verify no error/debug representation includes extracted values.

Where practical, load fake HTML into a nonpersistent `WebPage` and run the real JavaScript extractor.

### UI/integration tests

- Panel 3 occupies bottom-left.
- Cards and raw WebView toggle without replacing the page.
- Covered WebView is not interactive or separately accessible.
- Refresh retains prior cards.
- The sibling authored page and controller remain independent.
- Shared authentication configuration uses one website data store.
- Layout remains usable with the terminal expanded and at minimum window size.

### Manual verification

Christopher handles all authentication. Without capturing sensitive screenshots or logs, verify:

1. The configured review list loads normally.
2. Card count matches rendered rows.
3. Order and visible fields match GitLab.
4. Empty and failure states are not confused.
5. Show GitLab reveals the same page.
6. Show Cards returns immediately.
7. Refresh reloads the configured list and updates cards.
8. A card opens the correct MR.
9. Signing in through one GitLab page authenticates the other shared-data-store page.
10. No company data appears in logs, files, fixtures, or the final diff.

## Acceptance Criteria

- Panel 3 is the bottom-left Home quadrant and is labeled **Reviews Requested** or **MRs to Review** consistently.
- A real authenticated GitLab WebView fills the panel beneath native cards.
- The two GitLab pages share one persistent WebKit website data store but retain independent navigation histories.
- Native cards come only from the rendered review-list DOM.
- No added API/GraphQL request, cookie access, CLI ingestion, AI call, persistence, polling, or user-agent spoofing exists.
- Cards preserve GitLab order and never invent unavailable state.
- Browser/card toggling, manual refresh, card navigation, stale handling, and authentication work.
- Panel 4 can reuse the same foundation without duplication.
- Synthetic tests pass and existing Console behavior remains intact.
- The app builds and runs successfully.

## Open Questions for the Company Machine

1. What exact stable URL is Christopher's To Review list?
2. Which GitLab version and deployment type is in use?
3. Which semantic roles or stable attributes identify list items and card fields?
4. Does the page represent “review requested” through reviewer, assignee, or approval filters?
5. Which fields are actually visible: project, IID, author, draft, pipeline, approvals, and updated time?
6. Does the list paginate or virtualize rows?
7. Which SSO domains appear during login?
8. Does the shared website data store authenticate both retained pages correctly?

## Implementation Discipline

- Preserve unrelated user changes.
- Search for Panel 4's shared GitLab foundation before creating new files.
- Keep real GitLab content out of tools, logs, commits, fixtures, screenshots, and chat.
- Keep the scope to shared GitLab infrastructure, Panel 3, and the minimum Home/Settings integration required.
- Build and run the macOS app.
- Run focused GitLab tests and the relevant existing suite.
- Review the final diff for company data, secrets, URLs, raw DOM, debug probes, and duplicated session stores.

## Card Design Specification

### Product job

Each Panel 3 card should help Christopher make one fast decision: **which merge request should I review next, and is it actionable enough to open now?** The card is an entry point into the real GitLab review flow, not a compressed replacement for GitLab. It should establish repository context, identify the change and its author, expose only the most useful readiness cues, and then get out of the way.

This differs from Panel 4's authored-MR cards. In the review queue, **author** is useful because it identifies the teammate waiting for review, while branch details and a recap of Christopher's own review progress are secondary. Do not force both panels to display the same fields merely because they share a card component.

### Information hierarchy

Render no more than three compact rows. Fields are listed in display priority, not extraction priority:

1. **Merge-request title** — the dominant element, medium emphasis, up to two lines. This is the clearest description of the work Christopher is being asked to assess.
2. **Project display name and MR IID** — a compact eyebrow such as `Console iOS · !123`. The IID alone is ambiguous across projects; project context must accompany it when both are visibly available.
3. **Author and freshness** — a quiet footer such as `Alex · updated 2h ago`. Author answers who is waiting; visible update time helps distinguish an active change from an old queue item.
4. **Actionability cues** — show `Draft` and a visible pipeline state only when GitLab renders them in that list row. These cues help avoid opening work that is not ready or has failing automation.

The title and absolute MR URL are the minimum viable extracted values. Omit any unavailable optional field cleanly. Never infer a project name from a private URL, translate an icon into a status without a trustworthy accessible label, or synthesize priority from age, author, IID, list position, or pipeline state.

### Recommended compact outline

```text
┌────────────────────────────────────────────────────────┐
│ CONSOLE IOS · !123                 Draft   CI failed    │
│ Fix account recovery navigation crash                  │
│ Alex Chen · updated 2h ago                             │
└────────────────────────────────────────────────────────┘
```

The actual visual treatment should be quieter than the ASCII border suggests:

- Use a single card surface with modest padding and a minimum height that accommodates a two-line title.
- Keep the project/IID eyebrow and footer visually secondary to the title.
- Align the small status cues to the trailing side of the eyebrow when space permits; allow them to wrap below it rather than compressing the title.
- Use at most two status cues: `Draft` plus one pipeline state. Do not repeat “Review requested” on every card because the panel itself already establishes that context.
- Use text plus a simple symbol for state. Color may reinforce meaning but must never carry it alone.
- Preserve GitLab's list order. Do not locally rank, group, or hide drafts; doing so would invent a prioritization system and make the native view disagree with the source page.

When the panel is narrow, retain the hierarchy rather than shrinking typography: move status cues onto their own compact line, then omit lower-priority optional metadata if necessary. Keep the title visible.

### Status treatment

Status presentation should describe source facts, not recommend a review outcome:

- **Draft:** a neutral or muted `Draft` pill. Do not disable the card; a reviewer may still want to inspect early work.
- **Pipeline failed:** a clearly labeled failure symbol/pill. This is attention-worthy but must not imply the MR cannot be reviewed.
- **Pipeline running:** a labeled progress treatment. Animate only if the existing design has a restrained, accessible progress convention; otherwise use a static symbol.
- **Pipeline passed:** a low-emphasis confirmation. It should not visually outrank the title or a Draft marker.
- **Unknown or absent pipeline state:** show nothing. Never display `Unknown` for a field GitLab simply did not render.

Staleness from a failed panel refresh belongs in the **panel header**, not on every card. Keep the last successfully extracted cards visible and label the collection as stale with a safe timestamp or generic refresh message. Do not visually present stale data as a legitimate empty queue.

### Interaction

- Treat the entire card as one button. A click, keyboard Return, or Space selection reveals the retained Panel 3 GitLab WebView and navigates that same page to the captured MR URL.
- Give the card one primary action only. Do not add approve, comment, merge, checkout, copy-branch, or AI-review controls.
- Do not prefetch, preview, or open a hidden detail page on hover or focus. Population remains limited to the already rendered list DOM.
- Preserve a visible keyboard focus ring. Returning from GitLab to cards should restore focus to the card that was opened when practical.
- A tooltip may expose the full already-extracted title when visual truncation is necessary, but it must not trigger extraction or networking.

### Accessibility

- Expose each card as a button with an accessibility label assembled only from displayed fields, in this order: title, project/IID, author, draft/pipeline state, freshness.
- Keep each visible status word in the accessibility label; never rely on red, green, yellow, or an unlabeled icon.
- Use system text styles and allow text scaling. A two-line title is preferred to aggressive truncation.
- Maintain sufficient contrast for secondary metadata and status outlines in light, dark, high-contrast, and reduced-transparency appearances.
- Keep the covered WebView hidden from accessibility while cards are active so VoiceOver does not encounter duplicate GitLab content.

### Deliberate omissions

Do not display or derive the following on Panel 3 cards in this phase:

- Description, diff statistics, file names, code, commit messages, or discussion excerpts.
- Source and target branches unless a later company-machine review proves they are both already visible and essential to choosing a review; they are lower value than author and freshness here.
- Reviewer or approver avatar stacks, approval counts, comment counts, labels, milestones, or assignees unless a later design explicitly replaces a higher-priority field and the data is visibly rendered in the list.
- A generated urgency score, “recommended next” badge, or age-based warning.
- Any AI summary, sentiment, risk classification, or review estimate.
- Any content obtained by opening the MR, inspecting hidden page state, calling an API, or parsing session credentials.

This restraint keeps the panel scannable and ensures every card can be produced from the existing rendered list without extra company-network traffic.

### Card-level edge cases

- **Long title:** wrap to two lines, then truncate visually; retain the full extracted title for the button's accessibility label and optional local tooltip.
- **Missing project or IID:** display whichever visible identifier exists. Do not manufacture the missing half from the URL. If neither is visible, let the title lead.
- **Missing author or update text:** collapse the footer around the available value; do not leave placeholders such as `Unknown author`.
- **Same IID in multiple projects:** identity remains the normalized absolute MR URL, and visible project context prevents confusing cards when available.
- **Duplicate MR anchors in one row:** show one card after URL-based deduplication.
- **Draft with failed pipeline:** both cues may appear because they answer different questions, but they must remain subordinate to the title.
- **Many cards:** use one vertically scrolling list with stable card identity and source order. Do not make individual cards horizontally scroll.
- **Authentication or extraction failure:** never fabricate cards from partial page chrome. Show the panel-level state and raw GitLab fallback described earlier.

### Build and review checklist

- Verify a card can be understood in roughly one glance without reading the footer.
- Verify title, project/IID, author, freshness, Draft, and pipeline are each omitted gracefully when absent from synthetic DOM fixtures.
- Verify the card never exposes more fields than its source row and causes no request until the user activates it.
- Verify keyboard and VoiceOver activation open the correct MR in the retained Panel 3 page.
- Verify Draft, failed, running, and passed pipeline states remain understandable without color.
- Verify narrow panel widths preserve the title before optional metadata.
- Compare Panel 3 and Panel 4 side by side: shared styling is desirable, but Panel 3 must retain reviewer-oriented emphasis on **author and actionability**, not authored-MR progress details.
