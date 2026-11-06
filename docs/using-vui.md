# Using vui.el

Gotchas of vui.el as octocat uses it, and how the code works around them.

## Layout

- Folds use `octocat-vui-fold`, not `vui-collapsible`: it animates, builds
  its body only once unfolded, and follows "Expand all".
- Rows use `vui-text` inside a `vui-region`, not `vui-button`: a row may
  hold link buttons, which a button's label cannot.

## Moving point from an effect

`vui-mount` moves point to the top after the first render's effects
have run, so an effect that places point, such as scrolling to the lines
a link named, does it from a zero-delay timer (`octocat--goto-line-target`).
`vui-render` does the same, so a test of it mounts the component.

## Editable fields

A page with a `vui-field` sets `buffer-read-only` to nil in its mode,
undoing `octocat-page-mode`'s `t`: the field can't be typed in
otherwise.  `widget-setup` already refuses edits outside
fields.  Under Evil, normal-state RET on a field runs `evil-ret`, which
inserts a newline into it, and the field's keymap hides the mode's
Evil bindings, so bind RET buffer-locally to `octocat-evil-field-ret`
(see `octocat-evil--field-setup`), which enters insert state at the end
of the field's text instead, past the padding that fills the field to
its `:size` (`octocat-vui-field-value-end`).

A field in a form, such as the Run workflow inputs, gets an
`:on-submit` that calls `octocat-vui-field-next`, never the form's own
action: RET then moves to the next control, and only RET on the form's
button sends it.  `octocat-vui-field-next` runs
`octocat-vui-field-next-hook` first, through which Evil leaves insert
state.

## Timers

Every repeating timer is a `vui-use-interval`, never a bare
`run-with-timer`, so it stops when its component unmounts.  Its BODY
returns `:stop` when done: a BODY that sets state to the value it
already has does not re-render, so a timer that waited for SECONDS to
turn nil would run forever.

## Update a page in place; don't remount it

To change what a page shows (the list's query, the repo page's branch),
re-render it with new props, `octocat-vui-update-page` or
`octocat-vui-refresh-page`, not `vui-mount`.  A part that must start
afresh takes the new prop as its `:key` (the list's results, keyed by
the query).

- **Cost.**  A remount rebuilds every component: memos recompute, every
  `vui-use-async` refetches, folds and "load more" are lost.
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
`octocat-vui-revisit-page`.

The user's refresh, `octocat-vui-refresh` (`g`, `gr`), also resets the
page's view: the user asked to see the page afresh, so what they
unfolded or expanded goes back as first drawn.  A refresh after an
action does not, since the user is still looking at what they opened.
A component with view state, such as a fold's open flag, takes part by
calling `octocat-vui-use-view-reset` during render, as the first
binding of its `let*`, with a `vui-async-callback` that sets that
state back to its initial value.  The hook runs the callback once for
each `octocat-vui-refresh`, after the re-render.  State that is not a
view toggle, such as a filter, the branch shown, or what "load more"
added, stays.  Text outside vui's state, such as images shown in place
and `<details>` in markdown, is reset by `octocat-vui-refresh` itself.

## Reading the sync store

Pages don't fetch their data: they read it from the sync layer
(`octocat-sync.el`), which fetches the resources `octocat-model.el`
defines.  Only avatars and completion candidates are fetched
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
(`octocat-model-detail`), and `octocat-vui-use-detail` reads both back
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
screen; on failure it is dropped and what it acts on refetched.  A
change to a page's own data, such as its comments, is an `:edits`
function of the resource's body instead.

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

To add a resource or mutation, define it in `octocat-model.el`, in the
section of its page, with `octocat-sync-define-resource` or
`octocat-sync-define-mutation`, along with the queries and parsers it
fetches through.  Most name their `gh` call, `:gh` with its arguments
or `:graphql` with its query, and a `:parse` that makes the parsed tree
of its JSON; one that needs more has a `:fetch`, which calls `DONE`
with the tree or with `(error . MESSAGE)`.  Either way each shared
record in the tree is wrapped in `octocat-sync-entity` with GraphQL's
field names (the builders in "Entities" there do it).  The design, and
what is still to come, is in `plans/github-sync-mechanism.md`.
