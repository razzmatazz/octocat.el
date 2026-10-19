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
that again, which re-renders in place with a new `:tick`.  Each fetch
takes the tick into its key (`octocat-vui-use-cached`,
`octocat-vui-use-async-sticky`), so it refetches and keeps showing the
old data until the new data arrives.  A handler that must remount
defers it, e.g. `(run-at-time 0 nil ...)`.

## Reading the sync store

A page on the sync layer (`octocat-sync.el`; so far the user page) does
not fetch.  It names what it shows as a resource spec, such as
`(user-profile "octocat")`, and reads it with `octocat-vui-use-resource`,
which returns a snapshot: `:data` from the SQLite store, `:loading` while
a fetch runs, and `:error` from the last failed one.  The page paints at
once from whatever the store holds, and a fetch runs behind it.

The hook takes the page's `:tick`.  Opening a page fetches each resource
unless it was fetched within `octocat-sync-fresh-for`; a new tick (`g`)
always fetches.  Fetches write the store and never hand data to the
page.  After each write, sync reports which resources changed, including
every resource that shows an entity (a user, a repo) whose fields
changed.  Each page reading one of them re-renders once, from its root.
So a component that reads a resource must not be `:memo`: a memoized
component with unchanged props would skip the re-render and keep the
old snapshot.

To add a resource, define it beside its page with
`octocat-sync-define-resource`.  Its `:fetch` calls `DONE` with the
parsed tree, wrapping each shared record in `octocat-sync-entity` with
GraphQL's field names, or with `(error . MESSAGE)`.  See
`plans/github-sync-mechanism.md` for the full design and what is still
to come.
