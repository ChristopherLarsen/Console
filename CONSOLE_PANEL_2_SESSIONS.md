# Console Home Panel 2 — Agent Sessions

## Summary

Populate the top-right Home quadrant with a live **Sessions** radar: a compact, attention-sorted list of in-memory Claude sessions that lets Christopher see who needs him and jump to that session in one click. This panel is not a second Sessions page and must not embed a terminal. The Sessions sidebar destination remains the place where work happens. Home answers “does an agent need me, and which repo is it in?” then navigates.

## Use Cases

### Morning launch (empty is the default)

Sessions are memory-only. Quitting Console returns to zero sessions, so Home’s Sessions quadrant is empty at every launch.

1. Console opens on Home.
2. The top-right quadrant shows a quiet empty state: **No Claude Sessions** plus **New Claude Session**.
3. Christopher creates a session from the panel. On success, Console selects that session and navigates to the Sessions destination so he can type the first prompt.

### Scan and jump

1. Christopher is on Home reviewing tickets and MRs.
2. The Sessions panel lists every live session, sorted by displayed-state priority (waiting first).
3. A header count reads `Sessions · 3`, and if any session requires a human action, `· 1 needs you`.
4. He clicks a row. Console selects that session and navigates to Sessions. Process, terminal view, and scrollback are already alive.

### Open Sessions without picking a row

1. Christopher clicks **Open Sessions** in the panel header.
2. Console navigates to the Sessions destination without changing the current selection (or with none, if the store is empty).

### Agent finished or waiting while he is on Home

1. A session’s activity/attention updates through the existing bridge.
2. The Home row re-renders from `SessionStore` (same observable source as the Sessions list).
3. Summary text and artifact chips appear when the agent has posted them.
4. No extra polling, persistence, or network.

## Proposed Design

### Role split (non-negotiable)

| Surface | Job |
| --- | --- |
| Home Panel 2 | Attention radar + launcher |
| Sessions destination | Process list, terminal, stop/remove, scrollback |
| Bottom `zsh` drawer | Global shell chrome, unrelated to Claude PTYs |

Do not embed a SwiftTerm view in the Home quadrant. Do not duplicate stop, force-stop, or remove controls on Home. Do not start an agent from a JIRA or GitLab card in this assignment.

### Architecture

Read from the existing `SessionStore` already injected at app scope. Add a presentation helper and a Home-only view. Do not introduce a second store, persist sessions, or change lifecycle/bridge behavior.

```text
Console/Console/Home/Views/HomeView.swift                    (exists — extend)
Console/Console/Home/Views/HomePanelContainer.swift          (exists — reuse)
Console/Console/Home/Views/HomeSessionsPanelView.swift       (new)
Console/Console/Home/Views/HomeSessionCard.swift             (new, or private in the panel file)
Console/Console/Sessions/Models/HomeSessionsPresentation.swift (new)
Console/Console/Sessions/Views/NewClaudeSessionSheet.swift  (exists — small hook)
Console/Console/App/ConsoleNavigation.swift                 (exists — reuse showSessions())
Console/Console/ConsoleApp.swift                            (exists — new UITest launch flag)
Console/ConsoleTests/HomeSessionsPresentationTests.swift    (new)
Console/ConsoleUITests/HomeSessionsUITests.swift            (new)
CONSOLE_TERM_COMM.md                                        (exists — §8 currently says Panel 2 stays a placeholder)
```

Filesystem-synchronized Xcode groups pick up new Swift files automatically.

### Presentation helper

Put sort, “needs you” counting, and subtitle rules in a pure helper so they can be unit-tested without launching the app.

```swift
enum HomeSessionsPresentation {
    static func sorted(_ sessions: [ConsoleSession]) -> [ConsoleSession]
    static func needsYouCount(in sessions: [ConsoleSession]) -> Int
    static func needsYou(_ state: DisplayedSessionState) -> Bool
    static func subtitle(for session: ConsoleSession) -> String?
}
```

Rules:

- **Sort** by `displayedSessionState(...).priorityRank` ascending (Needs Approval / Needs Input first, Exited last). Keep store order as a stable tie-break — do not re-sort alphabetically.
- **Needs you** is true for `.needsApproval`, `.needsInput`, `.blocked`, `.needsReview`, and `.error`. **Done** is visible in the list as green but does **not** increment the header count.
- **Subtitle:** one-line `summary` if present; else the working-folder basename when it differs from `session.name`; else omit. Never show a folder line that merely repeats the name.
- Artifact chips: up to two, plus `+N` overflow, same as `SessionInfoStrip`. Informational only — no JIRA/GitLab navigation, no fetches.

Reuse `displayedSessionState(activity:attention:)` from `SessionModels.swift`. Extract shared state tint (the color switch now inlined in `SessionListRow`) into one place so Home cards and the Sessions list cannot drift. Do not copy-paste a third copy.

### Home integration

In `HomeView.panel(_:)`:

- Keep `HomePanel.sessions` title `"Sessions"` and accessibility identifier `HomePanelSessions`.
- Set `showsHeader: false` for Sessions, matching JIRA, because this panel owns a header with actions.
- Replace only the Sessions placeholder with `HomeSessionsPanelView()`. Leave GitLab quadrants on `HomePanelPlaceholder`. Do not regress the JIRA panel.

`HomePanelContainer` already supplies the card chrome and `HomePanelSessions` identifier. The inner view fills the body slot.

### Navigation hop

```swift
store.select(sessionID: session.id)
ConsoleNavigation.showSessions()
```

`ConsoleNavigation.showSessions()` already writes `sidebarSelection`. `SessionStore.select(sessionID:)` already exists. Do not add a new navigation type.

After a successful create from Home, the sheet’s existing `createSession` already selects the new session. Then call `ConsoleNavigation.showSessions()` so the first prompt is typed on the Sessions page, not from Home.

### Creation sheet hook

`NewClaudeSessionSheet` currently dismisses on success and does nothing else (correct for the Sessions page). Add an optional `var onCreated: (() -> Void)? = nil`. Home passes `{ ConsoleNavigation.showSessions() }`. Sessions keeps the default.

Do not duplicate the sheet.

### UITest preview flag

Today `-uiTestSessionsPreview` both injects fake sessions **and** selects the Sessions sidebar (`ConsoleApp.swift`). Home tests need injected sessions while staying on Home.

Add `-uiTestHomeSessionsPreview` that calls `injectUITestPreviewSessions()` and does **not** change `sidebarSelection`. Do not change the existing Sessions preview flag or the Alpha/Beta fixture names (`Preview Alpha`, `Preview Beta`) — `SessionsUITests` depends on them.

### Platform

macOS 26, SwiftUI, no new frameworks, no version gates. `SessionStore` is `@Observable` and already in the environment. No persistence, no network, no WebKit in this panel.

## Alternatives Considered

- **Mini-terminal in the quadrant.** Rejected: unusable at the 160pt panel minimum; the Sessions destination already hosts the persistent PTY.
- **Reuse `SessionListRow` unchanged.** Rejected: that row is a process-manager (stop/remove, no summary). Home needs summary + artifacts and must not expose destructive actions.
- **Attention-only filter.** Rejected: hiding Idle/Working makes it too easy to start a duplicate session in the same repo. Typical count is 1–4 sessions; show all, sorted.
- **Group by working directory.** Rejected: overkill at the session counts this app will have.
- **Stop / remove from Home.** Rejected for v1: stop already has a two-step confirmation on Sessions; a dashboard misclick is expensive. Remove-exited can be added later.
- **Include Done in “needs you”.** Rejected: Done is a “look when ready” state, already obvious as a green row. “Needs you” is reserved for states that block the agent.

## User Experience

1. Open Console → Home. Sessions quadrant is empty or lists live sessions.
2. Empty: **New Claude Session** is the primary action. Header **Open Sessions** still works.
3. Non-empty: scan state color and the optional `needs you` suffix, then click a row.
4. Clicking a row leaves Home and shows that session’s terminal.
5. Creating from Home leaves Home after success and shows the new terminal.
6. Returning to Home is the existing sidebar Home item. This assignment does not add a back control on the Sessions page.

Loading/error: there is no network. The panel always reflects `SessionStore.sessions`. Bridge-unavailable sessions still appear with whatever activity/attention the store has; do not add a second empty/error state for the bridge.

## User Interface

Match JIRA card density so the 2×2 grid stays even with the bottom terminal expanded. The card floor is **44pt, growing to content** (shared `HomeCardMetrics`; Design/HomeCards/DESIGN_PROMPT.md §3). A summary-less session with no artifacts is a two-line card.

### Header

```text
Sessions  3 · 1 needs you                        [+]  [window]
```

- Title uses the existing panel name `Sessions`. No service subtitle (unlike JIRA/GitLab).
- Count is the total session count, including exited rows still in the store.
- `· N needs you` appears only when `needsYouCount > 0`, in the needs-you red.
- `+` opens the intent picker (help: “New Claude Session”).
- **Open Sessions** is the icon-only `macwindow.on.rectangle` glyph (help + accessibility label: “Open Sessions”), parallel to JIRA’s “Show JIRA” and the MR panels’ “Show GitLab”. Keep the accessibility label explicit.
- One header per panel, owned by the panel itself; the container renders no header. 28pt, one row: title, then the quiet count run, then icon-only actions.

### Empty state

Centered, quiet, same tone as the Sessions destination empty list:

- `terminal` symbol, tertiary
- “No Claude Sessions”
- Button **New Claude Session** (`.controlSize(.small)`)

Accessibility identifier: `HomePanelSessions.EmptyState`.

### Row

Drawn to the shared Home card grammar (Design/HomeCards/DESIGN_PROMPT.md §3). Needs-approval card with artifacts:

```text
● Needs Approval                          ›
  AntivirusGodot
  Asking to run git push to origin   [PROJ-412] [!88]
```

Working, no summary, name equals folder:

```text
● Working                                 ›
  Pufferfishh
```

Working, no summary, name differs from folder (`Folder 2`):

```text
● Working                                 ›
  Pufferfishh
  Folder
```

- Leading 6pt state dot uses the shared `AttentionChannel` tint; the state label is tinted text beside it (semibold when `needsYou` is true) — the state label doubles as the identity token because sessions have no key.
- Name: the card title, 13pt medium, at the dashboard's fixed x-origin, two lines maximum. Never right-aligned.
- Row three merges folder-or-summary (10pt monospace, leading) with the artifact chips (trailing). Omitted entirely when there is nothing to say.
- Artifact chips: filled capsules, max two, then `+N`. Capsules mean a linked object. Do not make chips independently tappable in this phase; the whole card is one button.
- The reserved 16pt trailing slot on the title row carries the jump chevron at 30% opacity (100% on hover). It is decoration inside the single card button — never a nested control.
- States for which `needsYou` is true get a one-point red inset on the card.
- The card is one `Button` → select + `showSessions()`.
- One coherent accessibility element: name, folder if shown, state, summary if shown, “needs attention” when `needsYou` is true.
- Identifier: `HomeSessionCard.<session.name>` (parallel to `SessionRow.<session.name>`).

The whole card is the jump target. No nested buttons.

### Overflow

If sessions exceed the quadrant, scroll inside the panel (`ScrollView` + `LazyVStack`). Do not invent a “top N” model or a “N more” footer.

## Edge Cases

- **Zero sessions.** Empty state, not the numbered placeholder.
- **One session, any state.** Single card, header count `· 1`.
- **Duplicate names.** Store already suffixes `Folder 2`. Accessibility identifiers use the unique name. If a future collision happens, identifier uniqueness is best-effort; do not block on it.
- **Exited sessions.** Still listed (gray, last). Clicking still jumps to Sessions so scrollback can be read. No remove control on Home.
- **Session disappears while Home is visible.** Observation removes the row. No crash if the selected id is gone.
- **Create cancelled.** Sheet dismisses; stay on Home.
- **Create failed** (Claude not found, plugin assembly). Sheet already surfaces the error; stay on Home.
- **Minimum window / expanded terminal.** Home already scrolls as a canvas with 160pt panel minimums. Cards must remain readable; truncate text rather than shrinking below a usable row height.
- **Dynamic Type / accessibility sizes.** Follow `HomeView`’s existing taller rowHeight for accessibility sizes. Cards may grow; the panel scrolls.
- **No summary, no artifacts, name == folder.** One-line card is fine.
- **Bridge unavailable.** Still show the session; do not add a Home-specific bridge banner.

## Side Effects

- `CONSOLE_TERM_COMM.md` §8 currently says Home Panel 2 stays a placeholder. Update that bullet to point at this document and describe the radar + jump behavior.
- `HomeView` grows a Sessions branch next to the existing JIRA branch. GitLab placeholders stay.
- `NewClaudeSessionSheet` gains an optional callback; Sessions behavior must remain identical when the callback is nil.
- `ConsoleApp` DEBUG launch-argument handling gains one flag. Existing `-uiTestSelectSessions` / `-uiTestSessionsPreview` must keep selecting Sessions.
- No change to session persistence (still none), hooks, MCP bridge, or prompt submission.
- Future “Start Agent” on a JIRA card is still out of scope; leave visual room in the JIRA card as that plan already requires, but do not wire it here.

## Testing Strategy

Prefer `ConsoleTests` for presentation rules. Use targeted UITests only for launch, empty state, and the Home → Sessions hop. Never run the full `ConsoleUITests` scheme. From `Console/` (the directory that contains `Console.xcodeproj`):

### Unit (`ConsoleTests`)

`HomeSessionsPresentationTests`:

- Sort order follows `priorityRank` (approval before working before exited); store order breaks ties.
- `needsYouCount` counts approval/input/blocked/needsReview/error and excludes done/working/idle/starting/exited/unknown.
- Subtitle prefers summary; falls back to folder basename only when it differs from name; omits when they match and summary is nil.
- Empty array → count 0, sorted empty.

Do not launch Claude. Use in-memory `ConsoleSession` values. If constructing a real `LocalProcessTerminalView` in unit tests is painful, add a test seam (a lightweight `HomeSessionSnapshot` the helper sorts, mapped from `ConsoleSession` in the view) rather than spinning PTYs. Keep the seam in the presentation file, not a second store.

### UI (`ConsoleUITests/HomeSessionsUITests`)

Launch arguments only, no real Claude:

1. Default launch (Home): `HomePanelSessions` exists; `HomePanelSessions.EmptyState` exists; GitLab placeholders still present; JIRA panel still present.
2. `-uiTestHomeSessionsPreview`: `HomeSessionCard.Preview Alpha` and `HomeSessionCard.Preview Beta` exist on Home. Alpha appears above Beta (working before exited).
3. Tap Alpha → Sessions destination shows `SessionRow.Preview Alpha` selected (`Sessions.Header` / existing Sessions identifiers).
4. Tap header **Open Sessions** from empty Home → Sessions empty state.
5. Tap `HomePanelSessions.NewSessionButton` from empty Home → `SessionNameField` appears; cancel returns to Home empty state.

Run only:

```bash
xcodebuild test -project Console.xcodeproj -scheme ConsoleTests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleTests/HomeSessionsPresentationTests

xcodebuild test -project Console.xcodeproj -scheme ConsoleUITests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleUITests/HomeSessionsUITests
```

If `HomeSessionsPresentationTests` is folded into an existing test class, keep `-only-testing` pointed at that class. Also run any existing Sessions UITest that would break if the preview flag or Alpha/Beta fixtures change:

```bash
xcodebuild test -project Console.xcodeproj -scheme ConsoleUITests \
  -destination 'platform=macOS' \
  -only-testing:ConsoleUITests/SessionsUITests
```

### Manual

Two named sessions in different folders: Home lists both, waiting state floats, click jumps, create-from-Home lands on the new terminal, empty state after quit/relaunch.

## Open Questions

None blocking. Settled in the design conversation:

- Jump-only rows, plus New Session from the header.
- After create from Home, navigate to Sessions.
- No process control on Home for v1.
- Show all sessions, sorted; do not filter to attention-only.
- Done is listed but not counted as “needs you.”

If implementation discovers that `LocalProcessTerminalView` cannot be constructed in unit tests, use the snapshot seam described above — that is an implementation detail, not a product change.

## Out of Scope

- Embedding a terminal in the Home quadrant.
- Stop, force-stop, or remove from Home.
- Starting an agent from a JIRA or GitLab card.
- Persisting sessions across launch.
- Artifact chips as navigation to JIRA/GitLab.
- A back-to-Home control on the Sessions page.
- Badging the sidebar Sessions item.
- GitLab Home quadrants.
- Changing JIRA panel behavior.

---

## Implementation Kickoff Prompt

Paste the following into a new Cursor session:

```text
Implement Console Home Panel 2 (top-right Sessions radar) per CONSOLE_PANEL_2_SESSIONS.md. Read that document first and follow it. Also read CONSOLE_TERM_COMM.md (Sessions source of truth; §8 currently says Panel 2 stays a placeholder — update that bullet), Console/Console/Home/Views/HomeView.swift, HomePanelContainer.swift, SessionStore.swift, SessionModels.swift, SessionListRow.swift, SessionsView.swift, NewClaudeSessionSheet.swift, ConsoleNavigation.swift, ConsoleApp.swift (DEBUG launch args), and ConsoleUITests/SessionsUITests.swift.

Goal: replace only the Home Sessions placeholder with a live attention radar backed by the existing SessionStore. This is a launcher, not a second Sessions page.

Do:
- Add HomeSessionsPresentation (sort by displayed-state priority, needs-you count, subtitle rules) and unit tests.
- Add HomeSessionsPanelView in the top-right quadrant: custom header (count, optional “needs you”, +, Open Sessions), empty state, scrollable cards.
- Card shows state dot + label, name, summary-or-distinct-folder, up to two artifact chips. Whole card is one button: store.select + ConsoleNavigation.showSessions().
- Optional onCreated on NewClaudeSessionSheet; Home navigates to Sessions after successful create; Sessions destination behavior unchanged.
- New DEBUG flag -uiTestHomeSessionsPreview: injectUITestPreviewSessions() without selecting the Sessions sidebar.
- Targeted tests only (HomeSessionsPresentationTests + HomeSessionsUITests). Do not run the full UITest suite. Do not break SessionsUITests preview fixtures (Preview Alpha / Preview Beta).
- Extract shared displayed-state tint so Home and SessionListRow cannot drift.

Do not:
- Embed a terminal in the Home quadrant.
- Add stop/remove/force-stop on Home.
- Touch JIRA panel behavior or GitLab placeholders beyond HomeView’s Sessions branch.
- Persist sessions, add network, or start agents from JIRA/MR cards.
- Run xcodebuild test without -only-testing, and never test the Console scheme (it pulls in UITests).

Verify with the commands in CONSOLE_PANEL_2_SESSIONS.md Testing Strategy. Leave the tree ready for review; do not commit unless I ask.
```
