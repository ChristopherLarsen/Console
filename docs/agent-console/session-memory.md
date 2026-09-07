<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after TicketWorkflow Wave 1–3 merge prep._

## Next Intended Move

After `ticket-workflow-lead` lands on `main`: smoke Ticket Work sidebar + Track Work from a synthetic Jira fixture; optional live Simulator install path; VoiceOver pass if desired.

## Working Findings

- TicketWorkflow packages A–G + E merged in lead worktree with H wiring (sidebar without hotkey changes, store/coordinator bootstrap, Next `ticketWorkflowStep`, session lifecycle fan-out).
- Security §2a durable progress allowance is documented.
- Full end-to-end synthetic lifecycle + fixture iOS project smoke still lead-owned verification items.

## Dead Ends

- Do not implement in the shared Cursor orca checkout; use Workspace/Console worktrees.
- `TicketJiraClosureDecision.evaluate` must forward to `TicketJiraObservationPolicy.evaluate` (A/F merge shim).
