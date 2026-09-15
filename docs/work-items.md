# Work-item associations

## Model and ownership

`WorkItem` is a durable local activity with a UUID, an implementation/review/unspecified kind, external artifacts, and role-aware conversation links. A JIRA story is optional. One work item can contain multiple MRs and conversations; a conversation can participate in separate authoring and review work. Runtime terminal IDs are never durable relationship keys: links use `claudeSessionID`.

`SessionAssociationStore` owns the catalog and is observable. Conversation records contain resume metadata; their artifact arrays are read projections of work items. `SessionArtifact` remains the UI chip type. Process state, restoration eligibility, transcripts, browser tabs, remote issue status, and notification acknowledgments retain their existing owners. Session completion does not complete a work item.

## Identity and matching

- JIRA identity includes the site/context path and issue key, normalized through the existing JIRA URL rules.
- MR identity includes scheme, host/port, project path, and IID. Query strings, fragments, and default ports do not create a second identity.
- Labels and titles are display metadata, not identities.
- Key-only legacy tickets remain unscoped. They are useful for history classification but cannot match an arbitrary site's issue merely because its key is the same.
- New conversations join an existing work item only on one unambiguous scoped anchor of the same work kind. Existing work IDs remain stable during enrichment and conversation renaming.
- Review and authoring links stay separate. Generic historical conversations remain `related` until explicitly associated; a generic MR chip alone is not evidence of authorship.
- Runtime selection prefers a live conversation, then newer session-list order. Explicit author preferences are honored. Durable author/review lookup returns no automatic choice when multiple candidates remain.

## Write and read paths

`SessionStore` records source/bridge associations in the catalog and refreshes active session artifact projections. An explicit authored-MR association and its preferred conversation are saved in one transaction before updating chips. Failed saves roll back the catalog; existing persistence error presentation reports the failure.

Home story/review matching uses the catalog when the application store is available. Known work artifacts can resolve JIRA/MR navigation without an open terminal. A card with multiple known MR destinations does not silently pick one. The review action selects an existing live review conversation or resumes a unique saved one through the normal transcript/process checks.

Previous Sessions and the authoring-session picker use catalog ticket projections. The history reader invalidates cached classification when association keys change, even if transcript bytes have not changed. Older display-only parsing fallbacks remain for transcripts that have never been associated; opening history no longer persists guessed associations for every transcript.

## Migration

The existing `SessionAssociations.json` path is retained with schema version 2. Version 1 conversation artifacts become work-item artifacts; explicit preferred-author choices survive migration. The legacy UserDefaults ticket dictionary is imported once, including IDs whose transcript has not yet been opened. It remains untouched as an import source, but new production writes no longer update it.

Migration writes atomically. Unknown versions, corrupt input, or duplicate top-level identities block writes and preserve the original file. Save failures keep the previous on-disk data. The model uses the existing JSON persistence mechanism and requires no new framework or database.

## Verification

`WorkItemAssociationTests` covers identity, grouping, optional JIRA, role separation, reload, legacy import, version-1 migration, explicit author selection, enrichment, and rollback. Integration coverage lives in `SessionStoreTests`, `SessionLaunchCoordinatorTests`, `HomeStorySessionMatcherTests`, `SessionHistoryTests`, and existing authored-MR tests.
