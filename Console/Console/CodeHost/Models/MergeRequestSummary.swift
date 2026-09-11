import Foundation

/// The two retained merge-request lists Console keeps open per code host.
///
/// Both panels share one authenticated WebKit website data store but own
/// independent pages and navigation histories.
enum CodeHostListKind: String, CaseIterable, Sendable {
    case reviewsRequested
    case authored

    /// Short label used in panel chrome and sidebar controls. Matches the
    /// Home quadrant titles ("MRs to Review" / "My MRs") so one surface never
    /// renames the same list.
    var displayTitle: String {
        switch self {
        case .reviewsRequested: return "MRs to Review"
        case .authored: return "My MRs"
        }
    }

    /// Wording used when the configured URL turns out not to be this list.
    var listExpectationText: String {
        switch self {
        case .reviewsRequested: return "The configured URL must be your merge-request review list."
        case .authored: return "The configured URL must be your authored merge-request list."
        }
    }
}

/// Memory-only summary of one merge-request row the active code host rendered
/// in a list. Identity is the normalized absolute URL; IIDs are only unique
/// per project.
struct MergeRequestSummary: Identifiable, Equatable, Sendable {
    let id: URL
    let iidText: String?
    let title: String
    let projectDisplayName: String?
    let authorDisplayName: String?
    let isDraft: Bool
    let pipelineDisplayState: String?
    let reviewDisplayState: String?
    let updatedText: String?
    /// Host-rendered target version (GitLab milestone title, e.g. "24.10").
    /// Nil when the host rendered no milestone in the row.
    var targetVersionText: String? = nil
    let mergeRequestURL: URL
    let sourceOrder: Int
    var triageCategory: MRReviewCategory? = nil
    var triageReason: String? = nil
    var jiraIssueKey: String? = nil
}

/// Why a manual refresh did not produce fresh cards. Values are fixed,
/// data-free strings safe for state descriptions.
enum MergeRequestRefreshFailureReason: String, Equatable, Sendable {
    case timedOut
    case signInRequired
    case pageWasNotAList
    case extractionFailed

    var reasonText: String {
        switch self {
        case .timedOut: return "Refresh timed out"
        case .signInRequired: return "Sign-in required"
        case .pageWasNotAList: return "Page was not a merge-request list"
        case .extractionFailed: return "Refresh failed"
        }
    }
}

/// Explicit panel states. Descriptions intentionally never include extracted
/// MR content such as titles, URLs, projects, or author names.
enum MergeRequestListPanelState: Equatable {
    case unconfigured
    case loadingPage
    case authenticationRequired
    case extracting
    case loaded(items: [MergeRequestSummary], refreshedAt: Date)
    case empty(refreshedAt: Date)
    case stale(items: [MergeRequestSummary], refreshedAt: Date, reason: MergeRequestRefreshFailureReason)
    case unsupportedPage
    case extractionFailed

    /// Cards from the last successful extraction, if any should stay visible.
    var retainedItems: [MergeRequestSummary] {
        switch self {
        case .loaded(let items, _), .stale(let items, _, _):
            return items
        default:
            return []
        }
    }

    var refreshedAt: Date? {
        switch self {
        case .loaded(_, let date), .empty(let date), .stale(_, let date, _):
            return date
        default:
            return nil
        }
    }
}

extension MergeRequestListPanelState: CustomStringConvertible, CustomDebugStringConvertible {
    private var redactedName: String {
        switch self {
        case .unconfigured: return "unconfigured"
        case .loadingPage: return "loadingPage"
        case .authenticationRequired: return "authenticationRequired"
        case .extracting: return "extracting"
        case .loaded: return "loaded(\(retainedItems.count) items)"
        case .empty: return "empty"
        case .stale: return "stale(\(retainedItems.count) items)"
        case .unsupportedPage: return "unsupportedPage"
        case .extractionFailed: return "extractionFailed"
        }
    }

    var description: String { redactedName }
    var debugDescription: String { redactedName }
}
