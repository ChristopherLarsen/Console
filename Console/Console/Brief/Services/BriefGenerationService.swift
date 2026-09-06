import Foundation

/// Kind of in-flight Brief work. Starting either kind increments the
/// shared operation generation so the later click wins.
enum BriefOperationKind: Equatable, Sendable {
    case generate
    case refine
}

/// Identifies one generate/refine attempt. Cancellation is decided by
/// whether this token is still current, not by a weak view-model reference.
struct BriefOperationToken: Equatable, Sendable {
    let id: UInt64
    let day: Date
    let kind: BriefOperationKind
    let taskEditRevision: UInt64
}

/// Result of finishing generate/refine. `.superseded` must not be written
/// to disk or applied to the UI.
enum BriefOperationOutcome: Equatable {
    case applied(MorningBrief)
    case superseded
}

/// Owns brief lifecycle for the app: ensures a pre-prepared brief exists for
/// today, regenerates it, applies AI refinement, and persists task edits.
///
/// Policy: **last-started operation wins**. Starting Regenerate supersedes an
/// in-flight Refine, and starting Refine supersedes an in-flight Regenerate.
/// Completions that arrive later for an older token do not update disk or UI.
@MainActor
final class BriefGenerationService {
    private let store: BriefStore
    private let collector: any BriefActivityCollecting

    private var operationGeneration: UInt64 = 0
    private var taskEditRevisionByDay: [Date: UInt64] = [:]

    init(store: BriefStore? = nil,
         collector: (any BriefActivityCollecting)? = nil) {
        self.store = store ?? BriefStore()
        self.collector = collector ?? BriefActivityCollector()
    }

    // MARK: - Queries

    func brief(forDay day: Date) -> MorningBrief? {
        store.load(forDay: BriefStore.startOfDay(for: day))
    }

    func isCurrent(_ token: BriefOperationToken) -> Bool {
        token.id == operationGeneration
    }

    /// Increments the operation generation. Any previously started generate
    /// or refine token is superseded from this point.
    @discardableResult
    func beginOperation(_ kind: BriefOperationKind,
                        for day: Date,
                        calendar: Calendar = .current) -> BriefOperationToken {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        operationGeneration += 1
        return BriefOperationToken(
            id: operationGeneration,
            day: dayStart,
            kind: kind,
            taskEditRevision: taskEditRevisionByDay[dayStart] ?? 0
        )
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
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                workspacePaths: workspacePaths,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func ensureBrief(for day: Date,
                     workspacePaths: [String],
                     calendar: Calendar = .current,
                     token: BriefOperationToken) async -> BriefOperationOutcome {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            guard isCurrent(token) else { return .superseded }
            return .applied(existing)
        }
        return await performGeneration(
            dayStart: dayStart,
            workspacePaths: workspacePaths,
            calendar: calendar,
            token: token
        )
    }

    /// Rebuilds yesterday's lines from current activity data. Manually edited
    /// tasks always survive, and a quiet collection result never erases an
    /// already-recorded report.
    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                workspacePaths: workspacePaths,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current,
                    token: BriefOperationToken) async -> BriefOperationOutcome {
        await performGeneration(
            dayStart: BriefStore.startOfDay(for: day, calendar: calendar),
            workspacePaths: workspacePaths,
            calendar: calendar,
            token: token
        )
    }

    private func performGeneration(dayStart: Date,
                                   workspacePaths: [String],
                                   calendar: Calendar,
                                   token: BriefOperationToken) async -> BriefOperationOutcome {
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let activities = await collector.collectActivities(
            workspacePaths: workspacePaths,
            day: previousDay,
            calendar: calendar
        )
        guard isCurrent(token) else { return .superseded }

        let latest = store.load(forDay: dayStart)
        let editedDuringFlight = (taskEditRevisionByDay[dayStart] ?? 0) > token.taskEditRevision
        let carriedTasks = carriedTasks(
            from: latest,
            dayStart: dayStart,
            calendar: calendar,
            preserveLatestTasks: editedDuringFlight
        )
        var brief = BriefComposer.compose(
            day: dayStart,
            activities: activities,
            carriedTasks: carriedTasks
        )
        if let latest {
            brief.tasksManuallyEdited = latest.tasksManuallyEdited
            // A quiet result never erases an already-recorded report.
            if brief.yesterdayLines == [BriefComposer.quietDayLine],
               latest.yesterdayLines != [BriefComposer.quietDayLine] {
                brief.yesterdayLines = latest.yesterdayLines
                if !brief.tasksManuallyEdited { brief.source = latest.source }
            }
        }
        store.save(brief)
        return .applied(brief)
    }

    private func carriedTasks(from latest: MorningBrief?,
                              dayStart: Date,
                              calendar: Calendar,
                              preserveLatestTasks: Bool) -> [String] {
        if let latest, latest.tasksManuallyEdited || preserveLatestTasks {
            return latest.todayTasks
        }
        if let latest, !latest.todayTasks.isEmpty {
            return latest.todayTasks
        }
        return store.loadMostRecent(before: dayStart, calendar: calendar)?.todayTasks ?? []
    }

    private func resolvedBrief(from outcome: BriefOperationOutcome,
                               dayStart: Date) -> MorningBrief {
        switch outcome {
        case .applied(let brief):
            return brief
        case .superseded:
            return store.load(forDay: dayStart)
                ?? BriefComposer.compose(day: dayStart, activities: [], carriedTasks: [])
        }
    }

    // MARK: - Mutations

    /// Applies parsed AI output as the new report content. Today tasks are
    /// only taken when the user has not hand-edited them.
    @discardableResult
    func applyRefinement(_ parsed: BriefAIResponseParser.Parsed, to brief: MorningBrief) -> MorningBrief {
        let token = beginOperation(.refine, for: brief.day)
        switch applyRefinement(parsed, token: token) {
        case .applied(let updated):
            return updated
        case .superseded:
            return store.load(forDay: brief.day) ?? brief
        }
    }

    func applyRefinement(_ parsed: BriefAIResponseParser.Parsed,
                         token: BriefOperationToken) -> BriefOperationOutcome {
        guard isCurrent(token) else { return .superseded }
        guard let latest = store.load(forDay: token.day) else { return .superseded }

        var updated = latest
        updated.yesterdayLines = parsed.yesterdayLines
        let editedDuringFlight = (taskEditRevisionByDay[token.day] ?? 0) > token.taskEditRevision
        if !latest.tasksManuallyEdited, !editedDuringFlight, !parsed.todayTasks.isEmpty {
            updated.todayTasks = parsed.todayTasks
        }
        updated.source = .ai
        updated.generatedAt = Date()
        store.save(updated)
        return .applied(updated)
    }

    /// Persists a hand edit of today's tasks.
    @discardableResult
    func updateTasks(_ tasks: [String], in brief: MorningBrief) -> MorningBrief {
        let day = brief.day
        taskEditRevisionByDay[day, default: 0] += 1
        let latest = store.load(forDay: day) ?? brief
        var updated = latest
        updated.todayTasks = Array(tasks.prefix(MorningBrief.maxTodayTasks))
        updated.tasksManuallyEdited = true
        store.save(updated)
        return updated
    }
}
