# Console — Architecture Ground Truth

One page. Read this before touching code. Last verified against `main` at commit
`112045d` (2026-08-24). If reality has drifted, fix this file in the same commit.

## What Console is

A macOS 26 SwiftUI app (target: macOS 26, Swift, no cross-platform code) that is a
voice/AI-driven command console for Christopher's machine: it turns speech or text
into commands executed via AppleScript and AI providers, hosts Claude Code agent
sessions in real terminals, and renders a four-quadrant Home dashboard over live,
authenticated JIRA and GitLab WebViews.

App entry point: `Console/Console/ConsoleApp.swift` (`@main`). App-scope managers
are `@State` properties there plus `Console/Console/App/AppDependencies.swift`,
injected into the SwiftUI environment. Window defaults to `.defaultSize(1100x700)`;
**no declared minimum size**.

## Repository layout

```text
Console/
├── Console/                  # Xcode project dir (Console.xcodeproj) — build/test from here
│   ├── Console/              # app source (filesystem-synchronized group)
│   ├── ConsoleTests/         # unit tests (XCTest)
│   ├── ConsoleUITests/       # UI tests — TARGETED RUNS ONLY, never full suite
│   ├── ConsoleTermBridge/    # signed CLI helper target (hook + MCP modes)
│   └── SwiftTerm/            # VENDORED terminal emulator — do not modify unless explicitly tasked
├── CatalogGenerator/         # dev-only SPM CLI → generates bundled ActionCatalog.json (never ships)
├── Design/HomeCards/         # shared home-card design grammar (DESIGN_PROMPT.md §3)
├── Scripts/                  # generate-catalog.sh, clean-install.sh
└── CONSOLE_*.md              # binding spec documents (see docs index in the charter)
```

Filesystem-synchronized groups: new `.swift` files under `Console/Console/` and
`Console/ConsoleTests/` are picked up automatically. **No pbxproj edits needed**
to add files.

## Subsystem map (all paths relative to `Console/Console/`)

| Subsystem | Path | One-paragraph truth |
|---|---|---|
| **Command** | `Command/` | The voice/text command pipeline. Multi-provider AI generation (OpenAI, Claude, Gemini, Grok, LM Studio — each has `*CommandGenerator` + `*ModelFetcher`, unified by `LLMCommandGenerator`/`ModelFetcherFactory`/`LLMClient`). Matching (`CommandMatcher`, `ConsoleCommandMatcher`), validation (`CommandValidator`, `ScriptSafetyChecker`), execution (`CommandExecutor`, `LocalCommandExecutor`, `AppleScriptRunner`, `ActionExecutor`), wake words, listening modes, starter/curated commands. `ActionCatalog.swift` loads the bundled `ActionCatalog.json`. |
| **Speech** | `Speech/` | Speech recognition: `SpeechRecorder`, `SpokenWordTranscriber`, `AudioSessionController`, custom language model building, field-dictation vs command dictation modes (`ListeningMode`, `FieldDictationMode`, `NoteDictationMode` live near their consumers). |
| **Sessions** | `Sessions/` | Claude Code sessions. `SessionStore` (`@Observable`, **memory-only**, zero at launch) owns one persistent `LocalProcessTerminalView` (SwiftTerm PTY) per session; the resolved `claude` executable is launched directly as the PTY child (never typed into a shell). Lifecycle comes from Claude hooks; deliberate messages come through a stdio MCP bridge. See `CONSOLE_TERM_COMM.md` — implementation source of truth. |
| **Terminal drawer** | `Terminal/` | Global bottom `zsh` drawer on every destination. Owned by `TerminalSessionManager` — process ownership is NEVER shared with `SessionStore`. Two independent SwiftTerm views can be visible at once (drawer + selected session PTY). |
| **Jira panel** | `Jira/` | Home top-left quadrant. ONE process-scoped `WebPage` (`JiraWebSession.shared`) shared between Home quadrant and full JIRA sidebar destination. Native card overlay above the live WebView; DOM-only extraction via `WebPage.callJavaScript` returning JSON strings. Spec: `CONSOLE_PANEL_1_JIRA.md`. |
| **CodeHost / MergeRequests / GitLab** | `CodeHost/`, `MergeRequests/`, `GitLab/` | GitLab MR panels (GitHub support was removed — GitLab only). TWO retained `WebPage`s (reviews + authored) sharing one persistent `WKWebsiteDataStore`; independent histories, shared login. Specs: `CONSOLE_PANEL_3_GITLAB.md`, `CONSOLE_PANEL_4_GITLAB.md`. |
| **Home** | `Home/` | Four-quadrant grid: JIRA My Tickets · Agent Sessions · MRs to Review · My MRs (`HomePanel` enum in `HomeView.swift`). Sessions quadrant = attention radar/launcher over `SessionStore` (no terminal embedded, no destructive controls). Shared card grammar per `Design/HomeCards/DESIGN_PROMPT.md` §3. |
| **Brief** | `Brief/` | Morning Brief: collects activity, composes prompt, calls AI (`BriefAIService`), parses response (`BriefAIResponseParser`), stores results (`BriefStore`). |
| **Next** | `Next/` | "What should I do next" card: `NextContextBuilder.recommendedTask` (local priority selector) → `NextButtonModel` → `NextTaskCardView`. Panel-derived MR/ticket/session text never leaves the process. |
| **Note** | `Note/` | Voice dictation notes panel with its own dictation mode. |
| **Permissions / Authorization** | `Permissions/`, `Authorization/` | macOS permission checks (accessibility, automation, microphone), status polling, background observer, grant modals, voice authorization handler. |
| **Updates** | `Updates/` | GitHub-release-based updater (`UpdateManager`, `SemanticVersion`, `SourceCheckoutService`, `ProcessRunner`). |
| **Logging** | `Logging/` | Command execution logs + retention cleanup. |
| **MenuBar** | `MenuBar/` | Menu bar state/manager, toast overlay, error banner. |
| **Intents** | `Intents/` | App Intents for Shortcuts (create/execute/list commands, toggle listening). |
| **iOS workflow** | `IOSWorkflow/` | Per-workspace saved Xcode project/scheme/configuration/test-plan/Simulator profile. Discovery uses bounded `xcodebuild -list -json`, `-showTestPlans`, and `-showdestinations` via `ProcessRunner`. No signing credentials, source content, or builds in this slice. |
| **Settings** | `Settings/` | SettingsView sections incl. AI provider config, model selection, hotkey recorder, sessions section, iOS project profile, WebView URL fields (JIRA/GitLab). |
| **Utilities/Extensions/Styles/Views** | misc | Keychain (`KeychainManager`, `AIKeychain` — all API keys live here, never in code), MarkdownRenderer, SyntaxHighlighter, shared components. |

## Cross-cutting invariants

1. **Two web-session ownerships are separate**: `TerminalSessionManager` (zsh drawer)
   vs `SessionStore` (Claude PTYs). Never share processes between them.
2. **One JIRA WebPage**, two GitLab WebPages — shared data store, never cookie extraction.
3. **Sessions are memory-only.** Quit → zero sessions. No persistence of prompts,
   transcripts, ticket content, or summaries.
4. **API keys only in the Keychain** (`KeychainManager` / `AIKeychain`).
5. **SwiftTerm is vendored** — treat as a dependency, not app code.
6. **CatalogGenerator never ships**; only its generated `ActionCatalog.json`
   resource ships (committed to repo).
7. Accessibility identifiers are stable and generic (`HomePanelJiraTickets`,
   `SessionRow.<name>`) — never embed ticket keys, titles, URLs, or company data.
