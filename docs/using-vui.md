# Using vui.el

Gotchas of vui.el as octocat uses it, and how the code works around them.

## Layout

- `vui-collapsible` indents only the **first** body line (default `:indent
  2`).  Rows here carry their own two-space prefix, so every collapsible
  passes `:indent 0`; otherwise the first row is indented by four spaces.
- Rows use `vui-text` inside a `vui-region` (not `vui-button`) so per-segment
  faces are preserved; see "Row rendering" in `octocat-repo.el`.

## Timers

Every repeating timer goes through `octocat-vui-use-timer`, never a bare
`run-with-timer`.  It ties the timer to the component: it is cancelled
when the component unmounts or the hook's dependencies change, when the
callback returns nil (done), and when the callback signals, so a broken
frame is reported once instead of on every tick.  A callback that sets
state to the value it already has does not re-render, so a timer that
only stopped on a re-render would run forever: return nil instead.

## Update a page in place; don't remount it

To change what a page shows (the list's query, the repo page's branch),
re-render it with new props, `octocat-vui-update-page` or
`octocat-vui-refresh-page`, not `vui-mount`.  A part that must start
afresh takes the new prop as its `:key` (the list's results, keyed by
the query).

- **Cost.**  A remount rebuilds every component: memos recompute, every
  `vui-use-async` refetches, folds and "load more" are lost.
- **vui.el bug.**  vui runs handlers (`:on-click`, `:on-submit`, ...)
  inside `(let ((vui--root-instance captured-root)) ...)`, so a
  `vui-mount` in a handler is undone as it returns.  The new page is
  never unmounted and its effects keep running: its window-width hook
  repainted a PR list's old filter over the current one on `C-x 3`.  See
  the vui.el item in TODO.md.
- **Focus.**  `vui-mount` ends with `switch-to-buffer`, so a remount
  from an async callback, such as a merge finishing, pulls the user back
  to the page (see "Never steal focus" in
  docs/user-interface-conventions.md).

A page mounts once, when it is opened, through
`octocat-vui-refresh-page`.  Its refresh (`g`, or after an action) calls
that again, which re-renders in place with a new `:tick`.  Each
resource the page reads takes the tick (`octocat-vui-use-resource`), so
it refetches and keeps showing the old data until the new data arrives.
Returning to an open page, as from its tab, is not a refresh: see
`octocat-vui-revisit-page`.  A handler that must remount
defers it, e.g. `(run-at-time 0 nil ...)`.

## Reading the sync store

Pages don't fetch their data: they read it from the sync layer
(`octocat-sync.el`).  Only avatars and completion candidates are fetched
directly.  A page names a resource, such as `(user-profile "octocat")`,
and reads it with `octocat-vui-use-resource`.  It returns a snapshot:
`:data` from the SQLite store, `:loading` while a fetch runs, and
`:error` from the last failed one.  So a page paints at once, and a
fetch runs behind it.

Opening a page fetches each resource unless it was fetched within
`octocat-sync-fresh-for`; a new `:tick` (`g`) always fetches.  After
each write, sync reports the resources that changed, including those
showing an entity (a user, an issue) whose fields changed, and each
page reading one re-renders once from its root.  So a component that
reads a resource must not be `:memo`, or it would keep the old snapshot.

Issues, PRs and workflow runs are entities, and so are authors,
assignees and labels.  A list row and the issue's page store the same entity, so the
list shows what the page last fetched.  The page's resource keeps what
the list doesn't share, such as comments, beside the entity
(`octocat-sync-detail`), and `octocat-vui-use-detail` reads both back
as one table, as `gh issue view` gives it.  Before the page's first
fetch lands, `:partial` holds the list's copy, so the page paints its
real header with grey bars below.

Every action that changes an issue or PR, from a comment to a merge, is
a mutation (`octocat-sync-define-mutation`).  An optimistic one, such as
a rename, applies in memory at once, so every page showing the item
shows it before GitHub answers.  While it runs, the snapshot's
`:mutating` holds its label under its slot, such as `merge`, and the
page draws it there: in the merge box, or in place of the buttons.  On success the change is stored and the resources it made
outdated (its timeline, the lists it may leave) are refetched if on
screen; on failure it is dropped.

List rows name what they open in an `octocat-sync-prefetch` text
property.  When point rests on a row for `octocat-sync-prefetch-delay`,
those resources are fetched at low priority, so opening the row usually
needs no request.

The store is a cache.  Once a session, when Emacs is idle, it drops the
resources not fetched for `octocat-sync-keep-for` (30 days), then the
entities none of the rest link to; `M-x octocat-sync-collect` does it at
once.  A change to how a resource's body is shaped bumps
`octocat-sync--schema`, which recreates the store rather than read the
old shape.

To add a resource, define it beside its page with
`octocat-sync-define-resource`.  Its `:fetch` calls `DONE` with the
parsed tree, each shared record wrapped in `octocat-sync-entity` with
GraphQL's field names, or with `(error . MESSAGE)`.  The design, and
what is still to come, is in `plans/github-sync-mechanism.md`.
