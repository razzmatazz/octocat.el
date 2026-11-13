# Plan: Serve tree, file and blame data from the local clone

## Status

- Phase 1, SHA-named resources: done.
- Phase 3, `tree-commits` and the email → login lookup: done.
- Phase 3, `blame`: next.
- Phase 2, branch-named resources: not started; needs page changes
  first (see below).

## Goal

When the repo has a local clone that holds the objects a page needs,
read them with `git` and skip the GitHub round trip. On a first view,
each `gh api` call costs 300 ms to 2 s; `git cat-file` takes a few ms.

The local clone is only an accelerator. It may be missing (detached
mode, a repo never cloned, a page opened from another project), may
lack the objects (shallow or partial clone, not fetched yet), or may
be behind GitHub. In every one of those cases the resource is fetched
from GitHub as it is today. A page never shows something different
because a clone exists; it only shows it sooner.

## What can come from the clone

| Resource | Named by | Local source | Status |
|---|---|---|---|
| `tree-dir (repo sha)` | tree SHA | `git ls-tree -z --long SHA` | Done |
| `blob (repo sha)` | blob SHA | `git cat-file blob SHA` | Done |
| `tree-files (repo sha)` | tree SHA | `git ls-tree -r -z SHA` | Done |
| `file-text`, `file-blob`, `file-bytes` at a SHA ref | commit SHA + path | `git cat-file blob` of `REF:PATH` | Done |
| `tree-commits (repo commit dir sha)` | commit + dir | `git log -1` per entry | Done |
| `blame (repo commit path)` | commit + path | `git blame --porcelain` | Next |
| `tree-path` at a SHA ref | commit SHA + path | `git cat-file --batch-check` | Not started; exact, cheap to add |
| `tree-path`, `file-blob` at a branch | branch name | `origin/BRANCH` | Phase 2 |
| `repo-head` | ref + path | none | GitHub only: history `totalCount` |

The sync store keeps SHA-named resources for 30 days
(`octocat-model--fixed-max-age`), so the gain is on first views: a new
directory, a new file, a newly pushed commit.

## How it is built

### `octocat-clone`

A standalone module below `octocat-core` (it requires only `vc-git`
and built-ins) holds everything about the local clone:

- Which GitHub repo a directory is a clone of
  (`octocat-clone-current-repo`, via `vc-git-repository-url`), and its
  root (`octocat-clone-dir-for`, via `vc-git-root`).
- The checkout: unpushed commits, the tracked branch, `octocat-here`'s
  ref.
- The session's clones: `octocat-clone-add`, `-drop`, `-root`. A page
  that finds its clone adds it; it is kept in memory only, and checked
  for its `.git` before each use.
- The reads: `octocat-clone-read` checks the object with `git cat-file
  --batch-check`, then runs git and parses what it prints into GitHub's
  shape.

There is no setting to turn it off, and the timeout is a constant
(`octocat-clone-timeout`, 2 seconds).

### The `:local` resource property

A resource's `:local` is a function of DONE that reads it without the
network, nil when there is no clone. `octocat-sync--pump` starts it
first, outside `octocat-sync-max-requests`. An answer is stored as a
fetched one; `(error . _)` queues the resource for its normal fetch.
A local answer does not clear `octocat-sync--offline`.

### Why not vc for the reads

vc.el supplies `vc-git-program`, `vc-git-root` and
`vc-git-repository-url`. Its async runner, `vc-do-command` with
`async`, does not fit the reads: before Emacs 31 it mixes stderr into
the output, it calls nothing when git fails, it has no timeout, and it
runs `vc-post-command-functions` after every call. Its synchronous
reads block Emacs.

### Failures

- git runs with no terminal, `GIT_TERMINAL_PROMPT=0` and
  `GIT_NO_LAZY_FETCH=1`.
- A missing object, or one of another type, answers an error and keeps
  the clone.
- A non-zero exit, a failure to start, or a run past the timeout drops
  the clone for the session. A `git log` past the timeout keeps it: a
  long history is not a broken git.
- A partial clone is not used on git older than 2.44, which ignores
  `GIT_NO_LAZY_FETCH`; nor is a worktree's on old git, whose `.git` is a
  file.
- Stdin is closed only for a command that reads it: git can exit
  before an EOF is sent.

### Matching GitHub's data

Checked by comparing the local and GitHub answers field by field on
real repos, including rust-analyzer's merge-heavy history.

- `tree-commits` runs one `git log -1 -- PATH` per entry, eight at
  once: that is what GitHub answers. One walk of the directory's
  history differs at merges, which change a directory from every
  parent while each file in it is one parent's.
- Dates are converted to UTC (`…Z`), as GitHub gives them.
- `messageHeadline` is the first line; one past 72 characters is cut
  to 69 and "…".
- `file-blob`'s binary test is git's: a NUL in the first 8000 bytes.
  GitHub's `isBinary` may differ on rare files, such as UTF-16 text.
- git has no GitHub login. `octocat-model--commit-users` finds an
  email's user among the stored commits GitHub gave
  (`octocat-sync-find`, SQLite JSON over the resource bodies, newest
  first); a noreply email names its login. An email not seen yet has
  no user. Tree lines show no author, so nothing on screen differs,
  but the stored answer lacks that login for its 30 days.

## Phase 3: blame (next)

`git blame --porcelain` at COMMIT gives each line's commit, author
name, email and times; logins come from `octocat-model--commit-users`.

Before relying on it, compare it with GitHub's blame on several real
files, large ones and ones with moved or reformatted code, as was done
for `tree-commits`. GitHub does not document its blame options
(whitespace, moved-line detection), so its ranges may differ from
plain `git blame`. If they differ, find the git options that match, or
keep blame on GitHub.

Blame rows show the author, so an unknown login does show. Either
store such an answer as outdated and refetch from GitHub, which needs
the seeding below, or keep GitHub's blame when any author's login is
unknown.

## Phase 2: branch-named resources

Pages still wait one round trip to turn a branch into SHAs. Seeding
`tree-path` and `file-blob` from `origin/BRANCH` alone would not help:

- The tree page draws the tree only once `repo-head` is in, and uses
  its directory SHA; `tree-path` only prefetches listings, which phase
  1 already reads locally.
- The file page shows `file-blob`'s text only once it matches the blob
  SHA from `repo-head`.
- The repo root page does not read `tree-path`, and `tree-path` with no
  path answers an empty table.

So phase 2 needs:

1. In sync, a way to store a seed as outdated, so it is refetched at
   once and shows as data meanwhile. Outdated data already renders like
   fresh data, with only the mode line showing the refetch.
2. Pages that draw from the seeded `tree-path` and `file-blob` until
   `repo-head` lands, the last-commit line a grey bar meanwhile.
3. `tree-path` at a SHA ref read exactly from the clone.

Never seed from the local working tree or a local branch: the page
shows what GitHub has.

## Loose ends

- `octocat-here` still finds the clone root with
  `locate-dominating-file` (`octocat.el`), not `vc-git-root`.
- No test runs from a hanging git all the way to the `gh` fetch; each
  half is tested.
- Not in scope: finding a clone no page was opened from, by matching
  remotes in `project-known-project-roots`.

## Files

- `octocat-clone.el`: the clone, its checkout, the git runs and
  parsers.
- `octocat-sync.el`: `:local`, `octocat-sync-find`.
- `octocat-model.el`: `:local` on the resources, the GitHub-shaped
  tables, `octocat-model--commit-users`.
- `octocat-core.el`, `octocat-repo.el`, `octocat-search.el`,
  `octocat.el`: callers of `octocat-clone`.
- Tests: `test/octocat-clone-tests.el`, and the sync and model tests.
