# Plan: Emacs hangs when point rests on a list row

## Problem

On a PR list of 30 rows, resting point on a row freezes Emacs for about
a second: `hjkl` do nothing, `:loading` shows in the mode line, then it
unblocks.  It happens on any machine, in any repository whose pull
requests change often.

A CPU profile taken while it froze:

```
byte-code-function (the `gh' sentinel)             88%
  octocat-sync--done                               76%
    octocat-sync--invalidate                       63%
redisplay_internal                                  8%
```

That profile was taken with the spinner turned off.  With it on,
`redisplay_internal` took 65% (12% of it `doom-modeline-format`) and
automatic GC 13%: the spinner hides the cost behind redraws.

## What happens

1. Point rests 0.3 s on a row, and `octocat-vui--prefetch-schedule`
   prefetches `(pr REPO N)` and `(timeline-events REPO N)`.  Each is an
   async `gh` call, so nothing blocks yet.
2. The PR's answer arrives.  `octocat-sync--done`, in the sentinel,
   writes it, and the PR entity's fields differ from what the list
   stored: on a busy repository the values really changed.
3. `octocat-sync--done` sees the main entity changed and calls
   `octocat-sync--invalidate` on the PR's lists (`list-items`, `counts`,
   `repo-summary`, see `octocat-model--item-lists`).
4. That re-renders the list page three times, synchronously, one after
   another:
   - `octocat-sync--invalidate` notifies the outdated keys, and the page
     re-renders.
   - `octocat-vui--on-sync-invalidate` force-requests the list.
     `octocat-sync--set-loading` notifies again (data that is loading
     and outdated draws differently), and the page re-renders.
   - The same for `counts`: a third render.

   The first two draw nothing new: no page reads a snapshot's
   `:outdated`, and its `:loading` over data shows only in the mode
   line.
5. The list's refetch answers seconds later, and its sentinel writes 30
   PRs and re-renders once more.

While `:loading` shows, the spinner forces a mode-line update ten times
a second (`octocat--spinner-tick`), and Doom's mode line is costly to
compute.

### Measurements

One `octocat-sync--invalidate` of a 15-row PR list:

| Step | Time |
|---|---|
| `octocat-sync--outdate`, the SQL | 1 ms |
| notify of the outdated keys → `vui-rerender` | 77 ms |
| force-request of the list → `set-loading` → notify → `vui-rerender` | 84 ms |
| the same for `counts` → `vui-rerender` | 8 ms |
| **total** | **334 ms** |

A PR's first prefetch, with no invalidation, cost 100 ms: an 80 ms
re-render of the list, for fields only the detail page reads.  A second
prefetch of unchanged data cost 16 ms.

One render of the list costs about 5 ms a row.

## How we got here

The design said a write notifies once and each page renders once, with
no timer ("How a change reaches the screen" and "Page side" in
[github-sync-mechanism.md](github-sync-mechanism.md)).  The write path
keeps that.  Invalidation and loading were added beside it, and each
notifies on its own: one write now fans out into several notifications,
each a full render.  Nothing checked the invariant, and on a small list
or a quiet repository the cost stays under notice.

The design also says a prefetch "only writes the store".  Through
invalidation, a prefetch's write makes a page request and several
renders of the page the user is on.

### The investigation

- The first guess was a synchronous wait behind the echo-area hint.
  The ElDoc functions read text properties only, and every `gh` call is
  async.  A freeze can come from plain work in a sentinel, without
  waiting on anything.
- The prefetch was timed on another machine, against a public
  repository: 100 ms, no invalidation.  Its PRs had not changed, so the
  costly path never ran.  The bug depends on the data, not the machine.
- The `:loading` and the 65% redisplay pointed at the spinner.  Turning
  it off with `(advice-add 'octocat--spinner-start :override #'ignore)`
  moved the cost into the sentinel, where it was.
- The profiler named the sentinel only as an anonymous byte-code
  function.  Its disassembly's constants showed the resource key and the
  request reason, which said it was the list's refetch, not the
  prefetch.
- Timing advice around `octocat-sync--invalidate` and the functions it
  calls gave the table above.

### Lessons

- **Measure where it reproduces.**  A run elsewhere that doesn't
  reproduce proves little when the cost depends on the data.
- **Turn suspects off one by one.**  An `:override` advice that disables
  one part shows what is left.
- **Name hot callbacks.**  A sentinel that is a named function reads in
  a profile; an anonymous one needs its disassembly.
- **Enforce what the design promises.**  "One write, one render per
  page" needs a test.  It broke without anyone noticing.
- **Work in a sentinel blocks input as much as a synchronous call.**
  Fan-out from a store write runs on the main thread: keep it bounded.

## The contract between sync and pages

Fixing this one path would leave the next notification to fan out the
same way.  These rules say how a change reaches the screen.  Each is
checked by a test or measured at run time, and `docs/sync.md` keeps
them.

1. **Sync never renders.**  A handler of `octocat-sync-change-functions`
   only marks the pages reading the keys dirty and schedules one flush:
   a 0-delay timer.  The flush re-renders each dirty page once.  So any
   number of notifications in one turn of the command loop (a write, an
   invalidation, the requests it starts, a mutation) cost one render
   per page, after the sentinel, timer or command returns, and a render
   can't start inside a render.
2. **Notify only what a page draws.**  A page draws a snapshot's data,
   its partial entity, its pending mutations, and whether it is ready,
   pending or failed (`octocat-vui-snapshot-status`).  A change to
   anything else, such as `:loading` or `:outdated` over shown data,
   updates the mode and header lines only and notifies nothing.
3. **Only an entity's changed values spread.**  A field added to an
   entity, as a detail fetch adds to a list's copy, notifies no other
   resource and invalidates nothing: they never asked for it.
4. **Invalidation is for membership.**  A list row already updates
   through its entity.  A list is refetched only when a field its filter
   reads changed value; each entity type names those fields.  A changed
   order waits for the list's own refresh, by `g` or by polling.
5. **Pages not on screen don't render.**  A dirty page out of sight is
   rendered when it is shown again.
6. **Renders are measured.**  vui counts each page's renders and their
   time.  `octocat-doctor` shows them, and a render over 50 ms goes to
   the debug log with the keys that caused it, so a slow fan-out shows
   before it freezes anyone.

A prefetch may still update a page: what it finds is as real as any
other data.  The rules keep that cheap; the design's promise that a
prefetch "only writes the store" is dropped.

## Steps

Each step lands on its own, with `make ci-all` passing.

1. **Measure renders (rule 6).**  Count and time `vui-rerender` per page
   in `octocat-vui.el`, show them in `octocat-doctor`, and log slow ones
   with their cause.  This comes first, so each later step shows its
   effect in numbers.
2. **Flush renders once (rule 1).**  `octocat-vui--on-sync-change` adds
   the buffers to a dirty set and starts the flush timer unless one is
   pending.  The flush renders each live dirty page.  Tests that read a
   page right after a store write call the flush, through a helper, in
   place of relying on the render being synchronous.
3. **Drop status notifications (rule 2).**  `octocat-sync--invalidate`
   stops notifying: it only runs `octocat-sync-invalidate-functions`.
   `octocat-sync--set-loading` notifies only when the snapshot's status
   changes, from failed with no data to pending, not for outdated data.
4. **Spread only changed values (rule 3).**  `octocat-sync--merge`
   returns whether a value it had changed, apart from fields it gained.
   `octocat-sync--write` notifies linked resources, and
   `octocat-sync--done` invalidates, only for changed values.
5. **Invalidate on membership fields (rule 4).**  Each entity type
   names the fields its lists filter on, say `state`, `isDraft`,
   `labels`, `assignees` and the review state for a PR, and
   `octocat-sync--done` compares only those.  First log, on the machine
   that froze, which fields changed when it did, to check that these
   are the ones.
6. **Render visible pages only (rule 5).**  The flush skips pages out of
   sight and keeps them dirty; `octocat-vui--poll-shown-changed`, which
   sees a page come on screen, renders it.
7. **Make the spinner cheap.**  Fewer frames a second, only the windows
   that show it rather than `(force-mode-line-update t)`, and no frame
   while `input-pending-p`.
8. **Name the `gh` sentinel** (`octocat-core.el`) and the sync callbacks
   run in it, so a profile shows them.
9. **Profile one render of a 30-row list**, about 5 ms a row, and cut
   what dominates.
10. **Write it down.**  `docs/sync.md` states the rules, how a change
    reaches the screen, and how to add a resource, a notification or a
    status without breaking them.  "Reading the sync store" in
    `docs/using-vui.md` shortens to a link to it, as does
    `plans/github-sync-mechanism.md` for what is built.  `AGENTS.md`
    gains a rule: a store change never renders; see `docs/sync.md`.
    `CHANGELOG.md` gains an entry for the fixed freeze.

## Tests

- **Rule 1:** one store write touching several resources of one page
  renders it once; so does an invalidation of its list and counts with
  their refetches started.
- **Rule 2:** starting a refetch of shown data, or outdating it, renders
  nothing.
- **Rule 3:** a merge that only adds fields notifies no linked resource
  and invalidates nothing.
- **Rule 4:** a changed `updatedAt` invalidates no list; a changed
  `state` does.
- **Rule 5:** a dirty page out of sight renders when shown, not before.

## To verify

- On the machine that froze: resting on rows of a 30-row PR list of a
  busy repository doesn't freeze, and a CPU profile shows no
  `vui-rerender` under the sentinel.
- `octocat-doctor` shows one render per page for a prefetch that
  changed a row.
- `make ci-all`.
