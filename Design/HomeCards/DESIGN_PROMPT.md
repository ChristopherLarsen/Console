# Home dashboard card redesign — implementation brief

You are implementing a visual redesign of the four Home dashboard panels in the
Console macOS app. The design is already done. This file is the specification;
`images/` is what it should look like.

Read this whole file before editing anything. Sections marked **Constraint** are
non-negotiable and are the fastest way to break the build if ignored.

---

## 1. What is in this folder

| Path | What it is |
| --- | --- |
| `images/*.png` | The design, rendered. `-light` and `-dark` for each board. **This is the reference.** |
| `artboards/*.dc.html` | Editable source for each board, plus `canvas.json` for the pan/zoom layout. |
| `preview/*.html` | The same boards as standalone pages you can open in a browser. |
| `preview/build-previews.mjs` | Regenerates `preview/` from `artboards/`. |
| `render.sh` | Regenerates `images/` from `preview/` using headless Chrome. |
| `console-home-card-redesign.html` | The whole canvas in one file. Open it in a browser. |

Read the boards in this order:

1. **Main** — the shared card grammar. Everything else is an instance of it.
2. **Audit** — what ships today and why each part of it is wrong.
3. **Ticket**, **MergeRequest**, **Session** — before/after per card type.
4. **Chrome** — panel headers and the four states that are not a list.

If you change the design, change the `.dc.html` source and re-run
`node preview/build-previews.mjs && ./render.sh` so the images stay true.
Do not hand-edit files in `preview/` or `images/`.

---

## 2. The idea, in one paragraph

Home is a triage surface. Four panels, one question each — *what is my work*,
*does an agent need me*, *who is waiting on my review*, *what of mine is in
flight* — and each is answered by scanning a column top to bottom. The scan unit
is the **column**, not the card. So every card in every panel puts its attention
signal, its identity token, its title and its age in the same place, and the
skeleton never varies. Only which optional fields survive varies, by panel.

Everything below follows from that. When a detail here seems arbitrary, it is
usually protecting the column.

---

## 3. The card grammar

Two required rows, one optional third.

```
● SCRUM-19  In Progress                                    38m     ← row 1
  Terminal bridge drops the first prompt after a cold launch  [⌘]  ← row 2
  console-ios · Dana Reyes                          [SCRUM-19]     ← row 3 (optional)
```

**Row 1** — attention dot, identity, state, spacer, age.

- **Dot**: 6pt circle at a fixed leading x. The only coloured channel on the
  card. Its meaning is identical in all four panels (see the mapping below).
- **Identity**: monospaced, 10pt, secondary. `SCRUM-19`, `!5`, or — on session
  cards, which have no key — the state label itself.
- **State**: tinted **text**, 10pt medium. Never a filled capsule.
- **Age**: relative, right-aligned, tabular numerals, 10pt tertiary.

**Row 2** — title plus a permanently reserved trailing action slot.

- **Title**: 13pt medium, label colour, at the card's left padding. This is the
  one element with real size, and its x-origin is identical on every card in the
  dashboard. Wraps to a second line only when it needs one.
- **Action slot**: fixed 16pt, always reserved even when empty. 30% opacity at
  rest, 100% on card hover. Reserving the space is the point — it is what makes
  the current occlusion bug structurally impossible rather than tuned away.

**Row 3** — optional context. Present only when there is something to say.

### Colour mapping

One function, one file, called by all three card views. Today the tint is
decided in three separate places and means three different things.

| Dot | Meaning | Ticket status | MR condition | Session state |
| --- | --- | --- | --- | --- |
| red | Needs you | Blocked | pipeline failed | Needs Approval / Needs Input / Blocked / Needs Review / Error |
| orange | In flight | Testing, In Review | pipeline running or pending | — |
| blue | Active | In Progress | — | Working |
| green | Clear | Done | pipeline passed | Done |
| grey | Parked | Backlog, To Do | draft | Idle, Starting, Exited, Unknown |

`DisplayedSessionState` already owns the session column of this table. Extend
outward from it rather than writing a second mapping beside it.

Precedence when an MR has more than one condition:
`failed > blocked > running > draft > passed`.

### Shape vocabulary

- **Tinted text** means a workflow state.
- **A filled capsule** means a linked object — a ticket, an MR.

These must not be confused. That is why the ticket card's grey status capsule
becomes plain tinted text, and why the session card's artifact chips stay
capsules.

### Surfaces

- Card fill: `controlBackgroundColor`. **No stroke.**
- List background behind the cards: `windowBackgroundColor`.
- Corner radius 6pt on cards, 9pt on the panel.
- Hover: a one-point accent inset. Focus ring: unchanged from today.
- In dark mode the relationship inverts — cards read as recessed rather than
  raised. That is native AppKit behaviour and is intentional; do not "fix" it.

### Metrics

- Card padding `9 / 7 / 9 / 8`, internal row gap 3pt, gap between cards 4pt.
- Minimum card height 44pt, growing to content.
- Panel header 28pt, one row.

---

## 4. Per-panel work

Line numbers drift the moment the first change lands, so everything below is
anchored to **symbols**. Grep for them.

### 4.1 Ticket card — `Console/Console/Jira/Views/JiraPanelView.swift`

Symbols: `JiraTicketCard`, `JiraTicketCard.body`, `priorityTint`,
`JiraPanelView.ticketList(_:refreshedAt:staleReason:)`, `panelHeader`.

1. **Fix the occlusion.** `JiraTicketCard.body` is a
   `ZStack(alignment: .topTrailing)` whose second child — the session button —
   lands on top of row one's trailing `Text(priority)`. Remove the `ZStack`.
   The session button becomes a sibling of the title inside row two, in the
   reserved 16pt slot. This is the only defect a user can currently see, and it
   is worth landing on its own.
2. **Status leads.** Status drives the dot and becomes tinted text. Delete the
   `Capsule().fill(...quaternarySystemFill)` background.
3. **Priority demoted.** A single caret glyph at the leading edge of row one,
   drawn **only** for `High` and `Highest`. `Medium` and below are omitted
   entirely. `priorityTint` collapses to red / orange / nothing.
4. **Relative age.** See §5 on time.
5. **Density.** Drop `lineLimit(2, reservesSpace: true)` and `minHeight: 72`.
   Two lines maximum, but not reserved.
6. **Surfaces.** Strip the card's `RoundedRectangle.strokeBorder`; give the
   `ScrollView` behind the `LazyVStack` a `windowBackgroundColor` background.

### 4.2 Merge-request card — `Console/Console/CodeHost/Views/MergeRequestCardView.swift`

Symbols: `MergeRequestCardView.cardBody`, `eyebrow`, `statusCues`, `footerText`,
`symbolForPipeline`, `colorForPipeline`.

1. **Dissolve the eyebrow.** `eyebrow` currently joins project and iid on their
   own row, so a nil `projectDisplayName` renders `!5` alone on a whole line.
   The iid moves into row one as the identity token; the project moves to the
   optional row three.
2. **Author by panel.** The card gains a `CodeHostListKind`. In
   `.reviewsRequested` the author is the routing signal and stays. In
   `.authored` every row is the same person — drop row three entirely and the
   card is two lines tall.
3. **One state, not two cues.** `statusCues` currently renders Draft *and* a
   pipeline state competing for the same corner. Replace with a single state per
   the precedence rule in §3. `colorForPipeline` folds into the shared mapping.
4. **The action slot** carries an explicit open-in-host glyph. (A future
   start-session action on MR cards fits this same slot — there is already one
   in the full-page browser view, `MergeRequests.StartSessionButton` in
   `MergeRequestsBrowserView.swift`. Do not wire it up here.)

### 4.3 Session card — `Console/Console/Home/Views/HomeSessionsPanelView.swift`

Symbols: `HomeSessionCard`, `HomeSessionCard.body`, `chipRow`,
`HomeSessionsPanelView.header`.

1. **The name becomes the title.** Today `session.name` is right-aligned in the
   trailing corner of row one, so it starts at a different x on every row and
   truncates from a floating edge — the one field you are scanning for is the
   one you cannot scan. Move it to the title slot at the fixed x-origin, 13pt
   medium.
2. **Merge the subtitle and chip rows.** Folder or summary on the left in
   monospace, artifact chips right-aligned, one row. `minHeight` 56 → 44.
3. **Needs-you reads at a glance.** States for which
   `HomeSessionsPresentation.needsYou` is true get a semibold state label and a
   one-point red inset on the card. The predicate already exists; the card just
   has to show it.
4. **The jump chevron** goes in the reserved slot. **Constraint:** it is
   decoration inside the single card button, not a nested control —
   `CONSOLE_PANEL_2_SESSIONS.md` requires the whole card to be one button.

### 4.4 Panel chrome — `HomeView.swift`, `HomePanelContainer.swift`, `MergeRequestsPanelView.swift`

Symbols: `HomeView.panel(_:)`, `HomePanelContainer.header`,
`MergeRequestsPanelView.chromeHeader`, `JiraPanelView.panelHeader`,
`HomeSessionsPanelView.header`.

1. **One header per panel.** `HomeView.panel(_:)` passes
   `showsHeader: panel != .jiraTickets && panel != .sessions`, so each MR panel
   renders the container's header *and* its own `chromeHeader` directly beneath
   it — the same words twice, and roughly 30pt of a panel that currently shows
   four of its rows. Pick one owner. The recommended shape: the container owns
   the single 28pt header and exposes a trailing accessory slot that each panel
   fills with its own actions.
2. **Header content**: title (13pt semibold), then service and count as one
   quiet 10pt run, then icon-only actions. "Show GitLab" / "Show JIRA" become a
   window glyph with a tooltip — the words cost a third of the header width in a
   panel whose minimum is 160pt.
3. **The four non-list states** are on the Chrome board:
   - *Loading*: skeleton bones in the shape of the real card — a short bone
     where the identity goes, a long one where the title goes — not the current
     featureless 64pt blocks.
   - *Empty*: quiet. It is a positive result and must never borrow the language
     of failure.
   - *Stale*: an amber strip under the header naming the age of what you are
     looking at, plus a Retry action. Cards below stay at full strength — they
     are old, not wrong.
   - *Sign-in*: a pointer at the live page underneath, not a wall.

---

## 5. Time

The dashboard currently speaks two time languages: JIRA cards print an absolute
timestamp (`Aug 21, 2026, 11:34 PM`), GitLab cards print `updated 4 hours ago`.
Cards show **relative** age only — `38m`, `4h`, `2d`.

Both `JiraTicketSummary.updatedText` and `MergeRequestSummary.updatedText` are
strings scraped from whatever the host rendered. Parse them locally to a `Date`
and format relative. **When a string will not parse, fall back to showing it
verbatim** — never drop the field and never invent a date.

**Constraint:** do not reach for the JIRA REST API, `URLSession`, `curl`, or an
injected `fetch` to get a real timestamp. The ticket panel reads the DOM the
company JIRA instance has already rendered, and nothing else. See `CLAUDE.md`
and the "Non-Negotiable Security Boundaries" section of
`CONSOLE_PANEL_1_JIRA.md`. This is a hard boundary, not a preference.

---

## 6. Constraints

**Accessibility identifiers and labels are the test contract. Do not change
any of them.** The UI tests key on exact strings, and renaming one is the
easiest way to break the build silently. This includes, at minimum:

```
HomeDashboard
HomePanelJiraTickets · HomePanelSessions · HomePanelGitLabMRsToReview · HomePanelGitLabMyMRs
JiraTicketCard.<index> · JiraTicketCard.StartSession
JiraPanelHeader · JiraPanelRefreshButton · JiraPanelShowJIRAButton · JiraPanelShowCardsButton
JiraPanelStaleBanner · JiraPanelSkeletons · JiraPanelEmptyState · JiraPanelFooterTimestamp
JiraPanelAuthenticationNotice · JiraPanelUnsupportedState · JiraPanelFailureState
HomeSessionCard.<uuid> · HomePanelSessions.Header · HomePanelSessions.NewSessionButton
HomePanelSessions.OpenSessionsButton · HomePanelSessions.EmptyState
GitLabPanelRefreshButton · GitLabPanelShowGitLabButton · GitLabPanelUnconfiguredState
<idPrefix>LoadingState · <idPrefix>StaleNotice
```

If a redesign genuinely requires a new element, give it a **new** identifier;
do not repurpose an existing one.

Cards must also keep their current accessibility behaviour: one coherent element
per card (`.accessibilityElement(children: .ignore)` plus a composed label), and
the same accessibility actions. A field you moved visually still belongs in the
label.

**Preserve host order.** Cards render in the order JIRA and GitLab rendered
their rows. Do not apply a second Console-side sort. The one exception already
in the codebase is the Sessions radar, which is attention-sorted by
`HomeSessionsPresentation.sorted` — that stays.

**Omit unavailable fields; never guess and never print "Unknown".** The
"omit Medium and below priority" rule in §4.1 is a deliberate *extension* of
this — it drops a value that was present but carries no signal. It is a design
decision, not a bug; leave a comment saying so.

**Dynamic Type.** `HomeView` already grows row height at accessibility sizes.
Cards may grow and the panel scrolls; truncate rather than shrinking below a
usable row height.

**Do not commit.** Leave the work on a branch and let Christopher review. The
repo's default branch is `main`.

---

## 7. Suggested order

Each step is independently shippable and independently reviewable.

| # | Step | Scope | Done when |
| --- | --- | --- | --- |
| 1 | Unblock the priority — session button out of the `ZStack` into a reserved slot | 1 file | Priority text is fully readable on every ticket card at the narrowest panel width |
| 2 | One header per panel | 2 files | No panel renders its title twice; header is one 28pt row in all four |
| 3 | Strokes off, tray background on | 3 files | Cards separate from the panel by contrast, in both appearances |
| 4 | One shared status→tint mapping | 1 new file | No card view decides a state colour locally |
| 5 | Rebuild the row to the grammar | 3 files | Titles share one x-origin and one size across all four panels |
| 6 | Density: drop the reserved line and the height floors together | 3 files + doc | The 2×2 grid still reads even with the bottom terminal expanded |

Run the existing suites after each step — `HomeSessionsPresentationTests`,
`JiraPanelControllerTests`, `CodeHostListPanelControllerTests`,
`MergeRequestListExtractorTests`, and the UI tests including
`HomeSessionsUITests`. Steps 1 and 5 are the ones most likely to disturb them.

---

## 8. Documentation this change makes stale

Update these in the same branch. A spec that contradicts the app is worse than
no spec.

- `CONSOLE_PANEL_2_SESSIONS.md:149` — "Aim for roughly a 64–72pt card" and
  "match JIRA card density". The new floor is 44pt. Density parity between the
  two panels is still the requirement; the number changes.
- `CONSOLE_PANEL_1_JIRA.md:308` — "Do not add a nonfunctional Start Agent button
  in this phase." That button now exists and is wired to
  `SessionLaunchCoordinator`. The line is stale and should not be read as
  blocking the reserved action slot.
- `CONSOLE_PANEL_1_JIRA.md` card sketch (~line 299) and
  `CONSOLE_PANEL_3_GITLAB.md` card sketch (~line 307) — both show the old
  three-line layout. Replace with the grammar in §3.

---

## 9. Open question, not part of this work

`ConsoleSession` has no timestamp, so the age column at the right edge of the
session card is empty. Adding `lastActivityAt: Date` to `ConsoleSession` and
maintaining it from the bridge would complete the column across all four panels.
That is a model and state-plumbing change, not a visual one. Raise it; do not
fold it into this branch.
