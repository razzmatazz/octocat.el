# Plan: GitHub sync mechanism, rendered from a normalized SQLite store

## Goal

Today each page fetches via `gh`, keeps the result in vui state, and
mirrors it to a per-page JSON file (`octocat-vui-use-cached`).  Each page
handles its own loading and error states, nothing de-duplicates or caps
requests, and each action refreshes its page by hand.

We put a sync layer between pages and GitHub, with SQLite as its store.
Records shared by pages (issues, PRs, users, repos, labels, runs) are
stored once, as **entities**, and every page that shows one reads the
same row.  Its aims, in order of priority:

1. **Hiding latency.**  The user should rarely wait on the network or
   see that a request is in flight.  Every page paints at once: from
   the store if it has data, from the entities a list already fetched
   if it has some, or as a skeleton shaped like the page to come if
   not.  The row under point is prefetched, so opening it is usually
   instant.  Actions apply on screen before GitHub answers.  Refreshes
   run behind the painted page and never blank it.  A page's requests
   run in parallel, GraphQL keeps them few, and status notices wait
   half a second, so a fast network shows none.  When this goal
   conflicts with another, it wins.
2. **Less page code.**  A page gives a resource spec and a render
   function.  Fetching, caching, status, skeletons, errors, in-progress
   lines and post-action refreshes move into shared code.
3. **Changes reach other pages.**  After an issue is renamed, every
   page showing it shows the new title at once, with no refetch.  A
   list whose membership may have changed is marked outdated, and
   refetches when viewed.
4. **Less load on GitHub.**  An unchanged refetch writes and renders
   nothing, requests are de-duplicated and capped, permanent failures
   are remembered, invalidation refetches only what is on screen, and
   prefetch is bounded.

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
  it (a page, or prefetch at point), never on a timer.
- Whole-repo sync, as forge does it.  octocat browses any repo, so
  pulling every issue of each one up front costs too much.

### Prior art

- **Document cache with invalidation** (TanStack Query, SWR): paints
  from cache and refreshes behind, but an edit only marks other pages
  outdated.  This plan's first draft was this.
- **Query-driven graph cache** (Apollo, Relay, urql graphcache): every
  query reads one shared graph.  It assumes all data is GraphQL with
  ids, and needs per-field key arguments and merge functions.  Most
  octocat data comes from `gh … --json` and REST, so we don't copy it.
- **Relational sync** (forge): domain tables, filled by pulling whole
  repos incrementally by `UPDATED_AT`.  Pages are instant, but the
  up-front pull doesn't suit browsing.
- **Local-first object pool** (Linear): one object per entity,
  optimistic transactions, delta sync.  GitHub has no delta endpoint,
  but one row per entity and optimistic writes carry over.

We take entity normalization and optimistic writes from Linear, and
keep fetching per resource, on view.

## Compared with today

Better:
- Opening a row from a list is usually instant: it was prefetched while
  point rested on it, or its header paints from the list's data.
- Actions show at once, on every page; today they wait for the request
  and a hand-written refresh, and other pages wait for `g`.
- A failed refresh keeps the page; today it shows `Error: …`.
- Two windows on one item share requests and agree.
- Uncached pages (user, dashboard, workflow) open painted.

Worse:
- The refactor is large; the pilot must show it pays off.
- Prefetch spends requests on rows the user may not open.  It is
  capped, low-priority and skipped near the rate limit.

## How a change reaches the screen

vui re-renders only on `vui-set-state` or `vui-rerender`, and either one
re-renders the whole page.  Each page is its own buffer, so a change
re-renders just the pages that read it.

1. Sync writes a response, an optimistic change or a status change.
   It finds the touched resources: those whose own body changed, plus
   those linked to a changed entity.  Then it notifies once with their
   keys.
2. For each buffer with hooks subscribed to those keys, sync bumps their
   versions and re-renders the page once.
3. The page re-reads the store, vui patches the buffer (point is kept),
   and Emacs redisplays.

Never trigger a render during a render.  Notify once per write, after
the commit.  Subscriptions are effects, so they are removed when the
page's buffer is killed (`vui-mount` hooks `kill-buffer-hook`).

### Example: opening and renaming an issue from its list

The issue list of `o/r` is open.  The user moves point to #12, opens
it, and renames it.

Arrows from sync are **snapshots**: what the store says, not what is
drawn.  The page's wrapper turns each one into what the user sees.

```
 Issue list              Issue #12 page             Sync + store                 GitHub
      │                         │                         │                         │
 1    │── point rests on #12 ───┼────────────────────────▶│── prefetch 2 ──────────▶│
      │                         │                         │◀─ 2 bodies ─────────────│
 2    │── RET ─────────────────▶│── open #12 ────────────▶│                         │
      │                         │◀─ issue + timeline ─────│                         │
 3    │                         │── rename ──────────────▶│── send mutation ───────▶│
      │◀─ new title ────────────┼─────────────────────────│                         │
      │                         │◀─ new title, :mutating ─│                         │
 4    │                         │                         │◀─ ok + issue ───────────│
      │                         │◀─ :outdated timeline ───│── refetch timeline ────▶│
 5    │                         │                         │◀─ timeline ─────────────│
      │                         │◀─ new timeline ─────────│                         │
```

1. Point rests on the row for 0.3 s, so sync prefetches the issue and
   its timeline at low priority.  The list row and the issue page read
   the same entity, `issue:o/r#12`.  If the prefetch finds its title
   changed, the list row re-renders too.
2. RET opens the page.  Both resources were fetched within
   `octocat-sync-fresh-for`, so it paints complete, with no request.
   Had the prefetch still been running, the open would join it.  Had
   there been none, the header would paint from the list's copy of the
   entity, and the body and timeline as skeleton bars.
3. The mutation's optimistic change sets the entity's title in memory.
   Both windows re-render at once: the list row and the page show the
   new title, and the page draws `▘ Renaming issue…` in place of its
   buttons.  The list is linked to the entity but not named by the
   mutation, so it doesn't carry `:mutating`.
4. GitHub accepts it and returns the issue.  Its fields are written to
   the entity and the optimistic change is dropped; they agree, so
   nothing re-renders.  The mutation invalidates only the timeline,
   which gains a "renamed" event, and it is refetched.
5. The timeline lands and the page re-renders.

What this shows:
- Neither page fetches, waits or refreshes by hand.
- The rename shows everywhere before GitHub answers, and the list is
  never refetched: its row reads the entity.
- GitHub sees 2 prefetch requests, the mutation, and 1 refetch.
- Had the mutation failed, the optimistic change would be dropped, both
  windows would show the old title again, and the error would go to the
  echo area.

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
- Once per session, on idle, resources not fetched for 30 days are
  deleted, then entities no resource links to.
- The store's functions touch only SQLite, so tests run them on
  `(sqlite-open nil)`.

```sql
CREATE TABLE entity (
  key TEXT PRIMARY KEY,   -- e.g. issue:o/r#12, user:octocat
  type TEXT NOT NULL,     -- issue | pr | user | repo | label | run
  fields TEXT NOT NULL,   -- JSON object, merged field by field
  fetched_at REAL);       -- newest write

CREATE TABLE resource (
  key TEXT PRIMARY KEY,   -- printed spec, e.g. (issue "o/r" 12)
  body TEXT,              -- JSON tree, entities as {"__ref": key}; NULL = never fetched
  hash TEXT,              -- of body: an unchanged refetch writes nothing
  cursor TEXT,            -- lists: where the next page starts
  fetched_at REAL,        -- last success
  invalidated_at REAL,    -- known outdated since; cleared by a success
  error TEXT,             -- last failure; NULL after a success
  error_kind TEXT,        -- 'transient' | 'permanent'
  retry_at REAL);         -- don't fetch before this

CREATE TABLE link (       -- every entity a resource's body reaches
  resource TEXT, entity TEXT,
  PRIMARY KEY (resource, entity));
CREATE INDEX link_entity ON link (entity);
```

#### How the tables fit together

A **resource** is what a page asks for: one fetch's result.  An
**entity** is a record several resources show.  A resource's body holds
everything specific to it (order, counts, cursors, timeline events) and
points at entities with `{"__ref": key}`.  An entity's fields may point
at other entities too: an issue's `author` is a ref to a user.  **link**
lists, for each resource, every entity its body reaches, directly or
through another entity.

```
  resource                           link                    entity
 ┌────────────────────────┐        ┌──────────────┐        ┌────────────────────────┐
 │ key (PK)               │──1───N─│ resource     │        │ key (PK)               │
 │ body   ──{"__ref"}─────┼╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌╌╌╌╌╌╌╌┼╌╌╌╌╌╌╌▶│ type                   │
 │ hash, cursor           │        │ entity       │─N───1──│ fields ──{"__ref"}──┐  │
 │ fetched_at             │        └──────────────┘        │ fetched_at          │  │
 │ invalidated_at         │         index on entity        └─────────────────────┼──┘
 │ error, error_kind,     │                                          ▲           │
 │ retry_at               │                                          └───────────┘
 └────────────────────────┘                                   entity → entity refs
```

Dashed arrows are refs inside JSON; SQLite doesn't see them.  `link` is
the same refs as rows, so SQL can follow them both ways.

**Example.**  The open-issue list of `o/r`, issue #12's page and its
timeline are all stored.  Alice wrote #12; Bob commented on it.

`resource`:

| key                          | body                                                                  |
|------------------------------|-----------------------------------------------------------------------|
| `(issues "o/r" open)`        | `{"nodes":[{"__ref":"issue:o/r#12"},{"__ref":"issue:o/r#13"}],"totalCount":2}` |
| `(issue "o/r" 12)`           | `{"__ref":"issue:o/r#12"}`                                            |
| `(issue-timeline "o/r" 12)`  | `{"nodes":[{"kind":"comment","author":{"__ref":"user:bob"},"body":"LGTM"}]}` |

`entity`:

| key              | type    | fields                                                                                   |
|------------------|---------|------------------------------------------------------------------------------------------|
| `issue:o/r#12`   | `issue` | `{"title":"Crash on start","state":"OPEN","author":{"__ref":"user:alice"},"labels":[{"__ref":"label:o/r/bug"}],"body":"…"}` |
| `issue:o/r#13`   | `issue` | `{"title":"Typo","state":"OPEN","author":{"__ref":"user:bob"},"labels":[]}`             |
| `user:alice`     | `user`  | `{"login":"alice","name":"Alice"}`                                                       |
| `user:bob`       | `user`  | `{"login":"bob"}`                                                                        |
| `label:o/r/bug`  | `label` | `{"name":"bug","color":"d73a4a"}`                                                        |

`link`:

| resource                     | entity                                                          |
|------------------------------|-----------------------------------------------------------------|
| `(issues "o/r" open)`        | `issue:o/r#12`, `issue:o/r#13`, `user:alice`, `user:bob`, `label:o/r/bug` |
| `(issue "o/r" 12)`           | `issue:o/r#12`, `user:alice`, `label:o/r/bug`                   |
| `(issue-timeline "o/r" 12)`  | `user:bob`                                                      |

(One row per pair; grouped here to save space.)  #12's title is stored
once.  The list fetched no `body` for #13, so that entity has none; the
issue page fetched #12's, so the list's copy of #12 carries it too,
unused.

#### Reading a resource

```
 octocat-sync-request '(issue "o/r" 12)
   │
   ├─1─ SELECT body FROM resource WHERE key = ?
   │      → {"__ref":"issue:o/r#12"}
   │
   ├─2─ SELECT e.key, e.fields FROM link l JOIN entity e ON e.key = l.entity
   │    WHERE l.resource = ?
   │      → issue:o/r#12, user:alice, label:o/r/bug
   │
   ├─3─ apply optimistic overlays to those entities (in memory)
   │
   └─4─ replace each {"__ref"} with its entity's fields, recursively
          → {"title":"Crash on start","author":{"login":"alice",…},…}
          = :data, plain hash tables
```

Two statements, whatever the page's size: `link` already holds every
entity the body can reach, so no ref is chased through SQL.  If step 1
finds no body but the resource's `:entity` exists, steps 2–4 run on that
entity alone and the result goes in `:partial`.

#### Writing a fetch

```
 parsed tree (with octocat-sync-entity wrappers)
   │
   ├─ split ─▶ entities ─ merge each into its row, field by field ─▶ C = entity keys whose fields changed
   │
   └─ body with {"__ref"} in their place
        ├─ hash ─▶ same as stored? only fetched_at changes ─▶ R = {} or {this key}
        └─ refs, followed through entity fields ─▶ replace this resource's link rows

 one transaction, then notify once:
   R ∪ (SELECT resource FROM link WHERE entity IN C)
```

Say a refetch of the open list finds #12 renamed.  The list's body is
unchanged (same refs, same count), but `issue:o/r#12` changed, so C =
`{issue:o/r#12}`.  The `link` index turns that into the list and the
issue page, and both re-render; the timeline doesn't, since it links
only `user:bob`.  An optimistic change notifies the same way, with C
taken from the overlay, without writing.

Deleting is the reverse: collection drops old resources (with their
link rows, in the same transaction), then entities no link row names.

Several Emacs processes may share the file.  This stays correct but is
not efficient: each process fetches on its own and sees the other's
writes only when it next reads.  A write that is still locked after the
timeout is dropped and logged.

### Entities

Only records that more than one page shows are entities:

| Type    | Key                | Shown on                                 |
|---------|--------------------|------------------------------------------|
| `issue` | `issue:o/r#12`     | lists, dashboard, search, issue page     |
| `pr`    | `pr:o/r#12`        | lists, dashboard, search, PR page        |
| `user`  | `user:login`       | authors, assignees, reviewers, user page |
| `repo`  | `repo:o/r`         | user page, search, dashboard, repo page  |
| `label` | `label:o/r/name`   | rows, issue and PR pages                 |
| `run`   | `run:o/r/123`      | repo, workflow, PR checks, run page      |

Everything else (timeline events, jobs, files, trees) stays inside its
resource's body.

- **Keys are natural, not GraphQL node ids.**  Not every source gives a
  node id (`gh run list --json` has only `databaseId`), but every
  source, URLs included, gives the repo and number or login.  So no
  query needs extra `id` fields.  After a rename or transfer, the old
  key goes stale and is collected.
- **One field vocabulary per type**: GraphQL's camelCase names, which
  `gh … --json` already uses.  A REST fetch's parse maps its fields
  (`html_url` → `url`) through the type's map, kept in one place per
  type.
- **Writes merge field by field**, in Lisp: a field the fetch didn't
  return is kept, and a null is stored as null.  (`json_patch` would
  delete it.)  An entity is notified only if some field's value changed.
- **List fields of an entity are always whole.**  An entity may hold a
  small set (labels, assignees) only if every fetch that writes it asks
  for the whole set (`first: 100`).  A fetch that asks for fewer keeps
  them in its resource's body.  Paged connections (timeline, comments,
  reviews, files) are their own resources, e.g.
  `(issue-timeline "o/r" 12)`.  This is how we avoid Apollo's
  key-argument and merge-function machinery: no entity field ever
  depends on a query's arguments.

### Resources

```elisp
(octocat-sync-define-resource issue (repo number)
  :entity      (octocat-sync-key 'issue repo number)
  :fetch       (lambda (done) …)                     ; DONE gets the parsed tree
  :invalidates (lambda () (list `(issues ,repo _))))  ; when its entity changed
```

A fetch's parse builds the body, wrapping each entity with
`(octocat-sync-entity TYPE KEY FIELDS)`.  On write, sync splits those
out into `entity` rows, puts `{"__ref": key}` in their place, and
rewrites the resource's `link` rows.

**Rule: a resource's `:data` shape is its contract.**  Reading replaces
each ref with the entity's fields, so views get plain hash tables, as
`json-parse-string` returns and every view reads today.  An entity may
carry more fields than this resource fetched, written by other
resources; views ignore them.  Reshaping data is the parse function's
job, never the view's.

- A **spec** such as `(issue "o/r" 12)` names one instance, and its
  printed form is the key.  `_` is a wildcard, so `(issues "o/r" _)`
  matches every issue list of the repo.
- `octocat-sync-request (spec &key force prefetch)` returns a snapshot
  at once and queues a fetch if needed.  Reading never waits on the
  network.  The snapshot is
  `(:data :partial :loading :outdated :error :kind :offline :mutating)`.
- `:entity` names the resource's main entity.  When the resource has
  never been fetched but the entity exists (a list fetched it), the
  snapshot's `:partial` holds its fields, for partial paint.
- `octocat-sync-subscribe (spec fn)` returns an unsubscribe function,
  and the vui hook is built on it.
- Every resource, detail or list, is refetched each time a page opens
  it: the newest data matters most.  The exception is a fetch within
  `octocat-sync-fresh-for` (30 s), so an open right after a prefetch
  sends nothing.
- `:max-age` is a longer exception, for data that rarely changes and is
  costly to fetch, such as a file tree at a commit, which never
  changes.  Within it, opening doesn't refetch.  Invalidation and `g`
  refetch regardless.
- Nothing is fetched before `retry_at`, except on `g`.
- A fetch that returns the stored body hash and changes no entity field
  only updates `fetched_at`, and notifies nothing, unless it clears an
  outdated mark or an error, which the page must stop showing.
- If a fetch changes the resource's `:entity`, the resource's
  `:invalidates` are invalidated: the change may move it in or out of
  filtered lists.  A first fetch (no stored body) invalidates nothing:
  there is nothing to compare.
- **Invalidation** keeps the data and shows it with `:outdated t`.
  Resources on screen are refetched now; the rest when next viewed.
- **Lists:** a fetch replaces the first page, and `octocat-sync-more`
  appends the next one.

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
(octocat-sync-define-mutation rename-issue (repo number title)
  :label       "Renaming issue"
  :optimistic  (lambda () `((,(octocat-sync-key 'issue repo number)
                             ("title" . ,title))))
  :send        (lambda (done) …)          ; DONE gets the parsed payload, or nil
  :invalidates (lambda () (list `(issue-timeline ,repo ,number))))
```

`octocat-sync-submit` sends a mutation; it works online only.
- **Optimistic change.**  `:optimistic` gives entity keys and the field
  values the mutation will set.  They go into an in-memory overlay that
  reads apply over the stored fields, so every page showing the entity
  re-renders at once.  The overlay is never written to SQLite, so a
  crash can't leave a change GitHub never accepted.
- While it runs, the resources it names exactly (not wildcards), and
  those whose `:entity` it changes optimistically, carry
  `:mutating "Renaming issue"`.  Pages draw the in-progress line from
  it, replacing today's buffer-local action variables.
- **On success**, the payload's entities are written, as a fetch's
  would be.  If there is none (`gh issue edit` prints no JSON), the
  overlay's fields are written instead: GitHub accepted them.  The
  overlay is dropped, and `:invalidates` are invalidated, which
  replaces the hand-written refreshes.  A change that only affects list
  membership, like closing an issue, still needs its lists invalidated.
- **On failure**, the overlay is dropped, so pages show the old values
  again.  The error goes to the echo area, and a draft stays open in its
  `octocat-edit` buffer.
- Mutations with no sensible prediction (adding a comment, merging)
  leave `:optimistic` out; they show only `:mutating`.
- Two pending mutations on one field apply in submit order; a failed
  one drops only its own overlay entry.

### Prefetch at point

List rows put the specs their RET target opens first in a text
property, `octocat-sync-prefetch`: an issue row gives
`((issue "o/r" 12) (issue-timeline "o/r" 12))`, a run row its run and
jobs.  Diffs and logs are large and never prefetched.

- A buffer-local `post-command-hook` restarts a one-shot timer.  When
  point has rested for `octocat-sync-prefetch-delay` (0.3 s), the specs
  at point are requested with `:prefetch t`.  Holding `j` therefore
  prefetches nothing.
- Prefetches have low priority: they run only when no page request is
  queued, at most 1 at a time.  A new prefetch replaces queued ones that
  haven't started; a running one finishes.
- A prefetch is skipped if the resource was fetched within
  `octocat-sync-fresh-for`, before its `retry_at`, offline, or when the
  last response's rate-limit remaining was under 20%.
- A prefetch subscribes nothing: it only writes the store.  Its entity
  writes still update the list row, as in the example.
- Opening a spec whose prefetch is queued or running joins it and
  raises it to page priority.
- `octocat-sync-prefetch` (default `t`) turns it off.

### Queue and status

At most 4 requests run at once (`octocat-sync-max-requests`).  Running
one at a time would add up a page's fetch times, and no limit risks
GitHub's secondary rate limits.  Page requests run before prefetches.
Reads of one key are de-duplicated, mutations never are.  A rate-limit
error pauses the queue until its reset time.

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
- Sync notifies once per write, with every touched key.  It groups the
  matching subscriptions by buffer, bumps their versions, and calls
  `vui-rerender` once per buffer, synchronously.  So a write touching
  the issue, its timeline and the list renders each page once, with no
  timer.
- Nothing polls: fetches happen only on open, on `g`, on invalidation,
  or by prefetch at point.
- It records each snapshot per buffer, so the mode line and header line
  cover every resource on the page.

**The wrapper** leaves the page with no status code:

```elisp
(octocat-vui-resource-view `(issue ,repo ,number)
  :skeleton (lambda (partial) (octocat-vui-detail-skeleton repo number partial width))
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
- **No data, loading:** the skeleton, given `:partial`.  With a partial
  entity it draws the real header (title, state, author) and grey bars
  for the rest; without one, bars shaped like the header and tabs
  (`octocat-vui-detail-skeleton`).  Either way nothing jumps on
  arrival.
- **No data, offline or failed:** the message and a retry hint, below
  the partial header if there is one.
- **No data, permanent failure:** "Not found" or "No access".

The notice goes in the header line, not the buffer, so the content
doesn't shift when it clears.  The delay is a one-shot timer per
buffer, started when an outdated resource starts refetching and
cancelled when it lands.

## 3. Migration

**Pilot: the user page.**  The layer is added, and only `octocat-user.el`
moves to it, while other pages stay on the old helpers.  There is no
toggle: a page is on one path or the other.  The user page fits because
it has no cache today, so the gain shows.  It also mixes REST and
GraphQL, has a paged list, and writes two entity types (`user`, `repo`).
It has no mutations and no list to prefetch from; those come with the
issue pages, which also prove sharing between pages.

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
1. `octocat-sync.el` (store, entities, resources, queue), the hook and
   the wrapper, with tests.  Add the file to the AGENTS.md load order
   and to Eask, and document it in `docs/using-vui.md` and
   `docs/user-interface-conventions.md` (header line, skeletons,
   in-progress lines).
2. The user page pilot.
3. Issue page and issue list, with their mutations (optimistic where
   they can predict), prefetch at point, and partial paint.  Done when
   a rename shows in an open list without a refetch, and opening a
   row after a pause sends no request.
4. PR page, PR list and timeline.
5. Repo, dashboard, search, actions, runs, jobs and tree.
6. Delete the old cache helpers, the `octocat--*-cache-*` functions,
   `cache-v3/repos`, and the action variables.

## Tests

- Store:
  - a write round-trips, and an unchanged hash notifies nothing;
  - an old schema is recreated, and a new one signals;
  - a write blocked by a second connection is dropped quietly;
  - collection deletes old resources, then unlinked entities only.
- Entities:
  - a write splits entities out, links them transitively, and reads
    back the same tree;
  - a merge keeps fields the fetch lacked, and stores a null;
  - an entity write notifies every linked resource, and an unchanged
    one notifies none;
  - a REST and a `gh --json` fetch of one record share its entity and
    field names.
- Sync (stub fetchers):
  - a success clears the error;
  - a 5xx waits 60 s unless forced, and a 404 waits a day;
  - a failure with no status sets offline;
  - one fetch runs per key, and no more than the cap run at once;
  - a change to a resource's entity invalidates its wildcard lists, and
    an unchanged one doesn't;
  - an unfetched resource whose entity exists returns `:partial`;
  - a fetch within `octocat-sync-fresh-for` isn't repeated.
- Mutations:
  - an optimistic change re-renders linked resources before `:send`
    returns, and isn't in SQLite;
  - success writes the payload (or the overlay's fields), then
    invalidates; failure restores the old values;
  - two pending changes to one field apply in order, and one failing
    leaves the other.
- Prefetch:
  - it runs only after the delay, and not while point keeps moving;
  - page requests run first, and only 1 prefetch runs at once;
  - a new prefetch replaces queued ones but not a running one;
  - it is skipped when fresh, offline, before `retry_at`, or near the
    rate limit;
  - opening a spec joins its prefetch.
- Hook and wrapper:
  - a change to its key, or to a linked entity, re-renders, and a
    change to another key doesn't;
  - killing the buffer unsubscribes;
  - each of the wrapper's cases renders as described;
  - an outdated refetch that lands within the delay shows no header
    line, and one that runs longer does.

## To verify

- `gh api -i` gives a parseable HTTP status for REST and GraphQL
  failures, and network failures can be told apart from them.
  (Implemented instead: the kind is read from `gh`'s error text, since
  most fetches use `gh issue view`, `gh run list` and the like, which
  report no status; see `octocat-sync--error-kind`.)
- Reading a 100-row list (about 250 entities with authors and labels)
  takes under 5 ms.  If not, keep parsed entities in memory, updated on
  each write in this process.
- Re-rendering the longest PR timeline doesn't lag.  If it does, add
  `:memo` to the timeline and the markdown bodies.
- The prefetch hook adds no lag to `j`/`k`, and a minute of normal
  browsing stays well within the rate limit.

## Deferred (behind the resource API, so pages won't change)

- **Incremental list refetch**, as forge does: fetch a repo's issues
  ordered by `UPDATED_AT` and stop at the first unchanged row.  Worth it
  if big lists refetch slowly.
- **Prefetching visible rows**, not just the one at point, if opens
  still wait.
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
