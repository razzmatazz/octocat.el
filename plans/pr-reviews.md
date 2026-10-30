# Plan: PR reviews

## Goal

Review a PR in full from octocat, the way GitHub's "Files changed" tab
does: a review is started, collects draft comments, and is submitted (or
discarded) as one unit.  Today, only the last step exists:
`octocat-pr-diff-review` submits a review made only of a body and a
decision.

The core of the plan is the review's life on the diff page:

1. **Mark** a line, or a range of lines, in the diff; the marked lines are
   highlighted.
2. **Comment** on the mark.  The comment is a *draft*: it shows in the
   diff, boxed like the others but flagged **Pending**, visible only to me.
3. **Edit or delete** a draft as often as I like before submitting.
4. **Submit** all drafts at once, through the existing review dialog
   (`octocat-pr-diff-review`, `C-c C-r`: Comment / Approve / Request
   changes, plus a body).
5. Also **edit or delete my comments after they're submitted**, and
   **reply** to a thread, either right away or as part of the review.
6. **Resolve** a thread, or unresolve it; a resolved one folds away.
7. The same on a **commit's diff**, where comments are posted at once,
   as a commit has no reviews (see "Commit diffs").

## Where drafts live: GitHub's pending review

Drafts live on GitHub, as a pending review.  A review created without an
`event` is `PENDING`: only its author sees it, comments can be added to
it, edited and deleted, and it is submitted later with an event and a
body.  The web UI's "Start a review" / "Finish your review" uses exactly
this.  Each user has at most one pending review per PR.

- Nothing local to lose: it survives an Emacs crash, a store wipe, or a
  move to another machine.
- It works with the web UI in both directions.  A review started in the
  browser shows up in Emacs, and one started in Emacs can be finished in
  the browser.
- It fits the sync layer as it is: the pending review is a cached
  resource like any other, so the store's schema doesn't change, and
  every change to it is a mutation with an optimistic edit.
- Cost: each save of a draft is one API call, and drafting needs to be
  online.  A failed save keeps the edit buffer open with the text (as
  `octocat-edit-submit` already does), so nothing typed is lost.

`gh pr review` has no notion of a pending review, but the API it wraps
does, and `gh api` reaches it.  Checked against the live GraphQL schema
(2026-10-30):

- `PullRequestReviewState` has `PENDING`, "A review that has not yet been
  submitted".
- `AddPullRequestReviewInput.event` is optional, and leaving it out
  creates the pending review.
- `AddPullRequestReviewInput.threads` replaces the deprecated
  `comments` field.

## API surface

GraphQL (`gh api graphql`), since it covers pending reviews in full, and
we already use it widely:

| Action | Call |
|---|---|
| Read my pending review | `pullRequest.reviews(states: PENDING, first: 1)` → `id`, `comments{id databaseId body path line originalLine startLine diffSide startDiffSide replyTo{databaseId}}` |
| Start a review | `addPullRequestReview(pullRequestId, commitOID)` (no `event`) → pending review id |
| Add draft on lines | `addPullRequestReviewThread(pullRequestReviewId, path, line, side, startLine, startSide, body)` |
| Add draft reply | `addPullRequestReviewThreadReply(pullRequestReviewId, pullRequestReviewThreadId, body)` |
| Edit a comment (draft or submitted) | `updatePullRequestReviewComment(pullRequestReviewCommentId, body)` |
| Delete a comment | `deletePullRequestReviewComment(id)` |
| Submit | `submitPullRequestReview(pullRequestReviewId, event, body)` |
| Discard all drafts | `deletePullRequestReview(pullRequestReviewId)` |
| Reply right away (no review) | REST `POST pulls/N/comments/ID/replies` |
| Read threads | `pullRequest.reviewThreads` → `id isResolved isOutdated path line startLine diffSide startDiffSide subjectType viewerCanReply viewerCanResolve viewerCanUnresolve comments{...}` |
| Resolve / unresolve | `resolveReviewThread(threadId)`, `unresolveReviewThread(threadId)` |

**Checked** on a draft test PR of this repo (2026-10-30):

- `reviewThreads` returns a thread holding only my pending comment, with
  `state: PENDING` on the comment and on its `pullRequestReview`.  So
  one query reads submitted threads and drafts, and `pr-pending-review`
  needs only the review's `id` and `commitOid`.
- REST `pulls/N/comments` leaves pending comments out, and REST
  `pulls/N/reviews` lists the pending review.
- `addPullRequestReview` with no `event` creates the pending review, and
  `addPullRequestReviewThread` adds a draft to it.
- Right after `deletePullRequestReview`, `reviewThreads` still returned
  the deleted thread once; a moment later it was gone.  A mutation's
  `:edits` must therefore drop what it deleted, rather than rely on the
  refetch it triggers.

- `gh pr review` fails while a pending review exists, and posts nothing:
  "User can only have one pending review per pull request
  (addPullRequestReview)".  So whenever there is a pending review,
  submitting goes through `submitPullRequestReview` (see "Submitting");
  `gh pr review` stays only for a review with no drafts.

## Data model

The PR diff reads its comments from GitHub's own threads, GraphQL
`reviewThreads`, rather than REST `pulls/N/comments`.  REST has no thread
object, and the thread's node id is what both a draft reply
(`addPullRequestReviewThreadReply`) and resolving need.  So
`pr-review-comments` is replaced by:

```elisp
(octocat-sync-define-resource pr-review-threads (repo number)
  :fetch ...)  ; → vector of threads, paged like the timeline
(octocat-sync-define-resource pr-pending-review (repo number)
  :fetch ...)  ; → hash: id, commitOid, or :null when none
```

`octocat-diff` keeps taking comments, not threads, so the commit page,
whose REST comments have no threads, stays as it is.  Each thread is
converted to its comments in the REST shape `octocat-diff` already
draws (`path`, `line`, `start_line`, `side`, `body`, `user`, `id`,
`in_reply_to_id`, the first comment's `id` for each reply).  The
thread's own fields go on its first comment: `thread_id`, `resolved`,
`outdated`, `can_resolve`, `can_reply`.  A comment also carries its
`node_id`, and `"pending": t` for a draft.  `octocat-diff--threads` then
rebuilds GitHub's threads exactly, and placement and the "Review
Comments" fallback for outdated threads work unchanged.  The
conversion is a pure function, tested against fixture threads.

Mutations, each with `:edits` on `pr-review-threads` so the change shows
at once, `:slot 'inline'`:

- `review-draft-add (repo number anchor body)`.  It creates the pending
  review first if there is none (two calls in `:send`), so "Start a
  review" isn't a separate step.
- `review-draft-reply (repo number thread-id body)`
- `review-reply-now (repo number comment-id body)`, the REST reply.
- `review-comment-edit (repo number node-id body)`
- `review-comment-delete (repo number node-id)`
- `review-thread-resolve (repo number thread-id resolve)`
- `review-discard (repo number review-id)`
- `review-pr` grows a REVIEW-ID argument: with one, it sends
  `submitPullRequestReview`; without one, `gh pr review` as today.  Its
  `:invalidates` adds `pr-review-threads` and `pr-pending-review`.

## Long comments fold, as in the timeline

The timeline folds a comment past `octocat-timeline-comment-lines` (10)
behind a "N more lines" marker, through `octocat-vui-fold-lines`.  The
diff's comment boxes don't fold: a file's diff, boxes included, is built
as one string by `octocat-diff--patch-text`, so a box can't hold a
component.  Resolved threads that fold, and the [Resolve conversation]
buttons, need the same thing.

So a file's body becomes a list of segments.  Runs of diff lines stay
plain text, as now, and each thread placed in the diff is a component of
its own, `octocat-diff--thread`, in between.

- Each comment of a thread, the root and each reply, folds on its own
  with `octocat-vui-fold-lines`, to `octocat-timeline-comment-lines`, and
  unfolds the way a timeline comment does.  The fold marker sits behind
  the box's edge (`│`), indented like the reply it belongs to.
- A thread component is keyed by its root comment's id, so a refetch, or
  a new reply, doesn't fold back what was unfolded.
- `octocat-diff--walk` and the line anchors don't change.  Only where
  its output goes: text segments and thread components, instead of one
  string.
- The boxes keep their `octocat-comment` property, so
  `octocat-diff-toggle-comments` still rolls them in and out.  That
  needs checking, since `octocat-vui-roll` then runs over several
  components' text.
- The cost is a bigger vnode tree for a file with many threads.  The
  diff segments stay one memoised string each, and only the threads
  are components, so a large diff with few comments costs about what
  it does now.

## Resolving threads

As on GitHub, a resolved thread folds to its heading line, which reads
`@login  path:L12  Resolved by @someone`.  RET unfolds it.  An open thread
whose `can_resolve` is set ends in a **[Resolve conversation]** button,
and an unfolded resolved one in **[Unresolve conversation]**.  Both run
`review-thread-resolve`.  The thread count in the Files heading's
Comments (N) pill counts open threads first: `Comments (4 open, 2
resolved)`.

## Line identity in the diff

`octocat-diff--walk` tracks only the right-side line.  It needs to track
the left side too: context and added lines are `RIGHT`/new line, and
removed lines are `LEFT`/old line.  `octocat-diff--patch-text` puts the
anchor on each diff line as a text property:

```elisp
'octocat-diff-line (PATH SIDE LINE)   ; nil on @@ headers and "\ No newline"
```

It is plain data (functional core), tested like `octocat-diff--walk`'s
existing tests.  `octocat-diff--index` also needs `side` and `start_line`.
A LEFT comment is placed after its removed line, and a thread on a range
is placed after the range's last line, as GitHub does.

## Keys

The diff page uses the keys the PR and issue pages already use for
comments, so nothing new needs learning:

| Key | On | Does |
|---|---|---|
| `C-c C-a` | a diff line, or a region of lines | add a draft comment on them |
| `C-c C-a` | a file heading | add a draft comment on the whole file |
| `C-c C-a` | a comment box | reply to its thread |
| `C-c C-e` | my comment, draft or submitted | edit it |
| `C-c C-d` | in that comment's edit buffer | delete the comment, after `y-or-n-p` |
| `C-c C-r` | anywhere | the review dialog, as today |
| `C-c C-d` | in the review dialog | discard the pending review, after `y-or-n-p` |

Deleting has no key on the page itself: it is done from the comment's
edit buffer (`C-c C-e`, then `C-c C-d`), whose header line names the key,
so a slip on the page can't delete anything.  `C-c C-d` already means
"delete" in a dialog, as in the merge dialog's "delete branch".
Submitting an edit with an empty body also offers to delete.

## Marking lines

The region is the mark: `C-SPC` and motion in Emacs, `V` and motion in
Evil.  No mark key is needed, and Evil's `m` stays untouched.

- `C-c C-a` with an active region comments on the lines it touches;
  without one, on the line at point.  A `@@` header or a "No newline"
  note is not a line to comment on, and says so.
- On a file heading, `C-c C-a` comments on the whole file
  (`addPullRequestReviewThread` with `subjectType: FILE` and no line).
  The heading carries the anchor `(PATH nil nil)`, and such a thread is
  drawn right under the heading, before the diff.
- A range can't span files or hunks: GitHub rejects a range across
  hunks.  A clear `user-error` says so.
- While the edit buffer is open, the lines it is about stay highlighted
  in the diff, in `octocat-review-mark` (a background, `:extend t`), as
  an **overlay**.  The region itself is gone once the edit buffer is
  selected, and an overlay doesn't rebuild the fold's memoised patch
  string.  The edit buffer is titled `Comment on path:L12–L18`.
  `C-c C-c` saves it as a draft, and either way the highlight goes when
  the buffer closes.

Lines covered by a draft or a submitted comment keep a `line-prefix`
gutter (`▎` in `octocat-review-pending` or `octocat-dimmed`) after
saving.  It is baked into the patch text from the index, so the range
stays visible next to its box.  Using `line-prefix`, and not inserted
text, means the diff still copies out as a valid patch.

## Showing and editing comments

- A draft's box header reads `@me  Pending` (`Pending` in a warning-ish
  face), and its edge uses `octocat-review-pending`, so drafts stand out
  among the submitted comments.
- `C-c C-e` edits only my own comments (login = `(viewer)` login, as the
  timeline already checks), and on anyone else's signals an error, as
  `octocat-pr-edit` does.  The edit buffer is prefilled with the body and
  runs `review-comment-edit`.
- `C-c C-a` on a box replies.  On a submitted thread with a pending
  review, the reply becomes a draft.  With no pending review, it asks
  "Reply now or add to a review?" (GitHub's "Add single comment" vs
  "Start a review").
- These need a way to find the comment at point: a text property
  `octocat-comment-id` (with pending flag, node id) on every line of a
  box, next to the existing `octocat-comment` property.
- Following `docs/user-interface-conventions.md`: the box header gets
  `mouse-face`/`help-echo` "C-c C-e: edit  C-c C-a: reply".  Check the
  decision table for whether those should be inline buttons instead.

## Submitting

- Drafts show where GitHub shows them, and nowhere else:
  - on the diff page, the bottom button reads **Submit review (3
    pending)**, as GitHub's "Finish your review" button carries the
    count;
  - in the conversation timeline, the pending review is an item of its
    own, at the end, with its draft comments flagged **Pending**, as
    GitHub shows it only to its author.  RET on it opens the diff page.
  - PR lists show nothing, as on GitHub.
- `octocat-pr-diff-review` reads `pr-pending-review`.  With drafts, the
  dialog's header line shows "3 pending comments", `Comment` may be
  submitted with an empty body (`:allow-empty`), and submit goes through
  `review-pr` with the review id.
- A **Discard review** action (button next to submit, and `C-c C-d` in
  the dialog) deletes the pending review after confirmation.

## Commit diffs

The commit page (`octocat-commit.el`) gets line comments too, with the
same keys.  It already draws its `commit-comments` through
`octocat-diff`, and commit comments have the same shape as review
comments, so the line anchors, the gutter, the comment-at-point
property and the edit buffers are shared.  What differs is GitHub's
side.  A commit has no reviews, so there is no pending state: a comment
is posted at once.  And there is only REST: the GraphQL schema has a
`CommitComment` type (checked 2026-10-30), but no mutation that creates,
updates or deletes one.

| Action | Call |
|---|---|
| Add on a line | REST `POST commits/SHA/comments` (`body`, `path`, `position`) |
| Edit | REST `PATCH comments/ID` (`body`) |
| Delete | REST `DELETE comments/ID` |

- `position` is the line's 1-based place in the file's diff, which
  `octocat-diff--walk` already counts, so the anchor property carries it
  too.  It covers removed lines as well, with no `side`.
- No ranges: with an active region, `C-c C-a` says that commit comments
  are on one line, and comments on the region's last line.
- No threads either: `C-c C-a` on a box adds a comment on the same line,
  so it sits right under the one it answers.
- Mutations `commit-comment-add`, `commit-comment-edit` and
  `commit-comment-delete` edit `commit-comments`.
- Only the comment's author may edit it, gated on the viewer's login as
  on the PR diff.

So that each page's commands stay with the page, the commands
(`octocat-diff-add-comment`, `octocat-diff-edit-comment`) dispatch on a
buffer-local `octocat-diff--comment-backend`.  The PR diff and the
commit page each set it to a plist of their functions (add, reply, edit,
delete), and the plist decides drafts vs posting at once.

## Edge cases

- **Head moved while drafting.**  The pending review stays on its
  `commitOID`.  Drafts on lines that no longer exist fall into the "Review
  Comments" list as outdated, as submitted ones do.  New drafts must be
  anchored to the commit the diff shows: `pr-files` should record the
  head sha it fetched.  Add a draft with that `commitOID`, and when it
  differs from the pending review's commit, warn rather than misplace.
- **A pending review started on the web** is simply read and shown.
- **Polling** `pr-pending-review` slowly is enough; only I change it.
- **Several Emacs frames or buffers**: all read the same resource, so
  they stay consistent.

## Steps

Done: 1–8 and 10, but for the `line-prefix` gutter (a range's box names
its lines instead), the Comments pill's open/resolved count, the pending
review in the conversation timeline, and the head-moved warning.  Left:
those, and step 9, the commit page, whose backend plist
`octocat-diff--comment-backend` is ready for it.

1. Diff line anchors (`walk` with left/right, the `octocat-diff-line`
   property, `side`/`start_line` in the index), with tests.  Does not
   change how the page looks.
2. A file's body as diff segments and thread components, with long
   comments folding; on the commit page too.  Screenshot with a long
   comment folded.
3. `pr-review-threads` in place of `pr-review-comments`, and the
   thread-to-comments conversion; the page looks as before.  Then
   `pr-pending-review` and the pending style, so drafts made on the web
   show up.  Fixtures plus screenshot.
4. `C-c C-a` on a line or region → `review-draft-add`; the gutter on
   commented ranges.
5. `C-c C-e` on own comments, drafts and submitted, and `C-c C-d` in
   their edit buffer.
6. `C-c C-a` on a box replies, draft or immediate.
7. Resolving threads: folding resolved ones, the two buttons.
8. Submit with drafts, the pending count, discard; the pending review in
   the conversation timeline.
9. The commit page: `position` in the anchor, its backend plist and
   the three commit-comment mutations.
10. Evil bindings, `docs/usage.md`, CHANGELOG, screenshots
    (`pr-diff` with one draft, one resolved thread and one marked
    range).

## Beyond comments

Other parts of reviewing, for after the steps above.  Each is small and
mostly independent:

- **Viewed files** (`markFileAsViewed` / `unmarkFileAsViewed`,
  `files.viewerViewedState`).  A file I've marked viewed shows a ✓ and
  stays folded; "3/12 viewed" goes in the Files heading.
- **A review in the timeline** opens its comments: RET on a "reviewed"
  item jumps to the diff page, filtered to that review's comments.
- **Re-request a review** from a reviewer who already reviewed: an action
  on their line in the Reviewers list (`requestReviews` with
  `union: true`).
- **Dismiss a review** (`dismissPullRequestReview`, with a message), for
  maintainers, on the timeline's review item.
- **Suggested changes**: `C-c C-a` on a region offers to prefill the body with
  a ```` ```suggestion ```` block holding the marked lines.  Rendering
  one as a diff in the box, and applying it (a commit from the API), can
  come later.
