<!-- SESSION MEMORY — 4 KB hard cap. Wipe-and-rewrite as the final documentation act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-09 after removal of catalogue generation._

## Next Intended Move

No implementation follow-up for this removal. Prior manual verification of
Home extraction, Session Folder migration, and Review/GitLab remains pending.

## Working Findings

- Removed the development-only catalogue-generation package, discovery/parser/
  LLM implementation, package tests, generated intermediate entries, wrapper
  script, ignore rules, and obsolete documentation.
- There was no Generate Catalogue app screen/menu in the starting revision.
  The bundled ActionCatalog.json and runtime command consumers remain in use.
- Verification: clean Debug Console build passed under the shared host lease;
  repository search found no remaining generator or wrapper references before
  this memory update. Build emitted warnings in unchanged app source.
- Main checkout already contained uncommitted documentation/design deletions;
  preserve them when merging the isolated removal worktree.

## Dead Ends

- Never run the full UI suite or modify vendored SwiftTerm.
- Main-checkout agent documentation was locally deleted; worktree copies
  supplied the binding instructions for this session.
