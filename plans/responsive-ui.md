# Plan: no waiting on the network

## Goal

Every key answers at once where it is used often, as "Never block the
UI on the network" in docs/user-interface-conventions.md says.  A
one-off lookup may wait, with a message, as long as it acts only if the
user is still there.  Writes already answer at once (mutations); these
are the reads left.

Each step is a commit of its own, most frequent wait first.

## 1. Merge options

`octocat-pr-merge` says "Fetching merge options…" and opens the dialog
once `gh repo view` answers (`octocat-pr.el`), on every merge.

- A resource `(merge-options repo)` in the model: the `*Allowed` fields
  of `octocat-model-pr-merge-methods` and `deleteBranchOnMerge`.  Repo
  settings: `:max-age` an hour, polled slowly.  `octocat-pr--merge-allowed`
  moves into the model as its `:parse`.
- The PR page reads it while it renders, so the dialog opens at once,
  complete.  The store outlives the session and serves stale data, so
  only a repo's first merge finds it missing.
- Not yet stored: open the dialog anyway, with no sign of a fetch, as
  `octocat-pr--merge-initial-method` picks: the method last used on the
  repo, else none, so a merge is never the accidental choice; and
  delete-branch off.  As the options land, it updates quietly: a method
  not allowed is unpicked (or picked, if the only one), delete-branch
  follows the repo's setting.
- The dialog is an edit buffer, not a page: it adds a buffer-local
  function to `octocat-sync-change-functions` that calls
  `octocat-pr--merge-update`.  Document this in the conventions.
- A method not allowed, submitted before they land or turned off since,
  is refused by `gh pr merge`: its error shows as any mutation's, and
  the message typed is kept.

## 2. Diffing a file too large for the page

`octocat-diff-open-large` asks, then fetches the merge base, the old
text and the new one in turn, and pops up a buffer when all three are
in, perhaps after the user moved on.

- Open the buffer at once, saying it is fetching, and fill it in.
- Fetch the new side alongside the merge base: it needs none.
- The merge base as a resource `(merge-base repo base head)`, fetched
  with `octocat-sync-get` each time: the base is a branch, so it is not
  kept.  `octocat-diff--url-path` goes with its call.

## 3. Small fixes to waits that stay

These wait once in a while and have no sensible default, so they keep
fetching, then acting.  Each acts only if the user is still where they
pressed the key (`octocat--still-selected-p`).

- `M-x octocat-pr` (`octocat.el`): opens the branch's PR even after the
  user moved on.  It stays a direct `gh pr view`: that finds the PR from
  the clone's directory and upstream, and must not be served stale.
- `octocat-user` with no login (`octocat.el`): waits on `viewer` the
  first time only.
- The reaction prompt (`octocat-timeline.el`) waits on the first
  reaction to each comment; it checks already.  Review comments come
  from GraphQL: add `viewerHasReacted` to
  `octocat-model--review-comment-fields`, and the prompt reads it from
  the comment, so theirs never wait.
- The filter and value prompts (`octocat-vui-list--stored`) wait on a
  repo's first use; they check already.

## 4. Direct calls left

Through `octocat--run-gh`, outside the model.  The first two run as a
page draws its images, not from a key: they move for step 5's rule.

- `octocat-tree--fetch-blob-sha` (`octocat-repo.el`): a file's blob at a
  ref, for its page.  A resource, kept for good at a SHA.
- `octocat-tree--proxied-url` (`octocat-repo.el`): GitHub's rendering of
  a file, read for its images' signed URLs, cached in a table of its own
  that never expires, though signed URLs do.  A resource, kept a short
  while.
- `octocat--fetch-artifact` (`octocat-actions.el`): a download the user
  asked for, written to disk.  An effect, not data: it stays.
- `octocat-pr` (`octocat.el`): stays, see step 3.

## 5. Keep it so

A test fails on a call to `octocat--run-gh` or `octocat--gh-graphql`
outside `octocat-model.el`, `octocat-sync.el` and `octocat-core.el`,
but for those named in it (the artifact download, `octocat-pr`).  It
reads the files with Emacs's reader and walks the forms, not a regex.

## Out of scope

Local `git` runs synchronously (`octocat--current-branch`,
`octocat--head-info`, `octocat-repo--current-repo`): it takes
milliseconds and no network, as do search's `git` processes, `diff`
in `octocat-diff--show-large` and `gh --version` in the doctor.

Reading ahead what a rare key needs: the viewer's reactions to issue
and PR comments, and the prompts' candidates.  It would cost a request
on every page open for a wait that comes once in a while.
