import SwiftUI

/// The Morning Brief destination: one pre-prepared, super-terse executive
/// report — what was done yesterday and today's top tasks — ready to read
/// aloud at the morning meeting.
struct BriefView: View {
    @State private var viewModel: BriefViewModel

    init(workspacePathsProvider: @escaping () -> [String] = { [] },
         workspacesProvider: (() -> [BriefWorkspaceSnapshot])? = nil,
         identityReader: (any BriefIdentityReading)? = BriefActivityCollector()) {
        _viewModel = State(initialValue: BriefViewModel(
            workspacePathsProvider: workspacePathsProvider,
            workspacesProvider: workspacesProvider,
            identityReader: identityReader
        ))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                reportCard
                statusFooter
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.prepareIfNeeded()
        }
        .accessibilityIdentifier("BriefDashboard")
    }

    // MARK: - Report card

    private var reportCard: some View {
        VStack(spacing: 0) {
            HomePanelHeader(title: "Morning Brief") {
                HomePanelDetail(headerDateString,
                                rangeSummary,
                                sourceString)
            } accessory: {
                HStack(spacing: 6) {
                    if viewModel.showCopiedFeedback {
                        Text("Copied")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        viewModel.copyReport()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy the five-line report")

                    Button {
                        viewModel.regenerate()
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .help("Rebuild from the selected author and date range. Cancels an in-flight AI polish.")

                    Button {
                        viewModel.refineWithAI(
                            aiProviderManager: AppDependencies.shared.aiProviderManager
                        )
                    } label: {
                        if viewModel.isRefining {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                    .disabled(viewModel.isRefining || !viewModel.canRefineWithAI)
                    .help(viewModel.canRefineWithAI
                          ? "Polish wording with AI. Cancels an in-flight rebuild."
                          : "Configure an AI provider first")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                attributionSection

                Divider()

                section(title: "YESTERDAY") {
                    if let lines = viewModel.brief?.yesterdayLines, !lines.isEmpty {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            reportRow(text: line)
                        }
                    } else if !viewModel.isLoading {
                        reportRow(text: "Nothing recorded yet.")
                    }
                }

                Divider()

                section(title: "TODAY") {
                    taskEditorRows
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MorningBriefCard")
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func reportRow(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Attribution

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Activity range", selection: rangePresetBinding) {
                Text("Yesterday").tag(BriefDateRangePreset.yesterday)
                Text("Choose dates").tag(BriefDateRangePreset.custom)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("BriefDateRangePreset")

            if viewModel.dateRange.preset == .custom {
                HStack(spacing: 12) {
                    DatePicker(
                        "From",
                        selection: customStartBinding,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("BriefDateRangeCustomStart")
                    DatePicker(
                        "To",
                        selection: customEndBinding,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("BriefDateRangeCustomEnd")
                }
            }

            if !rangeSummary.isEmpty {
                Text("Reporting \(rangeSummary)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("BriefActivityRange")
            }

            if !sourceRepositoriesSummary.isEmpty {
                Text("Sources: \(sourceRepositoriesSummary)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("BriefSourceRepositories")
            }

            ForEach(viewModel.authorRows) { row in
                authorRow(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity range and author")
    }

    private func authorRow(_ row: BriefAuthorDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.workspaceName)
                    .font(.system(size: 12, weight: .medium))
                Text(row.identity.displaySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if !row.confirmed {
                    Button("Confirm identity") {
                        viewModel.confirmAuthor(for: row.workspaceID)
                    }
                    .accessibilityIdentifier("BriefConfirmAuthor")
                }
            }

            HStack(spacing: 6) {
                TextField(
                    "Add email alias",
                    text: aliasBinding(for: row.workspaceID)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .accessibilityIdentifier("BriefAddAliasField")

                Button("Add") {
                    viewModel.addAlias(for: row.workspaceID)
                }
                .disabled((viewModel.aliasDrafts[row.workspaceID] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("BriefAddAlias")
            }

            if !row.confirmed {
                Text("From Git config — confirm or add aliases before sharing this report.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rangePresetBinding: Binding<BriefDateRangePreset> {
        Binding(
            get: { viewModel.dateRange.preset },
            set: { viewModel.setDateRangePreset($0) }
        )
    }

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { viewModel.dateRange.customStart ?? Date() },
            set: { viewModel.setCustomStart($0) }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { viewModel.dateRange.customEnd ?? Date() },
            set: { viewModel.setCustomEnd($0) }
        )
    }

    private func aliasBinding(for workspaceID: UUID) -> Binding<String> {
        Binding(
            get: { viewModel.aliasDrafts[workspaceID] ?? "" },
            set: { viewModel.setAliasDraft($0, for: workspaceID) }
        )
    }

    // MARK: - Task editing

    @ViewBuilder
    private var taskEditorRows: some View {
        let tasks = viewModel.brief?.todayTasks ?? []
        ForEach(tasks.indices, id: \.self) { index in
            HStack(spacing: 6) {
                // The getter must be bounds-safe: on macOS the underlying
                // NSTextField evaluates stale bindings while sibling rows
                // are removed, so `index` can briefly outrun todayTasks.
                TextField("Task \(index + 1)", text: Binding(
                    get: { tasks.indices.contains(index) ? tasks[index] : "" },
                    set: { viewModel.updateTask(at: index, text: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))

                Button {
                    viewModel.removeTask(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove task")
            }
        }

        if tasks.count < MorningBrief.maxTodayTasks {
            Button {
                viewModel.addTask()
            } label: {
                Label("Add task", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Add a top task")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusFooter: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else if viewModel.isLoading && viewModel.brief == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing your brief…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Header strings

    private var headerDateString: String {
        let day = viewModel.brief?.day ?? Date()
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var rangeSummary: String {
        if let summary = viewModel.brief?.activityRangeDescription(), !summary.isEmpty {
            return summary
        }
        let calendar = Calendar.current
        let day = viewModel.brief?.day ?? Date()
        let interval = viewModel.dateRange.interval(relativeTo: day, calendar: calendar)
        return BriefDateRangeSelection.description(of: interval, calendar: calendar)
    }

    private var sourceRepositoriesSummary: String {
        viewModel.brief?.sourceRepositoryNames.joined(separator: ", ") ?? ""
    }

    private var sourceString: String {
        switch viewModel.brief?.source {
        case .ai: return "AI polished"
        case .local: return "local"
        case nil: return ""
        }
    }
}

#Preview("Morning Brief") {
    BriefView()
        .environment(SessionWorkspaceStore())
        .frame(width: 720, height: 480)
}
