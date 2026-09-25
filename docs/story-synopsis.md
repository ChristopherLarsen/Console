# Review Synopsis

Next up cards on Home have a **Review Synopsis** button. It opens a modal with a
plain-language TL;DR of the story, 150 words or fewer.

## Data boundary

Christopher explicitly authorized, on 2026-09-24, sending JIRA story text to Claude
and caching the resulting synopses on disk, for both the personal site and the
company JIRA instance. This is the only JIRA path that does so; `JiraLLMPolicyGate`
still blocks every other LLM transport for the company instance.

- **Collection is DOM-only.** `JiraIssueDetailReader` loads the issue URL in a fresh
  offscreen `WebPage` sharing the JIRA sign-in and reads rendered text (summary,
  description, type, rich-text custom fields such as acceptance criteria) with
  `callJavaScript`. No REST, fetch or XHR. The pinned JIRA tab is never touched.
- **Generation** uses Console's managed Claude access (`sonnet`), ephemeral, with no
  tools and no MCP. The story is passed as JSON data, not instructions.
- **Cache:** `~/Library/Application Support/Console/StorySynopses.json`, keyed by JIRA
  host plus issue key. Only the synopsis text is stored, never the story itself.
  Each story is summarized once.
- **Deletion:** when a JIRA extraction lands, synopses for stories now In Progress are
  deleted, and, when the list is current, synopses for stories no longer on it.
