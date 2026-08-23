import Foundation

/// Owns brief lifecycle for the app: ensures a pre-prepared brief exists for
/// today, regenerates it, applies AI refinement, and persists task edits.
@MainActor
final class BriefGenerationService {
    private let store: BriefStore
    private let collector: any BriefActivityCollecting

    init(store: BriefStore? = nil,
         collector: (any BriefActivityCollecting)? = nil) {
        self.store = store ?? BriefStore()
        self.collector = collector ?? BriefActivityCollector()
    }

    // MARK: - Queries

    func brief(forDay day: Date) -> MorningBrief? {
        store.load(forDay: BriefStore.startOfDay(for: day))
    }

    // MARK: - Generation

    /// Returns today's stored brief, generating it deterministically when
    /// missing. Cheap to call on every panel open; collection only runs when
    /// generation is actually required.
    func ensureBrief(for day: Date,
                     workspacePaths: [String],
                     calendar: Calendar = .current) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            return existing
        }
        return await generate(dayStart: dayStart,
                              workspacePaths: workspacePaths,
                              calendar: calendar)
    }

    /// Rebuilds yesterday's lines from current activity data. Manually edited
    /// tasks always survive, and a quiet collection result never erases an
    /// already-recorded report.
    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        return await generate(dayStart: dayStart,
                              workspacePaths: workspacePaths,
                              calendar: calendar)
    }

    private func generate(dayStart: Date,
                          workspacePaths: [String],
                          calendar: Calendar) async -> MorningBrief {
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        // A same-day brief with hand-edited tasks keeps them across
        // regeneration; otherwise tasks carry forward from the most recent
        // earlier day.
        let existing = store.load(forDay: dayStart)
        let carriedTasks: [String]
        if let existing, existing.tasksManuallyEdited {
            carriedTasks = existing.todayTasks
        } else {
            carriedTasks = existing?.todayTasks.isEmpty == false
                ? existing!.todayTasks
                : (store.loadMostRecent(before: dayStart, calendar: calendar)?.todayTasks ?? [])
        }
        let activities = await collector.collectActivities(
            workspacePaths: workspacePaths,
            day: previousDay,
            calendar: calendar
        )
        var brief = BriefComposer.compose(
            day: dayStart,
            activities: activities,
            carriedTasks: carriedTasks
        )
        if let existing {
            brief.tasksManuallyEdited = existing.tasksManuallyEdited
            // A quiet result never erases an already-recorded report.
            if brief.yesterdayLines == [BriefComposer.quietDayLine],
               existing.yesterdayLines != [BriefComposer.quietDayLine] {
                brief.yesterdayLines = existing.yesterdayLines
                if !brief.tasksManuallyEdited { brief.source = existing.source }
            }
        }
        store.save(brief)
        return brief
    }

    // MARK: - Mutations

    /// Applies parsed AI output as the new report content. Today tasks are
    /// only taken when the user has not hand-edited them.
    @discardableResult
    func applyRefinement(_ parsed: BriefAIResponseParser.Parsed, to brief: MorningBrief) -> MorningBrief {
        var updated = brief
        updated.yesterdayLines = parsed.yesterdayLines
        if !brief.tasksManuallyEdited, !parsed.todayTasks.isEmpty {
            updated.todayTasks = parsed.todayTasks
        }
        updated.source = .ai
        updated.generatedAt = Date()
        store.save(updated)
        return updated
    }

    /// Persists a hand edit of today's tasks.
    @discardableResult
    func updateTasks(_ tasks: [String], in brief: MorningBrief) -> MorningBrief {
        var updated = brief
        updated.todayTasks = Array(tasks.prefix(MorningBrief.maxTodayTasks))
        updated.tasksManuallyEdited = true
        store.save(updated)
        return updated
    }
}
