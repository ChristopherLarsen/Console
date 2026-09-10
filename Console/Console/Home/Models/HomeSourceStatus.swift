import Foundation

/// Whether a Home board source produced a usable list, retained a stale
/// list, or could not be checked. Distinguishes a real empty list from
/// signed-out, unconfigured, and failed panels so Home never reports an
/// unqualified all-clear.
struct HomeSourceStatus: Equatable, Sendable {
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

    static let current = HomeSourceStatus(check: .current)

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

    static func from(_ state: JiraPanelState) -> HomeSourceStatus {
        switch state {
        case .unconfigured:
            return HomeSourceStatus(check: .unconfigured)
        case .loadingPage, .extracting:
            return HomeSourceStatus(check: .pending, lastSuccessfulExtraction: state.refreshedAt)
        case .authenticationRequired:
            return HomeSourceStatus(check: .signedOut)
        case .loaded(_, let date), .empty(let date):
            return HomeSourceStatus(check: .current, lastSuccessfulExtraction: date)
        case .stale(_, let date, let reason):
            return HomeSourceStatus(
                check: .stale,
                lastSuccessfulExtraction: date,
                failureReason: reason
            )
        case .unsupportedPage:
            return HomeSourceStatus(check: .unsupported)
        case .extractionFailed:
            return HomeSourceStatus(check: .failed, failureReason: "could not read list")
        }
    }

    static func from(_ state: MergeRequestListPanelState) -> HomeSourceStatus {
        switch state {
        case .unconfigured:
            return HomeSourceStatus(check: .unconfigured)
        case .loadingPage, .extracting:
            return HomeSourceStatus(check: .pending, lastSuccessfulExtraction: state.refreshedAt)
        case .authenticationRequired:
            return HomeSourceStatus(check: .signedOut)
        case .loaded(_, let date), .empty(let date):
            return HomeSourceStatus(check: .current, lastSuccessfulExtraction: date)
        case .stale(_, let date, let reason):
            return HomeSourceStatus(
                check: .stale,
                lastSuccessfulExtraction: date,
                failureReason: reason.reasonText
            )
        case .unsupportedPage:
            return HomeSourceStatus(check: .unsupported)
        case .extractionFailed:
            return HomeSourceStatus(check: .failed, failureReason: "Refresh failed")
        }
    }
}
