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

    @ObservationIgnored private let generationService: BriefGenerationService
    @ObservationIgnored private let workspacesProvider: () -> [BriefWorkspaceSnapshot]
    @ObservationIgnored private let injectedRefiner: (any BriefRefining)?
    @ObservationIgnored private let identityReader: (any BriefIdentityReading)?
    @ObservationIgnored private var copiedFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var dayRolloverTask: Task<Void, Never>?
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

    /// The workday the user explicitly picked to report on; nil means
    /// auto-detect the previous workday from commit activity. Deliberately
    /// in-memory only: the pick lasts the session/day, then the brief
    /// returns to automatic detection on the next day or launch.
    private(set) var selectedWorkday: Date?

    // MARK: - Lifecycle

    /// Prepares the day's brief once per calendar day; later opens return the
    /// stored content instantly. `now` is injectable so a delayed previous-day
    /// operation can be tested against today's displayed brief.
    func prepareIfNeeded(now: Date = Date()) {
        scheduleDayRolloverMonitor(from: now)
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

        // New day (or fresh launch): any manual workday pick expires.
        selectedWorkday = nil
        let token = startOperation(.generate, day: day)
        operationTask = Task { [weak self, generationService] in
            guard let self else { return }
            let sources = await self.resolvedSources()
            let outcome = await generationService.ensureBrief(
                for: now,
                sources: sources,
                workday: self.selectedWorkday,
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
            let outcome = await generationService.regenerate(
                for: day,
                sources: sources,
                workday: self.selectedWorkday,
                token: token
            )
            self.applyOutcome(outcome, token: token)
        }
    }

    /// Reports work completed on the exact chosen day. The pick is a
    /// per-day override: it lives only until the next day or launch, then
    /// the brief returns to automatic previous-workday detection.
    func chooseWorkday(_ date: Date) {
        selectedWorkday = date
        regenerate()
    }

    func refineWithAI(aiProviderManager: AIProviderManager?) {
        guard let current = brief else { return }
        guard let refiner = makeRefiner(aiProviderManager: aiProviderManager) else {
            errorMessage = BriefAIError.noProvider.localizedDescription
            return
        }
        let token = startOperation(.refine, day: current.day)
        let yesterdayLines = current.yesterdayLines
        operationTask = Task { [weak self, generationService] in
            do {
                let parsed = try await refiner.refine(yesterdayLines: yesterdayLines)
                let outcome = generationService.applyRefinement(parsed, token: token)
                self?.applyOutcome(outcome, token: token)
            } catch is CancellationError {
                self?.applyOutcome(.superseded, token: token)
            } catch {
                self?.applyFailure(error, token: token)
            }
        }
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

    // MARK: - Day rollover

    /// Re-prepares when the calendar day changes while the Brief stays
    /// selected (no remount, so `onAppear` never fires again). Idempotent:
    /// `prepareIfNeeded` ignores same-day calls and in-flight generations.
    func handleDayRollover(now: Date = Date()) {
        prepareIfNeeded(now: now)
    }

    private func scheduleDayRolloverMonitor(from now: Date) {
        dayRolloverTask?.cancel()
        let calendar = Calendar.current
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now
        // +1s slack so the timer fires after the boundary, not on it.
        let delay = max(1, nextMidnight.timeIntervalSince(now) + 1)
        dayRolloverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.handleDayRollover()
        }
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
        errorMessage = generationService.lastPersistenceError
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

    private func makeRefiner(aiProviderManager: AIProviderManager?) -> (any BriefRefining)? {
        if let injectedRefiner { return injectedRefiner }
        guard let aiProviderManager else { return nil }
        return ProviderBackedBriefRefiner(aiProviderManager: aiProviderManager)
    }
}
