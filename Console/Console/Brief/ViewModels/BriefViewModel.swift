import AppKit
import SwiftUI

@Observable
@MainActor
final class BriefViewModel {
    private(set) var brief: MorningBrief?
    private(set) var isLoading = false
    private(set) var isRefining = false
    private(set) var errorMessage: String?
    private(set) var showCopiedFeedback = false
    private(set) var aliasDrafts: [UUID: String] = [:]
    private(set) var authorRows: [BriefAuthorDisplayRow] = []

    @ObservationIgnored private let generationService: BriefGenerationService
    @ObservationIgnored private let workspacesProvider: () -> [BriefWorkspaceSnapshot]
    @ObservationIgnored private let injectedRefiner: (any BriefRefining)?
    @ObservationIgnored private let identityReader: (any BriefIdentityReading)?
    @ObservationIgnored private var copiedFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var currentOperation: BriefOperationToken?
    @ObservationIgnored private var preparedDay: Date?

    let attributionStore: BriefAttributionStore

    init(generationService: BriefGenerationService? = nil,
         workspacePathsProvider: @escaping () -> [String] = { [] },
         workspacesProvider: (() -> [BriefWorkspaceSnapshot])? = nil,
         refiner: (any BriefRefining)? = nil,
         attributionStore: BriefAttributionStore? = nil,
         identityReader: (any BriefIdentityReading)? = nil) {
        self.generationService = generationService ?? BriefGenerationService()
        self.workspacesProvider = workspacesProvider ?? {
            workspacePathsProvider().map { path in
                BriefWorkspaceSnapshot(
                    id: UUID(),
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    directoryPath: path
                )
            }
        }
        self.injectedRefiner = refiner
        self.attributionStore = attributionStore ?? BriefAttributionStore()
        self.identityReader = identityReader
    }

    var dateRange: BriefDateRangeSelection {
        attributionStore.dateRange
    }

    // MARK: - Lifecycle

    /// Prepares the day's brief once per calendar day; later opens return the
    /// stored content instantly. `now` is injectable so a delayed previous-day
    /// operation can be tested against today's displayed brief.
    func prepareIfNeeded(now: Date = Date()) {
        let day = BriefStore.startOfDay(for: now)
        if let existing = brief, existing.day == day {
            preparedDay = day
            return
        }
        if currentOperation?.kind == .generate, currentOperation?.day == day {
            return
        }
        if preparedDay == day, brief?.day == day {
            return
        }

        let token = startOperation(.generate, day: day)
        operationTask = Task { [weak self, generationService] in
            guard let self else { return }
            let sources = await self.resolvedSources()
            self.refreshAuthorRows()
            let range = self.attributionStore.dateRange
            let outcome = await generationService.ensureBrief(
                for: now,
                sources: sources,
                range: range,
                token: token
            )
            self.applyOutcome(outcome, token: token)
        }
    }

    // MARK: - Actions

    func regenerate() {
        guard let current = brief else { return }
        let token = startOperation(.generate, day: current.day)
        let day = current.day
        operationTask = Task { [weak self, generationService] in
            guard let self else { return }
            let sources = await self.resolvedSources()
            self.refreshAuthorRows()
            let range = self.attributionStore.dateRange
            let outcome = await generationService.regenerate(
                for: day,
                sources: sources,
                range: range,
                token: token
            )
            self.applyOutcome(outcome, token: token)
        }
    }

    func setDateRangePreset(_ preset: BriefDateRangePreset) {
        var range = attributionStore.dateRange
        range.preset = preset
        if preset == .custom {
            let calendar = Calendar.current
            let today = BriefStore.startOfDay(for: brief?.day ?? Date(), calendar: calendar)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            if range.customStart == nil { range.customStart = yesterday }
            if range.customEnd == nil { range.customEnd = yesterday }
        }
        attributionStore.dateRange = range
    }

    func setCustomStart(_ date: Date) {
        var range = attributionStore.dateRange
        range.preset = .custom
        range.customStart = date
        attributionStore.dateRange = range
    }

    func setCustomEnd(_ date: Date) {
        var range = attributionStore.dateRange
        range.preset = .custom
        range.customEnd = date
        attributionStore.dateRange = range
    }

    func setAliasDraft(_ text: String, for workspaceID: UUID) {
        aliasDrafts[workspaceID] = text
    }

    func addAlias(for workspaceID: UUID) {
        let draft = aliasDrafts[workspaceID] ?? ""
        attributionStore.addEmail(draft, for: workspaceID)
        aliasDrafts[workspaceID] = ""
        refreshAuthorRows()
    }

    func confirmAuthor(for workspaceID: UUID) {
        attributionStore.confirm(workspaceID: workspaceID)
        refreshAuthorRows()
    }

    func refineWithAI(aiProviderManager: AIProviderManager?) {
        guard let current = brief else { return }
        guard let refiner = makeRefiner(aiProviderManager: aiProviderManager) else {
            errorMessage = BriefAIError.noProvider.localizedDescription
            return
        }
        let token = startOperation(.refine, day: current.day)
        let yesterdayLines = current.yesterdayLines
        let todayTasks = current.todayTasks
        operationTask = Task { [weak self, generationService] in
            do {
                let parsed = try await refiner.refine(
                    yesterdayLines: yesterdayLines,
                    todayTasks: todayTasks
                )
                let outcome = generationService.applyRefinement(parsed, token: token)
                self?.applyOutcome(outcome, token: token)
            } catch is CancellationError {
                self?.applyOutcome(.superseded, token: token)
            } catch {
                self?.applyFailure(error, token: token)
            }
        }
    }

    func updateTask(at index: Int, text: String) {
        guard let current = brief, current.todayTasks.indices.contains(index) else { return }
        var tasks = current.todayTasks
        tasks[index] = text
        brief = generationService.updateTasks(tasks, in: current)
    }

    func addTask() {
        guard let current = brief,
              current.todayTasks.count < MorningBrief.maxTodayTasks else { return }
        var tasks = current.todayTasks
        tasks.append("")
        brief = generationService.updateTasks(tasks, in: current)
    }

    func removeTask(at index: Int) {
        guard let current = brief, current.todayTasks.indices.contains(index) else { return }
        var tasks = current.todayTasks
        tasks.remove(at: index)
        brief = generationService.updateTasks(tasks, in: current)
    }

    func copyReport() {
        guard let reportText = brief?.reportText,
              !reportText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        showCopiedFeedback = true
        copiedFeedbackTask?.cancel()
        copiedFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.showCopiedFeedback = false
        }
    }

    var canRefineWithAI: Bool {
        if injectedRefiner != nil { return true }
        guard let manager = AppDependencies.shared.aiProviderManager else { return false }
        return manager.selectedProvider != AIProvider.none
    }

    // MARK: - Operation lifetime

    /// Starts a new generate/refine. Generation is incremented first so a
    /// cancelled predecessor that resumes immediately is already superseded.
    private func startOperation(_ kind: BriefOperationKind, day: Date) -> BriefOperationToken {
        let token = generationService.beginOperation(kind, for: day)
        operationTask?.cancel()
        currentOperation = token
        isLoading = kind == .generate
        isRefining = kind == .refine
        errorMessage = nil
        return token
    }

    private func applyOutcome(_ outcome: BriefOperationOutcome, token: BriefOperationToken) {
        guard currentOperation == token else { return }
        currentOperation = nil
        isLoading = false
        isRefining = false
        guard case .applied(let incoming) = outcome else { return }
        guard shouldDisplay(incoming) else { return }
        brief = incoming
        preparedDay = BriefStore.startOfDay(for: incoming.day)
    }

    private func applyFailure(_ error: Error, token: BriefOperationToken) {
        guard currentOperation == token else { return }
        currentOperation = nil
        isLoading = false
        isRefining = false
        errorMessage = error.localizedDescription
    }

    /// A delayed previous-day result must not replace a newer displayed brief.
    private func shouldDisplay(_ incoming: MorningBrief) -> Bool {
        guard let displayed = brief?.day else { return true }
        return incoming.day == displayed || incoming.day > displayed
    }

    private func resolvedSources() async -> [BriefCollectionSource] {
        await attributionStore.sources(
            for: workspacesProvider(),
            probing: identityReader
        )
    }

    private func refreshAuthorRows() {
        authorRows = workspacesProvider().compactMap { workspace in
            guard let selection = attributionStore.selection(for: workspace.id) else { return nil }
            return BriefAuthorDisplayRow(
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                identity: selection.identity,
                confirmed: selection.confirmed
            )
        }
    }

    private func makeRefiner(aiProviderManager: AIProviderManager?) -> (any BriefRefining)? {
        if let injectedRefiner { return injectedRefiner }
        guard let aiProviderManager else { return nil }
        return ProviderBackedBriefRefiner(aiProviderManager: aiProviderManager)
    }
}

struct BriefAuthorDisplayRow: Identifiable, Equatable {
    var workspaceID: UUID
    var workspaceName: String
    var identity: BriefAuthorIdentity
    var confirmed: Bool

    var id: UUID { workspaceID }
}
