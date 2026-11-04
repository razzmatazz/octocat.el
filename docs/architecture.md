# Architecture

octocat.el is split into one file per module.  `octocat.el` is the
package's main file: it holds every `;;;###autoload` entry point and
requires every other module, so whatever a user runs has all of them
loaded (see "Entry points" in [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Layers

From the bottom up:

- **Standalone renderers**: `octocat-mermaid` and `octocat-avatar`
  require no other module, so they can be loaded and tested on their
  own.  `octocat-markdown`, which also turns org into markdown, and
  `octocat-image` build on them to draw GitHub's markdown.
- **`octocat-core`**: running `gh`, faces, and the helpers every page
  shares.
- **`octocat-sync`**: the local SQLite store pages read from, and the
  syncing that fills it (see "Refresh and the sync store" in
  CONTRIBUTING.md).
- **`octocat-vui`**: components and helpers on top of vui.el, and the
  branch and repo pickers.
- **Shared parts of pages**: `octocat-edit`, `octocat-timeline`.
- **Pages**: one module per kind of page, or per group of related
  pages, such as `octocat-pr` (a PR's conversation, commits and files
  changed), `octocat-issue`, `octocat-repo` (a repository's code),
  `octocat-actions` (GitHub Actions and a commit's checks) or
  `octocat-diff` (the changed files of a diff, and the commit and
  compare pages), requiring the pages they link to.
  `octocat-search` and `octocat-dashboard` (the page `M-x octocat`
  opens) sit above the pages their rows open.
- **`octocat-evil`**: Evil bindings, loaded only once Evil is on.  It
  requires the pages it binds keys in, which `octocat.el` has loaded
  by then.

Requires must not form a cycle.  Where a lower module opens a page of
a higher one, or a page opens a peer it cannot require, it calls
`octocat-open` with the page's kind, such as `(octocat-open 'pr repo
number)`: a generic function in `octocat-core` that each page module
adds a `cl-defmethod` to for its kinds.  A key bound to a higher
module's command names it quoted, as `'octocat-jump`, not `#'`.

A lower module never names a higher one's function otherwise.  What it
needs from above, the caller hands it:

- bound around the call, as core binds the link handlers and host
  around `octocat-markdown-render`, which each link keeps;
- set buffer-locally by the page's mode, as the repo and file pages
  set the functions `octocat-image` fetches a repository's images with;
- added to a hook from a function the higher module runs anyway, as
  `octocat-vui--listen` adds vui's handlers to sync's and image's
  hooks when a page mounts.

## Module graph

An arrow points from a module to one it requires.  A dashed one is a
`require` inside a function, run only when it is called.  Every
`require` is drawn, even one a longer path already implies, so the
graph shows each module's real dependencies.  `octocat-evil` is left
out: it requires every page it binds keys in, so it has a graph of its
own, below.

<!-- module-graph -->
```mermaid
flowchart TD
  octocat_actions[octocat-actions]
  octocat_avatar[octocat-avatar]
  octocat_core[octocat-core]
  octocat_dashboard[octocat-dashboard]
  octocat_diff[octocat-diff]
  octocat_doctor[octocat-doctor]
  octocat_edit[octocat-edit]
  octocat_image[octocat-image]
  octocat_issue[octocat-issue]
  octocat_markdown[octocat-markdown]
  octocat_mermaid[octocat-mermaid]
  octocat_pr[octocat-pr]
  octocat_repo[octocat-repo]
  octocat_search[octocat-search]
  octocat_sync[octocat-sync]
  octocat_timeline[octocat-timeline]
  octocat_user[octocat-user]
  octocat_vui[octocat-vui]
  octocat[octocat]
  octocat_actions --> octocat_core
  octocat_actions --> octocat_mermaid
  octocat_actions --> octocat_sync
  octocat_actions --> octocat_vui
  octocat_core --> octocat_image
  octocat_core --> octocat_markdown
  octocat_dashboard --> octocat_core
  octocat_dashboard --> octocat_diff
  octocat_dashboard --> octocat_issue
  octocat_dashboard --> octocat_pr
  octocat_dashboard --> octocat_sync
  octocat_dashboard --> octocat_vui
  octocat_diff --> octocat_actions
  octocat_diff --> octocat_core
  octocat_diff --> octocat_sync
  octocat_diff --> octocat_vui
  octocat_doctor --> octocat_core
  octocat_doctor --> octocat_sync
  octocat_doctor --> octocat_vui
  octocat_edit --> octocat_core
  octocat_edit --> octocat_vui
  octocat_image --> octocat_markdown
  octocat_issue --> octocat_core
  octocat_issue --> octocat_edit
  octocat_issue --> octocat_sync
  octocat_issue --> octocat_timeline
  octocat_issue --> octocat_vui
  octocat_markdown --> octocat_mermaid
  octocat_pr --> octocat_actions
  octocat_pr --> octocat_core
  octocat_pr --> octocat_diff
  octocat_pr --> octocat_edit
  octocat_pr --> octocat_sync
  octocat_pr --> octocat_timeline
  octocat_pr --> octocat_vui
  octocat_repo --> octocat_core
  octocat_repo --> octocat_diff
  octocat_repo --> octocat_markdown
  octocat_repo --> octocat_sync
  octocat_repo --> octocat_vui
  octocat_search --> octocat_actions
  octocat_search --> octocat_core
  octocat_search --> octocat_diff
  octocat_search --> octocat_issue
  octocat_search --> octocat_pr
  octocat_search --> octocat_repo
  octocat_search --> octocat_sync
  octocat_search --> octocat_user
  octocat_search --> octocat_vui
  octocat_sync --> octocat_core
  octocat_timeline --> octocat_core
  octocat_timeline --> octocat_edit
  octocat_timeline --> octocat_sync
  octocat_timeline --> octocat_vui
  octocat_user --> octocat_avatar
  octocat_user --> octocat_core
  octocat_user --> octocat_sync
  octocat_user --> octocat_vui
  octocat_vui --> octocat_core
  octocat_vui --> octocat_sync
  octocat --> octocat_actions
  octocat --> octocat_core
  octocat --> octocat_dashboard
  octocat --> octocat_doctor
  octocat --> octocat_image
  octocat --> octocat_issue
  octocat --> octocat_pr
  octocat --> octocat_repo
  octocat --> octocat_search
  octocat --> octocat_sync
  octocat --> octocat_timeline
  octocat --> octocat_user
  octocat --> octocat_vui
```
<!-- /module-graph -->

### Evil bindings

`octocat.el` loads `octocat-evil` only once Evil is on.

<!-- evil-graph -->
```mermaid
flowchart TD
  octocat_actions[octocat-actions]
  octocat_core[octocat-core]
  octocat_dashboard[octocat-dashboard]
  octocat_diff[octocat-diff]
  octocat_doctor[octocat-doctor]
  octocat_evil[octocat-evil]
  octocat_issue[octocat-issue]
  octocat_pr[octocat-pr]
  octocat_repo[octocat-repo]
  octocat_search[octocat-search]
  octocat_user[octocat-user]
  octocat_vui[octocat-vui]
  octocat[octocat]
  octocat_evil --> octocat_actions
  octocat_evil --> octocat_core
  octocat_evil --> octocat_dashboard
  octocat_evil --> octocat_diff
  octocat_evil --> octocat_doctor
  octocat_evil --> octocat_issue
  octocat_evil --> octocat_pr
  octocat_evil --> octocat_repo
  octocat_evil --> octocat_search
  octocat_evil --> octocat_user
  octocat_evil --> octocat_vui
  octocat -.-> octocat_evil
```
<!-- /evil-graph -->

## Modules

<!-- module-list -->
| Module | What it is | Requires |
|---|---|---|
| `octocat-actions` | GitHub Actions and commit checks for octocat | `octocat-core`, `octocat-mermaid`, `octocat-sync`, `octocat-vui` |
| `octocat-avatar` | Draw an avatar image as coloured ASCII art |  |
| `octocat-core` | Shared infrastructure for octocat | `octocat-image`, `octocat-markdown` |
| `octocat-dashboard` | GitHub account dashboard for octocat | `octocat-core`, `octocat-diff`, `octocat-issue`, `octocat-pr`, `octocat-sync`, `octocat-vui` |
| `octocat-diff` | Diffs, commits and comparisons for octocat | `octocat-actions`, `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-doctor` | Report on octocat's code, store and requests | `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-edit` | Edit buffer for octocat PRs and issues | `octocat-core`, `octocat-vui` |
| `octocat-evil` | Evil keybindings for octocat | `octocat-actions`, `octocat-core`, `octocat-dashboard`, `octocat-diff`, `octocat-doctor`, `octocat-issue`, `octocat-pr`, `octocat-repo`, `octocat-search`, `octocat-user`, `octocat-vui` |
| `octocat-image` | Show images uploaded to GitHub in markdown | `octocat-markdown` |
| `octocat-issue` | Issue detail view for octocat | `octocat-core`, `octocat-edit`, `octocat-sync`, `octocat-timeline`, `octocat-vui` |
| `octocat-markdown` | GitHub markdown renderer | `octocat-mermaid` |
| `octocat-mermaid` | Draw mermaid diagrams as text |  |
| `octocat-pr` | Pull Request detail view for octocat | `octocat-actions`, `octocat-core`, `octocat-diff`, `octocat-edit`, `octocat-sync`, `octocat-timeline`, `octocat-vui` |
| `octocat-repo` | Repository overview, tree, files and history for octocat | `octocat-core`, `octocat-diff`, `octocat-markdown`, `octocat-sync`, `octocat-vui` |
| `octocat-search` | Repo-wide PR, issue and commit search for octocat | `octocat-actions`, `octocat-core`, `octocat-diff`, `octocat-issue`, `octocat-pr`, `octocat-repo`, `octocat-sync`, `octocat-user`, `octocat-vui` |
| `octocat-sync` | Sync GitHub data into a local SQLite store | `octocat-core` |
| `octocat-timeline` | GitHub-style timeline for issue and PR views | `octocat-core`, `octocat-edit`, `octocat-sync`, `octocat-vui` |
| `octocat-user` | GitHub user / organization page for octocat | `octocat-avatar`, `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-vui` | vui.el helpers and components for octocat | `octocat-core`, `octocat-sync` |
| `octocat` | GitHub Client powered by the gh CLI | `octocat-actions`, `octocat-core`, `octocat-dashboard`, `octocat-doctor`, `octocat-image`, `octocat-issue`, `octocat-pr`, `octocat-repo`, `octocat-search`, `octocat-sync`, `octocat-timeline`, `octocat-user`, `octocat-vui`, `octocat-evil` (lazily) |
<!-- /module-list -->

## Updating

`make update-architecture-md` rewrites the graph and the table above
from the `require` forms in the sources, read with Emacs's own reader,
and each file's title line.  `make lint` fails when they are out of date.  The
text around them is written by hand: change it when a module's place
in the layers changes.
