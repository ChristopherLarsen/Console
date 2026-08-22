# Console Terminal Communication and Sessions — Architecture

This document is the implementation source of truth for the Sessions milestone.
**Sessions** is a sidebar destination supporting zero or more concurrent Claude
Code terminals. It coexists with the global bottom `zsh` Terminal drawer, which
remains global chrome on every main-window destination.

Communication uses exactly three mechanisms:

1. **SwiftTerm PTY** for terminal input and process control.
2. **Claude Code hooks** for automatic lifecycle state.
3. **A local stdio MCP bridge** for deliberate agent-to-Console messages.

Out of scope: Anthropic's research-preview Claude Channels, and any scraping of
terminal output to determine state.

Official references:

- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/plugins-reference
- https://code.claude.com/docs/en/mcp
- https://modelcontextprotocol.io/specification/draft/basic/transports

## 1. Sessions experience

- The old `.terminal` sidebar entry is now a normal `.sessions` page. Sidebar
  navigation never toggles the drawer: stored `"terminal"` values migrate to
  `"home"` and the drawer expands; the `isTerminalExpanded` preference is
  preserved.
- The global bottom `zsh` Terminal drawer is restored as chrome on every
  main-window destination (`TerminalPanelView`, `TerminalViewWrapper`,
  `TerminalSessionManager`). Its login shell starts eagerly even while the
  drawer is collapsed and survives collapse; collapse/expand lives on the
  drawer chevron and resize on the drag handle above it. With Sessions selected
  and the drawer expanded, two independent SwiftTerm views are visible at once:
  the persistent `zsh` drawer and the selected session's Claude PTY. Process
  ownership is never shared between `TerminalSessionManager` and
  `SessionStore`.
- Console owns an observable `SessionStore`, created in `ConsoleApp` and
  injected into the environment.
- The Sessions destination shows a compact session list on the left and the
  selected terminal filling the remaining space. The app starts with zero
  sessions.
- **New Claude Session** opens a sheet requesting an editable session name and
  a required working directory chosen with `NSOpenPanel`. The suggested name is
  derived from the selected folder's last path component; duplicate active
  names are suffixed automatically (`Folder`, `Folder 2`, …).
- Claude is launched as the PTY child directly (the resolved `claude`
  executable). A shell is never started and `claude` never typed into it.
- Each creation generates two UUIDs: a Console session UUID and a Claude
  session UUID. Launch arguments include `--session-id <claudeUUID>`,
  `--name <session name>`, `--plugin-dir <bundled plugin>`, and preapproval of
  only the three qualified Console MCP tool names via `--allowedTools`.
- Switching sessions preserves every terminal process, view, and scrollback
  buffer: each session keeps one persistent `LocalProcessTerminalView`
  instance for its lifetime.
- Exited sessions and their scrollback remain visible until the user closes
  them explicitly.
- Stopping an Idle session happens immediately. Stopping a Working,
  Needs Approval, or Needs Input session requires confirmation. Termination is
  graceful first (SIGTERM with a grace period); Force Stop (SIGKILL) is offered
  only if the process has not exited, behind a second confirmation.
- Hiding Console's window leaves sessions running. Actual app termination stops
  all session processes.
- Sessions and agent messages are memory-only. Nothing persists; quitting
  Console returns it to zero sessions.

## 2. Models and state

```swift
struct ConsoleSession {
    let id: UUID                      // Console session UUID
    let claudeSessionID: UUID         // passed to --session-id
    var name: String
    var workingDirectory: URL
    let terminalView: LocalProcessTerminalView
    var activity: SessionActivity
    var attention: SessionAttention
    var summary: String?
    var artifacts: [SessionArtifact]
    var bridgeStatus: BridgeStatus
}

enum SessionActivity { case starting, idle, working, exited, error, unknown }

enum SessionAttention { case none, unreadCompletion, permission, question,
                        blocked, needsReview }

enum SessionArtifactKind { case jiraIssue, gitlabMergeRequest }
struct SessionArtifact { kind, label, url? }

enum BridgeStatus { case unknown, active, unavailable }
```

### Displayed state priority

Displayed state resolves from `(activity, attention)` in this order:

1. Needs Approval / Needs Input
2. Blocked / Needs Review
3. Error
4. Done
5. Working
6. Idle
7. Starting
8. Exited
9. Unknown

Activity and attention are stored separately so that a permission request or a
completion summary cannot be overwritten by a normal lifecycle transition.

## 3. Lifecycle mapping (hooks)

| Hook event | Reduced effect |
| --- | --- |
| `SessionStart` | Activity → Idle |
| `UserPromptSubmit` | Activity → Working; clears unread completion (and pending permission/question) |
| `PermissionRequest` | Attention → Needs Approval (activity unchanged) |
| `PreToolUse` narrowed to Claude's user-question tool (`AskUserQuestion`) | Attention → Needs Input |
| `Stop` or `Notification` with `notification_type == idle_prompt` | Activity → Idle plus unread Done |
| `StopFailure` | Activity → Error |
| `CwdChanged` | Working directory updated |
| `SessionEnd`, or SwiftTerm process termination | Activity → Exited |

Subsequent terminal input (typed in the terminal or submitted through the API)
clears permission/question attention optimistically.

The hook handlers are provided by a bundled plugin (`console-bridge`) loaded
with `--plugin-dir`. Every handler invokes the embedded helper in **hook mode**
and is registered `async` so instrumentation can never delay or change Claude's
behavior.

## 4. Claude executable resolution

Resolution order:

1. Valid executable path stored in Console Settings (`claudeExecutableOverride`).
2. Common installation paths (`~/.local/bin/claude`, `/usr/local/bin/claude`,
   `/opt/homebrew/bin/claude`, `~/.claude/local/claude`, `~/bin/claude`,
   `/usr/bin/claude`, `/opt/local/bin/claude`).
3. `command -v claude` executed through the user's login shell.

Settings shows the detected path, **Choose…**, and **Reset to Automatic**. Only
the override path persists — never session content. If Claude cannot be found,
the creation sheet stays open with an actionable local error.

## 5. Helper: `ConsoleTermBridge`

A signed command-line helper target embedded at
`Console.app/Contents/Helpers/ConsoleTermBridge`. It has two modes:

```text
ConsoleTermBridge hook <event-name>
ConsoleTermBridge mcp
```

Configuration reaches the helper through environment variables set on the
Claude process (and therefore inherited by hooks and MCP server children):

| Variable | Meaning |
| --- | --- |
| `CONSOLE_TERM_BRIDGE_HELPER` | Absolute helper path (used by plugin config) |
| `CONSOLE_TERM_BRIDGE_SOCKET` | Unix-domain socket path |
| `CONSOLE_TERM_BRIDGE_SESSION_ID` | Console session UUID |
| `CONSOLE_TERM_BRIDGE_TOKEN` | Random per-session token |

### Hook mode

- Reads the hook JSON from stdin.
- Decodes only required fields with narrow Codable types
  (`session_id`, `hook_event_name`, and where relevant
  `notification_type`, `new_cwd`, `error`).
- Immediately discards raw input after decoding.
- Forwards one reduced lifecycle envelope to Console over the socket.
- Never prints to stdout or stderr; always exits 0 so it can never block or
  alter Claude behavior.
- Never forwards prompts, tool arguments, assistant messages, transcript paths,
  descriptions, or raw hook JSON.

### MCP mode

Implements the minimum stdio JSON-RPC MCP surface over newline-delimited JSON:

- `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
- Never writes diagnostics to stdout.

Tools (exact input contracts enforced server-side):

```text
report_attention(category, message)
  category: question | blocked | needs_review
  message: required, trimmed, max 240 chars

link_artifact(kind, label, url?)
  kind: jira_issue | gitlab_merge_request
  label: required, max 80 chars
  url: optional HTTPS URL, max 2048 chars; never fetched

report_completion(outcome, summary)
  outcome: completed | blocked | needs_review
  summary: required, trimmed, max 400 chars
```

Results contain only concise success or validation-error text.

### Plugin resource

The bundle ships static plugin files under `Resources/`:

- `ConsoleClaudePlugin.plugin.json` — manifest (plugin name `console-bridge`)
- `ConsoleClaudePlugin.hooks.json` — hook registrations
- `ConsoleClaudePlugin.mcp.json` — MCP server declaration

At session start Console assembles them into the canonical plugin layout inside
the protected ephemeral directory:

```text
<ephemeral>/plugins/console-bridge/
├── .claude-plugin/plugin.json
├── hooks/hooks.json
└── .mcp.json
```

Hook commands use shell form `$CONSOLE_TERM_BRIDGE_HELPER` (hooks inherit the
Claude process environment); the MCP entry uses `${CONSOLE_TERM_BRIDGE_HELPER}`
expansion supported by `.mcp.json`.

Only the exact qualified names below are preapproved through launch arguments.
No MCP wildcard and no broadened permissions:

```text
mcp__plugin_console-bridge_console__report_attention
mcp__plugin_console-bridge_console__link_artifact
mcp__plugin_console-bridge_console__report_completion
```

There is no always-on instruction demanding completion reports. Hooks always
report state. Future JIRA/MR work packages will explicitly ask Claude to call
`report_completion` when a summary is valuable.

Normal user/project Claude settings and MCP servers are preserved: no
`--strict-mcp-config`, no modification of project or global configuration.

## 6. Console bridge transport

Console owns one Unix-domain socket listener inside a protected ephemeral
temporary directory (directory and socket mode `0700`).

- No HTTP server, localhost TCP listener, or external network traffic.
- Peer credentials are verified with `getpeereid(2)`; connections from other
  users are dropped.
- One random token is generated per Console session.
- Every envelope carries protocol version, session UUID, token, message kind,
  payload, and an event id for idempotency.
- Newline-delimited Codable JSON; maximum envelope size 8 KiB including the
  trailing newline.
- Events are processed serially and idempotently (duplicate event ids are
  ignored once applied).
- Rejected: unknown session, invalid token, unknown message kind, invalid
  enum values, oversized payloads, strings containing control characters.
- Nothing about message content is ever logged: no bodies, tokens, paths,
  summaries, artifact identifiers, hook payloads, or terminal content.
- If the socket, plugin, hooks, or MCP server are unavailable, the affected
  session's `bridgeStatus` becomes Unknown and Claude plus the terminal remain
  fully usable.

Message kinds:

| Kind | Payload fields |
| --- | --- |
| `lifecycle` | `lifecycle_event`: `session_started`, `prompt_submitted`, `turn_completed`, `turn_failed`, `session_ended` |
| `attention` | `category` (`permission`, `question`, `blocked`, `needs_review`), optional `message` ≤ 240 |
| `artifact` | `kind` (`jira_issue`, `gitlab_merge_request`), `label` ≤ 80, optional HTTPS `url` ≤ 2048 |
| `completion` | `outcome` (`completed`, `blocked`, `needs_review`), `summary` ≤ 400 trimmed |
| `cwd` | `directory`: new working directory path |

## 7. Terminal input API

```swift
@discardableResult
func submit(prompt: String, to sessionID: UUID) -> SubmissionResult
```

- Accepts only a nonempty prompt for a session whose activity is Idle or Done.
- Requires an explicit caller action; nothing is queued or auto-submitted.
- Input goes through SwiftTerm's main-thread `send` APIs only. The child file
  descriptor is never written directly.
- Multiline content is wrapped in bracketed-paste bytes
  (`ESC[200~ … ESC[201~`) followed by Return (`\r`).
- Future JIRA/MR card actions call this API; no redundant native prompt
  composer ships in this milestone.

## 8. Sessions UI

- Rows show session name, working-folder basename, displayed state, and unread
  attention indicator.
- The selected terminal header shows the session name and state.
- An optional compact strip above the terminal shows the latest one-line
  summary/attention message, up to two artifact chips, and an overflow count.
- Artifact chips are informational only this milestone — no JIRA/GitLab access,
  no network requests.
- State and metadata are exposed through one coherent accessibility element;
  terminal accessibility remains intact.
- Home Panel 2 ("Sessions") is the live Sessions radar described in
  `CONSOLE_PANEL_2_SESSIONS.md`: a compact, attention-sorted launcher over the
  same `SessionStore`. It shows state, summary-or-folder, and informational
  artifact chips; clicking a card selects that session and navigates to the
  Sessions destination. It never embeds a terminal and offers no
  stop/remove controls.
- Legacy `TabSelection.live` callers (`ConsoleNavigation.showTerminal(tab: .live)`)
  expand the bottom Terminal drawer instead of navigating; Sessions has its own
  `showSessions()`.

## 9. Testing

Automated tests use synthetic data only; they never require Claude network
access or real company data.

Coverage:

- Session creation, selection, duplicate-name handling, stopping, removal, and
  exited retention (`SessionStoreTests`).
- Lifecycle reducer transitions and display priority
  (`SessionLifecycleReducerTests`).
- Prompt submission gating and bracketed-paste byte generation
  (`PromptSubmissionTests`).
- Claude executable discovery and Settings override
  (`ClaudeExecutableLocatorTests`).
- Hook filtering with synthetic payloads containing fake sensitive fields, run
  against the real embedded helper binary (`HelperHookFilteringTests`).
- Verification that reduced envelopes contain no prompt, transcript path, tool
  input, or assistant response (`HelperHookFilteringTests`).
- Bridge token/session validation, same-session routing, duplicate events, size
  limits, malformed input (`BridgeProtocolTests`, `SessionBridgeServerTests`).
- MCP initialization, tool listing, valid calls, invalid calls, clean stdout
  framing (`HelperMCPTests`).
- Plugin/helper embedding and executable signing (`SessionsPackagingTests`).
- Zero-session UI, creation sheet, concurrent rows, switching, stop
  confirmation, exited retention (`SessionsUITests`).

Manual real-Claude verification checklist lives in the delivery report:
two named sessions in different folders survive switching; Idle, Working,
Needs Approval/Input, Done, Error, Exited exercised; all three MCP tools
invoked; only those tools preapproved; bridge failure leaves the terminal
usable; no local TCP listener, persisted session content, or sensitive log
output; quit and relaunch returns to zero sessions.
