# Plan: no waiting on the network

## Goal

Every key answers at once, as "Never block the UI on the network" in
docs/user-interface-conventions.md says: no command fetches and then
acts on the answer, and every fetch goes through `octocat-sync`.
Writes already do (mutations); these are the reads left.

Each step is a commit of its own, most frequent wait first.

## 1. Merge options

`octocat-pr-merge` says "Fetching merge options…" and opens the dialog
once `gh repo view` answers (`octocat-pr.el`), on every merge.

- A resource `(merge-options repo)` in the model: the `*Allowed` fields
  of `octocat-model-pr-merge-methods` and `deleteBranchOnMerge`.  Repo
  settings: `:max-age` an hour, polled slowly.
- The PR page reads it while it renders, so the dialog opens at once,
  complete.
- Not yet stored: open the dialog anyway, with no sign of a fetch: the
  method last used on the repo, else the first, and delete-branch off.
  As the options land, it updates quietly: a method not allowed becomes
  the first allowed, delete-branch follows the repo's setting.
- A method not allowed, submitted before they land or turned off since,
  is refused by `gh pr merge`: its error shows as any mutation's, and
  the message typed is kept.

## 2. Diffing a file too large for the page

`octocat-diff-open-large` asks, then fetches the merge base, the old
text and the new one in turn, and pops up a buffer when all three are
in, perhaps after the user moved on.

- Open the buffer at once, saying it is fetching, and fill it in.
- Fetch the new side alongside the merge base: it needs none.
- The merge base as a resource `(merge-base repo base head)`, kept for
  good when both are SHAs.  `octocat-diff--url-path` goes with its call.

## 3. Reactions

The reaction prompt waits on `viewer-reactions` the first time
("Fetching your reactions…", `octocat-timeline.el`).  The page could
read it as it renders, but that is a request per comment: read it for
the comment at point only, or keep the wait, which happens once an hour.
Decide when doing it.

## 4. The pull request of the branch

`M-x octocat-pr` looks the PR up with `gh pr view` before it opens
anything (`octocat.el`).  Make it a resource `(branch-pr repo branch)`,
and open the page at once when stored; else keep the message.  Opening
a page with no PR yet is more work than the wait costs.

## 5. Direct calls left

Through `octocat--run-gh`, outside the model:

- `octocat-tree--fetch-blob-sha` (`octocat-repo.el`): a file's blob at a
  ref, for its page.  A resource, kept for good at a SHA.
- `octocat-tree--proxied-url` (`octocat-repo.el`): GitHub's rendering of
  a file, read for its images' signed URLs, cached in a table of its own.
  A resource, kept a short while: the URLs expire.
- `octocat--fetch-artifact` (`octocat-actions.el`): a download the user
  asked for, written to disk.  An effect, not data: it stays.

## 6. Keep it so

A test fails on a call to `octocat--run-gh` or `octocat--gh-graphql`
outside `octocat-model.el`, `octocat-sync.el` and `octocat-core.el`,
but for those named in it (the artifact download).

## Out of scope

Local `git` runs synchronously (`octocat--current-branch`,
`octocat--head-info`, `octocat-repo--current-repo`): it takes
milliseconds and no network.  So does `gh --version` in the doctor.
