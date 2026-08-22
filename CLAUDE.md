# Console — Agent Instructions

## Two JIRA instances. Never confuse them.

Console work touches two entirely separate Atlassian instances. They have
different rules. Before any JIRA-related action, identify which one you are
dealing with.

### 1. The company JIRA instance

This is the instance the Home panel renders in the embedded `WebPage`
(`Console/Console/Jira/`), configured by the user at runtime via the
`Web View JIRA URL` setting.

- **Never** reach this instance through the `atlassian` MCP server, the JIRA
  REST API, `URLSession`, `curl`, or injected `fetch`/XHR.
- The only permitted access is reading the DOM that JIRA has already rendered
  in the WebView, via `WebPage.callJavaScript`.
- Never send its content to Claude, another LLM, an MCP server, analytics, or
  any external service. Never persist or commit it.
- The full, binding constraints are in `CONSOLE_PANEL_1_JIRA.md`
  ("Non-Negotiable Security Boundaries"). Read that file before touching
  anything under `Console/Console/Jira/`.

### 2. The personal Atlassian Cloud site

This is Christopher's own site, reached through the `atlassian` MCP server
(user-scoped, OAuth). It is the site that MCP server is authenticated against —
it is never the company instance.

Use it freely for:

- Tracking Console development work (epics, stories, bugs).
- Generating **synthetic** ticket fixtures for tests and for exercising the
  JIRA panel's extraction logic.
- Any read/write the MCP server exposes.

Nothing from the company instance may ever be copied into this site.

### Rule of thumb

MCP + REST → personal site only.
DOM read in the WebView → company instance only.
No content crosses between them.
