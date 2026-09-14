# Review evidence: Phase 1 — semantics and capability check

Status: design only, no implementation changes. Probed against gitlab.com (SaaS) on
2026-09-11 with read-only `glab api --method GET` calls, authenticated as the configured
user. Scope under test: group `drg4480034` (the configured reviews URL).

## 1. Verified evidence sources

| Evidence | Endpoint (read-only GET) | Verified fields | Verdict |
|---|---|---|---|
| Authenticated identity | `/user` | `id`, `username` | Available |
| Group inventory | `/groups/:id/merge_requests?state=opened&scope=all` | `iid`, `project_id`, `author`, `state`, `draft`, `reviewers`, `created_at`, `updated_at`, `web_url` | Available |
| `reviewer_id` discovery filter | `?reviewer_id=<id>` plus `Any`/`None` variants | group-level filter accepted, results filtered | Available |
| Project MR detail | `/projects/:id/merge_requests/:iid` | same core fields | Available |
| Current reviewers | MR list/detail `reviewers[]` | `{id, username, name, state, ...}` — `state` is the **account** state (`active`), not reviewer review-state | Available, **without** review-state |
| Reviewer review-state (`review_requested` / `review_completed` / `unreviewed`) | REST: absent from `reviewers[]`. GraphQL `reviewers.nodes.state` returns account state | confirmed live on gitlab.com | **Not available** |
| Review-request events | system notes in `/discussions` | `"requested review from @user"` with `created_at` | Available (best-effort timing) |
| Approvals | `/projects/:id/merge_requests/:iid/approvals` | `approvals_required`, `approvals_left`, `approved`, `approved_by`, `user_has_approved`, `approval_rules_left`, `has_approval_rules` | Available |
| `/approved_by` endpoint | `/projects/:id/merge_requests/:iid/approved_by` | HTTP 404 on the fixture project | **Treat as unavailable**; `/approvals.approved_by` supersedes |
| Revision changes | `/projects/:id/merge_requests/:iid/versions` | `id`, `created_at`, `head_commit_sha`, `base_commit_sha`, `real_size` | Available — authoritative revision-event source |
| Discussions/notes | `/projects/:id/merge_requests/:iid/discussions` | `notes[].system`, `resolvable`, `resolved`, `created_at`, `author{username,id,state}`, `type`, `commands_changes` | Available (`resolved` verified on resolvable notes via public data) |
| Bot identity | REST note authors carry **no** `bot` flag; `/users/:id` has `bot` | verified field absence | Lookup-based detection required |
| Commit history | `/commits` | `authored_date`, `committed_date`, … | Available but **excluded by policy** (never used for timing) |
| Events API | `/events?action=approved&target_type=merge_request` | returns 200 (empty for this user) | Available but **excluded by policy** (retention/visibility unreliable) |

### Capability gaps and the unknowns they force

1. **Reviewer review-state is not exposed.** "Review requested" must therefore mean
   *membership in the MR's current `reviewers` list* — which is exactly the plan's
   definition. GitLab does not distinguish "requested, not yet looked" from
   "requested, reviewed" through the API, so the product must not claim reviewer
   progress from the reviewers field. Review-request *timing* is only available where
   a `"requested review from @user"` system note exists; otherwise request timing is
   unknown and the MR sorts as unknown-timing.
2. **GraphQL introspection of reviewer state returned nothing definitive;** REST is the
   collector's source anyway. If reviewer state ever becomes available it is an
   additive enhancement, not a dependency.
3. **Bot detection needs `/users/:id`** (has `bot`) for note authors; cached per user
   per scan. Where lookup fails, author identity is *ambiguous* (see rules below).
4. **`/approved_by` is not universally available**; `/approvals` is.

## 2. Mode and scope policy

### Scope resolution
- Input is the configured reviews URL. Parse it into: host, path, and recognized
  filters. Supported list-page filters for v1: **labels, milestone, search**
  (translated into equivalent `merge_requests` query params, preserving the URL's
  interpretation). Everything else — author/assignee/reviewer filters, state, draft,
  wip, sorting, pagination — is ignored for discovery (mode determines inclusion),
  and scope/assignee filters are **rejected** with a specific explanation rather than
  silently broadened.
- Path forms: `/groups/<path>/-/merge_requests` → group scope;
  `/projects/<path>/-/merge_requests` or `/namespace/repo/-/merge_requests` → project
  scope; a dashboard URL (`/dashboard/merge_requests`, `/merge_requests`) → **all
  accessible projects on that host**, displayed explicitly as such.
- Resolve group/project to numeric IDs before discovery; unresolved identity is a
  hard failure, never a silent broadening.
- Effective scope (host + resolved scope + applied/ignored filters + mode) is shown in
  Settings and the review view.

### Personal mode
- Include an MR when: (a) the authenticated user is in the MR's current `reviewers`
  list, or (b) the user authored a qualifying non-system note in the MR's discussions.
- Prioritize (a) outstanding review requests, then (b) verified activity since the
  user's feedback.
- Own MRs (author id == me) are never included; they belong to the authored workflow.

### Team mode
- Include all eligible MRs in scope regardless of assigned reviewer.
- Prioritize MRs with no reviewer discussion, then remaining eligible MRs.
- "No reviewer discussion" never claims nobody reviewed — it states a fact about
  retrieved discussion evidence only.

### Shared eligibility (both modes)
- Exclude: `state != opened`, `draft == true`, own MRs.
- Keep approved MRs eligible; approval is a separate displayed fact.
- Exclusions are applied only from verified facts; unverifiable lifecycle/draft state
  retains the previous card as stale instead of removing it.

### Cache/snapshot identity
`host + resolved scope id + mode + authenticated user id + scope-filter signature`.
Switching mode or user never reads the other's snapshot as fresh.

## 3. Category decision table

Evidence facts (collector output, all with provenance):
- `requestedException`: I am in current `reviewers` (membership fact).
  `requestTiming`: from review-request system note, else unknown.
- `myQualifyingComments`: non-system, non-bot notes authored by me, with timestamps.
- `revisionChanges`: `/versions` entries with `created_at`.
- `authorRepliesInMyThreads`: author notes in discussions I participated in, after my
  latest note in that discussion.
- `otherHumanComments`: non-system, non-bot, non-author human notes (mine included in
  participation; others' count as reviewer discussion).
- `approvalFacts`: `approved_by`, `approvals_required/left` (separate, never suppress).
- `coverage`: endpoint/page completeness per MR and inventory completeness per scope.

Precedence (first match wins as primary label; all matching facts shown as reasons):

| # | Category | Requires | Mode inclusion | Example reason |
|---|---|---|---|---|
| 1 | Review requested | `requestedException` true | Personal (top priority), Team (eligible) | "GitLab requested your review 2 hours ago" / "GitLab lists you as a reviewer" (timing unknown) |
| 2 | Changes since your feedback | I have a qualifying comment at T, and a `/versions` entry with `created_at > T` | Personal (second priority) | "Source changed 35 minutes after your comment" |
| 3 | Author replied | Author note in a discussion I participated in, after my latest note there | Personal (third priority) | "Author replied to your discussion 12 minutes ago" |
| 4 | Reviewer discussion exists | ≥1 qualifying non-author human comment | Team (second priority), Personal (residual) | "2 reviewers have commented" |
| 5 | No reviewer discussion | Complete discussion evidence contains zero qualifying non-author human comments | Team (top priority) | "No reviewer discussion yet" |
| — | Evidence incomplete | Any required evidence unverifiable | Overlay on any card | "2 of 4 evidence sources verified" |

Deciding cases:

| Case | Decision |
|---|---|
| Requested reviewer + another developer commented | Review requested (primary) + reviewer-discussion fact |
| Comments exist but review completion unknown | Never a completed-review claim; category stays 1/4 by facts |
| Author reply in an unrelated thread | Not an author-reply fact for me; feeds "reviewer discussion exists" only |
| Code change after feedback; commits carry old authored dates | Uses `/versions[].created_at`; commit dates never consulted |
| Versions endpoint unavailable | "Change timing unknown"; category 2 cannot be assigned; fall through |
| Approval reset to zero / partially satisfied rules | Approval chip reflects current `/approvals`; never suppresses the card |
| Approved MR still requesting my review | Eligible; category 1; approval chip shown alongside |
| Bot or system note among comments | Excluded from qualifying counts |
| Author identity ambiguous (bot lookup failed, non-suffix name) | Note is not counted as qualifying; if it would have been the only qualifying evidence, the MR becomes Evidence incomplete instead of "No reviewer discussion" |
| Discussions fetch partial/failed | Evidence incomplete; previous card retained as stale |
| Inventory incomplete | Never "No merge requests to review"; coverage shown; missing MRs not removed |
| MR deleted out-of-band | Removed only after complete successful inventory confirming absence |
| Draft→ready, open→merged/closed, reviewer added/removed | Re-derived each scan; `updated_at` is a refetch hint only |

## 4. Deterministic classification rules

- Identity matching by numeric user IDs (MR `author.id`, note `author.id`,
  `reviewers[].id`, `/user.id`). Username string matching is never authoritative.
- Qualifying human comment: `system == false` AND author is not the MR author AND
  bot-status is determinably false. Bot status = `/users/:id` → `bot` field; when
  lookup fails, username suffix `-bot`/`_bot` marks a bot; anything else is ambiguous
  (see table).
- "Changes since your feedback" compares my latest qualifying comment time to
  `/versions[].created_at` only. `updated_at`, `prepared_at`, commit authored dates,
  and events are never activity proof. No version timestamp after my comment → the
  change claim is not made; unknown is shown when versions are unavailable.
- Author replies require discussion-level pairing: I commented in that discussion,
  author replied after my latest note in it. Replies elsewhere are not author-reply
  facts for me.
- Every category assignment must cite fact IDs (note id, version id, reviewers
  membership) in the disclosure; categories without citable facts are not shown.

## 5. Collector shape (Phase 2 contract)

Per scan: `/user` → resolve scope id → inventory (`/groups/:id/merge_requests` or
`/projects/:id/merge_requests`, paginated, `reviewer_id=<me>` second pass for Personal)
→ per-MR: `/approvals`, `/versions`, `/discussions` (paginated), plus `/users/:id` for
unknown note authors. Four endpoints/MR plus identity and inventory. Bounded
concurrency (4), per-request retry with backoff on 429/5xx, per-endpoint and overall
deadlines, pagination ledger per endpoint, memory-only cache keyed as in §2.

MRReviewScanController then publishes: evidence snapshot (typed facts + provenance),
coverage summary (e.g. `24 MRs found / 22 checked / 2 incomplete`), and deterministic
classification. It accepts nothing from AI. MRReviewTriagePrompt becomes an optional
summarizer over already-collected facts; failure leaves the factual UI intact.

Live-acceptance prerequisite: the current group scope contains only 4 open fixture MRs
with no reviewers, so Personal mode is empty there today. Acceptance needs a fixture
set with: requested reviewers, reviewer discussions, author replies after feedback,
post-feedback pushes, bots, and reset approvals — recorded independently.

## 6. Open items for implementation phase

- Default mode Personal (per plan) persisted under a new AppSettings key; selector in
  Home Review column header and Settings.
- `MRReviewCategory` is redefined; `MergeRequestSummary.triageCategory/triageReason`
  consumers (HomeBoardBuilder, cards, accessibility) need the new labels and facts.
- Rate limits: gitlab.com authenticated REST allows ~2,000 req/min; bounded
  concurrency plus 429/5xx backoff is sufficient for group-scale scans.