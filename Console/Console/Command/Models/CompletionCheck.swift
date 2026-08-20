import Foundation

struct CompletionCheck: Codable, Hashable {
    let type: CompletionCheckType
    let value: String
}

enum CompletionCheckType: String, Codable {
    case appRunning
    case fileExists
    case windowTitle
    case delay
}

// MARK: - Factory Methods

extension CompletionCheck {
    static func appRunning(_ bundleID: String) -> CompletionCheck {
        CompletionCheck(type: .appRunning, value: bundleID)
    }

    static func fileExists(_ path: String) -> CompletionCheck {
        CompletionCheck(type: .fileExists, value: path)
    }

    static func windowTitle(_ title: String) -> CompletionCheck {
        CompletionCheck(type: .windowTitle, value: title)
    }

    static func delay(milliseconds: Int) -> CompletionCheck {
        CompletionCheck(type: .delay, value: String(milliseconds))
    }
}
