import SwiftUI
import WebKit

/// One browser-style tab in a hosted web destination. Each tab owns a
/// distinct `WebPage` (independent history); pages supplied by the owner
/// share one persistent website data store, so authentication carries across
/// tabs. Tabs and their URLs are memory-only and never persist past process
/// exit.
@MainActor
struct BrowserTab: Identifiable {
    let id = UUID()
    let page: WebPage
    /// Fixed label for owned list pages (e.g. "To Review"); dynamic tabs
    /// fall back to the live page title.
    let titleOverride: String?
    /// Pinned tabs cannot be closed. The first tab of each destination wraps
    /// a page other surfaces (Home panels, extraction) also depend on.
    let isPinned: Bool

    var displayTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "New Tab" : title
    }
}

/// Observable, memory-only tab registry for a hosted web destination.
/// Pinned tabs come first and wrap pages with identities outside the
/// destination; dynamic tabs are opened by the user.
@MainActor
@Observable
final class BrowserTabStore {
    static let maxTabs = 8

    /// Tabs whose content stamp is at least this old are reloaded when their
    /// destination is entered.
    static let staleTabReloadInterval: TimeInterval = 10 * 60

    private(set) var tabs: [BrowserTab]
    private(set) var activeTabID: UUID
    /// URL loaded into each newly opened dynamic tab.
    var newTabURLProvider: () -> URL?

    /// When each tab's content last became current: seeded at tab creation
    /// (a new tab's page was just loaded or is blank) and refreshed whenever
    /// the destination auto-reloads stale tabs. Memory-only.
    private var contentStampedAt: [UUID: Date] = [:]
    private let now: () -> Date
    /// Reload seam; production calls the page's own reload.
    private let pageReloader: @MainActor (WebPage) -> Void

    init(
        pinnedTabs: [(page: WebPage, title: String?)],
        newTabURLProvider: @escaping () -> URL?,
        now: @escaping () -> Date = { Date() },
        pageReloader: (@MainActor (WebPage) -> Void)? = nil
    ) {
        self.newTabURLProvider = newTabURLProvider
        self.now = now
        self.pageReloader = pageReloader ?? { $0.reload() }
        let stampedAt = now()
        let pinned = pinnedTabs.map {
            BrowserTab(page: $0.page, titleOverride: $0.title, isPinned: true)
        }
        tabs = pinned
        activeTabID = pinned[0].id
        for tab in pinned {
            contentStampedAt[tab.id] = stampedAt
        }
    }

    var activeTab: BrowserTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    var activePage: WebPage {
        activeTab.page
    }

    /// Whether another tab may be opened.
    var canOpenTab: Bool {
        tabs.count < Self.maxTabs
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Opens a new tab, makes it active, and loads `newTabURLProvider`'s URL
    /// when one is configured. Returns the active tab when the cap is
    /// already reached.
    @discardableResult
    func openTab() -> BrowserTab {
        guard canOpenTab else { return activeTab }
        let tab = appendDynamicTab()
        if let url = newTabURLProvider() {
            tab.page.load(URLRequest(url: url))
        }
        return tab
    }

    /// Opens a new tab, makes it active, and loads `url`. At the tab cap the
    /// active tab navigates instead, so a handoff link is never dropped.
    @discardableResult
    func openTab(url: URL) -> BrowserTab {
        guard canOpenTab else {
            activePage.load(URLRequest(url: url))
            return activeTab
        }
        let tab = appendDynamicTab()
        tab.page.load(URLRequest(url: url))
        return tab
    }

    private func appendDynamicTab() -> BrowserTab {
        let tab = BrowserTab(page: WebPage(), titleOverride: nil, isPinned: false)
        tabs.append(tab)
        activeTabID = tab.id
        contentStampedAt[tab.id] = now()
        return tab
    }

    /// Reloads every open tab whose content stamp is at least `maxAge` old
    /// (or missing) and returns the reloaded tabs. Destinations call this on
    /// entry so long-idle tabs show the latest without reloading on every
    /// visit. A page already mid-load is treated as current and re-stamped,
    /// and `pageReloader` reloads in place so a page the user navigated away
    /// from the list keeps its location.
    @discardableResult
    func reloadStaleTabs(
        maxAge: TimeInterval = BrowserTabStore.staleTabReloadInterval
    ) -> [BrowserTab] {
        let current = now()
        var reloaded: [BrowserTab] = []
        for tab in tabs {
            let stampedAt = contentStampedAt[tab.id] ?? .distantPast
            guard current.timeIntervalSince(stampedAt) >= maxAge else { continue }
            if tab.page.isLoading {
                // An in-flight load is the freshest content there is.
                contentStampedAt[tab.id] = current
                continue
            }
            pageReloader(tab.page)
            contentStampedAt[tab.id] = current
            reloaded.append(tab)
        }
        return reloaded
    }

    /// Closes a non-pinned tab. Closing the active tab activates its right
    /// neighbor, or the closest remaining tab at the end.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              !tabs[index].isPinned else {
            return
        }
        let wasActive = tabs[index].id == activeTabID
        tabs.remove(at: index)
        if wasActive, !tabs.isEmpty {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }
}

/// Compact browser-style tab strip: one item per tab with a close affordance
/// on dynamic tabs, plus a New Tab action (⌘T).
struct BrowserTabBar: View {
    @Bindable var store: BrowserTabStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                tabItem(for: tab, index: index)
            }

            Button {
                store.openTab()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!store.canOpenTab)
            .keyboardShortcut("t", modifiers: .command)
            .help("New Tab")
            .accessibilityIdentifier("BrowserTabBar.NewTabButton")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("BrowserTabBar")
    }

    @ViewBuilder
    private func tabItem(for tab: BrowserTab, index: Int) -> some View {
        let isActive = tab.id == store.activeTabID
        HStack(spacing: 4) {
            if tab.page.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)

            if !tab.isPinned {
                Button {
                    store.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("BrowserTabBar.Tab.\(index)")
    }
}
