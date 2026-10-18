# Plan: GitHub sync mechanism, rendered from a local SQLite store

## Goal

Today each page fetches via `gh`, keeps the result in vui state, and
mirrors it to a per-page JSON file (`octocat-vui-use-cached`).  Each page
handles its own loading and error states, nothing de-duplicates or caps
requests, and each action refreshes its page by hand.

We put a sync layer between pages and GitHub, with SQLite as its store.
It has three aims:

1. **Less page code.**  A page gives a resource spec and a render
   function.  Fetching, caching, status, skeletons, errors, in-progress
   lines and post-action refreshes move into shared code.
2. **Changes reach other pages.**  After an issue is edited, the issue
   list shows at once that it is outdated, and refetches when viewed.
3. **Less load on GitHub.**  An unchanged refetch writes and renders
   nothing, requests are de-duplicated and
   capped, permanent failures are remembered, and invalidation refetches
   only what is on screen.

How it works: pages ask for **resources** ("issue o/r#12", "open PRs of
o/r") and submit **mutations**.  They never see `gh`, freshness or the
network.  Fetches write to the store and never hand data to the UI.
Pages read the store, and re-render when it reports a change to what
they read.  So a page paints from the store at once, a refresh runs
behind it, and the write re-renders the page.

Total code may not shrink much: the value is in the shared layer.  Page
code must shrink.

Out of scope: avatars, repo-search candidates, and completion candidates
(labels, people, branches).  These are small and already paint cached
data first.  Non-goals:
- Offline mutations.  Mutations need the network; offline, pages still
  read from the store.
- Background sync.  A resource is fetched only while something asks for
  it, never on a timer.

## Compared with today

Online browsing feels the same: most pages already paint from a cache.

Better:
- A failed refresh keeps the page; today it shows `Error: …`.
- After an action, other open pages update; today they wait for `g`.
- Two windows on one item share requests and agree.
- Uncached pages (user, dashboard, workflow) open painted.

Worse:
- The refactor is large; the pilot must show it pays off.

## How a change reaches the screen

vui re-renders only on `vui-set-state` or `vui-rerender`, and either one
re-renders the whole page.  Each page is its own buffer, so a change
re-renders just the pages that read it.

1. Sync writes a response or a status change, then notifies once with
   the touched keys.
2. For each buffer with hooks subscribed to those keys, sync bumps their
   versions and re-renders the page once.
3. The page re-reads the store, vui patches the buffer (point is kept),
   and Emacs redisplays.

Never trigger a render during a render.  Notify once per write, after
the commit.  Subscriptions are effects, so they are removed when the
page's buffer is killed (`vui-mount` hooks `kill-buffer-hook`).

### Example: commenting on an issue while its list is open

The issue list of `o/r` is open in one window.  The user opens issue
#12 in another and adds a comment.

Arrows from sync are **snapshots**: what the store says, not what is
drawn.  The page's wrapper turns each one into what the user sees.

```
 Issue list              Issue #12 page             Sync + store                 GitHub
      │                         │                         │                         │
 1    │                         │── open #12 ────────────▶│── fetch 2 ─────────────▶│
      │                         │◀─ no data, :loading ────│                         │
 2    │                         │                         │◀─ 2 bodies ─────────────│
      │                         │◀─ issue + timeline ─────│                         │
      │                         │                         │                         │
 3    │                         │── add comment ─────────▶│── send mutation ───────▶│
      │                         │◀─ :mutating ────────────│                         │
 4    │                         │                         │◀─ ok ───────────────────│
      │◀─ :outdated ────────────┼─────────────────────────│                         │
      │                         │◀─ :outdated ────────────│── refetch all 3 ───────▶│
 5    │                         │                         │◀─ timeline ─────────────│
      │                         │◀─ new timeline ─────────│                         │
 6    │                         │                         │◀─ issue ────────────────│
      │                         │◀─ fresh issue ──────────│                         │
 7    │                         │                         │◀─ list ─────────────────│
      │◀─ fresh list ───────────┼─────────────────────────│                         │
```

1. The snapshot has no data and `:loading t`, so the wrapper calls the
   page's `:skeleton`: grey bars shaped like the header and tabs to
   come (`octocat-vui-detail-skeleton`), so nothing jumps on arrival.
2. With data, the wrapper calls `:render`.  A first fetch invalidates
   nothing, so the list is untouched.
3. `:mutating "Adding comment"` makes the page draw
   `▘ Adding comment…` in place of its buttons.  The list is matched
   only by a wildcard, which doesn't carry `:mutating`.
4. GitHub accepts the comment.  Sync marks the issue, its timeline and
   the repo's issue lists `:outdated`.  Both windows keep their content,
   with the mode-line spinner.  All three are refetched at once.
5–7. Each refetch that changed something sends a fresh snapshot, and
   the window re-renders.  On a normal network this takes under a
   second, so no header line appears.  On a slow one, each window shows
   `Outdated: refreshing…` after half a second, until its refetches
   land.

What this shows:
- Neither page fetches, waits or refreshes by hand: each re-renders
  when sync tells it something it shows has changed.
- The list never blanks.  It keeps showing #12, and updates when its
  refetch lands.
- GitHub sees 2 requests on open and 3 after the comment.
- If the list's refetch had come back unchanged, nothing would
  re-render.
- If the list hadn't been open, it would be marked outdated without a
  request, and refetched the next time it is opened.

## 1. `octocat-sync.el` (new; loads after `octocat-core.el`)

### Store

- It uses Emacs's built-in `sqlite-*`, so there is no new dependency.
  The dev Emacs 31.1 has SQLite 3.54.0.  SQLite is required: without it,
  every octocat command fails with a `user-error`, and the README says
  so.
- There is one file per host, in `octocat-sync-directory`
  (`github.com.sqlite`, or the host from `$GH_HOST`).  It runs WAL, with
  `busy_timeout=2000`.
- The store is a cache, so there are no migrations: an older schema is
  dropped and recreated.  A newer schema means another Emacs runs a
  newer octocat, so the tables are left alone and the user is asked to
  restart.
- The store's functions touch only SQLite, so tests run them on
  `(sqlite-open nil)`.

```sql
CREATE TABLE resource (
  key TEXT PRIMARY KEY,   -- printed spec, e.g. (issue "o/r" 12)
  body TEXT,              -- JSON document; NULL = never fetched
  hash TEXT,              -- of body: an unchanged refetch writes nothing
  cursor TEXT,            -- lists: where the next page starts
  fetched_at REAL,        -- last success
  invalidated_at REAL,    -- known outdated since; cleared by a success
  error TEXT,             -- last failure; NULL after a success
  error_kind TEXT,        -- 'transient' | 'permanent'
  retry_at REAL);         -- don't fetch before this
```

Each resource stores one JSON document.  An issue in a list and on its
own page is stored twice, and invalidation keeps the copies honest.
Data stays hash tables, as `json-parse-string` returns and every view
reads today; there are no generated models.

Several Emacs processes may share the file.  This stays correct but is
not efficient: each process fetches on its own and sees the other's
writes only when it next reads.  A write that is still locked after the
timeout is dropped and logged.

### Resources

```elisp
(octocat-sync-define-resource issue (repo number)
  :fetch       (lambda (done) …)
  :invalidates (lambda () (list `(issues ,repo _))))   ; when it changed
```

**Rule: a resource's `:data` shape is its contract.**  Its fetch's parse
function defines the shape views read, and pages never depend on how
the store keeps it.  So the store can change later without touching any
page.  Normalization, the planned next phase (see "Migration"), will
rebuild each document from entity rows and run the same parse over it,
giving views the same shape.  Reshaping data is the parse function's
job, never the view's.

- A **spec** such as `(issue "o/r" 12)` names one instance, and its
  printed form is the key.  `_` is a wildcard, so `(issues "o/r" _)`
  matches every issue list of the repo.
- `octocat-sync-request (spec &key force)` returns a snapshot at once
  and queues a fetch if needed.  Reading never waits on the network.
  The snapshot is
  `(:data :loading :outdated :error :kind :offline :mutating)`.
- `octocat-sync-subscribe (spec fn)` returns an unsubscribe function,
  and the vui hook is built on it.
- Every resource, detail or list, is refetched each time a page opens
  it: the newest data matters most.  The body hash keeps an unchanged
  refetch from writing or re-rendering.
- `:max-age` is the exception, for data that rarely changes and is
  costly to fetch, such as a file tree at a commit, which never
  changes.  Within it, opening doesn't refetch.  Invalidation and `g`
  refetch regardless.
- Nothing is fetched before `retry_at`, except on `g`.
- If a fetch returns the stored hash, only `fetched_at` changes, and
  nothing is notified, unless the fetch clears an outdated mark or an
  error, which the page must stop showing.  If it
  returns a changed body, the body is stored, subscribers are notified,
  and the resource's `:invalidates` are invalidated.  A first fetch
  (no stored body) invalidates nothing: there is nothing to compare.
- **Invalidation** keeps the data and shows it with `:outdated t`.
  Resources on screen are refetched now; the rest when next viewed.
- **Lists:** a fetch replaces the first page, and `octocat-sync-more`
  appends the next one.  A paged list inside an item (timeline,
  comments, reviews) is its own resource, e.g.
  `(issue-timeline "o/r" 12)`.

**REST or GraphQL** is chosen per resource; pages never see which.
- Use GraphQL for detail pages, timelines and search lists.  One or two
  queries replace the 6–8 paged REST requests a PR page would need, so
  load and latency are lower and documents are smaller.  Some data is
  GraphQL-only: pinned items, linked PRs, review-thread resolution.
- Use REST where GraphQL lacks the data (Actions runs, jobs and logs;
  git trees) and for simple single objects.

**Transport: `gh`, behind one function.**  `gh` handles auth, hosts and
proxies.  Direct HTTP would need `url.el`, which is fragile, or a new
dependency, and every request would still pay a TLS handshake.  Every
request uses `gh api -i`, for REST and GraphQL alike, so the HTTP
status and rate-limit headers come back with the body.  Should `gh`'s
process start-up show as lag, only this function changes.

### Mutations

```elisp
(octocat-sync-define-mutation close-issue (repo number)
  :label       "Closing issue"
  :send        (lambda (done) …)
  :invalidates (lambda () (list `(issue ,repo ,number)
                           `(issue-timeline ,repo ,number)
                           `(issues ,repo _))))
```

`octocat-sync-submit` sends a mutation; it works online only.
- While it runs, the resources it names exactly (not wildcards) carry
  `:mutating "Closing issue"`, so the issue page shows it and the list
  doesn't.  Pages draw the in-progress line from it, replacing today's
  buffer-local action variables.
- On success, the affected resources are invalidated, which replaces
  the hand-written refreshes.
- On failure, the error goes to the echo area, and a draft stays open
  in its `octocat-edit` buffer.

### Queue and status

At most 4 requests run at once (`octocat-sync-max-requests`).  Running
one at a time would add up a page's fetch times, and no limit risks
GitHub's secondary rate limits.  Reads of one key are de-duplicated,
mutations never are.  A rate-limit error pauses the queue until its
reset time.

Status is kept apart from the data, so a failed refresh still shows the
old data.

- **Loading** is kept in memory only, so it can't outlive a crash.
- **Offline** is kept in memory.  It is set when a request fails with no
  HTTP status, and cleared by the next success.
- **A transient failure** (5xx, rate limit) is stored in the row, and
  retried after 60 s, or at the rate-limit reset.
- **A permanent failure** (404, 410, 403, 401) is stored in the row, and
  retried after a day.  A deleted issue reopens as "Not found" without a
  request; `g` retries at once.

## 2. Page side (`octocat-vui.el`)

**The hook.**  `octocat-vui-use-resource (spec)` returns the snapshot,
replacing `octocat-vui-use-cached` and `-use-async-sticky`.
- It memoizes the snapshot on the spec and a **version**.  The
  memo is just a read of the store, replaced on every change and never
  written back.
- It subscribes in an effect, registering (buffer, key, bump-version)
  in one subscription table.  The version lives in a `vui-use-ref`,
  because a hook can't own vui state, and a ref change doesn't
  re-render by itself.
- Sync notifies once per write, with every changed key.  It groups the
  matching subscriptions by buffer, bumps their versions, and calls
  `vui-rerender` once per buffer, synchronously.  So a write touching
  the issue, its timeline and the list renders each page once, with no
  timer.
- Nothing polls: fetches happen only on open, on `g`, or on
  invalidation.
- It records each snapshot per buffer, so the mode line and header line
  cover every resource on the page.

**The wrapper** leaves the page with no status code:

```elisp
(octocat-vui-resource-view `(issue ,repo ,number)
  :skeleton (lambda () (octocat-vui-detail-skeleton repo number width))
  :render   (lambda (issue) …))
```

- **Data, loading:** the page, with only the mode-line spinner, as
  today.
- **Data, outdated, refetch running:** the page, with only the
  mode-line spinner.  If the refetch is still running after
  `octocat-sync-notice-delay` (0.5 s), the header line adds
  `Outdated: changed since 14:02, refreshing…`.  A fast network never
  shows it.
- **Data, outdated, failed or offline:** the page, plus a header line
  at once, such as `Outdated: offline, showing data from 14:02` or
  `Refresh failed: MSG; g to retry`.
- **No data, loading:** the skeleton.
- **No data, offline or failed:** the message and a retry hint.
- **No data, permanent failure:** "Not found" or "No access".

The notice goes in the header line, not the buffer, so the content
doesn't shift when it clears.  The delay is a one-shot timer per
buffer, started when an outdated resource starts refetching and
cancelled when it lands.

## 3. Migration

**Pilot: the user page.**  The layer is added, and only `octocat-user.el`
moves to it, while other pages stay on the old helpers.  There is no
toggle: a page is on one path or the other.  The user page fits because
no other page reads its data, and it has no cache today, so the gain
shows.  It also mixes REST and GraphQL and has a paged list.  It has no
mutations; those come with the issue page.

The pilot is done when:
- the page has only specs and render functions, with no fetch or status
  code;
- it opens painted, revalidates, and `g` forces a fetch;
- offline, "Not found" and a failed refresh over old data all show;
- two windows on one user share requests;
- reopening it refetches, but an unchanged result writes and
  re-renders nothing;
- no subscribers are left after the buffer is killed, and there is no
  render lag.

**Steps** (each shippable):
1. `octocat-sync.el`, the hook and the wrapper, with tests.  Add the
   file to the AGENTS.md load order and to Eask, and document it in
   `docs/using-vui.md` and `docs/user-interface-conventions.md` (the
   header line).
2. The user page pilot.
3. Issue page and issue list, with their mutations.
4. PR page, PR list and timeline.
5. Repo, dashboard, actions, runs, jobs and tree.
6. Delete the old cache helpers, the `octocat--*-cache-*` functions,
   `cache-v3/repos`, and the action variables.

**Next phase: normalization** (intended, as a follow-up plan).  Once all
pages are on sync, the store moves from one document per resource to
one row per entity, so an edit shows everywhere at once (titles, users,
labels), with no refetch or patching.  It changes only the inside of
`octocat-sync.el`; the `:data` contract rule keeps pages untouched.  The
follow-up plan must handle what made us defer it: `id __typename` in
every query, fields keyed by their arguments (`labels(first: 5)` ≠
`labels(first: 100)`), merging partial fetches without `json_patch`,
and a type map for REST responses.

## Tests

- Store:
  - a write round-trips, and an unchanged hash notifies nothing;
  - an old schema is recreated, and a new one signals;
  - a write blocked by a second connection is dropped quietly.
- Sync (stub fetchers):
  - a success clears the error;
  - a 5xx waits 60 s unless forced, and a 404 waits a day;
  - a failure with no status sets offline;
  - one fetch runs per key, and no more than the cap run at once;
  - a changed fetch invalidates its wildcard lists, and an unchanged one
    doesn't;
  - a mutation sets `:mutating`, then invalidates.
- Hook and wrapper:
  - a change to its key re-renders, and a change to another key
    doesn't;
  - killing the buffer unsubscribes;
  - each of the wrapper's cases renders as described;
  - an outdated refetch that lands within the delay shows no header
    line, and one that runs longer does.

## To verify

- `gh api -i` gives a parseable HTTP status for REST and GraphQL
  failures, and network failures can be told apart from them.
- A 100-row list document reads and parses in under 5 ms.
- Re-rendering the longest PR timeline doesn't lag.  If it does, add
  `:memo` to the timeline and the markdown bodies.

## Deferred (behind the resource API, so pages won't change)

Normalization is not deferred but planned as the next phase; see
"Migration".


- **Patching copies**, for an instant list update after an edit, only
  if it is wanted before normalization, which supersedes it.  When
  fresh item data arrives, update copies with the same `id` in the
  repo's lists.  Copy only top-level scalar fields the copy already
  has, in Lisp.  Never copy connections: `labels(first: 5)` and
  `labels(first: 100)` would overwrite each other.  Never use
  `json_patch`, which deletes keys whose value is null.
- **REST ETags.**  A 304 doesn't count against the rate limit, but most
  fetches are GraphQL, which has no ETags, and pull-on-view stays far
  below the quota.  The body hash already skips the write and the
  render.  ETags are worth adding only for polling, or for a REST page
  that refreshes often.
- **One file per account.**  Accounts on one host share the file, so
  one account's private data can show under another until it
  revalidates.  A fix needs the active login without a request, e.g.
  from `gh`'s `hosts.yml`.
- **Direct HTTP** in place of `gh`, if `gh`'s process start-up shows as
  lag.
