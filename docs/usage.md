# Using octocat.el

What each page shows and how to get around it.  The keys common to all
pages are in the [README](../README.md#keybindings); every page is
pictured in [screenshots](screenshots/README.md).

## GitHub account dashboard (`M-x octocat`)

Run `M-x octocat` to open the GitHub account dashboard in a global
`*octocat*` buffer.  Like github.com's own dashboard, it starts with
the open pull requests and issues that involve you, then shows your
repositories and recent activity:

- **Pull Requests** and **Issues** — the `octocat-dashboard-item-limit`
  (5) most recently updated open items, across every repository, that
  you opened, are assigned to, were asked to review, are mentioned in or
  commented on (GitHub's `involves:@me` search).  Each row reads as on
  the list pages, with `owner/repo#N` on its second line.  `RET` opens
  the pull request or issue, and `C-c C-o` opens it on GitHub.
- **Recent Repositories** — your most-recently-pushed repos; press `RET`
  on a row to open its per-repository buffer, or `C-c C-o` to open
  it on GitHub.
- **Feed** — recent activity events across your account; press `RET` on
  an event to open the related commit, PR, issue or repo, and `+` to load
  more events.

## Per-repository view (`M-x octocat-repo`)

Run `M-x octocat-repo` inside any Git repository that has a GitHub `origin`
remote.  This opens the repository's page, laid out as GitHub's Code tab:

```
owner/repo  Code  Issues (3)  Pull requests (1)  Actions

[main ▾]  a1b2c3d  Fix the parser  2 hours ago  [1342 commits]
docs/
src/
Makefile
README.md

README  License
…
```

Opened from a local clone, the page, its tree browser and its commits
page show the branch checked out there, as GitHub has it: its upstream
on `origin`, or else `origin`'s branch of the same name.  A clone with
a detached HEAD, or on a branch never pushed, shows the default branch.
The pages follow the checkout: after a `git checkout`, `g` or switching
back to the page shows the new branch.

The `[main ▾]` picker (or `C-c C-b`) shows another branch, which the
page then keeps to, and `[reset to main]` goes back to the branch it
opened on: the clone's, or else the default branch.  Beside it is the
branch's last commit, laid out as on GitHub: its author and subject,
then, at the right edge, its SHA and when it was committed, and
`[N commits]`, which opens its history on its own commits page (see
below).  `RET` on the line, or on the SHA, which `TAB` reaches, opens
the commit.

The page lists the root's entries, directories first, as GitHub's
repository page does: the first `octocat-tree-entries` (15) of them,
then a `[Browse code]` button, which says how many more there are and
opens the tree browser (below).  Each entry shows, as on GitHub, the
subject of the last commit that touched it and, at the right, its age.  `RET` on a file opens it in the file
viewer, and `RET` on a directory opens the tree browser at it.
`S-RET` opens either in another window instead, as on every page.

Below the files the page shows the repository's README, as GitHub does.
A selector above it offers the other documents found at the root — Code
of conduct, Contributing, License and Security — and `RET` on one shows
it in place of the README.  Only the first `octocat-repo-doc-lines` (20)
lines show, the rest folded behind a "more lines" row that `RET`
expands.  Markdown files are rendered; `C-c C-v` shows them raw.  Other
files, such as a plain-text LICENSE, are shown as they are.

The page can show any ref, not only a branch: a github.com link to a tag
or a commit (`/tree/v1.0`, `/tree/a1b2c3d`) opens the page at it.

`C-c C-f` picks any file of the commit by path, with `completing-read`,
and opens it; its list is fetched once per commit.  `C-c C-o` opens the
entry at point on GitHub, and elsewhere the page itself.

### Tree browser (`octocat-tree-mode`)

The `*owner/repo tree*` buffer shows the whole tree of the branch, as
GitHub's sidebar, opened down to the directory or file it was opened
at, with point on it:

```
owner/repo  [main ▾]:/

@alice  Show open issue and PR counts …  a9fc167 · committed 1 day ago  [62 commits]
▸ .github/
▾ docs/
    user-interface-conventions.md
    using-vui.md
▸ plans/
  AGENTS.md
  …
```

Each entry shows the last commit that touched it, as on the repo page.
These come in one GitHub query per directory, and are stored by the
commit they start from, so a directory opened again shows them at once.
`RET` on a directory only expands or collapses it; the line above the
tree, underlined, stays on the root's last commit.  `RET` on a file opens it in the
file viewer, and `^` moves point to the directory holding the entry at
point.  `S-RET` opens a file in another window (see Keybindings).
Under Evil, as in treemacs-evil, `l` opens the entry at point and `h`
goes up a directory; `o` is `RET` and `O` is `S-RET`.  The entries are
not buttons, so `TAB` does not step from file to file.  The repo name
on the top line leads back to the repo page.  A github.com link to a
path (`/tree/main/src/parser`) opens the browser at it.

### Commits page (`octocat-commit-list-mode`)

`[N commits]` on the repo page lists the history of the ref shown, or of
the directory shown, newest first, `octocat-repo-commits-page-size` (25) at a time with a button to
load more; `C-c C-l` in the file viewer lists a file's.  Its top line is
the tree browser's, `owner/repo  [main ▾]:/dir`, with how many commits
there are, underlined: the picker shows another branch's history, and
a directory of the path its own.  Each row reads as on GitHub: the
subject, the author, when it was committed, then the short SHA.  The
local `HEAD` commit is highlighted, and `RET` on a commit opens it.  A github.com
`/commits/REF` link opens it too, and `/commits/REF/PATH` the history of
a file or directory.

## Pull request and issue lists (`M-x octocat-pr-list`, `M-x octocat-issue-list`)

Each list shows a page of items, filtered by the query field above it,
with a button to load the next page.  An item takes two lines: its
state, title and labels, then its number, author, age, review, checks
and comments.  `C-c C-v` switches the page to a compact view of one line
per item — state, `#N`, title, labels and author — which fits more on
screen, so it loads `octocat-list-compact-page-size` (30) items at a time
against `octocat-list-page-size` (15) in the full view.  The choice is
remembered per repository and page in `octocat-settings-file`, so it
survives restarting Emacs; pages start in the full view.

The query is a GitHub search, edited by hand (with completion) or through
the buttons below the field (or `F`).  On the pull request list,
**[Reviewer]** sets `review-requested:`; pick `@me` to list the pull
requests waiting for your review, including those requested from one of
your teams.

Items are marked as files are in Dired, the same with Evil:

| Key | Does |
|-----|------|
| `m` | Mark the item at point and move to the next; with a region, mark the items in it |
| `u` | Unmark, the same way |
| `U` | Unmark every item |

A marked row shows `✓` and is highlighted.  An item that leaves the
list, after a new query or once closed, is unmarked.

While items are marked, a **Marked** bar replaces the filters and acts
on them: **[Label]** adds or removes labels on all of them at once.

## Actions (`M-x octocat-run-list`, `M-x octocat-workflow-list`)

The Actions tab has two pages, each its own buffer and major mode, so
either can be opened directly: `M-x octocat-run-list` lists the
repository's recent workflow runs across all workflows,
`octocat-run-list-page-size` (30) at a time with a button to load
more; `M-x octocat-workflow-list` lists its workflows and whether they
are enabled.  `M-x octocat-actions`, and the Actions tab of any page,
open the runs.  A **Runs** / **Workflows** tab row under the header
switches between the two pages, with the count of workflows on its tab,
and `RET` on a row opens that run or workflow.  A workflow's own page
lists its runs as the run list does, without the workflow column.  A
workflow can also be reached from anywhere with `C-c C-j`, by its name
or file.

The runs are filtered as the pull request list is: a query in the field
above them, such as `branch:main status:failure`, edited by hand (with
completion) or through the **[Branch]**, **[Status]**, **[Workflow]**
and **[Actor]** buttons (or `F`).  The qualifiers are `branch:`,
`status:`, `workflow:`, `actor:` (who triggered the run), `event:` and
`commit:`; GitHub has no search for runs, so each becomes the matching
`gh run list` option, and anything else in the query is ignored, with a
note saying so.

Like the repo and file pages and the issue and pull request pages, the list pages
keep within `octocat-max-width` columns (112 by default, nil for the
whole window); the titles of rows take whatever the other columns leave.

## PR detail view (`octocat-pr-mode`)

Press `RET` on any PR row to open its detail buffer.  The buffer contains the
following collapsible sections (toggle with `TAB`):

| Section | Contents |
|---------|----------|
| **Info** | Title (editable), author, head→base branch, creation / merge / close date, diff stats |
| **Body** | The PR description (editable) |
| **Commits (N)** | One line per commit: subject · author · date · short SHA |
| **Checks (N)** | CI check name, workflow, and pass/fail/pending icon |
| **Reviews (N)** | Reviewer login and review state |
| **Comments (N)** | Commenter login and a truncated snippet (your own comments are editable) |

### Tabs

Under the header, as on GitHub, a tab row switches between the PR's
pages: **Conversation** (this timeline), **Commits (N)** and **Files
changed (N)**.  `RET` on a tab opens that page in its own buffer.  The
Commits page lists all of the PR's commits oldest first, one per line;
`RET` on one opens the commit and `C-c C-o` opens it on GitHub, or off
a commit the PR's commits.  It reuses the PR page's
data, so it fetches nothing more.

### Stacks

A PR in a [stack](https://github.com/github/gh-stack) shows its place
in it after its title, `≡ 2/3` (counting from the bottom).  On its page,
`RET` on that picks another PR of the stack, and the stack is listed
under the merge box, with what stops it merging.

### Inline editing

`RET` is context-sensitive in the PR detail buffer:

| Point position | Action |
|----------------|--------|
| **Title** row in Info | Prompts in the minibuffer to rename the PR title |
| **Changes** row in Info | Opens the full diff view |
| Commit row | Opens the commit detail view |

Use `C-c C-e` to edit the body or a comment you authored.

### Commit navigation

From the **Commits** section, press `RET` on a commit line to open the commit
detail view (see below).  Press `C-c C-o` on a commit line to open
it directly in your browser.


## Commit detail view (`octocat-commit-mode`)

Navigate to a commit from the PR detail view, the commits page, or the
last-commit line atop the repository's files (`RET` on the line, or `TAB`
to its SHA).  Below a top line like the tree browser's, the commit
reads as `git show --format=fuller` prints it, its message unindented:

```
owner/repo@a1b2c3d4e5f6…  [Browse files]   Diff  Patch
Author:     Jane Doe <jane@example.com> @jane
AuthorDate: Mon Oct 19 10:00:00 2026 +0300  (3 days ago)
Commit:     GitHub <noreply@github.com> @web-flow
CommitDate: Mon Oct 19 11:00:00 2026 +0300  (3 days ago)
Parent:     9f84ad6
Branch:     main

Commit subject line

<optional multi-line commit body>

Checks (2)
  ✓  build                github-actions        1m 2s

Files (3)
  M src/foo.el  +12 -3
  @@ -10,6 +10,18 @@
   (context line)
  +(added line)
  -(removed line)
  A src/bar.el  +40 -0

Comments (1)
  …
```

Each file is collapsible.  The Comments section shows only when the
commit has comments.  `[Browse files]` opens the tree browser at the
commit; the parent opens its own commit page, `@login` the user's page.
`Branch` names the default branch when it holds the commit, as GitHub
does, and is left out when it does not; it opens the tree at that
branch.  `RET` on a check opens the commit's checks.

Its files show as diffs, a Markdown file's too; an image unfolds to the
image on `RET`.  The Diff | Patch switch ending the top line, or
`C-c C-v`, shows the commit as a patch instead, as GitHub's `.patch`
link does: its header and message as `git format-patch` writes them,
then every file's diff in full, with its `diff --git`, `---` and `+++`
lines, to read or copy out for `git am`.  Diff, or `C-c C-v` again,
goes back.

Elsewhere, lists and last-commit lines show when a commit was
*committed*, as GitHub does ("committed 2 days ago"): after a rebase or a
merge on GitHub, that is when it landed, which its author date is not.


## Compare view (`octocat-compare-mode`)

Following a github.com compare link, such as
`https://github.com/owner/repo/compare/v1.0...main`, opens what GitHub's
compare page shows: the commits HEAD has that BASE lacks, oldest first,
then the changed files, folded as on the commit and PR diff pages.

```
owner/repo  v1.0...main
3 commits · 5 files changed

a1b2c3d  Fix the parser          Jane Doe  2 days ago
…

Files (5)  [Expand all]
  M src/foo.el  +12 -3
```

`RET` on a commit opens it, `C-c C-o` opens the comparison in a browser.
GitHub's API only compares from the merge base (`...`), so a two-dot
link (`BASE..HEAD`) is shown as its three-dot comparison.  The two are
the same when BASE is an ancestor of HEAD, as with two commits of one
branch; when the refs have diverged, a note under the summary says so.
GitHub's API returns at most 250 commits and 300 files, and the summary
says when a comparison is cut short.  A comparison of two commits never
changes, so it is kept like a commit is; one of branches or tags is
refetched behind the stored copy each time it is opened.  A compare
link with one ref, where github.com picks the base, opens in the browser.


## Files (`octocat-file-mode`)

`RET` on a file of the repo page's tree, a github.com `/blob/REF/PATH`
link, or a relative link in a README, opens a read-only buffer showing
the file at that ref.  A Markdown file is rendered, as on GitHub: its
relative links open the files they name at the same ref, and `RET` on a
relative image shows it in place.  Any other file is shown with the
syntax highlighting of its major mode.

The top line ends in a switch of the file's views, as GitHub's:
Preview | Code | Blame for a Markdown or org file, Code | Blame for any
other, drawn as one outlined pill with the view shown filled in.  `RET`
on one shows it, and `C-c C-v` shows the next, in turn; hovering over a view names the key.  The blame shows each
line, numbered, beside the commit that last changed it, with its
subject and age at the head of each run of lines, and a faint rule
under each run; `RET` on it opens the commit and `C-c C-o` opens it on
GitHub.  The page widens by the blame's column, past `octocat-max-width`,
so the code keeps its width.  It slides in from the left
edge and back out of it (not on low battery, nor in a file of more
than 300 lines).  Like the file, it is
stored by commit, so it opens at once the next time.

The top of the page is the tree browser's: `owner/repo  [main ▾]:/dir/file`,
the branch picker and the path, whose directories open the tree browser
down to them.
Under it, after a blank line, are the file's last commit and a
`[N commits]` button to its history, underlined.  A branch name longer than `octocat-ref-max-width`
is cut in its middle, there and in every branch picker; hovering over
it shows it in full, as does picking a branch.  Each ref of a file has a buffer of its own, named
`*owner/repo@ref:path*`; `C-c C-b`, or `RET` on the picker, opens the
file at another branch, in another buffer, so the two can be read side
by side.  Press `C-c C-o` to open the file on GitHub, or, on a link or
image, what it links to; `C-c C-l` to open the file's history on the
commits page, as `[N commits]` does; and `gr` to reload.  `RET` on an
image shown in place opens its file here, where it is shown whole.


## Images in markdown

In a graphical frame, an image that has a line of a PR, issue, comment
or README to itself can be shown there: `RET` (or a click) on its
`[image: alt]` link fetches it and shows it in place of the link,
scaled down to fit the window and at most `octocat-image-max-lines`
lines tall.  `RET` on the image then opens it in the browser.  Nothing
is downloaded until asked for, and a fetched image stays shown, across
refreshes, for the rest of the session.  An HTML table of images, as
pull requests use to set screenshots before and after a change side by
side, keeps them side by side: each image fits its column, under its
caption, and when the window is too narrow for them they are stacked
one under another instead.  Images within text or among a table's
text, and every image in a terminal, are plain links to the browser.

Only images uploaded to GitHub can be fetched: those on
`user-images.githubusercontent.com` (uploads before 2023),
`private-user-images.githubusercontent.com` and
`github.com/user-attachments/assets/` (uploads since); other images'
links open the browser.  Any other URL would tell whoever wrote it who
reads the page, and when.  Each redirect is checked too, so a fetch
cannot be bounced elsewhere.  Uploads to private repositories need a
GitHub web session, which octocat does not have, so they cannot be
fetched.

## Keys in more depth

The [README](../README.md#keybindings) lists every key; some do more
than fits there.

### Jumping (`C-c C-j`)

`C-c C-j` jumps to something in the repository: its PRs, issues,
commits, workflows and files.  Those octocat has seen before that match
show at once, with the commits `git log` finds in a local clone, when
there is one; GitHub's search results then take the lead as they
arrive, without repeating any.  With `C-u`, or on a page with no
repository, it jumps to another repository instead, or to a user with
`@`, matched the same way.

### Writing, reviewing and merging

`C-c C-n` writes a new issue: the first line is the title, the rest the
body, and `C-c C-c` creates it and opens its page.  `C-c C-r` submits a
review from any PR page, and `C-c C-t` there picks Comment / Approve /
Request changes.  `C-c C-m` merges the PR: edit the commit message,
`C-c C-t` picks Merge / Squash / Rebase (starting on the one last used
in the repo, if still allowed), `C-c C-d` toggles deleting the branch,
and `C-c C-c` merges.

### Reacting (`C-c C-l`)

`C-c C-l` on an issue's or PR's opening post, or on a comment, gives or
takes back a reaction, such as 👍 or 🎉.  It asks with one key per
reaction (`+`, `-`, `l`augh, `t`ada, `c`onfused, `h`eart, `r`ocket,
`e`yes) and ticks the ones you gave; picking one of those takes it
back.  The count beside the date changes at once.

### Refreshing (`g` / `gr`)

A refresh shows the page as when it opened: images shown in place are
links again, and `<details>`, folds and expanded entries are back as
first drawn.  Point, filters, the branch shown and what "load more"
added stay.

Pages on screen also refresh on their own: every minute
(`octocat-sync-poll-interval`), every 10 s while a run, job or checks
are under way.  They slow down when you are idle for 5 minutes
(`octocat-sync-poll-idle-after`), switch to another app or run on
battery, and stop after half an hour idle or on low battery; coming
back refreshes at once.  `M-x octocat-doctor` shows which pages are
refreshing, how often and why (see
[Diagnostics](#diagnostics-m-x-octocat-doctor)).

### Another view (`C-c C-v`)

`C-c C-v` is the one key for seeing a page another way: wherever a page
has a second way to show what is on it, `C-c C-v` switches to it and
back.  Pages showing markdown switch between rendered and raw text, so
the markup can be read or copied as written.  The file page has more
than two views and cycles through them: rendered, raw and blame for
Markdown and org, source and blame for other files (see
[Files](#files-octocat-file-mode)).  The commit page switches between
its diff and the commit as a patch.  The PR's files changed
page instead shows or hides the review comments in the diff, which
opening the page shows again; the `[Show comments (N)]` button
in its Files heading does the same, also on the commit page.  The PR and
issue lists switch between two-line rows and a compact view of one line
per item.
The list pages remember the choice per repository, across Emacs
sessions; the others go back to the default view when reopened.

### Windows and `q`

RET opens a page in the same window and `q` steps back, as in Magit (see
[UI conventions](user-interface-conventions.md#windows-opening-pages-and-q)).
`S-RET`, on any page, opens it in a window to the right instead, or in
another window already there, so repeated opens reuse one pane; `q`
there closes the window it made.
On Doom Emacs, let `q` reach octocat pages with
`(add-hook 'doom-real-buffer-functions #'octocat-buffer-p)`.

## github.com links

Following a github.com link in an octocat page (`RET` on a link in a
comment or README) opens it in octocat when there is a view for it: users, repositories, PRs and their diffs, issues, commits,
comparisons (`/compare/BASE...HEAD`), workflows, runs, jobs, and a
repository's PR, issue and Actions pages.  Links to a ref open as on
GitHub: `/tree/REF[/PATH]` the repo page at that branch, tag or commit, in that
directory,
`/commits/REF` its commits page, `/commits/REF/PATH` a path's history and
`/blob/REF/PATH` the file.  A ref may contain slashes (`feature/x`): as
GitHub does, the longest leading part of the path that names a ref is the
ref, which takes one request to find out.  Other links still open in the browser, and `C-c C-o` always
does.

To open github.com links this way from anywhere in Emacs (`browse-url`,
Org links, mail, other packages), turn on `octocat-github-links-mode`,
e.g. with `(octocat-github-links-mode 1)` in your init file.  It is off
by default, as loading a package should not change how Emacs opens
links.

## Diagnostics (`M-x octocat-doctor`)

`M-x octocat-doctor` reports, as text to paste into a bug report, which
files are loaded (and whether a compiled one is stale), the store's size
and largest resources, which pages refresh on their own and why, and
the requests to GitHub of the last hour: how many, how often, and how
much data they brought in.  It names the resources it stores, but not
your token.
