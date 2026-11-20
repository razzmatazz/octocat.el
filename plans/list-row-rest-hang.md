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

## Fixes

1. **Coalesce renders.**  `octocat-vui--on-sync-change` marks each page
   dirty and re-renders it once, from a 0-delay timer.  However many
   notifications one write, invalidation or request sends, a page
   renders once, after the sentinel returns, so input gets in between.
   This replaces "with no timer" in the design: one render per page per
   turn of the command loop, not per notification.
2. **Notify once per change.**  `octocat-sync--invalidate` notifies the
   outdated keys, and the force-request then notifies them again from
   `octocat-sync--set-loading`.  Notify once.  With fix 1 this is no
   longer a render, but it is still wasted work.
3. **Only invalidate when a field changed value.**  `octocat-sync--merge`
   tells a field that changed value from one only added.  Only changed
   values notify linked resources and invalidate lists.  A PR's first
   prefetch then renders nothing.
4. **Find which fields differ on a busy repository.**  Log the changed
   fields of each merge on the machine that reproduces it.  If it is
   `updatedAt` and the like, invalidation is too broad, see below.
5. **Make the spinner cheap.**  Fewer frames a second, only the windows
   that show it rather than `(force-mode-line-update t)`, and no frame
   while `input-pending-p`.
6. **Name the `gh` sentinel** (`octocat-core.el`) and the sync callbacks
   that run in it, so a profile shows them.
7. **Look into the row render cost**, about 5 ms a row, with a profile
   of one `vui-rerender` of a 30-row list.

### Tests

- One store write that touches several resources of one page renders it
  once.
- An invalidation of a page's list and counts, with their refetches
  queued, renders it once.
- A merge that only adds fields to an entity notifies no linked resource
  and invalidates nothing.

## Reconsidering sync and vui

The store calls into pages synchronously from wherever it changes: a
sentinel, a timer, a command.  Every new kind of change (invalidation,
loading, mutations) adds a notification, and each was a full render.
To decide:

- **Who flushes.**  Fix 1 puts a timer between sync and vui.  The other
  way is a batch in sync: collect the keys changed during a sentinel,
  notify once at its end.  The timer covers every caller without each
  one opting in; the batch keeps sync and vui in step.  Prefer the
  timer.
- **Pages not on screen.**  A buried page needn't render on every
  change.  It could render once when shown again;
  `octocat-vui--poll-shown-changed` already knows which pages are on
  screen.
- **What invalidation means.**  A list is invalidated when its entity
  changed, as the change may move it in or out of the filter.  Its row
  already updates through the entity, so a refetch is needed only when
  membership or order may change.  Narrow `:invalidates` to the fields
  filters and sort read (state, draft, labels, assignees, review
  state), or leave a list's order until the user refreshes it.
- **What a prefetch may do.**  Either a prefetch's write never
  invalidates, which keeps the design's promise, or it may, and fixes 1
  to 3 keep it cheap.  Prefer the latter: data a prefetch finds is as
  real as any other.

## To verify

- On the machine that reproduces it: resting on rows of a 30-row PR
  list of a busy repository no longer freezes, and a CPU profile shows
  no `vui-rerender` under the sentinel.
- `make ci-all`.
