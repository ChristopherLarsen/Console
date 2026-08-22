import Foundation
import WebKit

enum JiraListExtraction: Equatable {
    case tickets([JiraTicketSummary])
    case empty
    case authenticationRequired
    case unsupportedPage
    case failed
}

struct JiraListExtractor {
    struct ExtractedRow: Decodable, Equatable {
        let key: String?
        let summary: String?
        let status: String?
        let priority: String?
        let updated: String?
        let url: String?
    }

    struct Payload: Decodable {
        let kind: String
        let rows: [ExtractedRow]?
        let signedIn: Bool?
    }

    static func decode(payloadData: Data) -> JiraListExtraction {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            return .failed
        }
        switch payload.kind {
        case "auth":
            return .authenticationRequired
        case "empty":
            if payload.signedIn == false {
                return .authenticationRequired
            }
            return .empty
        case "unsupported":
            return .unsupportedPage
        case "tickets":
            let summaries = Self.summaries(from: payload.rows ?? [])
            return .tickets(summaries)
        default:
            return .failed
        }
    }

    static func summaries(from rows: [ExtractedRow]) -> [JiraTicketSummary] {
        var seen = Set<String>()
        var result: [JiraTicketSummary] = []
        for row in rows where !row.isInvalid {
            guard let url = URL(string: row.url ?? ""), isValidIssueURL(url) else { continue }
            if seen.contains(row.key!) { continue }
            seen.insert(row.key!)
            result.append(
                JiraTicketSummary(
                    key: row.key!,
                    summary: normalized(row.summary) ?? "",
                    status: normalized(row.status),
                    priority: normalized(row.priority),
                    updatedText: normalized(row.updated),
                    issueURL: url,
                    sourceOrder: result.count
                )
            )
        }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("none") == .orderedSame {
            return nil
        }
        return trimmed
    }

    private static func isValidIssueURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return false
        }
        return true
    }

    static func extract(from page: WebPage) async -> JiraListExtraction {
        do {
            let raw = try await page.callJavaScript(extractionScript)
            switch raw {
            case let json as String:
                return decode(payloadData: Data(json.utf8))
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}

private extension JiraListExtractor.ExtractedRow {
    var isInvalid: Bool {
        guard let key, let url, !key.isEmpty, !url.isEmpty else { return true }
        return false
    }
}

extension JiraListExtractor {
    static let readinessProbeScript = """
    const hasRows = document.querySelectorAll('[data-testid="native-issue-table.ui.issue-row"]').length > 0;
    const hasTable = document.querySelectorAll('table').length > 0;
    const hasTableMarkers = document.querySelectorAll('[data-testid^="native-issue-table"]').length > 0;
    const hasPassword = !!document.querySelector('input[type=password]');
    const path = location.pathname;
    return JSON.stringify({
      hasRows: hasRows,
      hasTable: hasTable || hasTableMarkers,
      authLike: hasPassword || path.indexOf('/login') === 0
    });
    """

    static let extractionScript = """
    function norm(value) {
      return (value || '').replace(/[\\s\\u00a0]+/g, ' ').trim();
    }
    function signedInMarkers() {
      const profile = document.querySelectorAll(
        '[data-testid="atlassian-navigation--secondary-actions--profile--trigger"], [data-testid*="profile--trigger"], [data-testid*="account-menu"]'
      );
      if (profile.length > 0) { return true; }
      const navAvatars = document.querySelectorAll('button img[src*="universal_avatar"]');
      return navAvatars.length > 0;
    }
    const hasPassword = !!document.querySelector('input[type=password]');
    const authHost = /(^|\\.)id\\.atlassian\\.com$/.test(location.hostname) ||
                     /(^|\\.)auth\\.atlassian\\.com$/.test(location.hostname);
    if (hasPassword || authHost || location.pathname.indexOf('/login') === 0) {
      return JSON.stringify({ kind: 'auth' });
    }
    const table = document.querySelector('table');
    const rows = table
      ? table.querySelectorAll('tbody tr[data-testid="native-issue-table.ui.issue-row"], tbody tr[role="row"]')
      : [];
    if (!table && rows.length === 0) {
      const markers = document.querySelectorAll('[data-testid^="native-issue-table"]');
      if (markers.length > 0) {
        return JSON.stringify({ kind: 'empty', signedIn: signedInMarkers() });
      }
      return JSON.stringify({ kind: 'unsupported' });
    }
    function semanticFor(headerText) {
      const t = headerText.toLowerCase();
      if (t.indexOf('priority') >= 0) { return 'priority'; }
      if (t.indexOf('status') >= 0) { return 'status'; }
      if (t.indexOf('updated') >= 0) { return 'updated'; }
      return null;
    }
    const columnByIndex = {};
    if (table) {
      const headRow = table.querySelector('thead tr') || table.rows[0];
      if (headRow) {
        const headCells = headRow.cells;
        for (let i = 0; i < headCells.length; i++) {
          const semantic = semanticFor(norm(headCells[i].textContent));
          if (semantic) { columnByIndex[i] = semantic; }
        }
      }
    }
    function cellValue(cell, semantic) {
      if (!cell) { return null; }
      if (semantic === 'status') {
        const lozenge = cell.querySelector('[data-testid$="--text"]');
        if (lozenge) { return norm(lozenge.textContent); }
      }
      if (semantic === 'priority') {
        const wrapper = cell.querySelector('[data-testid*="priority"]');
        if (wrapper) { return norm(wrapper.textContent); }
      }
      const direct = norm(cell.textContent);
      return direct.length > 0 ? direct : null;
    }
    const seenKeys = {};
    const outRows = [];
    rows.forEach(function(tr) {
      const keyAnchor =
        tr.querySelector('a[data-testid$="issue-key-cell"][href*="/browse/"]') ||
        tr.querySelector('a[href*="/browse/"]');
      if (!keyAnchor) { return; }
      const key = norm(keyAnchor.textContent);
      const href = keyAnchor.href;
      if (!key || !href) { return; }
      if (seenKeys[key]) { return; }
      seenKeys[key] = true;
      const summaryEl = tr.querySelector('[data-testid$="issue-summary-cell"]');
      let status = null;
      let priority = null;
      let updated = null;
      if (tr.cells) {
        for (let i = 0; i < tr.cells.length; i++) {
          const semantic = columnByIndex[i];
          if (!semantic) { continue; }
          const value = cellValue(tr.cells[i], semantic);
          if (!value) { continue; }
          if (semantic === 'status' && status === null) { status = value; }
          else if (semantic === 'priority' && priority === null) { priority = value; }
          else if (semantic === 'updated' && updated === null) { updated = value; }
        }
      }
      outRows.push({
        key: key,
        summary: summaryEl ? norm(summaryEl.textContent) : '',
        status: status,
        priority: priority,
        updated: updated,
        url: href
      });
    });
    if (outRows.length > 0) {
      return JSON.stringify({ kind: 'tickets', rows: outRows });
    }
    if (table || document.querySelectorAll('[data-testid^="native-issue-table"]').length > 0) {
      return JSON.stringify({ kind: 'empty', signedIn: signedInMarkers() });
    }
    return JSON.stringify({ kind: 'unsupported' });
    """
}
