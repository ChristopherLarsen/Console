import Foundation

/// One of the four local sources the Next card reads. Names are generic —
/// they never include hostnames, ticket keys, or MR titles.
enum NextSourceKind: String, Equatable, Sendable {
    case reviews
    case authored
    case jira
    case sessions
}

/// Whether a source produced a usable list, retained a stale list, or could
/// not be checked. Distinguishes a real empty list from signed-out,
/// unconfigured, and failed panels so Next never reports an unqualified
/// all-clear.
struct NextSourceStatus: Equatable, Sendable {
    enum Check: Equatable, Sendable {
        /// Successfully read; items (possibly empty) match the last extraction.
        case current
        /// Last successful extraction is retained after a later failure.
        case stale
        case unconfigured
        case signedOut
        case failed
        /// Load or extraction is still in flight with no usable answer.
        case pending
        case unsupported
    }

    var check: Check
    var lastSuccessfulExtraction: Date?
    var failureReason: String?

    static let current = NextSourceStatus(check: .current)

    init(
        check: Check,
        lastSuccessfulExtraction: Date? = nil,
        failureReason: String? = nil
    ) {
        self.check = check
        self.lastSuccessfulExtraction = lastSuccessfulExtraction
        self.failureReason = failureReason
    }

    /// True when this source must not be treated as a verified empty list.
    var couldNotCheck: Bool {
        switch check {
        case .unconfigured, .signedOut, .failed, .pending, .unsupported:
            return true
        case .current, .stale:
            return false
        }
    }

    var isStale: Bool { check == .stale }

    static func from(_ state: JiraPanelState) -> NextSourceStatus {
        switch state {
        case .unconfigured:
            return NextSourceStatus(check: .unconfigured)
        case .loadingPage, .extracting:
            return NextSourceStatus(check: .pending, lastSuccessfulExtraction: state.refreshedAt)
        case .authenticationRequired:
            return NextSourceStatus(check: .signedOut)
        case .loaded(_, let date), .empty(let date):
            return NextSourceStatus(check: .current, lastSuccessfulExtraction: date)
        case .stale(_, let date, let reason):
            return NextSourceStatus(
                check: .stale,
                lastSuccessfulExtraction: date,
                failureReason: reason
            )
        case .unsupportedPage:
            return NextSourceStatus(check: .unsupported)
        case .extractionFailed:
            return NextSourceStatus(check: .failed, failureReason: "could not read list")
        }
    }

    static func from(_ state: MergeRequestListPanelState) -> NextSourceStatus {
        switch state {
        case .unconfigured:
            return NextSourceStatus(check: .unconfigured)
        case .loadingPage, .extracting:
            return NextSourceStatus(check: .pending, lastSuccessfulExtraction: state.refreshedAt)
        case .authenticationRequired:
            return NextSourceStatus(check: .signedOut)
        case .loaded(_, let date), .empty(let date):
            return NextSourceStatus(check: .current, lastSuccessfulExtraction: date)
        case .stale(_, let date, let reason):
            return NextSourceStatus(
                check: .stale,
                lastSuccessfulExtraction: date,
                failureReason: reason.reasonText
            )
        case .unsupportedPage:
            return NextSourceStatus(check: .unsupported)
        case .extractionFailed:
            return NextSourceStatus(check: .failed, failureReason: "Refresh failed")
        }
    }
}

/// Where tapping the Next result should go. Item targets carry the exact
/// captured URL or session id; source targets open the panel without
/// substituting a different row.
enum NextOpenTarget: Equatable, Sendable {
    case mergeRequest(url: URL, list: CodeHostListKind)
    case jiraIssue(key: String, url: URL)
    case session(id: UUID)
    case source(NextSourceKind)
}
