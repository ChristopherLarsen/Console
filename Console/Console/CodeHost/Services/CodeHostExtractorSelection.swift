import Foundation

/// Selects the DOM extractor script for the active code host. Every script
/// only inspects DOM the host has already rendered — none initiates requests.
extension CodeHostProvider {
    var extractorJavaScriptSource: String {
        switch self {
        case .gitlab: return GitLabListExtractorJavaScript.source
        case .github: return GitHubListExtractorJavaScript.source
        }
    }
}
