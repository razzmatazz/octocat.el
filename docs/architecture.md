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
- **Shared parts of pages**: `octocat-diff`, `octocat-edit`,
  `octocat-timeline`.
- **Pages**: one module per kind of page, such as `octocat-pr`,
  `octocat-issue` or `octocat-repo`, requiring the pages they link to.
  `octocat-search` sits above the pages its results open.
- **`octocat-evil`**: Evil bindings, loaded only once Evil is on.  It
  requires the pages it binds keys in, which `octocat.el` has loaded
  by then.

Requires must not form a cycle.  Where a lower module calls into a
higher one, it does so through a variable or hook whose default the
higher module sets, or through a `declare-function` (see AGENTS.md).

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
  octocat_avatar[octocat-avatar]
  octocat_checks[octocat-checks]
  octocat_commit[octocat-commit]
  octocat_compare[octocat-compare]
  octocat_core[octocat-core]
  octocat_diff[octocat-diff]
  octocat_doctor[octocat-doctor]
  octocat_edit[octocat-edit]
  octocat_image[octocat-image]
  octocat_issue[octocat-issue]
  octocat_job[octocat-job]
  octocat_markdown[octocat-markdown]
  octocat_mermaid[octocat-mermaid]
  octocat_pr_diff[octocat-pr-diff]
  octocat_pr[octocat-pr]
  octocat_repo[octocat-repo]
  octocat_run[octocat-run]
  octocat_search[octocat-search]
  octocat_sync[octocat-sync]
  octocat_timeline[octocat-timeline]
  octocat_user[octocat-user]
  octocat_vui[octocat-vui]
  octocat_workflow[octocat-workflow]
  octocat[octocat]
  octocat_checks --> octocat_core
  octocat_checks --> octocat_sync
  octocat_checks --> octocat_vui
  octocat_commit --> octocat_checks
  octocat_commit --> octocat_core
  octocat_commit --> octocat_diff
  octocat_commit --> octocat_sync
  octocat_commit --> octocat_vui
  octocat_compare --> octocat_core
  octocat_compare --> octocat_diff
  octocat_compare --> octocat_sync
  octocat_compare --> octocat_vui
  octocat_core --> octocat_image
  octocat_core --> octocat_markdown
  octocat_diff --> octocat_core
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
  octocat_job --> octocat_core
  octocat_job --> octocat_sync
  octocat_job --> octocat_vui
  octocat_markdown --> octocat_mermaid
  octocat_pr_diff --> octocat_core
  octocat_pr_diff --> octocat_diff
  octocat_pr_diff --> octocat_edit
  octocat_pr_diff --> octocat_sync
  octocat_pr_diff --> octocat_timeline
  octocat_pr_diff --> octocat_vui
  octocat_pr --> octocat_checks
  octocat_pr --> octocat_commit
  octocat_pr --> octocat_core
  octocat_pr --> octocat_edit
  octocat_pr --> octocat_sync
  octocat_pr --> octocat_timeline
  octocat_pr --> octocat_vui
  octocat_repo --> octocat_commit
  octocat_repo --> octocat_core
  octocat_repo --> octocat_markdown
  octocat_repo --> octocat_sync
  octocat_repo --> octocat_vui
  octocat_run --> octocat_core
  octocat_run --> octocat_job
  octocat_run --> octocat_mermaid
  octocat_run --> octocat_sync
  octocat_run --> octocat_vui
  octocat_search --> octocat_commit
  octocat_search --> octocat_core
  octocat_search --> octocat_issue
  octocat_search --> octocat_pr
  octocat_search --> octocat_repo
  octocat_search --> octocat_sync
  octocat_search --> octocat_vui
  octocat_search --> octocat_workflow
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
  octocat_workflow --> octocat_core
  octocat_workflow --> octocat_run
  octocat_workflow --> octocat_sync
  octocat_workflow --> octocat_vui
  octocat --> octocat_checks
  octocat --> octocat_commit
  octocat --> octocat_compare
  octocat --> octocat_core
  octocat --> octocat_doctor
  octocat --> octocat_image
  octocat --> octocat_issue
  octocat --> octocat_job
  octocat --> octocat_pr
  octocat --> octocat_pr_diff
  octocat --> octocat_repo
  octocat --> octocat_run
  octocat --> octocat_search
  octocat --> octocat_sync
  octocat --> octocat_timeline
  octocat --> octocat_user
  octocat --> octocat_vui
  octocat --> octocat_workflow
```
<!-- /module-graph -->

### Evil bindings

`octocat.el` loads `octocat-evil` only once Evil is on.

<!-- evil-graph -->
```mermaid
flowchart TD
  octocat_checks[octocat-checks]
  octocat_commit[octocat-commit]
  octocat_compare[octocat-compare]
  octocat_core[octocat-core]
  octocat_diff[octocat-diff]
  octocat_doctor[octocat-doctor]
  octocat_evil[octocat-evil]
  octocat_issue[octocat-issue]
  octocat_job[octocat-job]
  octocat_pr_diff[octocat-pr-diff]
  octocat_pr[octocat-pr]
  octocat_repo[octocat-repo]
  octocat_run[octocat-run]
  octocat_search[octocat-search]
  octocat_user[octocat-user]
  octocat_vui[octocat-vui]
  octocat_workflow[octocat-workflow]
  octocat[octocat]
  octocat_evil --> octocat_checks
  octocat_evil --> octocat_commit
  octocat_evil --> octocat_compare
  octocat_evil --> octocat_core
  octocat_evil --> octocat_diff
  octocat_evil --> octocat_doctor
  octocat_evil --> octocat_issue
  octocat_evil --> octocat_job
  octocat_evil --> octocat_pr
  octocat_evil --> octocat_pr_diff
  octocat_evil --> octocat_repo
  octocat_evil --> octocat_run
  octocat_evil --> octocat_search
  octocat_evil --> octocat_user
  octocat_evil --> octocat_vui
  octocat_evil --> octocat_workflow
  octocat -.-> octocat_evil
```
<!-- /evil-graph -->

## Modules

<!-- module-list -->
| Module | What it is | Requires |
|---|---|---|
| `octocat-avatar` | Draw an avatar image as coloured ASCII art |  |
| `octocat-checks` | Check-run detail view for octocat | `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-commit` | Commit detail view for octocat | `octocat-checks`, `octocat-core`, `octocat-diff`, `octocat-sync`, `octocat-vui` |
| `octocat-compare` | Compare view for octocat | `octocat-core`, `octocat-diff`, `octocat-sync`, `octocat-vui` |
| `octocat-core` | Shared infrastructure for octocat | `octocat-image`, `octocat-markdown` |
| `octocat-diff` | Diff rendering for octocat | `octocat-core`, `octocat-vui` |
| `octocat-doctor` | Report on octocat's code, store and requests | `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-edit` | Edit buffer for octocat PRs and issues | `octocat-core`, `octocat-vui` |
| `octocat-evil` | Evil keybindings for octocat | `octocat-checks`, `octocat-commit`, `octocat-compare`, `octocat-core`, `octocat-diff`, `octocat-doctor`, `octocat-issue`, `octocat-job`, `octocat-pr`, `octocat-pr-diff`, `octocat-repo`, `octocat-run`, `octocat-search`, `octocat-user`, `octocat-vui`, `octocat-workflow` |
| `octocat-image` | Show images uploaded to GitHub in markdown | `octocat-markdown` |
| `octocat-issue` | Issue detail view for octocat | `octocat-core`, `octocat-edit`, `octocat-sync`, `octocat-timeline`, `octocat-vui` |
| `octocat-job` | Job detail view for octocat | `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-markdown` | GitHub markdown renderer | `octocat-mermaid` |
| `octocat-mermaid` | Draw mermaid diagrams as text |  |
| `octocat-pr-diff` | PR diff view for octocat | `octocat-core`, `octocat-diff`, `octocat-edit`, `octocat-sync`, `octocat-timeline`, `octocat-vui` |
| `octocat-pr` | Pull Request detail view for octocat | `octocat-checks`, `octocat-commit`, `octocat-core`, `octocat-edit`, `octocat-sync`, `octocat-timeline`, `octocat-vui` |
| `octocat-repo` | Repository overview, tree, files and history for octocat | `octocat-commit`, `octocat-core`, `octocat-markdown`, `octocat-sync`, `octocat-vui` |
| `octocat-run` | Workflow run detail view for octocat | `octocat-core`, `octocat-job`, `octocat-mermaid`, `octocat-sync`, `octocat-vui` |
| `octocat-search` | Repo-wide PR, issue and commit search for octocat | `octocat-commit`, `octocat-core`, `octocat-issue`, `octocat-pr`, `octocat-repo`, `octocat-sync`, `octocat-vui`, `octocat-workflow` |
| `octocat-sync` | Sync GitHub data into a local SQLite store | `octocat-core` |
| `octocat-timeline` | GitHub-style timeline for issue and PR views | `octocat-core`, `octocat-edit`, `octocat-sync`, `octocat-vui` |
| `octocat-user` | GitHub user / organization page for octocat | `octocat-avatar`, `octocat-core`, `octocat-sync`, `octocat-vui` |
| `octocat-vui` | vui.el helpers and components for octocat | `octocat-core`, `octocat-sync` |
| `octocat-workflow` | Workflow detail view for octocat | `octocat-core`, `octocat-run`, `octocat-sync`, `octocat-vui` |
| `octocat` | GitHub Client powered by the gh CLI | `octocat-checks`, `octocat-commit`, `octocat-compare`, `octocat-core`, `octocat-doctor`, `octocat-image`, `octocat-issue`, `octocat-job`, `octocat-pr`, `octocat-pr-diff`, `octocat-repo`, `octocat-run`, `octocat-search`, `octocat-sync`, `octocat-timeline`, `octocat-user`, `octocat-vui`, `octocat-workflow`, `octocat-evil` (lazily) |
<!-- /module-list -->

## Updating

`make update-architecture-md` rewrites the graph and the table above
from the `require` forms in the sources, read with Emacs's own reader,
and each file's title line.  `make lint` fails when they are out of date.  The
text around them is written by hand: change it when a module's place
in the layers changes.
