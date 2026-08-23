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
    @ObservationIgnored private let workspacePathsProvider: () -> [String]
    @ObservationIgnored private var copiedFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var preparedDay: Date?

    init(generationService: BriefGenerationService? = nil,
         workspacePathsProvider: @escaping () -> [String] = { [] }) {
        self.generationService = generationService ?? BriefGenerationService()
        self.workspacePathsProvider = workspacePathsProvider
    }

    // MARK: - Lifecycle

    /// Prepares the day's brief once per calendar day; later opens return the
    /// stored content instantly.
    func prepareIfNeeded() {
        guard !isLoading else { return }
        let day = BriefStore.startOfDay(for: Date())
        if let existing = brief, existing.day == day {
            preparedDay = day
            return
        }
        guard preparedDay != day else { return }

        isLoading = true
        errorMessage = nil
        let paths = workspacePathsProvider()
        Task { [weak self] in
            let generated = await self?.generationService.ensureBrief(
                for: Date(),
                workspacePaths: paths
            )
            guard let self, let generated else {
                self?.isLoading = false
                return
            }
            self.brief = generated
            self.preparedDay = BriefStore.startOfDay(for: generated.day)
            self.isLoading = false
        }
    }

    // MARK: - Actions

    func regenerate() {
        guard let current = brief, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let paths = workspacePathsProvider()
        Task { [weak self] in
            let regenerated = await self?.generationService.regenerate(
                for: current.day,
                workspacePaths: paths
            )
            guard let self, let regenerated else {
                self?.isLoading = false
                return
            }
            self.brief = regenerated
            self.isLoading = false
        }
    }

    func refineWithAI(aiProviderManager: AIProviderManager?) {
        guard let current = brief, !isRefining else { return }
        isRefining = true
        errorMessage = nil
        Task { [weak self] in
            do {
                guard let aiProviderManager else { throw BriefAIError.noProvider }
                guard let self else { return }
                let parsed = try await BriefAIService.refine(
                    yesterdayLines: current.yesterdayLines,
                    todayTasks: current.todayTasks,
                    aiProviderManager: aiProviderManager
                )
                self.brief = self.generationService.applyRefinement(parsed, to: current)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isRefining = false
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
        guard let manager = AppDependencies.shared.aiProviderManager else { return false }
        return manager.selectedProvider != AIProvider.none
    }
}
