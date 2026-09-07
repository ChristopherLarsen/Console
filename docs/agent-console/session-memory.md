<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-06 after committing leftover review docs._

## Next Intended Move

No numbered items remain in `docs/reviews/2026-09-06-ios-workflow-review.md`. Ask Christopher before opening live follow-up (800×500 visual pass, Simulator smoke, VoiceOver).

## Working Findings

- Review items 01–24 are on `main` (`fcc7cb7`). Status and leftover gaps are in that review file.
- `MainView` min size is 800×500; window default is 1100×700. UI-test AX-dialog notes are in `docs/agent-console/build-and-test.md`.

## Dead Ends

- Isolated review worktrees must be created from `/Users/christopherlarsen/Workspace/Console` on `main`. Do not implement in the shared Cursor checkout.
- Nested `Commands` structs and a `.sheet` on `MainView` did not present Developer Actions under UI tests; the overlay path did.
