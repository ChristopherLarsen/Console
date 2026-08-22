import Foundation

/// The function body handed to `WebPage.callJavaScript` for GitHub pull-request
/// lists. It only inspects DOM GitHub has already rendered — it never issues
/// requests. It returns a JSON string decoded by the shared
/// `MergeRequestListExtractor`.
///
/// Selectors follow the same structural-generality rules as the GitLab
/// extractor: anchors are located by the stable `/pull/<number>` URL shape,
/// rows by nearest list-item semantics, and fields prefer accessible labels
/// over generated class names.
enum GitHubListExtractorJavaScript {

    static let source = #"""
    const AUTH_SELECTORS = [
      'form[action="/session"]',
      'form[action$="/session"]',
      '#login_field',
      'input[name="login"]',
      'input[name="password"]'
    ];
    const EMPTY_SELECTORS = ['.blankslate', '[data-testid="blankslate"]', '.empty-state'];
    const TITLE_SELECTORS = [
      '[data-testid="pr-title"]',
      'a.markdown-title',
      'a.Link--primary'
    ];
    const PROJECT_SELECTORS = [
      'a[data-hovercard-type="repository"]',
      '[data-testid="repo-link"]'
    ];
    const AUTHOR_SELECTORS = [
      '.opened-by a',
      'a[data-hovercard-type="user"]'
    ];
    const REVIEW_SELECTORS = ['.State', '[data-testid="state-label"]'];
    const PR_PATH_PATTERN = /\/pull\/(\d+)\/?$/;

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

    function rowElementFor(anchor) {
      let current = anchor;
      for (let depth = 0; current && depth < 12; depth += 1) {
        if (current.tagName === 'LI') { return current; }
        if (current.getAttribute && current.getAttribute('role') === 'listitem') { return current; }
        if (current.classList && (current.classList.contains('js-issue-row') || current.classList.contains('Box-row'))) { return current; }
        if (current.getAttribute && current.getAttribute('data-testid')) { return current; }
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

    function pipelineState(row) {
      // Prefer an explicit accessible label on a status element.
      const labeled = row.querySelectorAll('[aria-label]');
      for (const element of labeled) {
        if (!isVisible(element)) { continue; }
        const label = accessibleLabel(element);
        if (!label) { continue; }
        const lowered = label.toLowerCase();
        if (lowered.indexOf('check') === -1 && lowered.indexOf('ci') === -1 && lowered.indexOf('action') === -1) { continue; }
        if (lowered.indexOf('fail') !== -1 || lowered.indexOf('error') !== -1) { return 'Failed'; }
        if (lowered.indexOf('pass') !== -1 || lowered.indexOf('success') !== -1) { return 'Passed'; }
        if (lowered.indexOf('progress') !== -1 || lowered.indexOf('pending') !== -1 || lowered.indexOf('running') !== -1) { return 'Running'; }
      }
      // Fall back to well-known status octicon shapes.
      if (firstVisible([row], ['.octicon-circle-slash', '.octicon-x'])) { return 'Failed'; }
      if (firstVisible([row], ['.octicon-check', '.octicon-check-circle-fill'])) { return 'Passed'; }
      if (firstVisible([row], ['.octicon-clock', '.octicon-dot-fill'])) { return 'Running'; }
      return null;
    }

    function isDraftRow(row) {
      if (firstVisible([row], ['.octicon-draft-pr', '[data-testid="draft-badge"]', '[class*="labelDraft" i]'])) { return true; }
      const badges = row.querySelectorAll('[class*="Label" i], [class*="badge" i], [class*="badge" i] *');
      for (const badge of badges) {
        if (!isVisible(badge)) { continue; }
        if ((compactText(badge) || '').toLowerCase() === 'draft') { return true; }
      }
      return false;
    }

    function updatedText(row) {
      const times = row ? row.querySelectorAll('relative-time, time') : [];
      for (let index = times.length - 1; index >= 0; index -= 1) {
        if (isVisible(times[index])) { return compactText(times[index]); }
      }
      return null;
    }

    if (matchesAny(AUTH_SELECTORS)) {
      return JSON.stringify({ outcome: 'authenticationRequired', items: [] });
    }

    const anchors = [];
    for (const anchor of document.querySelectorAll('a[href]')) {
      if (!anchor.pathname) { continue; }
      const match = anchor.pathname.match(PR_PATH_PATTERN);
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
      const hasEmptyState = matchesAny(EMPTY_SELECTORS);
      if (hasEmptyState) {
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
      let number = null;
      for (const candidate of rowAnchors) {
        const match = candidate.pathname.match(PR_PATH_PATTERN);
        if (!match) { continue; }
        const candidateText = compactText(candidate);
        if (candidateText && !/^#?\d+$/.test(candidateText)) { chosenAnchor = candidate; break; }
        if (!chosenAnchor) { chosenAnchor = candidate; }
      }
      if (!chosenAnchor) { continue; }
      number = chosenAnchor.pathname.match(PR_PATH_PATTERN)[1];

      const roots = [rowElement];
      let title = compactText(firstVisible(roots, TITLE_SELECTORS));
      if (!title) {
        const fallback = compactText(chosenAnchor);
        if (fallback && !/^#?\d+$/.test(fallback)) { title = fallback; }
      }
      if (!title) { continue; }

      items.push({
        url: chosenAnchor.href,
        iid: number,
        title: title,
        project: compactText(firstVisible(roots, PROJECT_SELECTORS)),
        author: compactText(firstVisible(roots, AUTHOR_SELECTORS)),
        isDraft: isDraftRow(rowElement),
        pipeline: pipelineState(rowElement),
        review: compactText(firstVisible(roots, REVIEW_SELECTORS)),
        updated: updatedText(rowElement)
      });
    }

    if (sawRowElement && items.length === 0) {
      // PR anchors existed but no row could be read; never report a false zero.
      return JSON.stringify({ outcome: 'unsupported', items: [] });
    }
    return JSON.stringify({ outcome: 'items', items: items });
    """#
}
