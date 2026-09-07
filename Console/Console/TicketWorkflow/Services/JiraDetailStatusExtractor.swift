import Foundation
import WebKit

/// Extracts issue key + status from the currently displayed Jira issue page.
/// DOM inspection only — same `WebPage.callJavaScript` JSON-string pattern as
/// `JiraListExtractor`. Never uses REST, cookies, fetch/XHR, or hidden pages.
struct JiraDetailStatusExtractor {
    struct Payload: Decodable {
        let kind: String
        let issueKey: String?
        let statusLabel: String?
        let pageURL: String?
        let originHost: String?
    }

    /// Decode a JS payload string into a typed extraction result.
    /// `navigationGeneration` and `observedAt` are supplied by the caller
    /// (WebView navigation counter / clock) — not inventable from the DOM.
    static func decode(
        payloadData: Data,
        navigationGeneration: Int,
        observedAt: Date = Date()
    ) -> TicketJiraDetailExtraction {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            return .extractionFailed
        }
        switch payload.kind {
        case "auth":
            return .authenticationRequired
        case "unsupported":
            return .unsupportedPage
        case "matched":
            return matchedDetail(
                from: payload,
                navigationGeneration: navigationGeneration,
                observedAt: observedAt
            )
        default:
            return .extractionFailed
        }
    }

    static func extract(
        from page: WebPage,
        navigationGeneration: Int,
        observedAt: Date = Date()
    ) async -> TicketJiraDetailExtraction {
        do {
            let raw = try await page.callJavaScript(extractionScript)
            switch raw {
            case let json as String:
                return decode(
                    payloadData: Data(json.utf8),
                    navigationGeneration: navigationGeneration,
                    observedAt: observedAt
                )
            default:
                return .extractionFailed
            }
        } catch {
            return .extractionFailed
        }
    }

    private static func matchedDetail(
        from payload: Payload,
        navigationGeneration: Int,
        observedAt: Date
    ) -> TicketJiraDetailExtraction {
        guard let rawKey = payload.issueKey,
              let statusRaw = payload.statusLabel,
              let urlString = payload.pageURL,
              let pageURL = URL(string: urlString),
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return .extractionFailed
        }

        let issueKey = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard isValidIssueKey(issueKey) else {
            return .extractionFailed
        }

        let statusLabel = normalizeWhitespace(statusRaw)
        guard !statusLabel.isEmpty else {
            return .extractionFailed
        }

        let hostFromPayload = payload.originHost.map(TicketJiraObservationPolicy.normalizeOriginHost) ?? ""
        let hostFromURL = pageURL.host.map(TicketJiraObservationPolicy.normalizeOriginHost) ?? ""
        let originHost = !hostFromPayload.isEmpty ? hostFromPayload : hostFromURL
        guard !originHost.isEmpty else {
            return .extractionFailed
        }

        return .matched(
            TicketJiraMatchedDetail(
                issueKey: issueKey,
                statusLabel: statusLabel,
                originHost: originHost,
                pageURL: pageURL,
                observedAt: observedAt,
                navigationGeneration: navigationGeneration
            )
        )
    }

    static func isValidIssueKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) != nil
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension JiraDetailStatusExtractor {
    /// Structural selectors prefer issue-view testids and `/browse/` URL shape
    /// over generated CSS class names (same philosophy as list extraction).
    static let extractionScript = """
    function norm(value) {
      return (value || '').replace(/[\\s\\u00a0]+/g, ' ').trim();
    }
    function isIssueKey(text) {
      return /^[A-Za-z][A-Za-z0-9]*-\\d+$/.test(text || '');
    }
    const hasPassword = !!document.querySelector('input[type=password]');
    const authHost = /(^|\\.)id\\.atlassian\\.com$/.test(location.hostname) ||
                     /(^|\\.)auth\\.atlassian\\.com$/.test(location.hostname);
    if (hasPassword || authHost || location.pathname.indexOf('/login') === 0) {
      return JSON.stringify({ kind: 'auth' });
    }
    function keyFromLocation() {
      const path = location.pathname || '';
      let match = path.match(/\\/browse\\/([A-Za-z][A-Za-z0-9]*-\\d+)/i);
      if (match) { return match[1].toUpperCase(); }
      match = path.match(/\\/issues\\/([A-Za-z][A-Za-z0-9]*-\\d+)/i);
      if (match) { return match[1].toUpperCase(); }
      try {
        const params = new URLSearchParams(location.search || '');
        const selected = params.get('selectedIssue');
        if (selected && isIssueKey(selected)) { return selected.toUpperCase(); }
      } catch (e) {}
      return null;
    }
    function keyFromDOM() {
      const selectors = [
        '[data-testid*="breadcrumb"] a[href*="/browse/"]',
        'a[data-testid*="issue-key"][href*="/browse/"]',
        '[data-testid*="issue.views.issue-base"] a[href*="/browse/"]',
        'a[href*="/browse/"]'
      ];
      for (let s = 0; s < selectors.length; s++) {
        const anchors = document.querySelectorAll(selectors[s]);
        for (let i = 0; i < anchors.length; i++) {
          const text = norm(anchors[i].textContent);
          if (isIssueKey(text)) { return text.toUpperCase(); }
          const href = anchors[i].href || anchors[i].getAttribute('href') || '';
          const match = href.match(/\\/browse\\/([A-Za-z][A-Za-z0-9]*-\\d+)/i);
          if (match) { return match[1].toUpperCase(); }
        }
      }
      const keyNode = document.querySelector(
        '[data-testid*="issue.views.issue-base.foundation.breadcrumbs"] [data-testid*="issue-key"], ' +
        '[data-testid="issue.views.issue-base.foundation.breadcrumbs.current-issue.item"]'
      );
      if (keyNode) {
        const text = norm(keyNode.textContent);
        if (isIssueKey(text)) { return text.toUpperCase(); }
      }
      return null;
    }
    function statusFromDOM() {
      const preferred = document.querySelector(
        '[data-testid*="issue.fields.status"][data-testid$="--text"], ' +
        '[data-testid*="status-lozenge"][data-testid$="--text"]'
      );
      if (preferred) {
        const value = norm(preferred.textContent);
        if (value) { return value; }
      }
      const field = document.querySelector(
        '[data-testid*="issue.fields.status"], [data-testid*="status-field"]'
      );
      if (field) {
        const lozenge = field.querySelector('[data-testid$="--text"]');
        if (lozenge) {
          const value = norm(lozenge.textContent);
          if (value) { return value; }
        }
        const value = norm(field.textContent);
        if (value) { return value; }
      }
      return null;
    }
    const issueMarkers = document.querySelectorAll(
      '[data-testid^="issue.views.issue-base"], ' +
      '[data-testid*="issue.views.issue-base"], ' +
      '[data-testid*="issue-view.issue-view-details"]'
    );
    const listRows = document.querySelectorAll('[data-testid="native-issue-table.ui.issue-row"]');
    const key = keyFromLocation() || keyFromDOM();
    const status = statusFromDOM();
    if (!key && issueMarkers.length === 0) {
      return JSON.stringify({ kind: 'unsupported' });
    }
    if (listRows.length > 0 && issueMarkers.length === 0 && !keyFromLocation()) {
      return JSON.stringify({ kind: 'unsupported' });
    }
    if (!key || !isIssueKey(key)) {
      return JSON.stringify({ kind: 'failed' });
    }
    if (!status) {
      return JSON.stringify({ kind: 'failed' });
    }
    return JSON.stringify({
      kind: 'matched',
      issueKey: key,
      statusLabel: status,
      pageURL: location.href,
      originHost: location.hostname
    });
    """
}
