# MR Review scans

## Data boundary

Christopher explicitly authorized sending company GitLab content to Claude,
the approved company AI provider, on 2026-09-10. The AI Disposition stage uses
Console's managed Claude Code access, not the general configurable AI provider.
Collection remains DOM-only through the embedded GitLab page. This stage sends
extracted card fields, not credentials, cookies, discussions, diffs or repository
files. Card data and classifications remain in memory; Claude runs are ephemeral,
with tools and MCP disabled. Only user-authored prompt/settings are persisted.

## Pipeline

1. The shared list controller loads the configured reviews URL, inspects its DOM
   and produces typed cards. A first Home load works without mounting a WebView.
   Recognized authentication requires completing sign-in in the GitLab destination.
2. Every successful extraction, including sign-in recovery, notifies the disposition
   controller. When enabled, it sends batches of up to 20 cards to Claude (Haiku by
   default). Opaque IDs and a request correlation ID validate exact response coverage.
3. Home displays `AI: <disposition>` while retaining the raw GitLab label in the
   tooltip. No AI response adds/removes cards, changes their URLs, or mutates GitLab.
   Failure falls back to the deterministic cards. Missing evidence is Unknown.

Manual refresh returns to the configured list even if the retained tab was on an
MR detail page or a different sort/page. Background scans defer to browsing. Both
respect recognized sign-in flows. Loads time out after 30 seconds into a recoverable
failure (stale cards when available); Home displays progress and outcome messages.

AI Disposition is enabled by default and independent of the periodic-scan toggle.
Its model, prompt editor, Save Prompt and Restore Default Prompt controls are in
Settings → MR Review Scans. Changing AI settings cancels obsolete classification
and reclassifies the last fresh cards. Disabling clears AI labels immediately.
Source refresh/reset invalidates in-flight AI responses; late results cannot label
new cards. Each Claude batch has a 60-second deadline.

The default prompt is `MRDispositionPrompt.defaultText`. The non-editable JSON
contract is appended separately. Current dispositions are Review Required,
Changes Requested, Approved, Draft, Merged, Closed and Unknown. These describe
the supplied host evidence, not verified current-user review history.

# MR response prep

When an authored-MR scan reports unresolved discussions on one of the user's own
merge requests, `MRResponsePrepController` prepares draft responses. Prep only:
nothing is committed, pushed, posted, resolved, or changed in GitLab or JIRA.

1. `MRResponsePrepFetcher` runs `glab api --method GET` for the MR metadata, its
   discussions and its diffs, and writes them plus Console-authored
   `INSTRUCTIONS.md` to `~/Library/Application Support/Console/MRResponsePrep/<mr>/`.
   Only unresolved discussions (a resolvable, unresolved note) are kept.
2. A background session (`MR-<iid> Response`) starts in the Session Folder with the
   `readOnlyPrep` tool profile: `--permission-mode dontAsk`, `--tools Read Grep Glob`,
   `--disallowedTools Bash Edit Write NotebookEdit WebFetch WebSearch Task mcp__*`,
   `--strict-mcp-config`, and the evidence folder via `--add-dir`. No permission
   bypass. It does not select, focus or navigate, and does not retire Restore Sessions.
   The bridge plugin's hooks still report lifecycle; its MCP tools are denied.
3. Once the bridge is live, Console types one prompt naming only the validated
   project path, MR number and instructions path. GitLab text reaches Claude only
   through the files, which the instructions mark as untrusted data.

The Review column shows these MRs first: "Reviewing comments" until the prep turn
completes, then "Response ready". "Review response" opens the live session or
resumes its conversation (a resume uses the standard tool profile). An MR is
prepared again only when its unresolved count rises above the last prepared count;
at most two preps run at once. Settings → MR Review Scans can turn automatic prep
off; the card then offers "Prepare response".
