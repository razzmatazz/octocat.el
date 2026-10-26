# User Interface Conventions

This document captures the visual and interaction conventions used across
octocat.el buffers, and the research behind them.

---

## Indicating that a line or section is interactive (RET-able)

A RET-able row is built with `octocat-vui-row`: a `vui-text` line in a
`vui-region` whose keymap binds RET, with `mouse-face 'highlight` and a
`help-echo` on the whole line.  The row keeps the faces of its segments
(a `vui-button` would apply one face to the whole label).  A segment that
has its own `help-echo`, such as a relative date, keeps it.

```elisp
(octocat-vui-row (concat icon "  " (propertize name 'face 'octocat-run-job-name))
                 (lambda () (octocat-job-open repo run-id job-id name))
                 "RET: open job")
```

A separate action inside a line, such as a tab or "Load N more…", is a
`vui-button`, drawn without brackets where the line already reads as a
control (see "Brackets mean \"button\"" below).

### Folds

A fold's toggle must be reachable with TAB, and its title must keep its
own faces.  A `vui-button` gives the first but draws its label in one face;
a row gives the second but is not a TAB stop.  So a fold header is both:
the ▸/▾ marker is a `vui-button`, the TAB stop, and the title after it is
an `octocat-vui-row`.  RET on either toggles.  `octocat-vui-fold-header`
builds it, for `octocat-vui-fold`:

```
  ▸ [✓] Set up job      success  1s     ← TAB stops on ▸; RET anywhere toggles
  ▾ [✗] Compile         failure  11s
      ▸ Run make compile                ← a nested fold, same shape
10:32:34 make compile                   ← the body: copyable, not indented
```

Unfolding and folding are animated like the timeline's long entries, and
a body that is costly to lay out (a step's log) is built only once
unfolded.

### Expand all

Wherever a section hides content by default, its heading carries an
`[Expand all]` button, which turns into `[Collapse all]`.  It unfolds
everything in the section, nested folds included, so isearch and other
buffer searches can find text that would otherwise be hidden; RET on one
fold's header still toggles just that fold.

```
Steps (8)  [Expand all]
```

`octocat-vui-expand-all-button` draws it.  The section keeps its last
value in its state and passes it to each `octocat-vui-fold` as `:bulk`,
and a fold passes it on to the folds in its body.  The job page's Steps
and the Files of the commit and PR diff pages do this; other folded
content (long timeline entries, the PR checks list) should follow.

Content hidden by default may start shown when it is small: the Files
section starts unfolded when the whole diff fits in the window, by
starting with the value Expand all would give (a fold that mounts with
it open paints open, without animating).

### Decision table

| Situation | Approach |
|---|---|
| The whole line opens something | `octocat-vui-row` with a `help-echo` |
| One control among others on a line | `vui-button` |
| A name or number within a line opens its page (a header's `#N`, `@author`, Assignees, Closes) | `octocat-repo-vui--link`: an unbracketed `vui-button`, so TAB stops on it; inside a row, pass `octocat-vui-row` a list of strings and vnodes |
| A foldable block | `vui-collapsible` for a plain title; `octocat-vui-fold` with `octocat-vui-fold-header` when the title has its own faces or the body should be built only once unfolded (see "Folds") |

### Go along with vui.el

Build interactive parts from vui's components (`vui-button`, `vui-field`,
`vui-region :keymap`), not hand-made text properties or `button.el`
calls: only vui's elements are TAB stops, and its internals may change.
Rendered markdown's links are still `keymap` text properties, so not
TAB stops: the markdown renders to one string, not vnodes.

---

## Editing fields: edit buffer vs. minibuffer

Two distinct mechanisms are used depending on whether the field is
single-line or multi-line:

### Multi-line fields → `octocat--open-edit-buffer`

Used for PR/issue **bodies** and **comments** — content where the user
may need multiple lines, markdown preview, and the ability to abandon
their work mid-edit.  The edit buffer derives from `text-mode` and
presents a familiar Magit-style commit-message workflow:

```
C-c C-c   submit (calls gh, refreshes source buffer, kills edit buffer)
C-c C-k   discard (confirms if modified, kills edit buffer)
```

The header line shows the action and a keyboard hint.  The source buffer
is refreshed automatically on success.  Under Evil it opens in insert state.

A new issue is written in the same buffer, opened by `C-c C-n` from the
PR and issue lists and detail pages.  It has a title and a body, so it
takes the commit-message shape: the first line is the title, the rest
the body.  One buffer keeps both in reach, and the title cannot be
forgotten behind a second prompt.  Unlike a comment, whose page shows it
under way, a new issue has no page yet, so the buffer stays open while
GitHub creates the issue, keeps the text on failure, and on success
gives way to the new issue's page.

### Single-line fields → `read-string` in the minibuffer

Used for **titles** — content that is always a single line and where
opening a split window would be disproportionate.  The current value is
pre-filled as the initial input so the user can edit in place:

```elisp
(read-string "PR title: " current-title)
```

Validation (non-empty) and the `gh` call happen immediately after the
user confirms with `RET`.  The buffer refreshes asynchronously on
success; on failure a message is shown in the echo area.

### Decision table

| Field type | Mechanism | Rationale |
|---|---|---|
| Multi-line markdown (body, comment) | `octocat--open-edit-buffer` | Needs line editing, markdown mode, and an explicit discard path |
| Single-line string (title) | `read-string` minibuffer | Single line; a split window would be disproportionate |
| List search query | inline `vui-field` (`octocat-vui-list-query-field`) | Always on screen; editing it below in the minibuffer was confusing |

---

## Displaying commit authors

GitHub's REST commits endpoint exposes two distinct author objects for each
commit:

| Field path | Type | Contains |
|---|---|---|
| `commit["author"]` (top-level) | GitHub user object | `"login"` — the GitHub handle |
| `commit["commit"]["author"]` (nested) | Git identity object | `"name"`, `"email"`, `"date"` |

The top-level object is `null` when the git commit email is not linked to
any GitHub account (e.g. bots, external contributors, unverified emails).

Three helpers in `octocat-core.el` cover the different display contexts:

### `octocat--author-login (obj)`

For **any** GitHub entity whose `"author"` key is a user node — PRs,
issues, reviews, comments.  Returns `"@login"` or `""`.  Do **not** use
this for commit hash-tables from the REST endpoint; use one of the two
commit-specific helpers below instead.

### `octocat--commit-author (commit)`

For **compact list rows** (e.g. the dashboard Commits section) where
horizontal space is at a premium.  Returns `"@login"` when the commit is
linked to a GitHub account, otherwise falls back to the bare git author
`name`.  Always a single short token.

### `octocat--commit-author-full (commit)`

For the **Author line** in detail views.  Returns a git-log-style
`Name  <email>` string built from the nested git identity fields:

```
Linus Torvalds  <torvalds@linux-foundation.org>
```

The GitHub handle is intentionally excluded from this string.  Callers
that want the handle should call `octocat--commit-author-login` and render
it on a **separate GitHub line** immediately below the Author line:

```
  Author  Linus Torvalds  <torvalds@linux-foundation.org>
  GitHub  @torvalds
  Date    2026-06-11 14:23
```

The GitHub line should be omitted entirely when
`octocat--commit-author-login` returns nil (commit not linked to an
account).

### `octocat--commit-author-login (commit)`

Returns `"@login"` when the commit's git email is linked to a GitHub
account, or `nil` otherwise.  Used exclusively to populate the optional
GitHub info line in detail views — do not use for compact list rows
(`octocat--commit-author` already handles the handle-or-name fallback
there).

### Decision table

| Context | Helper(s) | Example output |
|---|---|---|
| PR/issue/review/comment author | `octocat--author-login` | `@torvalds` |
| Commit list row (dashboard) | `octocat--commit-author` | `@torvalds` or `Linus Torvalds` |
| Commit detail Author line | `octocat--commit-author-full` | `Linus Torvalds  <torvalds@linux-foundation.org>` |
| Commit detail GitHub line | `octocat--commit-author-login` | `@torvalds` (omit line if nil) |

### `help-echo` wording

Follow magit's own wording style: `"mouse-2, RET: <imperative phrase>"`.
If mouse interaction is not expected (terminal-only views), `"RET:
<imperative phrase>"` is fine.

Examples:

```
"RET: open diff view"
"mouse-2, RET: open in browser"
"RET: expand commit"
```

### A button with a key shows it

When a button does what a key on the page also does, its `help-echo`
names the key, and ElDoc shows it in the echo area once point has
rested on the button for `eldoc-idle-delay`.  The reader who TABs to the
button learns the key and can skip the button next time, without
having to read the README's key table.  Build the hint with
`octocat--key-help`, which looks the key up with `where-is-internal`, so
it stays right when the user rebinds the command:

```elisp
(vui-button "Show comments (3)"
            :help-echo (octocat--key-help #'octocat-diff-toggle-comments
                                          "show the comments in the diff")
            :on-click #'octocat-diff-toggle-comments)
;; point rests on it → echo area: "RET, C-c C-v: show the comments in the diff"
```

Builders that take a button's command, such as `octocat-timeline-buttons`
and `octocat-vui-tab-row`, pass its "RET: …" hint through
`octocat--button-help`, which does this whenever the command has a key;
so a button added there needs nothing more.  A button that runs a
lambda has no key to show.

Only such hints reach the echo area, marked by a text property on the
`help-echo` string.  The plain "RET: …" hint of every row and button
would show on every line point crosses, and add nothing to what the
line already shows.  The hook is added by `octocat--ts-eldoc-setup`,
which every octocat major mode already calls.

### Show what the text hides

Put what text stands for but doesn't show in its `help-echo`, for the
mouse, and in a property an ElDoc function in `octocat--ts-eldoc-setup`
reads, for point; RET should never be the only way to find it out:

| Text | Hidden detail | Property |
|---|---|---|
| `3 days ago` | Exact time | `octocat-ts` |
| A cut title | Whole title | `octocat-full-text` |
| A markdown link | Its URL, unless the text shows it | `octocat-markdown-url` |
| `#123`, a short SHA | Repository, full SHA | `octocat-markdown-ref` |

---

## Users are `@login`

A GitHub user is shown as `@login` everywhere: in rows, page headers and
fields, and in completion, such as the assignee and reviewer pickers.
The `@` tells a person from a label or branch with the same name, as
GitHub's own UI does.  A picker adds the `@` to its candidates and
strips it from the answer, so `gh` still gets the bare login, and typing
a login without the `@` works too.

The list filters are the exception: their completions are search
qualifier values (`author:alice`), where `@me` means you, so they keep
the bare login.

---

## Formatting branch names in tabular rows

Branch names appear in columnar list views (dashboard Workflow Runs, PR
list, workflow detail).  Two helpers in `octocat-core.el` centralise the
width computation and rendering so every list stays consistent.

### `octocat-branch-max-width`

A `defconst` (currently `16`) that caps the branch column width across all
views.  Change it in one place to resize every list at once.

### `octocat--branch-column-width (runs key)`

Computes the branch column width for a given list of hash-tables:

```elisp
(octocat--branch-column-width runs "headBranch")
(octocat--branch-column-width prs  "headRefName")
```

Returns `(min octocat-branch-max-width (max 1 longest-name-length))`, so
the column is as narrow as possible while fitting every branch name —
up to the cap.  Call this once outside the `dolist` and bind the result to
`branch-w`.

### `octocat--format-branch (branch width)`

Renders a single branch string for insertion:

```elisp
(octocat--format-branch branch branch-w)
```

Pads/truncates `branch` to exactly `width` characters (trailing `…` when
truncated) and applies `octocat-branch` face.  Use this instead of
inline `propertize` + `truncate-string-to-width` at every call site.

### Pattern

```elisp
(let ((branch-w (octocat--branch-column-width items "headBranch")))
  (dolist (item items)
    (let ((branch (or (gethash "headBranch" item) "")))
      ...
      (octocat--format-branch branch branch-w)
      ...)))
```

---

## Formatting timestamps

Show the relative age (`3 days ago`); put the exact time in `help-echo`
(`Mon 2026-06-08 14:23:05 EEST`) for the mouse and ElDoc (echo area,
after `eldoc-idle-delay`) for point.  Never print both.  Every octocat
major mode calls `(octocat--ts-eldoc-setup)` in its body.

Helpers in `octocat-core.el` take an ISO-8601 UTC string; nil, `:null`
or `""` give `""`.

| Context | Helper | Output |
|---|---|---|
| Any displayed timestamp | `octocat--format-ts-relative` | `3 days ago`, exact time on hover |
| Not shown in a buffer | `octocat--relative-ts` | `3 days ago`, no properties |

- `propertize` and `format` padding keep the `help-echo`.
- `octocat-vui-row` adds its row hint only where no `help-echo` is set,
  so the date keeps its own.  Do the same for hand-built rows.
- Relative ages go stale; `gr` refreshes.
- Plain Elisp only, no `ts.el` or magit (see `AGENTS.md`).

---

## Copyable content is not indented

Text a user may copy out verbatim (diff lines, code, job logs, a file such as
the repo page's README) starts at column 0, so it pastes as-is.  A file shows
as it would in its own buffer.  Decoration (headings, comment boxes) may indent.

## Commit messages are plain text, not markdown

Git has no markup: a commit message is plain text its author wrapped by
hand, and `*`, `#` or `_` in it mean nothing special.  GitHub itself shows
commit messages verbatim, so octocat does too: the commit page shows the
message as `git show` does, indented four columns, as written, never passed through
`octocat--markdown-string`.  `C-c C-v` therefore leaves it alone; it only
toggles the markdown in comments, which GitHub does render.

---

## Indicating the active (currently checked-out) branch

### Background: Magit's convention

Magit marks the currently checked-out branch in its branch lists with a
combination of bold weight and an underline, using the `magit-branch-current`
face (which inherits `magit-branch-local` and adds `:underline t`).  It also
prepends a `*` glyph in some views.  The core signal is: **bold + underline
on the branch name itself**, no extra column or prefix character required.

`magit-branch-current` lives in the `magit` package, which octocat.el does
not depend on.

### The `octocat-branch-current` face

`octocat-core.el` defines `octocat-branch-current` as the equivalent for
octocat views:

```elisp
(defface octocat-branch-current
  '((((class color) (background dark))
     :foreground "#8ec07c" :weight bold :underline t)
    (((class color) (background light))
     :foreground "#427b58" :weight bold :underline t)
    (t :inherit (bold octocat-branch) :underline t))
  "Face for the currently checked-out branch …")
```

It deliberately reuses the same green as `octocat-branch` so the active
branch reads as a *highlighted variant* of the normal branch colour, not
a categorically different thing.  The bold weight and underline match
Magit's own current-branch treatment.

### Where it is applied

| View | Location | What changes |
|---|---|---|
| Dashboard PR list | `headRefName` column | `octocat-branch-current` face instead of `octocat-branch` |
| Dashboard Workflow Runs list | `headBranch` column | same |
| PR detail Info section, Branch line | head branch name | `octocat-branch-current` face |

No prefix glyph (`*`, `▶`, etc.) is added.  The bold + underline on the
branch name is sufficient and keeps column alignment intact.

### Helper: `octocat--current-branch ()`

`octocat-core.el` exposes a synchronous helper that returns the name of the
currently checked-out local branch, or `nil` on detached HEAD or any error:

```elisp
(octocat--current-branch)   ; => "feat/my-feature"  or  nil
```

Implemented with a single `git symbolic-ref --short HEAD` call — fast
enough to call inline at render time.

### Pattern for list rows

```elisp
(let* ((branch  (or (gethash "headRefName" pr) ""))
       (activep (and current-branch (string= branch current-branch)))
       (b-face  (if activep 'octocat-branch-current 'octocat-branch)))
  (propertize (truncate-string-to-width branch width nil ?\s "…")
              'face b-face))
```

`current-branch` is passed in from the caller (captured once per render,
not re-read per row).  Comparing with `string=` is correct; branch names
are plain ASCII strings.

### Pattern for detail-view info lines

In an info section the branch name is rendered inline without padding, so
the same face swap applies directly:

```elisp
(insert (format "  Branch   %s → %s\n"
                (propertize head
                            'face (if (string= head current-branch)
                                      'octocat-branch-current
                                    'octocat-branch))
                (propertize base 'face 'octocat-branch)))
```

`current-branch` is obtained by calling `(octocat--current-branch)` once at
the top of the render function and binding it to a local variable.  Do not
re-call the helper per line.

---

## Opening items in the browser (`C-c C-o`)

Every mode binds `C-c C-o` to its own browse command, which opens the item
the buffer shows, and no other key opens the browser (bare `o` is free
for opening in Emacs, as Evil's `o`/`O` on every page): `octocat-pr-browse`, `octocat-issue-browse`,
`octocat-commit-browse`, `octocat-checks-browse`, `octocat-workflow-browse`,
`octocat-run-browse`, `octocat-job-browse`, `octocat-repo-browse`,
`octocat-vui-list-browse` and so on.  Each reads the buffer-local variables
set when the buffer was opened.

| Page | URL opened |
|---|---|
| PR | `gh pr view --web NUMBER --repo REPO` |
| Issue | `gh issue view --web NUMBER --repo REPO` |
| Commit | `https://github.com/REPO/commit/SHA` |
| Checks | `https://github.com/REPO/commit/SHA/checks` |
| Workflow | `https://github.com/REPO/actions/workflows/FILE` |
| Run | `https://github.com/REPO/actions/runs/ID` |
| Job | `https://github.com/REPO/actions/runs/RUN_ID/job/JOB_ID` |

### Using `gh` vs. `browse-url`

PRs and issues are opened via `gh pr view --web` / `gh issue view --web`
rather than a hard-coded URL.  This ensures the correct GitHub host is used
when `gh` is configured for GitHub Enterprise or an alternative host.  All
other items are opened with `octocat-browse-external` using a constructed
URL.

### Following links vs. opening in the browser

Octocat leans towards Emacs-native views: a link is opened in Emacs when
some package can show it there, and in the browser only when none can,
or when the user asks for the browser.

- **Following a link** (RET on a link in markdown, a check that is not
  an Actions run) calls `browse-url`.  It consults `browse-url-handlers`,
  so github.com links open in octocat (see below) and links to any other
  web app open in whatever Emacs package registered a handler for them.
- **"Open in browser" commands** (`C-c C-o` and friends) call
  `octocat-browse-external`, i.e. `browse-url-with-browser-kind
  'external`.  It skips handlers marked `internal`, octocat's included,
  so `C-c C-o` on a PR does not just reopen the PR page.

Octocat's handler is `octocat-browse-url`, registered in
`browse-url-handlers` with `octocat--github-url-target` as its
predicate, while `octocat-open-github-urls` is non-nil (the default).
The predicate maps a URL to a view and returns nil for pages octocat has
no view for (blobs, wikis, releases, …), which then fall through to the
browser.  A link names its own repository, so one to another owner's
commit or run opens in that repository; `#123` and bare commit hashes
are not links and still open in the buffer's repository.  When adding a
view that has a github.com page, add its URL to
`octocat--github-url-target` and `octocat-browse-url`.

---

## Alternative view (`C-c C-v`)

`C-c C-v` switches a page to its other way of showing the same content,
and back: rendered vs. raw markdown on pages with markdown, two-line vs.
one-line rows on the PR and issue lists.  The PR's files changed page
shows or hides its review comments instead: there the diff is what is
read, and the comments' markdown matters less than reading it without
them.  Users learn one key for "show
this differently", so a page that gains a second view binds it to
`C-c C-v` (in the mode map and, for Evil, in octocat-evil.el) rather than
to a key of its own, and documents it in the README's keybinding table.
A page has at most one alternative view, so the key stays a plain
toggle.

Re-render the page in place with the new prop (`octocat-vui-update-page`),
not a remount; see [using vui.el](using-vui.md).  Remember the choice with
`octocat--setting-put` when it describes how the reader likes a page,
not just what they are looking at now, as the list pages' compact view
does.

## Windows: opening pages and `q`

Octocat follows Magit (`magit-display-buffer-traditional`,
`magit-mode-quit-window`), so its windows behave as the rest of Emacs
expects:

- **Open every page with `octocat-display-buffer`**, never `pop-to-buffer`
  or `switch-to-buffer`.  From an octocat page it shows the new page in the
  selected window, so RET drills down in place; from any other buffer it
  leaves the choice to `display-buffer`.  Both go through `display-buffer`,
  so users can override them in `display-buffer-alist`.
- **Bind `q` to `octocat-quit-window`.**  Like `quit-window`, it shows the
  window's previous buffer, so `q` steps back out page by page.  A window
  that octocat created (marked `octocat-dedicated` when it is first shown)
  is deleted once no other octocat page it showed is left.
- **`S-RET` opens in another window** (Evil: `O`, with `o` as `RET`),
  on every page: `octocat-visit-other-window` looks up whatever RET is
  bound to at point (a row's `keymap`, a button, the mode's own RET)
  and runs it inside `octocat-call-in-other-window`, so a new page
  needs nothing extra as long as it opens through `octocat-display-buffer`
  synchronously, before any fetch.  The key lives in
  `octocat-common-map` (see [Keys every page shares](#keys-every-page-shares));
  Evil's `o`/`O` are bound per mode in `octocat-evil-setup`.  A lone window
  is split to the right, and the new window is selected; `q` deletes
  it, as it is `octocat-dedicated`.  Otherwise another window is reused,
  so repeated opens keep one pane.

- **`q` returns to where the user left the page.**  Point is back on the
  row they opened, at the same height in the window, even though the
  page re-rendered while hidden: opening a PR from the list refreshes
  that PR in the sync store, which re-renders the list behind it.  vui
  keeps the places windows remember for a hidden buffer across a
  render, from the buffer's point, so a background refresh must never
  move point itself.

`q` is not a history: it relies on the window's previous buffers, as in
Magit.  A real back/forward (as `help-mode`'s `l`/`r`) could be added
later, as an octocat history, if stacks get deep.

`pop-to-buffer` alone avoids the selected window, so pages used to
ping-pong between two windows and `q` restored the wrong one.

Doom's workspaces (persp-mode) set a frame `buffer-predicate` that hides
buffers outside the workspace from `quit-window`, and only Doom's "real"
buffers join one, so `q` skips octocat pages.  Users fix it in their
config (octocat must not call Doom):
`(add-hook 'doom-real-buffer-functions #'octocat-buffer-p)`.

---

## Keys every page shares

A key that does the same thing on every page is bound once, not in each
mode's keymap, so adding or changing it touches one line.  Each mode's
map inherits the shared keys through its parent:

- `octocat-common-map` (`octocat-core.el`) holds the keys of every octocat
  page, such as `C-c C-j` and `S-RET`.
- `octocat-vui-page-map` (`octocat-vui.el`) is the parent of every vui
  page's keymap.  It adds the keys only vui pages share, `q` and `g`, and
  inherits `octocat-common-map` and `vui-mode-map` through
  `make-composed-keymap`.
- A page that is not a vui page composes `octocat-common-map` with its
  own base map, such as `special-mode-map`.

A mode binds a shared key itself only when it means something else
there, as `gr` does in the file viewer.  Evil's normal-state bindings
are the exception: Evil does not reliably find them through a parent
keymap, so `octocat-evil-setup` binds the shared ones in a loop over
every mode's map.

## Indicating that a page is loading or refreshing

A page paints at once from the sync store and refetches behind it (see
"Reading the sync store" in docs/using-vui.md).  What it shows meanwhile:

- **Loading** shows only in the mode line: `(Octocat-PR:loading ▘)`, as
  in `(Compilation:run)`.  No loading text in the buffer.  The vui layer
  keeps it for every resource the page reads, so pages don't track it;
  a component's own fetch, such as a "load more" page, calls
  `octocat-vui-use-mode-line-loading`.
- **No data yet**: a **skeleton**, grey bars (`octocat-vui-skeleton-bar`,
  face `octocat-skeleton`) shaped like the content to come, so the
  layout doesn't jump when it arrives (`octocat-vui-list-skeleton`,
  `octocat-vui-detail-skeleton`).  When a list already fetched the item,
  the page draws its real header from the list's copy and bars below
  it (`octocat-vui-post-skeleton`).
- **No data, failed**: one line saying why, then how to retry: "Not
  found; g to retry", "No access", "Offline: GitHub can't be reached" or
  the error (`octocat-vui-error-text`).
- **Data, refresh failed or offline**: the data stays, and the **header
  line** says it may be out of date: `Refresh failed: MSG; g to retry`
  or `Offline: showing data from 14:02; g to retry`.

Notices go in the header line, not the buffer, so the content doesn't
shift when they clear.  Only lasting states go there, as showing one
resizes the window; a refetch stays in the mode line.
`octocat-vui-resource-view` draws the skeleton, the error or the page
from a snapshot, so a page gives only those pieces.

---

## Never block the UI on the network

A command that writes to GitHub (merge, comment, state change) must not
leave the user waiting on `gh`: on a slow network or a slow GitHub that
can take many seconds.  Validate what can be checked locally, then close
any dialog at once and show the action on the page itself, as
github.com does.

Every such action is a sync **mutation** (`octocat-sync-define-mutation`).
One whose result is known, such as a rename, closing or marking a draft
ready, is **optimistic**: the change shows at once on every page that
shows the item, and is undone if GitHub refuses it.  Every mutation
shows **in progress** where it acts until GitHub answers, then the pages
refetch what it changed; on failure the error goes to the echo area.

A mutation names its **slot**, where its page draws it.  The page reads
it from its snapshot's `:mutating`, so a refresh (`g`) while it runs
still shows it, and no buffer-local state is kept.  While it is set,
hide the buttons that would start it again, and make their commands
refuse with a `user-error`.

Lead the in-progress line with the turning block spinner the mode line
shows while loading, `octocat-vui-spinner`: `▘ Merging pull request…`.
The mode line's `:loading` is for fetching; an action under way is shown
where its button was.  The spinner animates through its `display`
property, without re-rendering the page.

A dialog whose text the user typed (a comment, a description) must not
lose it: `octocat-timeline-submit` sends its mutation, closes the dialog
at once and reopens it with the text if GitHub refuses.

Where each slot shows:

- **`action`**, under the timeline, in place of its `+ Add a comment` /
  Close row: posting or editing a comment or description, closing,
  reopening (`octocat-timeline-buttons-or-action`).
- **`merge`**, in the merge box, in place of its buttons: merging,
  converting to draft, marking ready for review.
- **`approve`**, in place of the `[Approve workflows to run]` button
  under the checks, leaving the merge buttons alone.
- **`review`**, under the review comments on the PR's Files page:
  submitting a review.
- **The mode line**, for an action with no button on the page to
  replace, such as renaming the title: `octocat-vui-mode-line-action`
  shows `(Octocat-PR:saving ▘)`, ahead of `:loading`.

---

## Never steal focus

Only the command the user just ran may change what their windows show.
Async work, such as a `gh` call ending or a timer firing, must not
select a window, switch a window's buffer or open a prompt: by the time
it runs, the user may be reading or typing somewhere else.

- **A refresh re-renders the page in place.**  A page is mounted once,
  when it is opened, and every later refresh goes through
  `octocat-vui-refresh-page` without remounting.  A remount would also
  select the buffer: a merge finishing used to pull the user back to
  the PR page from wherever they had gone (see docs/using-vui.md).
- **Something shown after a fetch checks that the user is still there.**
  A command that has to wait on `gh` before it can show anything, such
  as resolving `#123` to a PR or an issue, or fetching the labels to
  pick from, goes ahead only if `octocat--still-selected-p` says the
  buffer it started from is still in the selected window.

---

## Long lines and large content

Since Emacs 29, drawing long lines is fast.  What still freezes it is
Lisp work on large texts: highlighting a 1 MiB file with its major mode
takes about half a second, all of it blocking.  So pages keep that work
small, borrowing from `compilation-mode` and Magit:

- **A long line is cut, with a button for the rest**, as
  `compilation-max-output-line-length` does: past
  `octocat--max-line-length` (1000) characters, `octocat--clip-line`
  draws the rest as `[… N more characters]`, and `RET` on it shows it.
  The text stays in the buffer, so it is copied and searched whole.
  Diffs, logs and the file viewer clip their lines.
- **Large content is built only when asked**, as Magit collapses diffs
  it cannot show quickly.  A diff file and a log step are folds whose
  body is built once unfolded (see "Folds").  The file viewer does not
  fetch a file larger than `octocat--max-file-size` (256 KiB), learning
  its size from the `repo-head` query; it says so, with a `[Show
  anyway]` button that shows it as plain text, neither highlighted nor
  rendered.  A larger README is shown as it is, not rendered.
- **Say why something is missing.**  A binary file is not shown, and
  has no button.  GitHub leaves out the patch of a binary file, or one
  too large to diff; that diff file's heading says `binary, or too
  large to show`.

A new page that shows a file, a diff or a log does the same.

---

## Revealing more rows ("Load N more…")

Rows that a `[+] Load N more…` button brings in **unfold** one frame at a
time, the way the rest of a long PR body or comment does when its fold
marker is expanded: fast at first, easing out towards the end
(`octocat-vui-unfold-step`: a fraction, `octocat-vui-unfold-growth`, of
the distance left, capped at `octocat-vui-unfold-peak` of the whole,
every `octocat-vui-unfold-interval` seconds).  The list never jumps by a whole
page.

- Draw a pageable list with `octocat-vui-reveal-list` (ITEMS, ROW-FN,
  KEY-FN) instead of `vui-list`.  It shows everything on the first render
  -- a paint from the store, `gr` -- and only animates items that arrive
  afterwards.
- Compute shared column widths (author width, ...) from **all** the
  items *before* the call, so columns do not shift while rows appear.
- Keep the load-more button below the list, with its `:key`, so point stays
  on it while the rows unfold.
- While the page is fetched, pass the button LOADING -- that page is on
  the way, not merely a background refresh -- and a SKELETON shaped like
  the rows (`octocat-vui-list-skeleton`, `octocat-vui-line-skeleton`).
  The skeleton unfolds above the button, then folds away as the rows
  unfold: nothing → skeleton → rows, never a jump.
- Folded text uses the same constants through `octocat-vui-fold-rest`;
  tune the pace in `octocat-vui.el` and both follow.

---

## Buffer names

Name a buffer after what it shows, not its mode; the mode line already
shows the mode.  Keep each page's name unique: add a short suffix only
where the bare identity would collide.

| Page | Name |
|---|---|
| Repo / tree / commits | `*owner/repo*`, `*owner/repo tree*`, `*owner/repo commits*` |
| PR / issue | `*owner/repo#12*` |
| PR diff / commits | `*owner/repo#12 diff*`, `*owner/repo#12 commits*` |
| Commit / checks | `*owner/repo@abc1234*`, `*owner/repo@abc1234 checks*` |
| Run / job | `*owner/repo run 123*`, `*owner/repo job 456*` |
| Workflow | `*owner/repo/CI*` |
| Lists | `*owner/repo prs*`, `issues`, `actions` |
| File | `*owner/repo@ref:path*`, one buffer per ref |
| User | `*@login*` |
| Edit | `*<title>*` |

---

## Repo name, brackets and the repo tab strip

### Brackets mean "button"

`vui-button` (and `buttonize`d labels) draw `[ ]` around their label.
Brackets therefore signal an *action*: `[State]`, `[Author]`, `[Load more]`,
the `[Code]` / `[Issues (N)]` tabs.  Plain, un-bracketed text is content or
a heading.

So a label that must stand apart from the text beside it, but is not an
action, takes parentheses: the compact PR list marks a draft with a grey
`(draft)` before its title, where there is no state column to say so.

The **repo name is not an action**; it is where the page sits.  It is
never bracketed, so the top line reads `owner/repo` (or `owner/repo#N`,
`owner/repo@sha`) on every page.

### Every page starts with `owner/repo`

Every page about a repository starts with `owner/repo` on its first
line, so one always sees where one is and every page reads alike.  What
the page is about follows on that line: the tab strip on the repository
and list pages, `#N`, the title and its author on an issue or PR, `@sha` on a
commit.  Details such as an item's state and date go on the
lines below, never before the repo name.  On an issue or PR the state
heads the line of the fields one edits, and a last line shows the rest,
but not the age: the opening timeline entry has it.

```
octocat/hello#42  Fix the greeting · @alice
OPEN    Assignees @bob · Reviewers none · Labels bug
        feature → main · Review required · Milestone v1
```

A title too long for the line is cut with `…`; hovering or resting
point on it shows the whole.

Two spaces separate the page's name (`owner/repo`, with its `#N` or
`@sha`) from what follows on the line, such as a title or the tab
strip, so the name stands apart from it.

A new page starts the same way, using `octocat-vui-repo-heading`.

### The last commit stands apart from the top line

On the repository page, the tree browser and the file viewer a blank
line sets the last commit's line apart from the top line, so it reads
as content, not as part of the page's name.

### The owner links, the repo name does not

On a page's first line the owner links to the owner's user or
organization page, so one can walk up to it.  The repo name is plain on
every page: it is where the page sits, and the repository page is a
`C-u C-c C-j` or the Code tab away.  Build the heading with
`octocat-vui-repo-heading`.

```
octocat/hello#42  Fix the greeting · @alice  ← only "octocat" (and @alice) link
```

The owner is an unbracketed button in `link` over `octocat-repo`, so
it is a TAB stop and looks like a link.  What follows the name (`#N`,
`@sha`, a branch pair) is plain text.

### The tab strip

The repo page at its root and the issue / PR / Actions list pages share
one strip, `octocat-vui-repo-tabs`, imitating GitHub's repository
tabs:

```
owner/repo  [Code]  [Issues (N)]  [Pull requests (N)]  [Actions]
```

- Tabs are buttons (bracketed), so they follow the rule above.
- The tab of the page being shown is drawn as an un-bracketed
  `octocat-section-heading` and is not clickable.
- Code is the repo page itself, as on GitHub, so it is current there.
  The repo page lists the root's first files; the whole tree, as
  GitHub's sidebar, is the tree browser.  It and the commits page leave
  the strip out, so the files and commits start sooner.
- The strip is underlined, gaps included, so it reads as a tab bar
  rather than a row of buttons.  Unlike `octocat-vui-tab-row` it stops at
  the last tab: it shares its line with the repo name.
- The issue and PR tabs show the open counts of the `repo-summary`
  resource, which the strip reads itself, so every page that draws it
  shows the counts; they are `(…)` until it first loads.  The summary is
  reused for `octocat-repo-summary-ttl` seconds (5 minutes by default)
  before opening a page refetches it.  `g` refetches it at once, and closing,
  reopening or merging an item outdates it, so the counts follow your own
  changes.
- Pages that show the strip put it on the top line, next to the repo name.
  Item counts
  ("N open · M closed") go on their own dimmed line.
- `octocat-vui-repo-tabs` reads `octocat--repo-tabs`, so labels and help
  text stay in one place.
- The commands behind the tabs, `octocat-issue-list`, `octocat-pr-list` and
  `octocat-actions` (as `octocat-run-list` and `octocat-workflow-list`), take the repo as an optional argument: a buffer's
  repo is not derivable from its mode or `default-directory`.

### Tabs over content

Tabs that switch what is shown below them (a PR's Conversation / Commits / Files
changed, the repo page's README / License) use `octocat-vui-tab-row`: the
row is underlined across the page, like GitHub's tab bar, so it reads as
a header rather than the content's first line, with no blank line after.

### Detail pages

Detail pages (PR, issue, PR diff, commit, checks, workflow, run, job) do
not show the strip: it belongs to the top-level pages.  Their top line is
only the identity, RET-able to the repo page:

```
owner/repo#42
OPEN  The PR title  labels

owner/repo@abc1234
The commit subject
```

A commit (and its checks page) is identified as `owner/repo@sha`, the
short SHA in `octocat-commit-sha`, as an issue or PR is by `owner/repo#N`.
