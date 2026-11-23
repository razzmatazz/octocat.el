# Plan: improving PR reviews

[pr-reviews.md](pr-reviews.md) built drafting, replying, editing,
resolving and submitting on the PR diff.  This plan collects what is
left: its unfinished steps, and the parts of GitHub's review model
octocat doesn't show yet.  It starts with that model, as everything
below follows from it.

## GitHub's review model

### Three kinds of comment on a PR

| Kind | Attached to | REST |
|---|---|---|
| Issue comment | the PR as an issue (Conversation tab); no code | `issues/N/comments` |
| Review | the PR, and the head commit it was submitted on | `pulls/N/reviews` |
| Review comment (inline) | a review, and a place in a diff: file, line, side, commit | `pulls/N/comments` |

Commit comments (`commits/SHA/comments`) are a fourth kind, on a bare
commit, outside any PR; a PR's pages mostly ignore them.

### Reviews

A review has an author, a body (possibly empty), a `commit_id` and a
state:

- `PENDING`: a draft only its author sees; at most one per user per PR.
- `COMMENTED`, `APPROVED`, `CHANGES_REQUESTED`: once submitted.
- `DISMISSED`: an approval or change request withdrawn later.

Every inline comment belongs to a review.  GitHub's "Add single comment"
is a `COMMENTED` review holding that one comment, submitted at once.

The PR's verdict, GraphQL `reviewDecision`, comes from each reviewer's
latest approving or change-requesting review, under the branch
protection rules.  Review requests (`requested_reviewers`) are a
separate list: submitting a review clears your request, and the author
can request it again.

### Inline comments have two parents

```
            Review (who, when, verdict)
               │
   ┌───────────┼───────────┐
 comment A   comment B   comment C
   │                       │
 Thread 1 (file.el:42)   Thread 2 (other.el:7)
   ├ comment A  ← root
   ├ reply (in Bob's later review)
   └ reply (in Carol's review)
```

- The **review** groups comments by submission: who, when, which verdict.
- The **thread** groups them by place in the code.  Its root comment
  holds the anchor; replies point at it by `in_reply_to_id`, so threads
  are flat.  Each reply belongs to the review its author was writing.

GraphQL has both views, `reviews { comments }` and
`reviewThreads { comments }`.  Only a thread has `isResolved` and
`isOutdated`, and only GraphQL can resolve one.

### Anchoring

A comment is placed on a diff, not on a file:

- `path`; `side`: `RIGHT` (new side: added or context lines) or `LEFT`
  (old side: removed lines);
- `line`, and `start_line`/`start_side` for a range;
- `subject_type`: `line`, or `file` for a comment on the whole file;
- `commit_id`: the commit it maps to now; `original_commit_id` and
  `original_line`: where it was written, never changing;
- `diff_hunk`: the diff around it when it was written;
- `position`: the legacy offset in the diff, deprecated except on
  commit comments.

### When the head moves

GitHub carries each comment forward to the new head.  If its lines are
still in the diff, `commit_id` and `line` follow.  If not, the thread is
**outdated**: `line` is null, and only the `original_*` fields and
`diff_hunk` say where it was; the web UI shows it collapsed, with that
hunk.  A review's `commit_id` stays on the head it reviewed, which is
how an approval goes stale, and how branch protection can dismiss it on
push.

### In short

A review is a verdict on a commit.  A review comment is a note on one
side of one line of one diff, in one review and one thread.  A thread
is that line's conversation, which can be resolved and can go outdated.

## Where octocat stands

- The PR, commit and compare pages show their files as Tree and Patch
  only.  A changed file opens in the file viewer, in a buffer of its
  origin's (`octocat-tree--file-origin`), on its Diff view; ✉ and a
  link to lines open it at them (`octocat-diff-use-link`).  Item 1
  below is done.
- A PR's file buffer (`octocat-pr-file-diff`) draws the file's threads
  in its diff and takes the review commands, through the PR's backend
  (`octocat-pr-diff--comment-backend`); a line shows the pending
  review's drafts, with a button to the PR's files, where it is
  submitted or discarded.  Its Code and Blame are at the PR's head.
- The Tree counts each file's unresolved conversations, `✉ N`,
  leaving out outdated ones and drafts, as GitHub's tree does
  (`octocat-pr-diff--open-threads`).
- "Review Comments" on the PR's files lists the comments no diff
  places (`octocat-pr-diff--unplaced`), as outdated ones, with no hunk
  and no sign of where they were.  The thread query asks for neither
  `originalLine` nor `diffHunk`.
- The timeline shows a review as a box with its body; its inline
  comments aren't listed there or linked to.
- Nothing shows which commit a review was on, so a stale approval
  looks like a current one.

## Improvements

### 1. Pages of changes drop their Diff view; review in the file viewer

The Diff view goes, outright: a PR's Files changed page, a commit page
and a comparison show just Tree and Patch, and the pill reads
`Tree | Patch` on every one.  A change is read in the file viewer, a
file at a time, as GitHub's single-file view, and reviewing moves there:
opening a changed file from the PR shows its diff with the PR's
conversations, and the review commands work there.

**One buffer per file and what its Diff compares.**  Today a file
buffer is keyed by repo, ref and path, `*acme/rocket@REF:src/main.rs*`,
and the change it diffs is a buffer-local, `octocat-tree--file-change`,
that the next opening overwrites.  The key gains the origin:

| Opened from | Buffer | Diff shows | Comments |
|---|---|---|---|
| tree browser, link, `C-c C-j` | `*acme/rocket@main:src/main.rs*` | the file's last commit | none |
| PR #128's Tree or ✉ | `*acme/rocket#128:src/main.rs*` | the PR, base to head | PR #128's threads, review commands |
| a commit's Tree | `*acme/rocket@3f9c2a1:src/main.rs*` | that commit | its commit comments, later (step 9 of pr-reviews.md) |
| a comparison's Tree | `*acme/rocket@main...topic:src/main.rs*` | that comparison | none |

A PR's buffer is keyed by its number, not its head SHA: a push updates
the same buffer, as it does the PR's Files changed page, and the review
belongs to the PR, its threads carried forward across pushes.  Code and
Blame there show the file at the PR's current head.

**What moves into the PR's file buffer:**
- the file's threads, placed in its diff as the PR's Diff places them
  (`octocat-diff--file` with the file's comments);
- `C-c C-a` on a line, a region or the file's heading, replying,
  `C-c C-e`, resolving: the buffer sets `octocat-diff--comment-backend`
  to the PR's, as the PR's Files changed page does;
- `[Hide comments (N)]`, for the file's conversations;
- a line with the pending review's count and a link back to the PR's
  Files changed page, `Your review: 2 pending  [Submit on the PR]`:
  submitting and discarding stay there, in one place.

**What stays on the PR's Files changed page:** the Tree with its ✉,
the Patch, "Review Comments" (the threads no file's diff can place, as
outdated ones), and `[Submit review]` / `[Discard review]`.

**What opens the file buffer:**
- RET on a changed file in the PR's Tree, on its Diff;
- ✉, at the file's first conversation;
- a link to lines of a PR's files (`…/pull/128/files#diff-HASHR12`), at
  them;
- the timeline's review comments (3 below), at their thread.

Both pages read one resource, `pr-review-threads`, so a reply, resolve
or draft in a file buffer updates the Tree's ✉ and the pending count
at once.

**What is stored, and what the model and sync need first.**  A PR's
data is in four resources, each keyed by `(repo number)` but the last:

| Resource | From | Holds |
|---|---|---|
| `pr` | GraphQL | the PR page's fields |
| `pr-files` | REST `pulls/N/files`, paginated | the changed files with their patches, at most 3000; no head SHA |
| `pr-review-threads` | GraphQL, paginated | `headRefOid`, your pending review, every thread |
| `merge-base (repo base head)` | REST | the diff's old side, for files too large to diff |

`commit (repo sha)` and `compare (repo base head)` hold their files the
same way, kept for good between two SHAs.  The file's text and blame
are `file-text`, `file-blob` and `blame`, keyed by `(repo ref path)`.
A comment's mutation edits `pr-review-threads` at once and invalidates
it, `pr` and `timeline-events`.

What has to change:

1. **The change becomes a reference, not a snapshot.**  The file
   viewer's `octocat-tree--file-change` holds the file's entry, patch
   included, from when it was opened.  A commit's never changes, but a
   PR buffer follows pushes, so it would show a stale patch.  The buffer
   holds its origin instead, `(pr REPO NUMBER)`, `(commit REPO SHA)` or
   `(compare REPO BASE HEAD)`.  The page reads the origin's resource and
   takes the file's entry from it each render, with a pure lookup
   (`octocat-model-origin-file ORIGIN DATA PATH`).  Code and Blame read
   the ref the same way: a PR's is the `headRefOid` of
   `pr-review-threads`, not the SHA it had when opened.
2. **The PR's comment backend takes its PR as an argument.**  Its
   functions (`octocat-pr-diff--add`, `--reply`, `--edit`, `--resolve`,
   `octocat-pr-diff--threads`) read the PR from the Files changed page's
   buffer-locals, `octocat--pr-diff-repo` and `octocat--pr-diff-number`,
   in 16 places.  They take `(repo number)` instead, as "Functional core"
   in CONTRIBUTING.md asks, so a file buffer and the Files changed page
   call them alike.
3. **The head and the files can disagree for one poll.**  `pr-files` has
   no head SHA, and `headRefOid` comes from the separate threads fetch,
   so just after a push the patch can be the new head's while the
   threads' lines are the old one's.  The Files changed page lives with
   this today, and the next poll settles it.  In one file's diff it is
   more visible, so if it shows in use, a new `headRefOid` in
   `pr-review-threads` invalidates `pr-files`.
4. **Nothing new to fetch.**  A file buffer reads the same resources as
   the Files changed page, so several buffers of one PR share one fetch
   and one poll.  A PR buffer's `C-c C-o` and copied URL name the PR's
   view of the file, `…/pull/N/files#diff-HASH`, with the lines at point.
   A commit buffer's comments, later, come from `commit-comments (repo
   sha)`, which exists.

**Moving between files:** no keys for the next or previous changed
file; `q` goes back to the Tree, whose ✉ show where to go next.

**Steps:**
1. **Done.**  Drop the Diff view of the PR, commit and compare pages, first and on
   its own: `octocat-diff--views` becomes `(tree patch)`, so the pill
   and `octocat-diff-cycle-view` show only those; `octocat-diff-open-view`
   and the Files section's `[Expand all]` and filter go.  The pages open
   on the Tree; ✉ and a link to lines open the file viewer's Diff at
   them, as RET on a Tree file does today.  "Review Comments" and
   `[Submit review]` / `[Discard review]` move under the Tree.  Until
   step 4, the PR's threads show only in "Review Comments", and new
   drafts can't be added.  Screenshots, CHANGELOG.

   Everything left without a caller goes, with its tests and
   docstring mentions; nothing is kept dormant for later steps, which
   recover what they need from git history, reshaped for the file
   buffer:
   - the Diff view: `octocat-diff--files`, `octocat-diff-files-section`,
     `octocat-diff--file-at`, `octocat-diff-open-view`,
     `octocat-diff-show-at` (✉ opens the file viewer instead),
     `octocat-diff--line-count`, the `diff` branches of
     `octocat-diff--path-at-point` and `octocat-diff-show-view`;
   - the filter, set only from the Diff's heading: `octocat-diff--filter`,
     `octocat-diff-filtered`, `-set-filter`, `--ask-filter`,
     `--filter-candidates`, `--filter-default`, `--filter-buttons`,
     `-filter-line`, and the `filter` arguments of the three pages;
   - comments in a diff, which only the Diff drew: the `comments`
     argument of `octocat-diff--file` and what places them
     (`octocat-diff--thread`, `--folded-body`, `--placed-count`,
     `octocat-diff-by-path`), hiding them (`octocat-diff--hide-comments`,
     `-toggle-comments`, `--comments-switch`, the pages' `hide-comments`),
     and adding or editing on a diff line (`octocat-diff-add-comment`,
     `-edit-comment`, `-comment-at-point`, `--backend`, `--anchors`,
     `--range`, `--mark-lines`, the `C-c C-a`/`C-c C-e` bindings,
     Evil's too);
   - the comment backend, read only by those: `octocat-diff--comment-backend`,
     `octocat-pr-diff--comment-backend` and its `octocat-pr-diff--add`,
     `--reply`, `--edit`, `--resolve`, and their sync mutations if
     nothing else submits them;
   - whatever these alone called, found by a compile and
     `make lint` after each removal.

   What still has callers stays: `octocat-diff--file` for the file
   viewer's Diff, `octocat-diff--line-anchor` and `--url-fragment` for
   copied URLs (from the file viewer only once the Diff is gone, so check
   each page's), `octocat-vui-expand-all-button` (the Actions page),
   "Review Comments" (a plain timeline), submitting and discarding the
   review, and `octocat-diff-cycle-view` over the two views left.
2. **Done.**  The model: the origin lookup and the PR's ref from it.
   No visible change; tests.
3. **Done.**  Key file buffers by origin, which names them and replaces
   the change snapshot.  Whether the origin removed the file, which
   decides the views, is read from the store, where the Tree found it.
4. **Done.**  A PR origin's Diff draws the PR's threads and takes the
   review commands, with the pending line, bringing back from history
   what step 1 removed, the comment backend now taking `(repo number)`.
   `[Hide comments (N)]` counts the file's conversations; matching ✉'s
   open count is item 2's.  Screenshot of a file with a thread and a
   draft.
5. **Done.**  Route the entry points above to the PR's file buffer, at
   the thread or lines: the Tree, ✉ and links.  The timeline's review
   comments are item 4's.

### 2. Unfinished steps of pr-reviews.md

As listed under its "Steps": the `line-prefix` gutter on commented
ranges, the Comments pill's open/resolved count, the pending review in
the conversation timeline, the warning when the head moved under a
pending review, and step 9, comments on the commit page, which go in
the commit's file buffers (1 above).

The Comments pill is the Diff's `[Hide comments (N)]` button, which
moves into the PR's file buffers (1 above).  Its open count should match
the Tree's ✉, so it counts with `octocat-pr-diff--open-threads`.

### 3. Outdated threads show where they were

Add `originalLine originalStartLine diffHunk (originalCommit oid)` to
`octocat-model--review-thread-fields`.  In "Review Comments", an
outdated thread's heading reads `path:L12  Outdated` and its box opens
with the `diff_hunk`, drawn as a diff, ending at the original line, as
GitHub does.  RET on the heading opens the original commit's buffer of
that file (1 above) at that line, as a line link to it does (see
[github-line-links.md](github-line-links.md)).

### 4. A review's comments from the timeline

The timeline's review item lists its inline comments, one line each:
`path:L12  first line of the body`.  RET on one opens the PR's buffer of
that file (1 above) at its thread, its lines as `(diff HASH FROM TO)`
as `octocat-pr-diff--open-threads` builds them.  This needs the
review's comments with their thread's anchor:
`reviews { comments { … path line originalLine } }` in the timeline
query, or a lookup in `pr-review-threads` by comment id.

### 5. Which commit a review was on

On the PR page's reviewers list and on the timeline's review item, a
review on an older head than the current one says so: `approved at
abc1234, 3 commits ago`.  This needs `commit { oid }` on each review,
compared with `headRefOid`; the count comes from the PR's commits.

### 6. Beyond comments

From pr-reviews.md's "Beyond comments", each small and independent:

- viewed files (`markFileAsViewed`, `files.viewerViewedState`): the
  Diff's Files heading goes with it, so a viewed file is marked on its
  Tree row, with "3/12 viewed" above the Tree, and toggled in its file
  buffer;
- re-requesting a review (`requestReviews` with `union: true`);
- dismissing a review (`dismissPullRequestReview`, with a message);
- suggested changes: a ```` ```suggestion ```` block prefilled from
  the region, then drawn as a diff in its box.

## Order

1 first, as the others land in the file viewer it builds.  Then 3 and
5: each is one query field and a pure function for what it draws, with
fixtures and screenshots (`make screenshots`; there is no
`docs/usage.md` to update any more).  Then 4, then the rest of 2, then
6.  Each new key needs asking first (see AGENTS.md).
