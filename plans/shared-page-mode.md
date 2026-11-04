# A shared parent mode for the pages

## Why

Every page's major mode repeats the same setup calls in its body:
`octocat--ts-eldoc-setup` and `octocat-markdown-copy-setup` in all of
them, `octocat--max-width-setup` in most.  A new page can forget one,
and nothing says which calls a page must make.

Magit solves the same problem with a parent mode: every Magit mode
derives from `magit-section-mode`, whose body runs once for all of them.
Octocat does the same with a new `octocat-page-mode`, derived from
`vui-mode`, that the page modes derive from.

A minor mode is the wrong tool here.  It suits a feature a user turns on
and off, or one that also runs in buffers of other modes.  These setups
are always on, and only on octocat pages.

## The mode

`octocat-page-mode`, in `octocat-vui.el`, derived from `vui-mode`:

```elisp
(define-derived-mode octocat-page-mode vui-mode "Octocat-Page"
  "Base major mode of every octocat page."
  :group 'octocat
  (octocat--ts-eldoc-setup)
  (octocat-markdown-copy-setup))
```

Only setup that is the same on every page goes in it.  These stay in
each mode, as they differ between pages:

- `octocat--max-width-setup`: the dashboard, user and Actions pages are
  not capped.
- `buffer-read-only`: the list pages are editable, for their query field.
- `truncate-lines`, `revert-buffer-function`, `octocat--refresh-fn`,
  `octocat--url-function`, `octocat--repo-function`.

## Modes to reparent

From `vui-mode` onto `octocat-page-mode`, dropping the two calls from
their bodies:

- `octocat-mode` (dashboard), `octocat-user-mode`
- `octocat-pr-mode`, `octocat-pr-commits-mode`, `octocat-pr-diff-mode`
- `octocat-issue-mode`
- `octocat-commit-mode`, `octocat-compare-mode`
- `octocat-repo-mode` (its children `octocat-tree-mode` and
  `octocat-commit-list-mode` follow), `octocat-file-mode`
- `octocat-job-mode`, `octocat-run-mode`, `octocat-workflow-mode`,
  `octocat-checks-mode`
- `octocat-vui-list-mode` (the PR, issue, run and workflow lists follow)

`octocat-doctor-mode` derives from `special-mode` and is not a vui page;
it stays as it is.  `octocat-edit-mode` is a text buffer, not a page.

## Also

- Keymaps: a child's map inherits from its parent's.  `vui-mode-map`
  stays the grandparent, so no binding changes.  Bindings that every
  page repeats could move onto `octocat-page-mode-map` later.
- `octocat-page-mode-hook` lets a user customise every page at once;
  mention it in the README.
- AGENTS.md's "Call 1" finds octocat buffers by the `octocat-` prefix of
  the mode's name; `(derived-mode-p 'octocat-page-mode)` says it
  directly.  Other `string-prefix-p "octocat-"` tests on `major-mode`,
  if any, can change the same way.
- `docs/architecture.md`: note the parent mode under the vui layer.
- Tests: a test that every page mode derives from `octocat-page-mode`,
  so a new page cannot miss the setup.

## Later

If copying as drawn is ever wanted (a timeline with its rail), the copy
filter can become a minor mode, `octocat-copy-mode`, that the parent
turns on and a user can turn off.
