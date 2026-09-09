<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-09 after replacing the iOS settings project search with a manual picker._

## Next Intended Move

Christopher should manually verify Settings → iOS Project: "Choose…" opens a
panel; select a `.xcodeproj`/`.xcworkspace` (or a folder containing exactly
one) → scheme/config/test-plan/Simulator discovery fills from that project.
Also still open from earlier sessions: manual verification of the JIRA sidebar
crash fix (main @ 6160eeb) and the exit-shell fix (now committed as 45d451a —
previously believed uncommitted), and the LATENT GitLab crash (below).

## Working Findings

- iOS project search removed (main @ 8a4cc57, worktree merged + cleaned).
  Old behavior: bounded filesystem walk (`IOSProjectFileSearch`) auto-found
  and auto-selected projects per workspace; reported broken. New behavior:
  Settings → iOS Project has a Choose… button → NSOpenPanel; user picks the
  `.xcodeproj`/`.xcworkspace` directly, or a folder containing exactly one
  (`IOSProjectManualSelection.resolve`, direct children only — never a deep
  walk). Repair policy: empty profile → `.projectNotSelected`; project is
  NEVER auto-selected. `IOSDiscoveryRefreshResult` lost `candidates`;
  `discovery.refresh(saved:)` lost `workspaceFolder`; `.searchingProjects`
  phase removed. Scheme/config/test-plan/Simulator discovery via bounded
  xcodebuild argv unchanged. 34 targeted IOS* tests pass; Debug build clean.
- main advanced mid-task (JIRA sidebar merge 6160eeb); rebased the branch
  before ff-merge. Worktree was at ../Console-wt-iospicker — removed.
- LATENT GitLab crash remains: `MergeRequestsPanelView` + GitLab sidebar share
  WebPages; selecting GitLab from Home likely crashes like JIRA did
  (one-WebView-per-WebPage, see CONSOLE_PANEL_1_JIRA.md). Same one-hop
  `isWebViewMounted` deferral would fix it.
- JIRA sidebar crash repro method: Debug build, launch binary, osascript
  System Events sidebar buttons (button 4 = JIRA, 1 = Home) — see docs history.

## Dead Ends

- Full UITest suite remains forbidden (targeted `-only-testing:` only).
- No UI tests cover the iOS settings surface (`Settings.IOS.*` identifiers
  unreferenced in ConsoleUITests) — unit tests are the only guard there.
- Synthesized XCUI clicks on custom sidebar rows unreliable on this host;
  System Events clicks work. `entire contents of window 1` misses sidebar.
