import SwiftUI

/// The Morning Brief destination: one pre-prepared, super-terse executive
/// report of the work completed on the previous workday, ready to read
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
                    .help("Copy the report")

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
                    .help("Rebuild from the latest commit activity. Cancels an in-flight AI polish.")

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
                section(title: "PREVIOUS WORK DAY") {
                    DatePicker(
                        "Choose date",
                        selection: workdayBinding,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("BriefWorkdayPicker")

                    if let lines = viewModel.brief?.yesterdayLines, !lines.isEmpty {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            reportRow(text: line)
                        }
                    } else if !viewModel.isLoading {
                        reportRow(text: "Nothing recorded yet.")
                    }
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

    // MARK: - Workday picker

    /// The displayed workday: the explicit pick when set, otherwise the
    /// day the brief actually reported. Picking a date regenerates the
    /// brief for that exact workday.
    private var workdayBinding: Binding<Date> {
        Binding(
            get: {
                if let selected = viewModel.selectedWorkday { return selected }
                if let reported = viewModel.brief?.activityInterval?.start {
                    return reported
                }
                return BriefComposer.previousWeekday(
                    before: viewModel.brief?.day ?? Date(),
                    calendar: .current
                )
            },
            set: { viewModel.chooseWorkday($0) }
        )
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

    /// The header names the day the report covers, not the generation day.
    private var headerDateString: String {
        if let reported = viewModel.brief?.activityInterval?.start {
            return reported.formatted(date: .abbreviated, time: .omitted)
        }
        let day = viewModel.brief?.day ?? Date()
        return day.formatted(date: .abbreviated, time: .omitted)
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
