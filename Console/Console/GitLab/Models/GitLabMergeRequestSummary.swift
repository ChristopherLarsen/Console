import Foundation

/// The two retained GitLab merge-request lists Console keeps open.
///
/// Both panels share one authenticated WebKit website data store but own
/// independent pages and navigation histories.
enum GitLabListKind: String, CaseIterable, Sendable {
    case reviewsRequested
    case authored

    /// Short label used in panel chrome and sidebar controls.
    var displayTitle: String {
        switch self {
        case .reviewsRequested: return "Reviews Requested"
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

/// Memory-only summary of one merge-request row GitLab rendered in a list.
/// Identity is the normalized absolute MR URL; IIDs are only unique per project.
struct GitLabMergeRequestSummary: Identifiable, Equatable, Sendable {
    let id: URL
    let iidText: String?
    let title: String
    let projectDisplayName: String?
    let authorDisplayName: String?
    let isDraft: Bool
    let pipelineDisplayState: String?
    let reviewDisplayState: String?
    let updatedText: String?
    let mergeRequestURL: URL
    let sourceOrder: Int
}

/// Why a manual refresh did not produce fresh cards. Values are fixed,
/// data-free strings safe for state descriptions.
enum GitLabRefreshFailureReason: String, Equatable, Sendable {
    case signInRequired
    case pageWasNotAList
    case extractionFailed

    var reasonText: String {
        switch self {
        case .signInRequired: return "Sign-in required"
        case .pageWasNotAList: return "Page was not a merge-request list"
        case .extractionFailed: return "Refresh failed"
        }
    }
}

/// Explicit panel states. Descriptions intentionally never include extracted
/// MR content such as titles, URLs, projects, or author names.
enum GitLabListPanelState: Equatable {
    case unconfigured
    case loadingPage
    case authenticationRequired
    case extracting
    case loaded(items: [GitLabMergeRequestSummary], refreshedAt: Date)
    case empty(refreshedAt: Date)
    case stale(items: [GitLabMergeRequestSummary], refreshedAt: Date, reason: GitLabRefreshFailureReason)
    case unsupportedPage
    case extractionFailed

    /// Cards from the last successful extraction, if any should stay visible.
    var retainedItems: [GitLabMergeRequestSummary] {
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

extension GitLabListPanelState: CustomStringConvertible, CustomDebugStringConvertible {
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
