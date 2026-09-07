import SwiftUI

// MARK: - Integration entry (lead mounts)

/// Standalone Ticket Work destination. Lead mounts this after adding a
/// sidebar case / navigation route. Requires `TicketWorkflowStore` in the
/// environment. Wire `handlers` to `TicketWorkflowCoordinating`.
struct TicketWorkRootView: View {
    @Environment(TicketWorkflowStore.self) private var store

    var handlers: TicketWorkActionHandlers = TicketWorkActionHandlers()
    var resultsProvider: (UUID) -> [TicketWorkResultsPresentation] = { _ in [] }
    var showsTemplateEditor: Bool = true

    @State private var listModel: TicketWorkListViewModel?
    @State private var showingTemplateEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if let listModel {
                    VStack(spacing: 0) {
                        TicketWorkPersistenceBanner(store: store)
                        TicketWorkListView(model: listModel) { id in
                            TicketWorkDetailView(
                                model: TicketWorkDetailViewModel(
                                    workflowID: id,
                                    store: store,
                                    handlers: handlers,
                                    resultsProvider: resultsProvider
                                )
                            )
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                if showsTemplateEditor {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Template") {
                            showingTemplateEditor = true
                        }
                        .accessibilityIdentifier(TicketWorkflowAccessibility.templateEditor)
                    }
                }
            }
            .sheet(isPresented: $showingTemplateEditor) {
                if let template = store.templates.values.sorted(by: { $0.version > $1.version }).first {
                    TicketWorkTemplateEditorView(
                        model: TicketWorkTemplateEditorViewModel(
                            template: template,
                            handlers: handlers
                        )
                    )
                    .frame(minWidth: 520, minHeight: 420)
                }
            }
        }
        .onAppear {
            if listModel == nil {
                listModel = TicketWorkListViewModel(store: store)
            }
        }
    }
}

/// Surfaces durable-progress lock / recovery / corrupt states without exposing
/// ticket content.
struct TicketWorkPersistenceBanner: View {
    @Bindable var store: TicketWorkflowStore
    @State private var confirmingReset = false

    var body: some View {
        Group {
            switch store.persistenceState {
            case .ready:
                EmptyView()
            case .lockedRetryable:
                banner(
                    message: "Ticket Work progress is locked. Unlock Keychain, then retry.",
                    retry: true,
                    reset: false
                )
            case .missingKeyNeedsRecovery:
                banner(
                    message: "Ticket Work identity key is missing. Reset progress to continue tracking.",
                    retry: true,
                    reset: true
                )
            case .corruptPreserved:
                banner(
                    message: "Saved Ticket Work progress is unreadable. Reset to start fresh.",
                    retry: false,
                    reset: true
                )
            case .newerFormatPreserved(let version):
                banner(
                    message: "Ticket Work progress was saved by a newer Console (format \(version)). Upgrade or reset.",
                    retry: false,
                    reset: true
                )
            case .saveFailed:
                banner(
                    message: "Could not save Ticket Work progress.",
                    retry: true,
                    reset: false
                )
            }
        }
    }

    private func banner(message: String, retry: Bool, reset: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if retry {
                Button("Retry") {
                    Task {
                        await store.retryLoadAfterKeychainAvailable()
                        if store.persistenceState == .ready {
                            store.applyCoordinatorRestartHooks()
                        } else if store.persistenceState == .saveFailed {
                            await store.saveProgress()
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier(TicketWorkflowAccessibility.persistenceRetry)
            }
            if reset {
                Button("Reset", role: .destructive) {
                    confirmingReset = true
                }
                .controlSize(.small)
                .accessibilityIdentifier(TicketWorkflowAccessibility.persistenceReset)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TicketWorkflowAccessibility.persistenceBanner)
        .confirmationDialog(
            "Reset Ticket Work progress? Existing associations cannot be recovered.",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Progress", role: .destructive) {
                Task {
                    try? await store.resetDurableProgressForRecovery()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - List

struct TicketWorkListView<Detail: View>: View {
    @Bindable var model: TicketWorkListViewModel
    @ViewBuilder var detail: (UUID) -> Detail

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TicketWorkflowAccessibility.list)
        .navigationDestination(item: $model.selectedWorkflowID) { id in
            detail(id)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterButton(title: "Active", filter: .active, id: TicketWorkflowAccessibility.listFilterActive)
            filterButton(title: "Closed", filter: .closed, id: TicketWorkflowAccessibility.listFilterClosed)
            Spacer()
            Text("\(model.items.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func filterButton(title: String, filter: TicketWorkflowFilter, id: String) -> some View {
        Button(title) {
            model.setFilter(filter)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: model.filter == filter ? .semibold : .regular))
        .foregroundStyle(model.filter == filter ? Color.accentColor : .secondary)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: HomeCardMetrics.listGap) {
                    ForEach(model.items) { item in
                        TicketWorkListRow(item: item) {
                            model.select(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ticket")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.filter == .active ? "No active tracked work" : "No closed tracked work")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whole card is one button — Home card grammar; no nested controls.
struct TicketWorkListRow: View {
    let item: TicketWorkflowListItemSnapshot
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(channel.color)
                        .frame(width: 6, height: 6)

                    Text(item.stage.displayName)
                        .font(HomeCardMetrics.identityFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(TicketWorkUILabels.lifecycle(item.lifecycle))
                        .font(HomeCardMetrics.stateFont)
                        .foregroundStyle(channel.color)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let jira = item.jiraStatusLabel, item.isConnectedToJira {
                        Text(jira)
                            .font(HomeCardMetrics.stateFont)
                            .foregroundStyle(AttentionChannel.forTicketStatus(jira).color)
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    Text(item.title)
                        .font(HomeCardMetrics.titleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 2)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.3))
                        .homeActionSlot
                }

                if let next = item.nextActionTitle {
                    Text(next)
                        .font(HomeCardMetrics.identityFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(HomeCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
            .homeCardSurface(hovering: hovering, alertInset: item.lifecycle == .blocked ? Color.red : nil)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(TicketWorkflowAccessibility.workflowRow(item.id))
    }

    private var channel: AttentionChannel {
        switch item.lifecycle {
        case .blocked: return .needsYou
        case .closed: return .clear
        case .needsReconciliation: return .inFlight
        case .active:
            return item.isConnectedToJira
                ? AttentionChannel.forTicketStatus(item.jiraStatusLabel)
                : .parked
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.stage.displayName, TicketWorkUILabels.lifecycle(item.lifecycle)]
        if item.isConnectedToJira, let jira = item.jiraStatusLabel {
            parts.append(jira)
        }
        parts.append(item.title)
        if let next = item.nextActionTitle { parts.append(next) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct TicketWorkDetailView: View {
    @Bindable var model: TicketWorkDetailViewModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(snapshot)
                        stageProgress(snapshot)
                        nextAction(snapshot)
                        checklist(snapshot)
                        resultsSlot
                        blockers(snapshot)
                        sessions(snapshot)
                        workflowActions(snapshot)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Workflow unavailable", systemImage: "ticket")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TicketWorkflowAccessibility.detail)
    }

    private func header(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)

            HStack(spacing: 12) {
                labeledValue("Jira status", snapshot.isConnectedToJira
                    ? (snapshot.jiraStatusLabel ?? "Unknown")
                    : "Disconnected")
                labeledValue("Console stage", snapshot.stage.displayName)
                labeledValue("Lifecycle", TicketWorkUILabels.lifecycle(snapshot.lifecycle))
                labeledValue("Cycle", "\(snapshot.workCycle)")
            }
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    private func stageProgress(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stages")
                .font(.headline)
            HStack(spacing: 4) {
                ForEach(snapshot.stages) { stage in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(stageFill(stage))
                            .frame(width: 10, height: 10)
                        Text(stage.stage.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(stage.isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TicketWorkflowAccessibility.stageProgress)
        .accessibilityLabel(
            "Stage \(snapshot.stage.displayName), \(snapshot.stages.filter(\.isCompleted).count) of 7 complete"
        )
    }

    private func stageFill(_ stage: TicketStageProgressSnapshot) -> Color {
        if stage.isCompleted { return .green }
        if stage.isCurrent { return .accentColor }
        return Color(nsColor: .quaternaryLabelColor)
    }

    @ViewBuilder
    private func nextAction(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        if let next = snapshot.nextAction {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next")
                    .font(.headline)
                CapsuleButton(next.title, systemImage: "arrow.forward.circle", style: .primary) {
                    model.performNextAction()
                }
                .accessibilityIdentifier(TicketWorkflowAccessibility.nextAction)
            }
        }
    }

    private func checklist(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checklist")
                .font(.headline)
            ForEach(snapshot.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: stepIcon(step.outcome))
                        .foregroundStyle(stepColor(step.outcome))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 6) {
                            Text(TicketWorkUILabels.outcome(step.outcome))
                            if step.isRequired {
                                Text("Required")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    stepButtons(step)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier(TicketWorkflowAccessibility.stepRow(step.id))
            }
        }
    }

    @ViewBuilder
    private func stepButtons(_ step: TicketStepSnapshot) -> some View {
        HStack(spacing: 6) {
            if step.canAcknowledge {
                Button("Done") { model.acknowledge(stepID: step.id) }
                    .controlSize(.small)
            }
            if step.canSkip {
                Button("Skip") { model.skip(stepID: step.id) }
                    .controlSize(.small)
            }
            if step.canStartAction {
                Button("Start") { model.startAction(stepID: step.id) }
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
    }

    private var resultsSlot: some View {
        TicketWorkResultsSlotView(results: model.results)
    }

    @ViewBuilder
    private func blockers(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        if !snapshot.blockers.isEmpty || snapshot.lifecycle == .blocked {
            VStack(alignment: .leading, spacing: 8) {
                Text("Blockers")
                    .font(.headline)
                ForEach(snapshot.blockers) { blocker in
                    HStack {
                        Text(TicketWorkUILabels.blocker(blocker.code))
                        Spacer()
                        Button("Resume") {
                            model.resume(blockerID: blocker.id)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier(TicketWorkflowAccessibility.resumeButton)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessions(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        if !snapshot.associatedSessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions")
                    .font(.headline)
                ForEach(snapshot.associatedSessions) { session in
                    Text(session.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func workflowActions(_ snapshot: TicketWorkflowDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.headline)

            HStack(spacing: 8) {
                Button("Advance") { model.advance() }
                    .disabled(!snapshot.canAdvance)
                    .accessibilityIdentifier(TicketWorkflowAccessibility.advanceButton)

                Button("Return to Implementation") { model.returnToImplementation() }
                    .disabled(!snapshot.canReturnToImplementation)
                    .accessibilityIdentifier(TicketWorkflowAccessibility.returnToImplementationButton)
            }

            HStack(spacing: 8) {
                Picker("Blocker", selection: $model.pendingBlockerCode) {
                    ForEach(TicketBlockerCode.allCasesUI, id: \.self) { code in
                        Text(TicketWorkUILabels.blocker(code)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                Button("Block") { model.block() }
                    .disabled(snapshot.lifecycle == .closed)
                    .accessibilityIdentifier(TicketWorkflowAccessibility.blockButton)

                if let first = snapshot.blockers.first {
                    Button("Resume") { model.resume(blockerID: first.id) }
                        .accessibilityIdentifier(TicketWorkflowAccessibility.resumeButton)
                }
            }

            HStack(spacing: 8) {
                if snapshot.canClose {
                    Button("Close Workflow") { model.close() }
                        .accessibilityIdentifier(TicketWorkflowAccessibility.closeWorkflowButton)
                } else if let reason = TicketWorkUILabels.closeBlockedReason(snapshot.closeBlockedReason) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Forget Tracking", role: .destructive) { model.forget() }
                    .accessibilityIdentifier(TicketWorkflowAccessibility.forgetButton)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func stepIcon(_ outcome: TicketStepOutcome) -> String {
        switch outcome {
        case .succeeded, .acknowledged, .skipped: return "checkmark.circle.fill"
        case .failed, .interrupted: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .blocked: return "exclamationmark.octagon.fill"
        case .previouslyPassedNeedsRevalidation, .unverified: return "exclamationmark.circle"
        case .pending: return "circle"
        }
    }

    private func stepColor(_ outcome: TicketStepOutcome) -> Color {
        switch outcome {
        case .succeeded, .acknowledged: return .green
        case .failed, .interrupted, .blocked: return .red
        case .running: return .orange
        case .skipped: return .secondary
        default: return .secondary
        }
    }
}

private extension TicketBlockerCode {
    static var allCasesUI: [TicketBlockerCode] {
        [
            .waitingForInformation,
            .waitingForReviewer,
            .waitingForQA,
            .waitingForExternalAction,
            .workspaceRepairNeeded,
        ]
    }
}
