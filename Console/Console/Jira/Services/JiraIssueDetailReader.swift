import Foundation
import WebKit

/// The rendered text of one JIRA issue, read from its page.
nonisolated struct JiraIssueDetail: Equatable, Sendable {
    let summary: String
    let description: String
    let issueType: String?
    /// Other rich-text fields (for example acceptance criteria), labelled.
    let otherFields: String
}

/// Reads an issue's rendered text by loading its page in an offscreen
/// `WebPage` that shares the JIRA sign-in, then reading the DOM. DOM-only: no
/// REST, fetch or XHR, for both the personal and the company instance. Each
/// read uses a fresh page, so reads never disturb the pinned JIRA tab.
@MainActor
struct JiraIssueDetailReader {
    enum ReadError: LocalizedError, Equatable {
        case signInRequired
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Sign in to JIRA in the JIRA destination, then try again."
            case .notLoaded: return "The JIRA story did not finish loading. Try again."
            }
        }
    }

    /// Total wait for the page to render the story.
    var timeout: TimeInterval = 25
    /// Extra wait for a lazily rendered description once the summary shows.
    var descriptionGrace: TimeInterval = 5
    static let maxFieldCharacters = 12_000

    func read(url: URL) async throws -> JiraIssueDetail {
        let page = WebAuthenticationStore.makePage()
        page.load(URLRequest(url: url))
        defer { page.stopLoading() }
        let start = Date()
        var loadedAt: Date?
        var latest: Probe?
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let probe = await probe(page) else { continue }
            if probe.auth { throw ReadError.signInRequired }
            // Readiness is the page itself, not a guessed field selector, so an
            // unfamiliar JIRA layout still yields a (noisier) synopsis.
            guard probe.loaded else { continue }
            latest = probe
            let loaded = loadedAt ?? Date()
            loadedAt = loaded
            if !probe.description.isEmpty || Date().timeIntervalSince(loaded) >= descriptionGrace {
                return detail(from: probe)
            }
        }
        if let latest { return detail(from: latest) }
        throw ReadError.notLoaded
    }

    /// Known fields when the selectors match; otherwise the page's main text.
    private func detail(from probe: Probe) -> JiraIssueDetail {
        JiraIssueDetail(
            summary: probe.summary,
            description: probe.description.isEmpty ? probe.fallback : probe.description,
            issueType: probe.type.isEmpty ? nil : probe.type,
            otherFields: probe.other
        )
    }

    private struct Probe: Decodable {
        let summary: String
        let description: String
        let type: String
        let other: String
        let fallback: String
        let loaded: Bool
        let auth: Bool
    }

    private func probe(_ page: WebPage) async -> Probe? {
        guard let raw = try? await page.callJavaScript(Self.probeScript) as? String else { return nil }
        return try? JSONDecoder().decode(Probe.self, from: Data(raw.utf8))
    }

    /// Jira Cloud `data-testid`s first, then Jira Server/Data Center ids.
    static let probeScript = """
    const text = (el) => (el && el.innerText ? el.innerText.trim() : "");
    const pick = (selectors) => {
      for (const s of selectors) { const t = text(document.querySelector(s)); if (t) return t; }
      return "";
    };
    const cap = (s) => s.slice(0, \(maxFieldCharacters));
    const summary = pick(['[data-testid="issue.views.issue-base.foundation.summary.heading"]', '#summary-val']);
    const description = pick(['[data-testid="issue.views.field.rich-text.description"]', '#description-val']);
    const typeButton = document.querySelector('[data-testid="issue.views.issue-base.foundation.change-issue-type.button"]');
    const type = (typeButton && (typeButton.getAttribute('aria-label') || '').trim()) || pick(['#type-val']);
    const other = Array.from(document.querySelectorAll('[data-testid^="issue.views.field.rich-text.customfield"]'))
      .map((el) => {
        const heading = el.closest('[data-testid*="field"]')?.querySelector('h2, h3, label');
        const t = text(el);
        return t ? ((heading ? text(heading) + ': ' : '') + t) : '';
      })
      .filter(Boolean).join('\\n\\n');
    const auth = /(^|\\.)id\\.atlassian\\.com$/.test(location.hostname) || /\\/login/.test(location.pathname)
      || !!document.querySelector('#login-form, input[type="password"]');
    const main = document.querySelector('[data-testid="issue.views.issue-details.issue-layout.container-left"], #issue-content, main, [role="main"]') || document.body;
    const fallback = text(main);
    const loaded = document.readyState === 'complete' && fallback.length > 40;
    return JSON.stringify({ summary: cap(summary), description: cap(description), type: cap(type), other: cap(other),
      fallback: cap(fallback), loaded, auth });
    """
}
