# Console — Security Boundaries (BINDING)

These rules are non-negotiable. They come from `CLAUDE.md` and the
"Non-Negotiable Security Boundaries" sections of `CONSOLE_PANEL_1_JIRA.md` /
`CONSOLE_PANEL_3_GITLAB.md`. If a task seems to require breaking one, STOP and
escalate to Christopher instead.

## 1. The two-JIRA-instances rule (and its GitLab twin)

There are two entirely separate instances of each service. Never confuse them:

| | Company instance (JIRA + GitLab) | Personal site |
|---|---|---|
| What | The JIRA/GitLab rendered inside Console's WebViews; configured at runtime by the user | `deadratgames.atlassian.net` + personal gitlab.com namespace |
| Access | ONLY by reading DOM already rendered in the WebView (`WebPage.callJavaScript`) | Free: `atlassian` MCP server, REST via MCP, browser — whatever dev needs |
| Data handling | Never send content to Claude/any LLM/MCP/analytics/external service. Never persist or commit it. Never log URLs (private hosts). | Synthetic fixtures may be freely read, screenshotted, discussed, committed |

Rule of thumb: **MCP + REST → personal site only. DOM read in the WebView →
company instance only. No content crosses between them.**

Christopher signs into company instances himself (credentials + MFA). Never
request, capture, print, commit, or transmit company credentials, cookies, raw
DOM, ticket/MR content, project paths, employee names, or screenshots of them.
The company laptop and network are monitored; the implementation must be
defensible under review.

## 2. Implementation constraints (never relax, regardless of instance)

Console itself must NEVER acquire:

- A REST/GraphQL client for JIRA or GitLab (`URLSession`, `curl`, shell calls to these services)
- Cookie reading, export, copy, or replay from WebKit
- Injected `fetch` / `XMLHttpRequest` / hidden API navigations / undocumented endpoints
- `customUserAgent` or Safari user-agent spoofing
- An AI data path for ticket/MR retrieval (AI is for Brief/Next/commands, not panel data)
- Persistence of ticket/MR content (no SwiftData, UserDefaults, files, snapshots, logs)
- Automatic scrolling/paging/reloading to force virtualized rows to load

If reliable cards cannot be produced within these constraints, leave the real
page usable and report the limitation. Do not silently broaden the approach.

**Company-data constraints do NOT apply to synthetic fixtures** on the personal
sites — that content is invented and is the intended source of committed test
data (scrub the site hostname from committed HTML).

## 3. Sessions bridge privacy

Per `CONSOLE_TERM_COMM.md`:

- The `ConsoleTermBridge` helper forwards ONLY reduced lifecycle envelopes:
  session id, event kind, small bounded payloads. Never prompts, tool
  arguments, assistant messages, transcript paths, or raw hook JSON.
- Hook handlers are async and always exit 0 — instrumentation must never delay
  or change Claude's behavior.
- Socket lives in a `0700` ephemeral dir; peer credentials verified with
  `getpeereid(2)`; per-session random token; ≤ 8 KiB envelopes; idempotent event ids.
- Only the three exact qualified MCP tool names are preapproved — no wildcards.
- Nothing about message content is ever logged.

## 4. General data hygiene

- No secrets in code or commits — API keys live in the Keychain.
- Before finishing any task touching panels/sessions: review the diff for
  company data, real URLs, debug output, raw DOM, secrets, snapshots.
- Ticket values never appear in `print`, assertions, crash messages,
  accessibility identifiers, or analytics. Accessibility LABELS shown to the
  user may mirror visible card text; identifiers may not carry it.
- Starter prompts and summaries are memory-only — not persisted, logged, or
  placed in process arguments/environment.

## 5. When boundaries seem to block legitimate work

Escalate. Say which boundary blocks what, and propose an alternative that
respects it. Do not implement first and ask later. Explicit company approval is
required before ANY REST/OAuth integration with company services can even be
considered (see "Alternatives Considered" in the panel specs).
