import SwiftUI
import Observation

@Observable
@MainActor
final class InfoManager {
    enum InfoType: String, CaseIterable, Identifiable {
        case speechCountdown
        case endpointURL
        case confidenceLevel
        case sleepAfter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speechCountdown:
                return "Speech Countdown"
            case .endpointURL:
                return "Endpoint URL"
            case .confidenceLevel:
                return "Matching Confidence"
            case .sleepAfter:
                return "Sleep After"
            }
        }

        var message: String {
            switch self {
            case .speechCountdown:
                return """
The countdown controls how long Console waits after you stop speaking before automatically sending your message to the Claw.

- **Shorter countdown** — sends faster but may cut you off mid-thought
- **Longer countdown** — gives you more time to pause and continue speaking
"""
            case .endpointURL:
                return """
The endpoint URL is the web address where API requests are sent to your AI provider.

- **Default value** — each provider has a standard endpoint that works for most users
- **Custom endpoint** — use this if you're routing through a proxy, VPN, or self-hosted instance

Most users should leave this at the default value.
"""
            case .confidenceLevel:
                return """
Matching confidence controls how closely what you say must match a saved command phrase before Console will run it.

- **Casual** — more forgiving. Works well if you tend to paraphrase or add extra words like "please" or "the" around your commands
- **Normal** — balanced. Matches commands accurately while allowing minor differences in how you say them. Recommended for most users
- **Strict** — requires a very close match to the exact command phrase. Best if you have many similar-sounding commands and want to avoid accidental triggers
"""
            case .sleepAfter:
                return """
Sleep After controls how long Console stays actively listening before automatically going to sleep when no commands are detected.

- **Never** — Console stays listening indefinitely until you manually turn it off
- **Timed intervals** — Console will automatically stop listening after the selected period of inactivity, saving system resources

This is useful if you tend to leave Console on and forget to turn it off.

**Note:** Background audio such as televisions or music may be detected and processed, which can keep Console awake and prevent it from sleeping automatically.
"""
            }
        }
    }

    var activeInfo: InfoType?

    func present(_ type: InfoType) {
        activeInfo = type
    }

    func dismiss() {
        activeInfo = nil
    }
}
