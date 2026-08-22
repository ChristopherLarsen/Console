import SwiftUI

extension DisplayedSessionState {
    /// The single shared tint for the displayed state. Home cards and the
    /// Sessions list both render through this so they cannot drift.
    var tint: Color {
        switch self {
        case .needsApproval, .needsInput:
            return .orange
        case .blocked, .needsReview:
            return .purple
        case .error:
            return .red
        case .done:
            return .green
        case .working:
            return .accentColor
        case .idle:
            return .secondary
        case .starting:
            return .yellow
        case .exited:
            return .gray
        case .unknown:
            return .gray
        }
    }
}
