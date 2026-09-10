<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten 2026-09-09 after the workspace → single Session Folder refactor
(vx_planner/gpt-6-astra consulted, decisions A–F adopted). Uncommitted._

## Next Intended Move

Manual verification: (1) Home unmounted-WebPage extraction still pending from
earlier; (2) single Session Folder flow — Settings → Claude → Session Folder
picker, fresh-install launch, migration from the old multi-workspace data
(previous default adopted), launch refusal when unset; (3) Review column /
GitLab flow. Then Christopher's call on committing the whole day's stack.

## Working Findings

- Workspace → Session Folder refactor (this session):
  - `SessionWorkspaceStore` is now a SINGLE-folder adapter: authoritative
    keys `sessions.defaultFolderPath` + `sessions.defaultFolderWorkspaceID`;
    one `SessionWorkspace` entry with stable UUID per canonical path.
    `setDefaultFolderPath(nil)` clears. One-time migration: previous default
    workspace (or sole legacy entry) adopted with its UUID preserved;
    ambiguous legacy data (several entries, no default) left unset; marker
    `sessionWorkspaces.migratedToDefaultFolder` prevents re-import after a
    clear. Legacy keys deleted on migration.
  - Launch: `SessionLaunchCoordinator.launch` = validate single folder →
    performLaunch. New LaunchErrors: sessionFolderMissing /
    sessionFolderUnavailable / sessionFolderNotAGitRepository (reviews only;
    general works in non-git folders). NO home-dir fallback, ever.
  - DELETED: 5-step resolution chain, learned associations, per-purpose
    last-used, `PendingWorkspaceChoice`, `WorkspaceChoiceSheet`,
    `SessionsSettingsSection`, `SessionDraft.workspaceID`,
    `confirmWorkspaceChoice`/`canConfirmWorkspace`/`workspaceBlockingReason`
    /`restoreChoiceSheetIfNeeded` (now `restoreCollisionSheetIfNeeded`),
    `RepositoryIdentityResolver` use in the coordinator (class + tests kept).
    Shared-checkout collision flow KEPT (PendingSharedCheckoutWarning lost
    workspaceID/rememberingAssociation fields).
  - Settings → Claude section now has the Session Folder row (Choose…/Clear,
    orange validation), id Settings.Claude.SessionFolder{Choose,Clear,Path}.
  - SessionIntentPickerView: workspace picker/overrides deleted; header shows
    the one folder + inline Choose button; launcher launches directly, errors
    surface inline with Settings route.
  - Brief + iOS keep the workspace-ID contract via the adapter (0/1 entries).
    Empty-state copy now points at "Settings → Claude". iOS profiles keyed by
    the folder's stable UUID; different folder = fresh UUID = old profiles
    orphaned (deliberate invalidation).
  - Tests: SessionWorkspaceChooserTests deleted; SessionWorkspaceStoreTests
    rewritten (set/clear/canonical/stable-ID/unavailable + 4 migration
    tests); SessionLaunchCoordinatorTests rewritten around folder validation
    (7 new tests replacing the resolution-order suite); SharedCheckoutWarning
    helpers now `useSessionFolder` (linked-worktree distinctness test DELETED
    — two workspaces unsupported). Full ConsoleTests: 1269 passed + 1 known
    pre-existing flake (EndToEndIntegrationTests, fails on pristine main).
- Home board + Sessions copy + URL fields (earlier this session): covered
  Home WebViews REMOVED (macOS 26 WebView composites above SwiftUI — never
  stack covered WebViews under SwiftUI chrome); "Sign in required" buttons;
  card shadows; BrowserURLField address bars (Jira.URLField /
  MergeRequests.URLField); "No Sessions"; + button after Sessions title.
- vx_planner responses: /var/folders/…/opencode/vxplanner*/response.txt.

## Dead Ends

- `app.windows.firstMatch` still fails on this host (NavigationUITests red).
- Synthesized sidebar clicks: dead — drive UI from menu bar, launch hooks, or
  in-content buttons only.
- Full UITest suite remains forbidden.
- WebKit launch SIGTRAP flake can hit test hosts → retry once before
  diagnosing.
- OpenRouter streaming responses may contain raw control chars — jq chokes;
  parse with python json fallback.
- Edit-tool paths in this repo: Console/Console/Console/... (double Console);
  wrong-depth paths intermittently "not found" but edit tool sometimes
  auto-locates — verify with rg after edits.
- Do NOT touch Console/SwiftTerm/ (vendored).