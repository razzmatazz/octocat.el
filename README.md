# octocat.el

A GitHub client for Emacs, powered by the [`gh`](https://cli.github.com/) command-line tool.

> **Note:** This project was largely written with the assistance of LLMs (Claude).
> Source files carry an `Assisted-by:` header line per the [MELPA attribution convention](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Overview

`octocat.el` integrates GitHub workflows directly into Emacs by leveraging the official GitHub CLI (`gh`). It provides a convenient Emacs interface for common GitHub operations without leaving your editor.

## Requirements

- [Emacs](https://www.gnu.org/software/emacs/) 29.1 or later, built with SQLite (`(sqlite-available-p)` returns `t`); pages keep what they fetched in a SQLite store
- [GitHub CLI (`gh`)](https://cli.github.com/) — must be installed and authenticated
- [vui.el](https://melpa.org/#/vui) — declarative UI library every octocat buffer is drawn with, from MELPA

### Installing `gh`

```bash
# macOS
brew install gh

# Linux (Debian/Ubuntu)
sudo apt install gh

# Windows
winget install --id GitHub.cli
```

Then authenticate:

```bash
gh auth login
```

## Installation

Clone the repository and add it to your Emacs load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/octocat.el")
(require 'octocat)
```

## Usage

### GitHub account dashboard (`M-x octocat`)

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

### Per-repository view (`M-x octocat-repo`)

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
branch's last commit, `RET` opening it; `[N commits]` opens its history
on its own commits page (see below).

The page lists the root's entries, directories first, as GitHub's
repository page does: the first `octocat-tree-entries` (15) of them,
then a `[Browse code]` button, which says how many more there are and
opens the tree browser (below).  `RET` on a file opens it in the file
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

#### Tree browser (`octocat-tree-mode`)

The `*owner/repo tree*` buffer shows the whole tree of the branch, as
GitHub's sidebar, opened down to the directory or file it was opened
at, with point on it:

```
owner/repo

[main ▾]  a9fc167  Show open issue and PR counts …  [62 commits]
▸ .github/
▾ docs/
    user-interface-conventions.md
    using-vui.md
▸ plans/
  AGENTS.md
  …
```

`RET` on a directory only expands or collapses it; the line above the
tree stays on the root's last commit.  `RET` on a file opens it in the
file viewer, and `^` moves point to the directory holding the entry at
point.  `S-RET` opens a file in another window (see Keybindings).
Under Evil, as in treemacs-evil, `l` opens the entry at point and `h`
goes up a directory; `o` is `RET` and `O` is `S-RET`.  The entries are
not buttons, so `TAB` does not step from file to file.  The repo name
on the top line leads back to the repo page.  A github.com link to a
path (`/tree/main/src/parser`) opens the browser at it.

#### Commits page (`octocat-commits-mode`)

`[N commits]` on the repo page lists the history of the ref shown, or of
the directory shown, newest first, `octocat-repo-commits-page-size` (25) at a time with a button to
load more.  The local `HEAD` commit is highlighted, `RET` on a commit
opens it, and the picker shows another branch's history.  A github.com
`/commits/REF` link opens it too, and `/commits/REF/PATH` the history of
a file or directory.

### Pull request and issue lists (`M-x octocat-pr-list`, `M-x octocat-issue-list`)

Each list shows a page of items, filtered by the query field above it,
with a button to load the next page.  An item takes two lines: its
state, title and labels, then its number, author, age, review, checks
and comments.  `C-c C-v` switches the page to a compact view of one line
per item — state, `#N`, title, labels and author — which fits more on
screen, so it loads `octocat-list-compact-page-size` (30) items at a time
against `octocat-list-page-size` (15) in the full view.  The choice is
remembered per repository and page in `octocat-settings-file`, so it
survives restarting Emacs; pages start in the full view.

### Actions (`M-x octocat-actions`)

The Actions page has two tabs, as on GitHub: **Runs**, shown first, lists
the repository's recent workflow runs across all workflows,
`octocat-actions-runs-page-size` (30) at a time with a button to load
more; **Workflows** lists its workflows and whether they
are enabled, with their count on the tab.  `RET` on a tab switches to
it, and `RET` on a row opens that run or workflow.

The runs are filtered as the pull request list is: a query in the field
above them, such as `branch:main status:failure`, edited by hand (with
completion) or through the **[Branch]**, **[Status]**, **[Workflow]**
and **[Actor]** buttons (or `F`).  The qualifiers are `branch:`,
`status:`, `workflow:`, `actor:` (who triggered the run), `event:` and
`commit:`; GitHub has no search for runs, so each becomes the matching
`gh run list` option, and anything else in the query is ignored, with a
note saying so.

Like the repo page and the issue and pull request pages, the list pages
keep within `octocat-max-width` columns (112 by default, nil for the
whole window); the titles of rows take whatever the other columns leave.

### PR detail view (`octocat-pr-mode`)

Press `RET` on any PR row to open its detail buffer.  The buffer contains the
following collapsible sections (toggle with `TAB`):

| Section | Contents |
|---------|----------|
| **Info** | Title (editable), author, head→base branch, creation / merge / close date, diff stats |
| **Body** | The PR description (editable) |
| **Commits (N)** | One line per commit: short SHA · subject · author |
| **Checks (N)** | CI check name, workflow, and pass/fail/pending icon |
| **Reviews (N)** | Reviewer login and review state |
| **Comments (N)** | Commenter login and a truncated snippet (your own comments are editable) |

#### Tabs

Under the header, as on GitHub, a tab row switches between the PR's
pages: **Conversation** (this timeline), **Commits (N)** and **Files
changed (N)**.  `RET` on a tab opens that page in its own buffer.  The
Commits page lists the PR's commits oldest first, grouped under a
"Commits on <day>" heading per day; `RET` on one opens the commit and
`C-c C-o` opens the PR's commits on GitHub.  It reuses the PR page's
data, so it fetches nothing more.

#### Inline editing

`RET` is context-sensitive in the PR detail buffer:

| Point position | Action |
|----------------|--------|
| **Title** row in Info | Prompts in the minibuffer to rename the PR title |
| **Changes** row in Info | Opens the full diff view |
| Commit row | Opens the commit detail view |

Use `C-c C-e` to edit the body or a comment you authored.

#### Commit navigation

From the **Commits** section, press `RET` on a commit line to open the commit
detail view (see below).  Press `C-c C-o` on a commit line to open
it directly in your browser.

---

### Commit detail view (`octocat-commit-mode`)

Navigate to a commit from the PR detail view (press `RET` on a commit row).
The commit buffer:

```
owner/repo@a1b2c3d  [Code]  [Issues]  [Pull requests]  [Actions]
Commit subject line
Jane Doe  <jane@example.com> · @jane · 3 days ago
SHA a1b2c3d…

Message
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
commit has comments.  `RET` on the top line opens the repo, on a
check opens the commit's checks.

---

### Compare view (`octocat-compare-mode`)

Following a github.com compare link, such as
`https://github.com/owner/repo/compare/v1.0...main`, opens what GitHub's
compare page shows: the commits HEAD has that BASE lacks, grouped by day
as on a PR's Commits tab, then the changed files, folded as on the
commit and PR diff pages.

```
owner/repo  v1.0...main
3 commits · 5 files changed

Commits on Oct 17, 2026
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

---

### Files (`octocat-file-mode`, `octocat-file-log-mode`)

#### File viewer (`octocat-file-mode`)

`RET` on a file of the repo page's tree, or a github.com `/blob/REF/PATH`
link, opens a read-only buffer showing the raw file content
with syntax highlighting inferred from the file extension.  Press
`C-c C-o` to open the file on GitHub, `C-c C-l` to open the file's commit
history, and `gr` to reload.  `[Browse tree]` on its top line opens the tree
browser at the file's branch, opened down to the file.

#### File commit log (`octocat-file-log-mode`)

Press `C-c C-l` from a file viewer buffer to open the commit history for that
file, from the ref it was opened at back; a github.com `/commits/REF/PATH`
link opens it too.  The log buffer lists up to 25 commits that touched the
file, one per row:

```
owner/repo  src/foo.el  (7 commits)
  a1b2c3d  2026-06-01       Jane Doe          Refactor parser logic
  f4e5d6c  2026-05-28       Bob Smith         Fix edge case in tokeniser
  …
```

- **`RET`** on a commit row opens its full commit detail view.
- **`C-c C-o`** opens the commit on GitHub in the browser.
- **`gr`** re-fetches the commit list from the API.
- **`q`** closes the buffer.

---

### Images in markdown

In a graphical frame, an image that has a line of a PR, issue, comment
or README to itself is shown there, scaled down to fit the window and
at most `octocat-image-max-lines` lines tall; `RET` on it opens it in
the browser.  Images within text or tables, and every image in a
terminal, are shown as `[image: alt]` links instead.

Only images uploaded to GitHub are fetched: those on
`user-images.githubusercontent.com` (uploads before 2023),
`private-user-images.githubusercontent.com` and
`github.com/user-attachments/assets/` (uploads since).  Any other URL
would tell whoever wrote it who reads the page, and when.  Each
redirect is checked too, so a fetch cannot be bounced elsewhere.
Uploads to private repositories need a GitHub web session, which
octocat does not have, so they stay links.  Set `octocat-image-show`
to nil to never fetch images.

### Keybindings

| Key | Action |
|-----|--------|
| `RET` | Context-dependent: open detail view, navigate to commit, or inline-edit title / body / comment at point |
| `S-RET` | What `RET` does, but the page opens in another window (Evil: `O`, and `o` is `RET`) |
| `C-c C-o` | Open item at point in browser |
| `C-c C-a` | Add a comment (PR and issue detail views) |
| `C-c C-r` | Submit a review (all PR pages: conversation, commits, files changed); `C-c C-t` picks Comment / Approve / Request changes |
| `C-c C-e` | Edit the title, body, comment, or Labels / Assignees / Reviewers field at point (PR and issue detail views); `RET` on a field does the same |
| `C-c C-n` | Write a new issue (PR and issue lists and detail views): the first line is the title, the rest the body; `C-c C-c` creates it and opens its page |
| `C-c C-m` | Merge the PR (all PR pages): edit the commit message, `C-c C-t` picks Merge / Squash / Rebase (starting on the one last used in the repo, if still allowed), `C-c C-d` toggles deleting the branch, `C-c C-c` merges |
| `C-c C-j` | Jump to another repository, or a user with `@`: repos and users octocat has seen before that match show at once, then GitHub's search results take the lead as they arrive, without repeating any |
| `C-c C-s` | Search the repository's PRs, issues, commits and files: those octocat has seen before that match show at once, with the commits `git log` finds in a local clone, when there is one; GitHub's search results then take the lead as they arrive, without repeating any |
| `C-c C-v` | Alternative view of the page (see below): raw markdown on the repo page and the PR, commit and issue pages; the review comments in the diff on the PR's files changed page; one line per item on the PR and issue lists |
| `C-c C-b` | Pick the branch shown (repo page, commits page); `[reset to main]` goes back to the clone's branch, or the default |
| `C-c C-f` | Open fuzzy file finder — `completing-read` over the full recursive file list of the commit shown; works from the repo page and the file viewer (the list is fetched once per commit) |
| `C-c C-l` | Open file commit log — shows the commit history for the file currently open in `octocat-file-mode` |
| `g` / `gr` | Refresh current buffer |
| `q` | Back to the previous page, or out of octocat (see below) |
| `TAB` | Expand / collapse section at point |
| `S-TAB` | Cycle visibility of all sections |

`C-c C-v` is the one key for seeing a page another way: wherever a page
has a second way to show what is on it, `C-c C-v` switches to it and
back.  Pages showing markdown switch between rendered and raw text, so
the markup can be read or copied as written.  The PR's files changed
page instead shows or hides the review comments in the diff, which start
hidden so the diff reads uninterrupted; the `[Show comments (N)]` button
in its Files heading does the same, also on the commit page.  The PR and
issue lists switch between two-line rows and a compact view of one line
per item.
The list pages remember the choice per repository, across Emacs
sessions; the others go back to the default view when reopened.

RET opens a page in the same window and `q` steps back, as in Magit (see
[UI conventions](docs/user-interface-conventions.md#windows-opening-pages-and-q)).
`S-RET`, on any page, opens it in a window to the right instead, or in
another window already there, so repeated opens reuse one pane; `q`
there closes the window it made.
On Doom Emacs, let `q` reach octocat pages with
`(add-hook 'doom-real-buffer-functions #'octocat-buffer-p)`.

### github.com links

Following a github.com link anywhere in Emacs (`RET` on a link in a
comment, `browse-url`, Org links, …) opens it in octocat when there is a
view for it: users, repositories, PRs and their diffs, issues, commits,
comparisons (`/compare/BASE...HEAD`), workflows, runs, jobs, and a
repository's PR, issue and Actions pages.  Links to a ref open as on
GitHub: `/tree/REF[/PATH]` the repo page at that branch, tag or commit, in that
directory,
`/commits/REF` its commits page, `/commits/REF/PATH` a path's history and
`/blob/REF/PATH` the file.  A ref may contain slashes (`feature/x`): as
GitHub does, the longest leading part of the path that names a ref is the
ref, which takes one request to find out.  Other links still open in the browser, and `C-c C-o` always
does.  Set `octocat-open-github-urls` to nil to turn this off.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions and guidelines.

## Development

### Running the linter

The `test` Makefile target runs `checkdoc` and
[`package-lint`](https://github.com/purcell/package-lint) inside an
Emacs 29 Docker container — no local Emacs install required.

```bash
make test
```

> **Requires:** Docker

The image used is [`silex/emacs:29.4`](https://hub.docker.com/r/silex/emacs).
Override it with `EMACS_IMAGE` if you need a different version:

```bash
make test EMACS_IMAGE=silex/emacs:29.1
```

### CI

GitHub Actions runs `make test` automatically on every push and pull request.
See [`.github/workflows/test.yml`](.github/workflows/test.yml).

## License

This project is licensed under the [GNU GENERAL PUBLIC LICENSE](LICENSE).
