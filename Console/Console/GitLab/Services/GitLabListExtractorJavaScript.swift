import Foundation

/// The function body handed to `WebPage.callJavaScript`. It only inspects DOM
/// GitLab has already rendered — it never issues requests. It returns a JSON
/// string decoded by `MergeRequestListExtractor`.
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
    const EMPTY_SELECTORS = [
      '.empty-state',
      '[data-testid="empty-state"]',
      // Pajamas EmptyState, used by current GitLab group/project list pages.
      '.gl-empty-state'
    ];
    const TITLE_SELECTORS = [
      'a[data-testid="issuable-title-link"]',
      'a.issue-title-text',
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
    const TARGET_SELECTORS = [
      'a[href*="/milestones/"]',
      '[data-testid="merge-request-milestone"]',
      '[data-testid="milestone-link"]',
      '.milestone'
    ];
    const MR_PATH_PATTERN = /\/-\/merge_requests\/(\d+)\/?$/;
    const DRAFT_TITLE_PATTERN = /^\s*(\[(draft|wip)\]\s*|(draft|wip)\s*:\s*)/i;

    function compactText(element) {
      if (!element) { return null; }
      const value = (element.textContent || '').replace(/\s+/g, ' ').trim();
      return value.length > 0 ? value : null;
    }

    function isVisible(element) {
      if (!element || !element.isConnected) { return false; }
      // Home reads a retained page without mounting a WebView. Geometry may
      // be empty there; CSS visibility still distinguishes hidden templates.
      for (let current = element; current; current = current.parentElement) {
        const style = window.getComputedStyle(current);
        if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') {
          return false;
        }
      }
      return true;
    }

    function firstVisible(selectorRoots, selectors) {
      for (const root of selectorRoots) {
        if (!root || !root.querySelectorAll) { continue; }
        for (const selector of selectors) {
          for (const found of root.querySelectorAll(selector)) {
            if (isVisible(found)) { return found; }
          }
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

    const isListRoute = /\/(?:dashboard\/merge_requests|-\/merge_requests)\/?$/.test(window.location.pathname);
    const legacyContainer = firstVisible([document], LIST_SELECTORS);
    // Issuable lists are shared with issues. Only recognize them on an MR
    // list route, and only read anchors inside explicitly marked MR rows.
    const modernRoot = isListRoute
      ? firstVisible([document], ['.issuable-list-container']) : null;
    const modernContainer = modernRoot
      ? firstVisible([modernRoot], ['.content-list.issuable-list']) : null;
    const listContainer = legacyContainer || modernContainer;
    const hasListContainer = Boolean(listContainer);
    function unsupported(reason) {
      // Structural diagnostics only; no page text, URLs or extracted values.
      return JSON.stringify({ outcome: 'unsupported', reason: reason, items: [] });
    }

    const anchors = [];
    for (const anchor of (listContainer || modernRoot || document).querySelectorAll('a[href]')) {
      if (!isVisible(anchor)) { continue; }
      if (!legacyContainer && modernRoot) {
        const row = anchor.closest('.merge-request, [data-testid="merge-request"]');
        if (!row || !modernContainer || !modernContainer.contains(row)) { continue; }
      }
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

    if (rowsInOrder.size > 0 && !hasListContainer) {
      // MR links on a page without a merge-request list container (dashboard
      // widget, wiki) are not a merge-request list.
      return unsupported(isListRoute ? 'unrecognizedLayout' : 'wrongPage');
    }

    if (rowsInOrder.size === 0) {
      const emptyState = firstVisible([modernRoot || document], EMPTY_SELECTORS);
      const saysNoMergeRequests = /\bno (?:open |closed |merged |matching )?merge requests?\b/i.test(compactText(emptyState) || '');
      if ((hasListContainer || isListRoute) && saysNoMergeRequests) {
        return JSON.stringify({ outcome: 'empty', items: [] });
      }
      // A bare list container may still be hydrating; without positive
      // empty-state evidence it is never a decisive empty list.
      return unsupported(hasListContainer || modernRoot ? 'listNotReady' : (isListRoute ? 'unrecognizedLayout' : 'wrongPage'));
    }

    const items = [];
    let sawRowElement = false;
    for (const [rowElement, rowAnchors] of rowsInOrder) {
      sawRowElement = true;
      if (!isVisible(rowElement)) { continue; }
      const titleElement = firstVisible([rowElement], TITLE_SELECTORS);
      const titleAnchor = titleElement && (titleElement.closest('a[href]') || titleElement.querySelector('a[href]'));
      let chosenAnchor = rowAnchors.includes(titleAnchor) ? titleAnchor : null;
      let iid = null;
      for (const candidate of rowAnchors) {
        if (titleAnchor && chosenAnchor === titleAnchor) { break; }
        const match = candidate.pathname.match(MR_PATH_PATTERN);
        if (!match) { continue; }
        const candidateText = compactText(candidate);
        if (candidateText && !/^!?\d+$/.test(candidateText)) { chosenAnchor = candidate; break; }
        if (!chosenAnchor) { chosenAnchor = candidate; }
      }
      if (!chosenAnchor) { continue; }
      iid = chosenAnchor.pathname.match(MR_PATH_PATTERN)[1];

      const roots = [rowElement];
      let title = compactText(titleElement);
      if (!title) {
        const fallback = compactText(chosenAnchor);
        if (fallback && !/^!?\d+$/.test(fallback)) { title = fallback; }
      }
      if (!title) { continue; }

      const isDraft = Boolean(firstVisible(roots, [
        '.draft-status',
        '[data-testid="issuable-draft-status-badge"]',
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
        target: compactText(firstVisible(roots, TARGET_SELECTORS)),
        updated: updatedText(rowElement)
      });
    }

    if (sawRowElement && items.length === 0) {
      // MR anchors existed but no row could be read; never report a false zero.
      return unsupported('unreadableRows');
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
        document.querySelector('.issuable-list-container .content-list.issuable-list') ||
        document.querySelector('.empty-state, [data-testid="empty-state"], .gl-empty-state') ||
        document.querySelector('form#new_user, input[name="user[login]"], form[action*="users/sign_in"]')
      );
    return Boolean(ready);
    """#
}
