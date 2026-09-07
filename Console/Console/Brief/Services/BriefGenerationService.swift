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
    private let sequencer: BriefOperationSequencer

    private var taskEditRevisionByDay: [Date: UInt64] = [:]

    init(store: BriefStore? = nil,
         collector: (any BriefActivityCollecting)? = nil) {
        let resolvedStore = store ?? BriefStore()
        self.store = resolvedStore
        self.sequencer = BriefGenerationService.sequencer(forDirectory: resolvedStore.directory)
        self.collector = collector ?? BriefActivityCollector()
    }

    /// Operation generations are shared by every service that persists to the
    /// same brief directory, so a late generate from one instance cannot
    /// overwrite a newer write from another (e.g. launch bootstrap vs the
    /// Brief panel).
    @MainActor
    private final class BriefOperationSequencer {
        private(set) var generation: UInt64 = 0

        func nextID() -> UInt64 {
            generation += 1
            return generation
        }

        var currentID: UInt64 { generation }
    }

    private static var sequencersByDirectory: [String: BriefOperationSequencer] = [:]

    private static func sequencer(forDirectory directory: URL) -> BriefOperationSequencer {
        if let existing = sequencersByDirectory[directory.path] { return existing }
        let created = BriefOperationSequencer()
        sequencersByDirectory[directory.path] = created
        return created
    }

    // MARK: - Queries

    func brief(forDay day: Date) -> MorningBrief? {
        store.load(forDay: BriefStore.startOfDay(for: day))
    }

    func isCurrent(_ token: BriefOperationToken) -> Bool {
        token.id == sequencer.currentID
    }

    /// Increments the operation generation. Any previously started generate
    /// or refine token is superseded from this point.
    @discardableResult
    func beginOperation(_ kind: BriefOperationKind,
                        for day: Date,
                        calendar: Calendar = .current) -> BriefOperationToken {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        let id = sequencer.nextID()
        return BriefOperationToken(
            id: id,
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
                     calendar: Calendar = .current,
                     range: BriefDateRangeSelection = .yesterday) async -> MorningBrief {
        await ensureBrief(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            range: range
        )
    }

    func ensureBrief(for day: Date,
                     sources: [BriefCollectionSource],
                     calendar: Calendar = .current,
                     range: BriefDateRangeSelection = .yesterday) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            return existing
        }
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                sources: sources,
                range: range,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func ensureBrief(for day: Date,
                     workspacePaths: [String],
                     calendar: Calendar = .current,
                     range: BriefDateRangeSelection = .yesterday,
                     token: BriefOperationToken) async -> BriefOperationOutcome {
        await ensureBrief(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            range: range,
            token: token
        )
    }

    func ensureBrief(for day: Date,
                     sources: [BriefCollectionSource],
                     calendar: Calendar = .current,
                     range: BriefDateRangeSelection = .yesterday,
                     token: BriefOperationToken) async -> BriefOperationOutcome {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            guard isCurrent(token) else { return .superseded }
            return .applied(existing)
        }
        return await performGeneration(
            dayStart: dayStart,
            sources: sources,
            range: range,
            calendar: calendar,
            token: token
        )
    }

    /// Rebuilds yesterday's lines from current activity data. Manually edited
    /// tasks always survive, and a quiet collection result never erases an
    /// already-recorded report.
    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current,
                    range: BriefDateRangeSelection = .yesterday) async -> MorningBrief {
        await regenerate(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            range: range
        )
    }

    func regenerate(for day: Date,
                    sources: [BriefCollectionSource],
                    calendar: Calendar = .current,
                    range: BriefDateRangeSelection = .yesterday) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                sources: sources,
                range: range,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current,
                    range: BriefDateRangeSelection = .yesterday,
                    token: BriefOperationToken) async -> BriefOperationOutcome {
        await regenerate(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            range: range,
            token: token
        )
    }

    func regenerate(for day: Date,
                    sources: [BriefCollectionSource],
                    calendar: Calendar = .current,
                    range: BriefDateRangeSelection = .yesterday,
                    token: BriefOperationToken) async -> BriefOperationOutcome {
        await performGeneration(
            dayStart: BriefStore.startOfDay(for: day, calendar: calendar),
            sources: sources,
            range: range,
            calendar: calendar,
            token: token
        )
    }

    private func performGeneration(dayStart: Date,
                                   sources: [BriefCollectionSource],
                                   range: BriefDateRangeSelection,
                                   calendar: Calendar,
                                   token: BriefOperationToken) async -> BriefOperationOutcome {
        let request = BriefCollectionRequest(
            sources: sources,
            range: range,
            briefDay: dayStart,
            calendar: calendar
        )
        let collected = await collector.collectActivities(request)
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
            activities: collected.activities,
            carriedTasks: carriedTasks,
            activityRange: request.interval,
            sourceRepositoryNames: collected.sourceRepositories.map(\.displayName)
        )
        if let latest {
            brief.tasksManuallyEdited = latest.tasksManuallyEdited
            // A quiet result never erases an already-recorded report.
            if brief.yesterdayLines == [BriefComposer.quietDayLine],
               latest.yesterdayLines != [BriefComposer.quietDayLine] {
                brief.yesterdayLines = latest.yesterdayLines
                brief.activityRangeStart = latest.activityRangeStart
                brief.activityRangeEnd = latest.activityRangeEnd
                brief.sourceRepositoryNames = latest.sourceRepositoryNames
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

    static func sources(from workspacePaths: [String]) -> [BriefCollectionSource] {
        workspacePaths.map { path in
            BriefCollectionSource(
                workspaceID: nil,
                path: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                identity: BriefAuthorIdentity()
            )
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
