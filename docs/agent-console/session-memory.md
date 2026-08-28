<!-- SESSION MEMORY — rules in header. 4 KB hard cap. Wipe-and-rewrite as your FINAL act each session. Never append. -->

# Session Memory

_Rewritten in full at the end of each session by agent-console._

## Next Intended Move

- Await Christopher's confirmation that the Morning Brief minus-button crash
  is gone (delete tasks repeatedly, including while editing/focused) and that
  earlier surfaces look right: unified terminal surface (radius 6), Next as
  `.next` destination with content-hugging card (minHeight 150), hotkey remap
  (⌃1-9 sidebar / ⌘1-9 sessions / ⌘` sessions page, no ⌃0). Also unverified:
  LM Studio Retry now pings reconnect then searches models — needs a live
  test with LM Studio stopped/started. If Sessions terminal surface should
  float free of the divider instead of flush-under, add a top margin at that
  call site only.

## Working Findings

- Hotkey scheme REMAPPED this session (Go menu, ConsoleApp): ⌃1…⌃9 now target
  sidebar destinations in order via `ConsoleNavigation.sidebarHotkeyDestinations`
  ([.home, .next, .brief, .jira, .mergeRequests, .triggers, .commands,
  .aiProvider, .sessions] — Settings deliberately unnumbered). Sessions are
  ⌘1…⌘9 (`openHotkeySession` contract unchanged: select Nth or show Sessions
  with cleared selection) and ⌘` shows Sessions without touching selection.
  Legacy ⌃0 "Sessions (No Selection)" menu item REMOVED at Christopher's ask
  (clearSelection() still used by openHotkeySession on miss). Menu shortcuts
  override macOS window-cycling on ⌘`.
- Menu bar buddy icons regenerated 2026-08-27: four 32x32 black+alpha PNGs
  drawn via CoreGraphics script (poses: sleeping/bored/awake/attentive),
  Contents.json now carry template-rendering-intent. RULE: any menubar icon
  here must be transparent-bg black+alpha — MenuBarManager sets isTemplate,
  so opaque colored art renders as washed-grey blobs.
- Morning Brief crash FIXED: BriefView task-row TextField binding getter
  subscripted todayTasks unguarded; NSTextField evaluates stale bindings while
  sibling rows delete → Index out of range. Getter now reads the per-render
  snapshot with indices.contains check.
- Terminal drawer first-open lag addressed: view+shell spawn was already at
  launch (MainView.onAppear); the lag was first-layout cost (font metrics,
  cell grid, TextKit, one draw) on the detached zero-frame view. New
  `TerminalSessionManager.preheatTerminalView()` (guarded on superview==nil
  && frame==.zero) warms it async at launch. SwiftTerm Metal renderer is OFF
  in Console (setUseMetal never called), so no shader warm-up needed.
- Exhaustive switches over SidebarSelection exist in TWO places:
  `MainView.centerContent` and `ConsoleNavigation.show(_:)`.
- Next flow: `NextButtonModel.checkIfNeeded(...)` skips only when status is
  .ready AND last check < 5 min. Card content-hugging, floor minHeight 150.
  GOTCHA: card fills any offered height because its state VStacks contain
  greedy Spacers — NextView must pin `.fixedSize(horizontal: false,
  vertical: true)` on the card. If embedding it elsewhere, keep that pin.
- Console.xcodeproj uses fileSystemSynchronizedGroups — new files under
  `Console/Console/` need no pbxproj edit. Static stored properties are
  illegal on generic types — use a private metrics enum.

## Dead Ends

- Full ConsoleTests scheme runs hit load-dependent flakes:
  `AppIconResolverTests.testConcurrentAccessDoesNotCrash` and documented-flaky
  dictation E2E test. Neither relates to app changes here; verify against
  pristine main before blaming real failures.

---
