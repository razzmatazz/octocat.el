# Plan: Use Emacs's built-in vc where it helps

## Goal

Use the parts of Emacs's built-in vc (`vc`, `vc-git`, `log-view`,
`vc-annotate`) that make octocat fit in with what users already do in
Emacs. vc ships with Emacs, so this adds no package dependency.

Running git through vc is out of scope: vc's reads block Emacs and
work on files, not on objects by SHA (see `plans/local-repo-data.md`).
So are `vc-git-mode-line-string`, `vc-git-revision-completion-table`
and `log-edit`. They are cached per file, list local rather than
GitHub branches, or don't fit octocat's markdown edit buffers.

The items are independent, and each can ship on its own, in the order
below.

## 1. `octocat-here` in vc's log and blame buffers

`octocat-here` opens a file or directory as GitHub has it. In vc's
history and blame buffers, the useful target is the commit at point.

- In `log-view-mode` (`vc-print-log`, `vc-print-root-log`),
  `log-view-current-tag` gives the commit at point.
- In `vc-annotate-mode`, `vc-annotate-extract-revision-at-line` gives
  `(REVISION . FILENAME)`.

`octocat-here` checks for these modes first, before the file and
Dired cases, and opens `(octocat-open 'commit repo sha)`. The repo
comes from the buffer's `default-directory`, as it does now.

A commit not on GitHub has no page. Before opening, check that origin
has it with `git branch --remotes --contains SHA --list 'origin/*'`,
as `octocat-repo--here-ref` does. If origin doesn't have it, signal
`user-error` "SHA isn't on GitHub".

The docstring and README section on `octocat-here` list the new
buffers. No new key binding: `octocat-here` keeps whatever binding the
user gave it.

Tests: a temp git repo with two commits, one pushed to a bare
"origin". Check that a `log-view-mode` buffer on each gives the
commit's `octocat-open` arguments, or the user error. Pull out the
target computation as a pure function of (mode, sha, known-p) so most
of the test needs no buffers.

## 2. Refresh repo pages after vc's git commands

`vc-post-command-functions` runs after every `vc-do-command`, so after
`vc-push`, `vc-pull`, `vc-checkin` and branch switches. It runs async
commands once the process ends. Each function gets COMMAND, FILES and
FLAGS, and runs in the buffer the command ran in.

Add `octocat-repo--on-vc-command`. When COMMAND is `vc-git-program`,
find the root of `default-directory` (see item 5). Then refresh each
open repo, tree and commits page whose `octocat-repo--local-dir` is
that root, quietly, as a poll would. This updates the "Local commits
not on GitHub" section after a push or commit, and follows a checkout
made with vc.

melpazoid rules out a top-level `add-hook`. Add the hook where the
repo page mounts, as `octocat-vui--listen` adds the sync hooks. The
handler does nothing when no page matches, so adding it once and
leaving it is fine.

A push's effect on GitHub (new commits on the branch) shows on the
next poll or `gr`. The hook refreshes local state only, so it starts
no GitHub fetch beyond what a refresh already does.

Tests: call the handler with a fake COMMAND, FLAGS and
`default-directory`, and check which pages it refreshes. Use a stub
refresh function, without running vc.

## 3. Run the git the user configured: `vc-git-program`

octocat runs `"git"` by name in `octocat--current-branch`,
`octocat--head-info`, `octocat-repo--git-lines`, `octocat-repo--git-ok`
and `octocat--search-git`. Use `vc-git-program` in each, so a git set
for vc (another path, or a wrapper) is used by octocat too.

- `octocat--current-branch` and `octocat--head-info` use
  `shell-command-to-string` with a command string. Move them to
  `process-file` with the program and an argument list, as
  `octocat-repo--git-lines` already does. That also drops the shell
  and its quoting.
- `octocat--search-git` checks `(executable-find "git")`. Check
  `vc-git-program` instead.
- `octocat-core` needs `(require 'vc-git)` for the variable, or a
  `defvar` plus a call that loads it. Prefer the `require`: vc-git is
  small and already loaded in most sessions.

## 4. "Local changes" in `octocat-here` via `vc-state`

When opening a file, `octocat-here` warns "local changes; lines may
differ" after `git diff --quiet REV -- PATH`. REV is origin's commit,
so the check also catches committed but unpushed changes.

`vc-state` returning `edited` is the public way to ask about
uncommitted changes, and vc caches it for visited files. But it
compares against HEAD, not origin's commit. So:

- When the buffer visits the file, ask `vc-state` first. `edited`
  means there are local changes, without running git.
- Otherwise, or when it says `up-to-date`, keep `git diff --quiet REV`
  for changes committed but not pushed.

This saves a git call in the common case of an edited file. If
profiling shows the call is not worth saving, drop this item.

## 5. Find the clone and origin with vc-git

`octocat-repo--current-repo` runs `git remote get-url origin` through
`shell-command-to-string`. `octocat-repo--local-dir-for` and
`octocat-here` find the root with `locate-dominating-file ".git"`.

- The root: `vc-git-root`. It also handles a `.git` *file* (worktrees,
  submodules) and is cached per directory.
- The origin URL: `vc-git-repository-url` with `"origin"`.

The URL parsing stays as it is. The same change is in
`plans/local-repo-data.md`, item "Finding the clone for a repo". Do it
once, in whichever plan ships first.

## 6. Check out a PR's branch locally

Octocat has no checkout command today. A PR page could offer "check
out this branch" in the clone:

- Only when the page's repo has a local clone, see item 5.
- For a branch in the same repo: `git fetch origin BRANCH`, then
  `vc-retrieve-tag ROOT BRANCH`, which runs `git checkout` through vc.
  vc then updates its own state and buffers.
- For a PR from a fork, the branch is not on origin. Use `gh pr
  checkout NUMBER` in the clone instead, which adds the fork's remote.
  `gh` is already a dependency.
- Refuse, with a message, when the working tree has uncommitted
  changes. Don't stash or force.

This needs a key binding on the PR page. AGENTS.md asks that a new
binding be agreed first, so settle the key before starting. It may
also fit as a button on the PR's branch line, per
`docs/user-interface-conventions.md`.

Tests: the decision of what to run (same repo, fork, no clone, dirty
tree) is a pure function, tested without git. One integration test
checks out a branch in a temp repo with a bare origin.

## Files touched

- `octocat.el`: `octocat-here` for items 1 and 4.
- `octocat-core.el`: `vc-git-program` in the git helpers and
  `vc-git-repository-url` in `octocat-repo--current-repo`, items 3
  and 5.
- `octocat-repo.el`: the vc hook handler, `vc-git-root`, and
  `vc-git-program` in `git-lines`/`git-ok`, items 2, 3 and 5.
- `octocat-search.el`: `vc-git-program`, item 3.
- `octocat-pr.el`: checkout, item 6.
- `CHANGELOG.md` for items 1, 2 and 6; `README.md` for items 1 and 6.
