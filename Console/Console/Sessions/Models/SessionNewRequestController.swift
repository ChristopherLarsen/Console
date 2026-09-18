import Foundation
import Observation

/// Cross-view one-shot signal for "start a new session" (menu ⌘N). The
/// requester bumps the token; SessionsView consumes requests by presenting
/// the intent picker. Consumption is tracked here — not in view state — so
/// a request presents exactly once and re-entering Sessions never
/// re-presents a stale request. A token — not a boolean — so a second
/// request while the picker is already up still registers.
@MainActor
@Observable
final class SessionNewRequestController {
    private(set) var requestToken = 0
    private var consumedToken = 0

    /// True when a button/hotkey requested the launcher and nothing has
    /// presented it yet.
    var hasPendingRequest: Bool { requestToken != consumedToken }

    func request() {
        requestToken += 1
    }

    /// Marks any pending request handled; returns true when one was pending.
    @discardableResult
    func consumePendingRequest() -> Bool {
        guard hasPendingRequest else { return false }
        consumedToken = requestToken
        return true
    }
}