<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-09 after adding browser-style tabs to the JIRA and GitLab sidebar destinations (uncommitted)._

## Next Intended Move

No open queue. Tab feature is implemented, built, and unit-tested but NOT
committed (Christopher did not ask) and not pushed; `main` is still 1 commit
ahead of `origin/main` from last session. Next: manual verification of tabs
against the personal fixture sites (⌘T new tab, close, switching, deep links),
then commit if Christopher asks.

## Working Findings

- Tab feature (this session):
  - `Console/Console/Views/Components/BrowserTabStore.swift` (new): shared
    `BrowserTab` + `@Observable BrowserTabStore` + `BrowserTabBar`. Pinned
    tabs first (unclosable), dynamic tabs capped at 8, ⌘T opens, each tab =
    own `WebPage` on the shared persistent data store, strictly memory-only.
  - JIRA: `JiraWebSession.tabStore` (lazy) pins `shared.page` as tab 0
    ("My Tickets"); Home cards + extraction stay bound to that page.
    `loadIfNeeded` now always targets `session.page` so remounting never
    yanks a free tab back to the configured list. Deep links select tab 0.
    New JIRA tabs load the configured URL (UserDefaults read, normalized by
    `JiraView.normalizedURL`).
  - GitLab: `CodeHostWebSessionStore.tabStore` (lazy) pins reviews (0) and
    authored (1) — the old segmented picker was REPLACED by the tab strip.
    New GitLab tabs load the configured reviews URL. Settings URL changes
    reload their own list (legacy key → reviews). Deep-link kind hints
    select the matching pinned tab.
  - Tab switching remounts the WebView one runloop hop apart (macOS 26:
    a WebPage attaches to only one live WebView) — same pattern as the
    existing Home/destination swap; unmount-then-mount in both views.
  - Accessibility ids preserved: `JiraWebView`, `JiraEmptyState`,
    `MergeRequestsWebView`, `MergeRequestsEmptyState` (UI tests untouched).
    `MergeRequestsListSelector` id is GONE (picker removed).
  - Tests: new `BrowserTabStoreTests` (10 cases) green; full `ConsoleTests`
    run: 1368 passed, 1 failed, 1 skipped.
- `EndToEndIntegrationTests.testNormalCommandFlow_EngineRemainsStableAcrossSessions`
  fails with a 5s "Command received" wait timeout on PRISTINE main too
  (re-confirmed 2026-09-09 via stash) — pre-existing flake, same family as
  the documented `testFieldDictation_ActivatesAndReleasesCleanly` flake.
- overview.md invariant 2 updated for tabs (same-session edit).
- WebKit SIGTRAP host crashes seen at 14:27/14:37 during test runs
  (SwiftUI PlatformViewChild.updateValue → WebKit representable); no crash
  since 14:37 despite repeated runs. Likely the known launch flake family;
  watch for recurrence.

## Dead Ends

- `app.windows.firstMatch` still fails on this host (NavigationUITests red).
- Synthesized sidebar clicks: dead — drive UI from menu bar, launch hooks, or
  in-content buttons only.
- Full UITest suite remains forbidden.
- WebKit launch SIGTRAP flake can hit test hosts → retry once before
  diagnosing.
