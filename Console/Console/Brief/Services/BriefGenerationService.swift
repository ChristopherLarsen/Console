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
}

/// Result of finishing generate/refine. `.superseded` must not be written
/// to disk or applied to the UI.
enum BriefOperationOutcome: Equatable {
    case applied(MorningBrief)
    case superseded
}

/// Owns brief lifecycle for the app: ensures a pre-prepared brief exists for
/// today, regenerates it, and applies AI refinement.
///
/// Policy: **last-started operation wins**. Starting Regenerate supersedes an
/// in-flight Refine, and starting Refine supersedes an in-flight Regenerate.
/// Completions that arrive later for an older token do not update disk or UI.
@MainActor
final class BriefGenerationService {
    private let store: BriefStore
    private let collector: any BriefActivityCollecting
    private let sequencer: BriefOperationSequencer

    /// Persisted-content error from the most recent write attempt. Save
    /// failures must be visible: the UI otherwise shows content the disk
    /// never received, and a later regenerate silently reloads stale data.
    private(set) var lastPersistenceError: String?

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
            kind: kind
        )
    }

    // MARK: - Generation

    /// How far back auto-detection searches for the last day with completed
    /// work before giving up and reporting a quiet weekday.
    static let workdayLookbackDays = 14

    /// Returns today's stored brief, generating it deterministically when
    /// missing. Cheap to call on every panel open; collection only runs when
    /// generation is actually required.
    func ensureBrief(for day: Date,
                     workspacePaths: [String],
                     calendar: Calendar = .current,
                     workday: Date? = nil) async -> MorningBrief {
        await ensureBrief(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            workday: workday
        )
    }

    func ensureBrief(for day: Date,
                     sources: [BriefCollectionSource],
                     calendar: Calendar = .current,
                     workday: Date? = nil) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            return existing
        }
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                sources: sources,
                workday: workday,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func ensureBrief(for day: Date,
                     workspacePaths: [String],
                     calendar: Calendar = .current,
                     workday: Date? = nil,
                     token: BriefOperationToken) async -> BriefOperationOutcome {
        await ensureBrief(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            workday: workday,
            token: token
        )
    }

    func ensureBrief(for day: Date,
                     sources: [BriefCollectionSource],
                     calendar: Calendar = .current,
                     workday: Date? = nil,
                     token: BriefOperationToken) async -> BriefOperationOutcome {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        if let existing = store.load(forDay: dayStart) {
            guard isCurrent(token) else { return .superseded }
            return .applied(existing)
        }
        return await performGeneration(
            dayStart: dayStart,
            sources: sources,
            workday: workday,
            calendar: calendar,
            token: token
        )
    }

    /// Rebuilds the report from current activity data. A quiet collection
    /// result never erases an already-recorded report.
    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current,
                    workday: Date? = nil) async -> MorningBrief {
        await regenerate(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            workday: workday
        )
    }

    func regenerate(for day: Date,
                    sources: [BriefCollectionSource],
                    calendar: Calendar = .current,
                    workday: Date? = nil) async -> MorningBrief {
        let dayStart = BriefStore.startOfDay(for: day, calendar: calendar)
        let token = beginOperation(.generate, for: dayStart, calendar: calendar)
        return resolvedBrief(
            from: await performGeneration(
                dayStart: dayStart,
                sources: sources,
                workday: workday,
                calendar: calendar,
                token: token
            ),
            dayStart: dayStart
        )
    }

    func regenerate(for day: Date,
                    workspacePaths: [String],
                    calendar: Calendar = .current,
                    workday: Date? = nil,
                    token: BriefOperationToken) async -> BriefOperationOutcome {
        await regenerate(
            for: day,
            sources: Self.sources(from: workspacePaths),
            calendar: calendar,
            workday: workday,
            token: token
        )
    }

    func regenerate(for day: Date,
                    sources: [BriefCollectionSource],
                    calendar: Calendar = .current,
                    workday: Date? = nil,
                    token: BriefOperationToken) async -> BriefOperationOutcome {
        await performGeneration(
            dayStart: BriefStore.startOfDay(for: day, calendar: calendar),
            sources: sources,
            workday: workday,
            calendar: calendar,
            token: token
        )
    }

    private func performGeneration(dayStart: Date,
                                   sources: [BriefCollectionSource],
                                   workday: Date?,
                                   calendar: Calendar,
                                   token: BriefOperationToken) async -> BriefOperationOutcome {
        // Explicit pick: collect exactly that workday. Auto: scan a lookback
        // window so the last day with completed work wins — weekends,
        // holidays, and quiet days are skipped automatically.
        let window: DateInterval
        if let workday {
            window = BriefComposer.workdayInterval(for: workday, calendar: calendar)
        } else {
            let lookbackStart = calendar.date(
                byAdding: .day,
                value: -Self.workdayLookbackDays,
                to: dayStart
            ) ?? dayStart
            window = DateInterval(start: lookbackStart, end: dayStart)
        }
        let request = BriefCollectionRequest(
            sources: sources,
            rangeStart: window.start,
            rangeEnd: window.end,
            calendar: calendar
        )
        let collected = await collector.collectActivities(request)
        guard isCurrent(token) else { return .superseded }

        let reportedDay: Date
        let dayActivities: [CommitActivity]
        if let workday {
            // An explicit pick reports exactly that workday.
            reportedDay = calendar.startOfDay(for: workday)
            dayActivities = collected.activities.filter {
                calendar.startOfDay(for: $0.committedAt) == reportedDay
            }
        } else if let activeDay = BriefComposer.mostRecentActiveDay(
            of: collected.activities,
            before: dayStart,
            calendar: calendar
        ) {
            reportedDay = activeDay
            dayActivities = collected.activities.filter {
                calendar.startOfDay(for: $0.committedAt) == activeDay
            }
        } else {
            reportedDay = BriefComposer.previousWeekday(before: dayStart, calendar: calendar)
            dayActivities = []
        }

        let latest = store.load(forDay: dayStart)
        var brief = BriefComposer.compose(
            day: dayStart,
            activities: dayActivities,
            activityRange: BriefComposer.workdayInterval(for: reportedDay, calendar: calendar),
            sourceRepositoryNames: collected.sourceRepositories.map(\.displayName)
        )
        if let latest, workday == nil {
            // A quiet auto-detected result never erases an already-recorded
            // report. Explicit picks always report exactly the chosen day.
            if brief.yesterdayLines == [BriefComposer.quietDayLine],
               latest.yesterdayLines != [BriefComposer.quietDayLine] {
                brief.yesterdayLines = latest.yesterdayLines
                brief.activityRangeStart = latest.activityRangeStart
                brief.activityRangeEnd = latest.activityRangeEnd
                brief.sourceRepositoryNames = latest.sourceRepositoryNames
                brief.source = latest.source
            }
        }
        save(brief)
        return .applied(brief)
    }

    private func resolvedBrief(from outcome: BriefOperationOutcome,
                               dayStart: Date) -> MorningBrief {
        switch outcome {
        case .applied(let brief):
            return brief
        case .superseded:
            return store.load(forDay: dayStart)
                ?? BriefComposer.compose(day: dayStart, activities: [])
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

    /// Applies parsed AI output as the new report content.
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
        updated.source = .ai
        updated.generatedAt = Date()
        save(updated)
        return .applied(updated)
    }

    /// Persists and records a failure in `lastPersistenceError` so the UI can
    /// surface it — a failed write must never look like success.
    private func save(_ brief: MorningBrief) {
        do {
            try store.save(brief)
            lastPersistenceError = nil
        } catch {
            printDebug("[Brief] Failed to persist brief: \(error.localizedDescription)")
            lastPersistenceError = "Could not save the brief: \(error.localizedDescription)"
        }
    }
}
