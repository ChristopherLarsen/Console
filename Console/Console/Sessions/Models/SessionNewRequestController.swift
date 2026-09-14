import Foundation
import Observation

/// Cross-view one-shot signal for "start a new session" (menu ⌘N). The
/// requester bumps the token; SessionsView consumes requests by presenting
/// the intent picker. A token — not a boolean — so a second request while
/// the picker is already up still registers.
@MainActor
@Observable
final class SessionNewRequestController {
    private(set) var requestToken = 0

    func request() {
        requestToken += 1
    }
}