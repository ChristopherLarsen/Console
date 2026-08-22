# Console JIRA Panel — Synthetic Fixtures

Synthetic tickets on the **personal** Atlassian site (`deadratgames.atlassian.net`,
project `SCRUM`). Entirely invented. No company data. See `CLAUDE.md` for the
two-instance boundary — these fixtures exist so the JIRA panel can be built and
tested without touching the company instance.

## Configuring Console against them

Set `Web View JIRA URL` in Settings to a My Tickets list on the personal site:

```
https://deadratgames.atlassian.net/issues/?jql=assignee%20%3D%20currentUser()%20ORDER%20BY%20created%20DESC
```

**Verified 2026-08-21** via `searchJiraIssuesUsingJql`: that JQL returns exactly
the 16 fixtures, in order `SCRUM-21` down to `SCRUM-6`. `SCRUM-1`–`SCRUM-5` are
Atlassian's onboarding samples, are unassigned, and are correctly excluded.

The *filter semantics* above are verified. The *URL path* is not — it was not
loaded in a browser. If `/issues/?jql=` 404s on this team-managed project, the
team-managed route is:

```
https://deadratgames.atlassian.net/jira/software/projects/SCRUM/issues?jql=assignee%20%3D%20currentUser()%20ORDER%20BY%20created%20DESC
```

## What each fixture exercises

`JiraTicketSummary` carries `key`, `summary`, `status`, `priority`,
`updatedText`, `issueURL`, `sourceOrder`. Variation is concentrated there;
assignee, labels, due date, and epic grouping are not extracted, so they are
not varied. Labels are used only to tag the fixtures themselves.

### Summary-parsing edge cases

| Key | Label | Exercises |
| --- | --- | --- |
| `SCRUM-6` | `edge-short-summary` | Minimal summary (`Fix`) — layout with almost no text |
| `SCRUM-7` | `edge-markup-escaping` | `<b>`, `&`, `"`, `<script>` in the summary — the extractor must use `textContent`, never `innerHTML` |
| `SCRUM-8` | `edge-unicode-cjk` | Emoji + CJK + em dash — multi-byte handling, grapheme-safe truncation |
| `SCRUM-9` | `edge-diacritics` | Combining marks / precomposed accents |
| `SCRUM-10` | `edge-rtl-bidi` | Arabic + Latin in one row — bidirectional layout |
| `SCRUM-11` | `edge-long-summary` | 241 chars (Jira's cap is 255) — truncation and wrapping |
| `SCRUM-12` | `edge-whitespace` | Repeated spaces and literal tabs — whitespace normalisation |
| `SCRUM-13` | `edge-key-in-summary` | Contains the literal text `SCRUM-999`. **The extractor must take the key from the row's own key element, not by regex over row text.** A naive `/[A-Z]+-\d+/` match returns the wrong key here. |
| `SCRUM-14` | `edge-punctuation` | Delimiter characters (`,` `|` `/` `:` `;` `]` `}`) that break naive string splitting |
| `SCRUM-15` | `edge-punctuation-only` | Summary is a single em dash — non-empty but semantically blank |

### Realistic rows

`SCRUM-16` … `SCRUM-21` read like ordinary Console tickets, so the panel can be
eyeballed for whether it looks right, not just whether it parses.

## Status and priority coverage

This project's workflow is **Backlog → Next Up → In Progress → In Review →
Testing**. There is no `Done` status; `Testing` sits in the `done` status
category. Multi-word status names are themselves a useful fixture.

| Status | Keys |
| --- | --- |
| Backlog | 6, 8, 9, 10, 12, 14, 15, 18 |
| Next Up | 7, 13 |
| In Progress | 16, 19 |
| In Review | 11, 17 |
| Testing | 20, 21 |

All five priorities appear: Highest (13, 16), High (7, 17, 19), Medium (8, 10,
11, 14, 18), Low (9, 12, 20), Lowest (6, 15, 21).

## `sourceOrder`

With `ORDER BY created DESC` the expected row order is fully determined, because
keys were assigned sequentially at creation:

```
SCRUM-21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6
```

The spec requires cards to render "in the same order as the configured JIRA My
Tickets list", so this sequence is directly assertable against `sourceOrder`.

## Known gap: `updatedText`

Every fixture was created within minutes of the others, so all rows render
effectively the same relative "updated" text. Distinguishing that parse needs
either a synthetic-DOM unit test or edits spread over time. Do not treat a live
run against these fixtures as coverage of `updatedText`.
