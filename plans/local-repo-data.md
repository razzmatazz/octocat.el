# Plan: Serve tree, file and blame data from the local clone

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

The resources split by how they name their data:

| Resource | Named by | Local source | Safe? |
|---|---|---|---|
| `tree-dir (repo sha)` | tree SHA | `git ls-tree SHA` | Yes: same SHA, same content |
| `blob (repo sha)` | blob SHA | `git cat-file blob SHA` | Yes |
| `tree-files (repo sha)` | tree SHA | `git ls-tree -r SHA` | Yes |
| `file-text`, `file-blob`, `file-bytes` at a SHA ref | commit SHA + path | `git cat-file blob REF:PATH` | Yes |
| `tree-path`, `repo-head`, `file-blob` at a branch | branch name | `origin/BRANCH` | No: can be behind GitHub |
| `tree-commits` (last commit per entry) | commit + dir | `git log` | Partly: no GitHub login |
| `blame (repo commit path)` | commit + path | `git blame --porcelain` | Partly: no GitHub login |

Only the SHA-named rows are exact. They are also the bulk of what the
tree and file pages fetch, so phase 1 covers just those.

The sync store already keeps SHA-named resources for 30 days
(`octocat-model--fixed-max-age`), so the gain is on first views: a new
directory, a new file, a newly pushed commit.

## Phase 1: SHA-named resources

### Finding the clone for a repo

Today `octocat-repo--local-dir-for` finds the clone only from
`default-directory`, so a page opened from elsewhere has none. Add a
lookup by repo in `octocat-core`:

- `octocat-local-clone (repo)`: the clone's root, or nil.
- It is filled whenever a page finds its clone, as
  `octocat-repo--local-dir-for` does now, and kept in memory for the
  session. It is not persisted: a directory can be moved or deleted.
- A cached entry is checked (`file-directory-p` on its `.git`) before
  use and dropped when gone.
- A defcustom `octocat-use-local-clone` (default t) turns the feature
  off.

Not in scope: searching `project-known-project-roots` for matching
remotes. It could come later if the session cache proves too narrow.

### The `:local` resource property

Add `:local` to `octocat-sync-define-resource`: a function of DONE that
reads the resource from the clone. `octocat-sync--fetch` calls it
first when the repo has a clone. If it answers `(error . _)`, for
example because the object is missing, the normal `:fetch`/`:gh` path
runs. The page never sees the local error.

```elisp
(octocat-sync-define-resource tree-dir (repo sha)
  :max-age octocat-model--fixed-max-age
  :local (octocat-model--local repo (list "ls-tree" "-z" "--long" sha)
                               #'octocat-model--parse-ls-tree)
  :gh ...)
```

`octocat-sync` stays independent of git. The `:local` function is
built in `octocat-model`, where the resources live, from one helper
there that runs git asynchronously with `make-process` and calls DONE
with the parsed result or an error. Parsing functions are pure (string
→ table) and unit-tested on fixed `git` output.

A local answer is stored like a fetched one, since the content is
identical. `:local` is then only another way to fetch, and snapshots,
pages and polling need no changes. The cost is that blobs are kept
twice, in git and in the store, as they already are when fetched from
GitHub.

A local read does not count against `octocat-sync-max-requests`. If
the fallback to GitHub is needed, it is queued normally.

### Keeping the data the same shape

- `tree-dir`: `git ls-tree -z --long` gives mode, type, SHA, size and
  name. Map these to GitHub's `path`, `type` (`blob`/`tree`/`commit`
  for submodules), `sha`, `size` and `mode`. Sort order follows the
  page's own sort (`octocat-tree--sorted-entries`), not git's.
- `blob`: GitHub returns base64 `content`. Return the same, base64 of
  the raw bytes, so `octocat-model-blob-content` and every reader stay
  unchanged. Read with `coding-system-for-read` `binary`.
- `tree-files`: `git ls-tree -r -z` → the same (PATH . BLOB-SHA) table.

### Missing or partial objects

- Check the object exists before reading it (`git cat-file -e SHA`, or
  one `cat-file --batch` call that reports `missing`).
- In a partial clone (`--filter=blob:none`), a missing blob makes git
  fetch it from origin on its own, which is network I/O again and can
  prompt for credentials. Run git with `GIT_NO_LAZY_FETCH=1` (git
  2.44+). On older git, skip the local path for blobs when
  `remote.origin.promisor` is set.
- A shallow clone answers "missing" for old objects, which falls back
  to GitHub.

### Tests

- Model tests: each parser on recorded `git` output, including
  submodule entries, names with spaces and newlines (`-z`), and binary
  blobs.
- Sync tests: `:local` answering, `:local` failing and falling back,
  and no clone at all, which must call only `:gh`.
- An integration test that runs `git init` in a temp dir, commits two
  files, and reads `tree-dir` and `blob` through the resource.
- Screenshots: fixtures must not pick up the developer's checkout.
  Bind `octocat-use-local-clone` to nil in `test/screenshots/`.

## Phase 2: branch-named resources

Phase 2 is optional and should be measured after phase 1.

Phase 1 still makes one round trip per page to turn a branch into SHAs
(`repo-head`, `tree-path`, `file-blob`), so the first paint waits on
the network. To skip that wait, show the local `origin/BRANCH` right
away as an outdated snapshot, and refetch from GitHub at once. When
GitHub agrees, which is the usual case after a recent fetch, nothing
on screen changes. When it does not, the page redraws as it does on a
poll today.

This needs a way to seed a resource as stale: store it with an old
`fetched_at` or mark it invalidated, so the sync layer refetches it.
`repo-head` also carries GitHub-only fields (author login, history
`totalCount`). Seed only `tree-path` and `file-blob`, which are pure
git data, and leave `repo-head` to the network.

Never seed from the local *working tree* or local branch. The page
shows what GitHub has; unpushed work already has its own section.

## Phase 3: history-derived resources

`tree-commits` and `blame` are the slowest GitHub calls: a GraphQL
history walk per 50 entries, and server-side blame. Locally, one
`git log --name-only` walk can answer a directory's last commits, and
`git blame --porcelain` gives a file's blame in milliseconds.

The catch is `octocat-model--commit-fields`: rows show
`author.user.login`, which git does not have. Options:

1. Fill `login` as nil and show the author's name. The rows then
   change once the GitHub answer replaces them.
2. Serve ranges and SHAs locally, and fill commit details from stored
   `commit` entities when the sync store already has them.

Decide after phase 1. Blame on large files is the case most worth it.

## Files touched

- `octocat-core.el`: `octocat-local-clone`, the clone cache, defcustoms.
- `octocat-sync.el`: the `:local` property, tried first in
  `octocat-sync--fetch`.
- `octocat-model.el`: the async git helper, parsers, and `:local` on
  `tree-dir`, `blob`, `tree-files` and the SHA-ref file resources.
- `octocat-repo.el`: register the clone when a page finds it.
- Tests as above; `CHANGELOG.md`; a short section on local clones in
  `README.md`.
