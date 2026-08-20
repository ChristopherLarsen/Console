import SwiftUI

struct AvailableCommandsView: View {
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tabSelection") private var tabSelection: TabSelection = .triggers
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarSelection = .home
    @State private var initialTab: TabSelection = .triggers
    @State private var initialSidebar: SidebarSelection = .terminal

    private let apps = CuratedAppShowcase.sortedByPopularity
    @State private var searchText: String = ""
    @State private var selectedCategory: AppCategory = .all

    private var filteredApps: [ShowcaseApp] {
        var result = apps
        if selectedCategory != .all {
            result = result.filter { $0.category == selectedCategory }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { app in
                app.name.lowercased().contains(query)
                || app.showcaseCommands.contains { $0.lowercased().contains(query) }
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            categoryPills
            Divider()
                .padding(.horizontal, 16)

            if apps.isEmpty {
                emptyState
            } else if filteredApps.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if selectedCategory == .all {
                            groupedByCategory
                        } else {
                            flatList(filteredApps)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 520, height: 560)
        .onAppear {
            initialTab = tabSelection
            initialSidebar = sidebarSelection
        }
        .onChange(of: tabSelection) { _, newValue in
            if newValue != initialTab {
                performClose()
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            if newValue != initialSidebar {
                performClose()
            }
        }
    }

    private func performClose() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Available Commands")
                    .font(.title3.bold())

                Text("\(apps.count) apps with voice commands")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            CloseButton { performClose() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Search apps or commands", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .onChange(of: searchText) { _, newValue in
                    let sanitized = InputSanitizer.searchQuery(newValue)
                    if sanitized != newValue { searchText = sanitized }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Category Filter

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppCategory.allCases) { category in
                    let selected = selectedCategory == category
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedCategory = category
                        }
                    } label: {
                        Text(category.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .foregroundStyle(selected ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    // MARK: - List Content

    private func flatList(_ items: [ShowcaseApp]) -> some View {
        ForEach(items) { app in
            ShowcaseAppRow(app: app)
        }
    }

    private var groupedByCategory: some View {
        let categories = AppCategory.allCases.filter { $0 != .all }
        return ForEach(categories) { category in
            let categoryApps = filteredApps.filter { $0.category == category }
            if !categoryApps.isEmpty {
                sectionHeader(category.displayName, count: categoryApps.count)
                flatList(categoryApps)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.4), in: Capsule())
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Empty / No Results

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Commands Available")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("The curated app list is empty.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No matching apps")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("No results for \"\(searchText)\"")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Button {
                searchText = ""
                selectedCategory = .all
            } label: {
                Text("Clear search")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
