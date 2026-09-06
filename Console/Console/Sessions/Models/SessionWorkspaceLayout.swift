import Foundation
import Observation

/// Geometry limits for the Sessions destination list. The selected terminal
/// keeps at least `detailMinWidth` so an 800-point window remains usable.
enum SessionWorkspaceLayout {
    static let listMinWidth: CGFloat = 180
    static let listIdealWidth: CGFloat = 260
    static let listMaxWidth: CGFloat = 360
    static let listCollapsedRailWidth: CGFloat = 28
    static let detailMinWidth: CGFloat = 320

    /// Clamp a proposed list width to the bounded range, shrinking the max
    /// when the Sessions column cannot also keep `detailMinWidth`.
    static func clampedListWidth(_ proposed: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maxAllowed = min(
            listMaxWidth,
            max(listMinWidth, availableWidth - detailMinWidth)
        )
        return min(max(proposed, listMinWidth), maxAllowed)
    }
}

/// Chrome captured when entering Focus Session so exit can restore it.
struct SessionChromeSnapshot: Equatable {
    var isListVisible: Bool
    var listWidth: CGFloat
    var isTerminalExpanded: Bool
    var terminalHeight: CGFloat
}

/// In-memory Sessions layout chrome. Focus Session is an explicit developer
/// action; session activity never writes these values.
@MainActor
@Observable
final class SessionWorkspaceLayoutController {
    var isListVisible: Bool = true
    var preferredListWidth: CGFloat = SessionWorkspaceLayout.listIdealWidth
    private(set) var listWidth: CGFloat = SessionWorkspaceLayout.listIdealWidth
    private(set) var isFocusMode = false
    private(set) var lastRestoredChrome: SessionChromeSnapshot?

    private var restore: SessionChromeSnapshot?
    private var notedTerminalExpanded = true
    private var notedTerminalHeight: CGFloat = 250

    var showsSessionList: Bool { isListVisible && !isFocusMode }
    var showsCollapsedListRail: Bool { !isListVisible && !isFocusMode }

    func applyListWidth(_ proposed: CGFloat, availableWidth: CGFloat) {
        preferredListWidth = min(
            max(proposed, SessionWorkspaceLayout.listMinWidth),
            SessionWorkspaceLayout.listMaxWidth
        )
        relayout(availableWidth: availableWidth)
    }

    func relayout(availableWidth: CGFloat) {
        listWidth = SessionWorkspaceLayout.clampedListWidth(
            preferredListWidth,
            availableWidth: availableWidth
        )
    }

    /// Remember live drawer chrome so Focus Session can snapshot it without
    /// the Sessions page holding a MainView closure.
    func noteTerminalChrome(expanded: Bool, height: CGFloat) {
        guard !isFocusMode else { return }
        notedTerminalExpanded = expanded
        notedTerminalHeight = height
    }

    func toggleFocusSession() {
        if isFocusMode {
            lastRestoredChrome = exitFocusSession()
        } else {
            enterFocusSession(
                terminalExpanded: notedTerminalExpanded,
                terminalHeight: notedTerminalHeight
            )
        }
    }

    func enterFocusSession(terminalExpanded: Bool, terminalHeight: CGFloat) {
        guard !isFocusMode else { return }
        restore = SessionChromeSnapshot(
            isListVisible: isListVisible,
            listWidth: preferredListWidth,
            isTerminalExpanded: terminalExpanded,
            terminalHeight: terminalHeight
        )
        isFocusMode = true
    }

    func exitFocusSession() -> SessionChromeSnapshot? {
        guard isFocusMode else { return nil }
        let snapshot = restore
        restore = nil
        isFocusMode = false
        lastRestoredChrome = snapshot
        return snapshot
    }
}
