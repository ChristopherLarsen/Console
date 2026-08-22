import Foundation

/// Outcome of one extraction pass over a page GitLab has already rendered.
/// Never carries extracted content in its descriptions.
enum GitLabListExtractionResult: Equatable {
    case items([GitLabMergeRequestSummary])
    case empty
    case authenticationRequired
    case unsupportedPage
}

extension GitLabListExtractionResult: CustomStringConvertible, CustomDebugStringConvertible {
    private var redactedName: String {
        switch self {
        case .items(let items): return "items(\(items.count))"
        case .empty: return "empty"
        case .authenticationRequired: return "authenticationRequired"
        case .unsupportedPage: return "unsupportedPage"
        }
    }

    var description: String { redactedName }
    var debugDescription: String { redactedName }
}

enum GitLabMergeRequestListExtractorError: Error {
    case invalidPayload
}

/// Turns the JSON produced by `GitLabListExtractorJavaScript` (run against the
/// already-rendered GitLab list DOM via `WebPage.callJavaScript`) into typed,
/// deduplicated, order-preserving summaries.
///
/// Identity is the normalized absolute MR URL — never the IID alone, which is
/// only unique within one project.
enum GitLabMergeRequestListExtractor {

    // MARK: - JSON payload

    private struct Payload: Decodable {
        enum CodingKeys: String, CodingKey {
            case outcome
            case rows = "items"
        }

        let outcome: String
        let rows: [Row]
    }

    struct Row: Decodable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey {
            case url
            case iid
            case title
            case project
            case author
            case isDraft
            case pipeline
            case review
            case updated
        }

        var url: String?
        var iid: String?
        var title: String?
        var project: String?
        var author: String?
        var isDraft: Bool
        var pipeline: String?
        var review: String?
        var updated: String?

        init(
            url: String? = nil,
            iid: String? = nil,
            title: String? = nil,
            project: String? = nil,
            author: String? = nil,
            isDraft: Bool = false,
            pipeline: String? = nil,
            review: String? = nil,
            updated: String? = nil
        ) {
            self.url = url
            self.iid = iid
            self.title = title
            self.project = project
            self.author = author
            self.isDraft = isDraft
            self.pipeline = pipeline
            self.review = review
            self.updated = updated
        }

        /// Tolerant decoding: absent fields stay nil/false so a partially
        /// rendered row from a different GitLab version cannot invalidate the
        /// whole list payload.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            iid = try container.decodeIfPresent(String.self, forKey: .iid)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            project = try container.decodeIfPresent(String.self, forKey: .project)
            author = try container.decodeIfPresent(String.self, forKey: .author)
            isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
            pipeline = try container.decodeIfPresent(String.self, forKey: .pipeline)
            review = try container.decodeIfPresent(String.self, forKey: .review)
            updated = try container.decodeIfPresent(String.self, forKey: .updated)
        }
    }

    // MARK: - Decoding

    /// Decodes an extractor payload string. Rows without a valid absolute MR
    /// URL or without a usable title are dropped; duplicates collapse onto the
    /// first occurrence while preserving DOM order.
    static func decode(_ json: String) throws -> GitLabListExtractionResult {
        guard let data = json.data(using: .utf8) else { throw GitLabMergeRequestListExtractorError.invalidPayload }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw GitLabMergeRequestListExtractorError.invalidPayload
        }

        switch payload.outcome {
        case "authenticationRequired":
            return .authenticationRequired
        case "empty":
            return .empty
        case "items":
            return .items(summaries(from: payload.rows))
        default:
            return .unsupportedPage
        }
    }

    static func summaries(from rows: [Row]) -> [GitLabMergeRequestSummary] {
        var seenURLStrings = Set<String>()
        var results: [GitLabMergeRequestSummary] = []

        for row in rows {
            guard let url = normalizedMRURL(from: row.url),
                  let title = displayTitle(for: row)
            else { continue }

            let urlString = url.absoluteString
            guard !seenURLStrings.contains(urlString) else { continue }
            seenURLStrings.insert(urlString)

            let draftFromTitle = Self.isDraftTitle(title)

            results.append(
                GitLabMergeRequestSummary(
                    id: url,
                    iidText: row.iid.flatMap(nonEmpty),
                    title: draftFromTitle.stripped,
                    projectDisplayName: row.project.flatMap(nonEmpty),
                    authorDisplayName: row.author.flatMap(nonEmpty),
                    isDraft: row.isDraft || draftFromTitle.isDraft,
                    pipelineDisplayState: row.pipeline.flatMap(nonEmpty),
                    reviewDisplayState: row.review.flatMap(nonEmpty),
                    updatedText: row.updated.flatMap(nonEmpty),
                    mergeRequestURL: url,
                    sourceOrder: results.count
                )
            )
        }

        return results
    }

    /// Normalizes to an absolute http(s) URL without its fragment.
    static func normalizedMRURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let cleaned = components?.url else { return nil }
        return cleaned
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayTitle(for row: Row) -> String? {
        guard let raw = row.title else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Detects `Draft:` / `WIP:` / `[Draft]` / `[WIP]` title prefixes and
    /// returns the title with that prefix stripped so the card's Draft cue is
    /// not repeated inside the title.
    private static func isDraftTitle(_ title: String) -> (isDraft: Bool, stripped: String) {
        let pattern = #"^\s*(\[(?:draft|wip)\]\s*|(?:draft|wip)\s*[:：]\s*)"#
        guard let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return (false, title)
        }
        let stripped = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, stripped.isEmpty ? title : stripped)
    }
}

/// The function body handed to `WebPage.callJavaScript`. It only inspects DOM
/// GitLab has already rendered — it never issues requests. It returns a JSON
/// string decoded by `GitLabMergeRequestListExtractor`.
enum GitLabListExtractorJavaScript {

    static let source = #"""
    const AUTH_SELECTORS = [
      'form#new_user',
      'input[name="user[login]"]',
      'input[name="user[password]"]',
      'form[action*="users/sign_in"]',
      '[data-testid="sign-in-form"]',
      'body.login-page'
    ];
    const LIST_SELECTORS = [
      'ul[data-testid="merge-request-list"]',
      'ul.merge_requests-list',
      '#merge_requests_list',
      'ul.mr-list',
      '.merge-request-list'
    ];
    const EMPTY_SELECTORS = ['.empty-state', '[data-testid="empty-state"]'];
    const TITLE_SELECTORS = [
      '[data-testid="merge-request-title-text"]',
      '.merge-request-title-text',
      '[data-testid="merge-request-title"]',
      '.merge-request-title'
    ];
    const PROJECT_SELECTORS = [
      '[data-testid="merge-request-project-name"]',
      '.merge-request-project-name',
      '.project-name',
      '.namespace'
    ];
    const AUTHOR_SELECTORS = ['a.author_link', '[data-testid="author-link"]', '.author-link'];
    const PIPELINE_SELECTORS = [
      '[data-testid="pipeline-status"]',
      '.ci-status-link',
      '.ci-status'
    ];
    const REVIEW_SELECTORS = [
      '[data-testid="merge-request-review-state"]',
      '.review-state'
    ];
    const MR_PATH_PATTERN = /\/-\/merge_requests\/(\d+)\/?$/;
    const DRAFT_TITLE_PATTERN = /^\s*(\[(draft|wip)\]\s*|(draft|wip)\s*:\s*)/i;

    function compactText(element) {
      if (!element) { return null; }
      const value = (element.textContent || '').replace(/\s+/g, ' ').trim();
      return value.length > 0 ? value : null;
    }

    function isVisible(element) {
      if (!element) { return false; }
      if (element.getClientRects().length === 0) { return false; }
      const style = window.getComputedStyle(element);
      return style.display !== 'none' && style.visibility !== 'hidden';
    }

    function firstVisible(selectorRoots, selectors) {
      for (const root of selectorRoots) {
        if (!root || !root.querySelectorAll) { continue; }
        for (const selector of selectors) {
          const found = root.querySelector(selector);
          if (found && isVisible(found)) { return found; }
        }
      }
      return null;
    }

    function accessibleLabel(element) {
      if (!element) { return null; }
      const raw = element.getAttribute('aria-label')
        || element.getAttribute('title')
        || element.getAttribute('data-original-title')
        || element.textContent
        || '';
      const value = String(raw).replace(/\s+/g, ' ').trim();
      return value.length > 0 ? value : null;
    }

    function pipelineState(row) {
      const element = firstVisible([row], PIPELINE_SELECTORS);
      if (!element) { return null; }
      const label = accessibleLabel(element);
      if (label) { return label; }
      const classes = element.className && element.className.baseVal !== undefined
        ? element.className.baseVal
        : String(element.className || '');
      const iconMatch = classes.match(/ci-status-icon-([a-z]+)/);
      if (iconMatch) {
        return iconMatch[1].charAt(0).toUpperCase() + iconMatch[1].slice(1);
      }
      return null;
    }

    function updatedText(row) {
      const times = row ? row.querySelectorAll('time') : [];
      if (times.length === 0) { return null; }
      const last = times[times.length - 1];
      if (!isVisible(last)) { return null; }
      return compactText(last);
    }

    function rowElementFor(anchor) {
      let current = anchor;
      for (let depth = 0; current && depth < 12; depth += 1) {
        if (current.tagName === 'LI') { return current; }
        if (current.getAttribute && current.getAttribute('role') === 'listitem') { return current; }
        if (current.classList && current.classList.contains('merge-request')) { return current; }
        if (current.getAttribute && current.getAttribute('data-testid') === 'merge-request') { return current; }
        current = current.parentElement;
      }
      return anchor;
    }

    function matchesAny(selectors) {
      for (const selector of selectors) {
        const found = document.querySelector(selector);
        if (found) { return true; }
      }
      return false;
    }

    if (matchesAny(AUTH_SELECTORS)) {
      return JSON.stringify({ outcome: 'authenticationRequired', items: [] });
    }

    const anchors = [];
    for (const anchor of document.querySelectorAll('a[href]')) {
      if (!anchor.pathname) { continue; }
      const match = anchor.pathname.match(MR_PATH_PATTERN);
      if (!match) { continue; }
      anchors.push(anchor);
    }

    const rowsInOrder = new Map();
    for (const anchor of anchors) {
      const rowElement = rowElementFor(anchor);
      if (!rowsInOrder.has(rowElement)) {
        rowsInOrder.set(rowElement, []);
      }
      rowsInOrder.get(rowElement).push(anchor);
    }

    if (rowsInOrder.size === 0) {
      const hasContainer = matchesAny(LIST_SELECTORS);
      const hasEmptyState = matchesAny(EMPTY_SELECTORS);
      if (hasContainer || hasEmptyState) {
        return JSON.stringify({ outcome: 'empty', items: [] });
      }
      return JSON.stringify({ outcome: 'unsupported', items: [] });
    }

    const items = [];
    let sawRowElement = false;
    for (const [rowElement, rowAnchors] of rowsInOrder) {
      sawRowElement = true;
      if (!isVisible(rowElement)) { continue; }
      let chosenAnchor = null;
      let iid = null;
      for (const candidate of rowAnchors) {
        const match = candidate.pathname.match(MR_PATH_PATTERN);
        if (!match) { continue; }
        const candidateText = compactText(candidate);
        if (candidateText && !/^!?\d+$/.test(candidateText)) { chosenAnchor = candidate; break; }
        if (!chosenAnchor) { chosenAnchor = candidate; }
      }
      if (!chosenAnchor) { continue; }
      iid = chosenAnchor.pathname.match(MR_PATH_PATTERN)[1];

      const roots = [rowElement];
      let title = compactText(firstVisible(roots, TITLE_SELECTORS));
      if (!title) {
        const fallback = compactText(chosenAnchor);
        if (fallback && !/^!?\d+$/.test(fallback)) { title = fallback; }
      }
      if (!title) { continue; }

      const isDraft = Boolean(firstVisible(roots, [
        '.draft-status',
        '[data-testid="draft-badge"]'
      ])) || DRAFT_TITLE_PATTERN.test(title);

      items.push({
        url: chosenAnchor.href,
        iid: iid,
        title: title.replace(DRAFT_TITLE_PATTERN, ''),
        project: compactText(firstVisible(roots, PROJECT_SELECTORS)),
        author: compactText(firstVisible(roots, AUTHOR_SELECTORS)),
        isDraft: isDraft,
        pipeline: pipelineState(rowElement),
        review: compactText(firstVisible(roots, REVIEW_SELECTORS)),
        updated: updatedText(rowElement)
      });
    }

    if (sawRowElement && items.length === 0) {
      // MR anchors existed but no row could be read; never report a false zero.
      return JSON.stringify({ outcome: 'unsupported', items: [] });
    }
    return JSON.stringify({ outcome: 'items', items: items });
    """#

    /// Small readiness probe used for bounded local checks while a list page
    /// settles. DOM inspection only; no network requests are initiated.
    static let readinessProbeSource = #"""
    const ready =
      document.readyState !== 'loading' &&
      (
        document.querySelector('a[href*="/-/merge_requests/"]') ||
        document.querySelector('ul[data-testid="merge-request-list"], ul.merge_requests-list, #merge_requests_list, ul.mr-list, .merge-request-list') ||
        document.querySelector('.empty-state, [data-testid="empty-state"]') ||
        document.querySelector('form#new_user, input[name="user[login]"], form[action*="users/sign_in"]')
      );
    return Boolean(ready);
    """#
}
