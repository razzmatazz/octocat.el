# Contributing to octocat.el

## AI-assisted code

Using AI to assist in writing code or opening pull requests is fine, but the
human author should be the first and most thorough reviewer of any such
output.  Please help track AI assistance by adding a
[Linux-style `Assisted-by:` line](https://docs.kernel.org/process/coding-assistants.html#attribution)
immediately after the `Author:` header (or `Copyright` line in sub-files that
omit `Author:`):

```elisp
;; Author: Your Name <you@example.com>
;; Assisted-by: Claude:claude-sonnet-4-6
```

`AGENT_NAME` is the product name (e.g. `Claude`) and `MODEL_VERSION` is the
specific model (e.g. `claude-sonnet-4-6`).  This convention follows
[MELPA's attribution spec](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Code conventions

### Entry points (`;;;###autoload` commands)

**All `;;;###autoload` / `M-x`-invokable commands must be defined in
`octocat.el`**, even when the mode/logic they open lives elsewhere — e.g.
`octocat-repo` is a thin wrapper in `octocat.el` that calls into
`octocat-repo-mode` and friends, defined in `octocat-repo.el`.

`octocat.el` is the only file every other file omits requiring (to avoid
circularity), so it's the only file that can assume everything else is
loaded — including its own bottom-of-file `octocat--evil-init` trigger,
which wires up Evil keybindings. A second autoloaded command elsewhere
could be invoked first, in a session where that trigger never ran, leaving
Evil bindings unset. See AGENTS.md's "Byte-compiler warnings" section for
the related loaded-by-`octocat.el` invariant.

When adding a new entry point: define the `;;;###autoload` command in
`octocat.el` alongside `octocat`/`octocat-repo`; put the mode, keymap, and
supporting logic in its own `octocat-<feature>.el` file; and make sure
`octocat.el` `require`s that file.

### Indicating loading / async activity

Use the buffer-local `mode-line-process` variable to indicate that a
background operation is in flight: `(octocat-vui-mode-line-busy ":loading")`,
Emacs's `(Mode:run)` style plus a spinner (vui pages:
`octocat-vui-use-mode-line-loading`).  Clear it to `nil`
when the calls complete.  Do not erase or replace existing buffer content just to show a
loading state — keep stale content visible and let `mode-line-process` signal
that fresh data is on its way.

### Refresh and the sync store

Every view paints from the local SQLite store and refetches behind it
(`octocat-sync.el`): a page names the resources it shows and reads them
with `octocat-vui-use-resource`, so it never fetches, caches or tracks
loading itself.  Opening a page fetches each resource unless it was
fetched just now; `g` always does.  A failed fetch keeps the stored
data.  See "Reading the sync store" in
[docs/using-vui.md](docs/using-vui.md).

Completion candidates and search results are resources too, read with
`octocat-sync-get`; the only other file octocat writes is
`octocat-settings-file`.  Do **not** hardcode
`~/.config/emacs/.local/cache` — that is Doom-specific.  Use
`locate-user-emacs-file` for defaults.

### UI framework: vui.el

Every buffer is rendered with vui.el: the dashboard (`octocat-mode`), the
repo overview (`octocat-repo.el`, `octocat-repo-mode`), the user page
(`octocat-user-mode`), the PR, issue, PR diff, commit, checks, workflow,
run and job detail views (`octocat-pr-mode`, `octocat-issue-mode`,
`octocat-pr-diff-mode`, `octocat-commit-mode`, `octocat-compare-mode`,
`octocat-checks-mode`, `octocat-workflow-mode`, `octocat-run-mode`,
`octocat-job-mode`; PR diff, commit and compare share `octocat-diff.el`), the tree browser and the commits page
(`octocat-tree-mode`, `octocat-commits-mode`, in `octocat-repo.el`), the file viewer and file log (`octocat-tree.el`,
`octocat-file-mode`, `octocat-file-log-mode`) and the PR and issue list
pages and the Actions page (`octocat-pr-list-mode`,
`octocat-issue-list-mode`, defined next to the matching detail views, and
`octocat-actions-mode` in `octocat-actions.el`; all derive from
`octocat-vui-list-mode`).  The issue and PR views are GitHub-style
timelines of the opening post, comments and events; what point is on is
carried by a text property (e.g. `octocat-issue-target`).  The repo
overview is a dashboard of independent sections, each reading its own
sync resource, with its own pagination counter (`:state`) and collapse
state (`vui-collapsible`).

Generic, repo-agnostic vui helpers (the RET-able `octocat-vui-row`,
`octocat-vui-load-more-button`, folds) live in
`octocat-vui.el`; buffer-specific vui code stays in that buffer's file.
Put new reusable vui hooks/components there, and keep them free of GitHub
knowledge.

vui.el gotchas, and the workarounds for them, are in
[docs/using-vui.md](docs/using-vui.md).  Read it before adding a vui button
or field whose handler changes what the page shows.

### Functional core

Write functions to be as functional as possible: take everything they
need as arguments and return a value, rather than reading ambient state
(windows, the current buffer, buffer-local or global variables) or
changing it.  Keep the core body of the code functional, and push side
effects out to a thin layer of commands, effects and async callbacks.
Prefer a required argument to an optional one that falls back to ambient
state.

In particular, render code (vui components, memo bodies, section
inserters) and library modules (markdown, mermaid, avatar, timeline) must
not select windows or frames, move point other than by inserting, or
change global state, and must not prompt or `sit-for`.  Side effects
belong in commands and `vui-use-effect`.

vui re-renders from timers, often while the buffer sits in an unselected
window.  Selecting that window resets the buffer's point mid-render and
scrambles the page.  That happened via `window-max-chars-per-line`, which
selects the window internally.  So read window state once in the page
component and pass it down, e.g. `(octocat--markdown-width)` into
`octocat-timeline-entries`.  Wrap any window query that might select a
window in `save-excursion`.

### Dependencies

Runtime dependencies are exactly those in the `Package-Requires` header of
`octocat.el`, and the `Eask` file must list the same set.  Only call functions
from declared dependencies.

`vui` comes from MELPA; `Package-Requires` declares `(vui "0.1")`.  Treat
it as a young, fast-moving library: re-test when bumping it, and keep
generic vui helpers in `octocat-vui.el`.

### Indicating interactivity in the UI

See [docs/user-interface-conventions.md](docs/user-interface-conventions.md)
for how to signal that a section heading or inline value is RET-able:
`mouse-face`, `help-echo` wording, when to use `buttonize`, and the decision
table for each situation.

### Evil keybindings

Evil bindings for all octocat modes live in `octocat-evil.el` and are
installed by `octocat-evil-setup`.

Each mode's map gets its bindings with `evil-define-key*`.  Rows bind RET
themselves (a `keymap` text property, see `octocat-vui-row`), so only the
mode-wide commands go there.

## Versioning and releases

octocat follows [semantic versioning](https://semver.org/).  While it is
below 1.0, a release that adds a feature or changes behaviour (a key
binding, a command's name, a customisation) bumps the minor version, e.g.
0.1.0 to 0.2.0, and a release with only fixes bumps the patch version, e.g.
0.1.0 to 0.1.1.

The version lives in two places, which must always agree: the `;; Version:`
header of `octocat.el` and the version in `Eask`.  The other files carry no
version of their own.

### Changelog

Every significant change adds a line under `## [Unreleased]` in
`CHANGELOG.md` as it lands, not at release time: anything a user would
notice, such as a feature, a key binding or a fixed bug, and any change to
the Emacs versions octocat supports or is tested on.  Word entries for
users, not for developers.

### Cutting a release

1. Make sure CI is green on `main`.
2. Bump the version in `octocat.el` and `Eask`.
3. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   and add a fresh, empty `## [Unreleased]` above it.
4. Commit this as `Release X.Y.Z`.
5. Tag that commit and push both:

   ```bash
   git tag -a vX.Y.Z -m "octocat X.Y.Z"
   git push origin main vX.Y.Z
   ```

Never move or delete a pushed tag; if a release is broken, release a fixed
one with the next patch version instead.

### MELPA and MELPA Stable

[MELPA](https://melpa.org/) builds a snapshot from every commit on `main`,
versioned by date, e.g. `20261023.559`.  [MELPA
Stable](https://stable.melpa.org/) builds only from tags, versioned by the
tag: `v0.1.0` becomes `0.1.0`, as MELPA drops the `v` and parses the rest
with `version-to-list`.  So a tag is what publishes a release.

MELPA installs only the top-level `*.el` files, so `README.md`,
`CHANGELOG.md`, `docs/` and `test/` stay in the repository, as MELPA asks.

To check what MELPA will build before tagging, build the recipe in a clone
of [melpa/melpa](https://github.com/melpa/melpa) and install the result
into a clean Emacs:

```bash
make recipes/octocat                  # snapshot, into packages/
make recipes/octocat CHANNEL=stable   # latest tag, into packages-stable/
emacs -Q --eval '(progn
  (add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")))
  (package-refresh-contents)
  (package-install-file "packages/octocat-VERSION.tar"))'
```

Watch `*Compile-Log*` for warnings: the install byte-compiles the package
with the Emacs you run, so it can catch what CI's compile does not.

Building may end with a "Could not determine string width" error from
the badge image step when ImageMagick is missing; the package itself is
already built by then.
