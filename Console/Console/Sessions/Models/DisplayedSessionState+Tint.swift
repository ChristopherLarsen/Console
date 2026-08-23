import SwiftUI

extension DisplayedSessionState {
    /// The single shared tint for the displayed state. Home cards and the
    /// Sessions list both render through this so they cannot drift.
    ///
    /// Resolved through the dashboard-wide `AttentionChannel` mapping so a
    /// session's colour means the same thing as a ticket's or an MR's.
    var tint: Color {
        attentionChannel.color
    }
}
