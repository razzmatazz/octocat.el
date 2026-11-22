# Plan: Emacs hangs when point rests on a list row

## Status

- Done: steps 1 (232cad3), 2 (3ad197f), 3 (70197a8), 7 (b61e712),
  8 (d1732f7), and of step 9 the `git` calls (ef70ab4).
- Order, by what helps every page most (see "What helps most"):
  1. Fewer renders: 4 and 5, which remove the renders a hover still
     causes, then 6.  First check, on a busy list, the render counts in
     `octocat-doctor` and the slow renders in the debug log.
  2. Renders that cost what changed: 10, entity versions and memo.
  3. Then 9's remaining cuts, and 11.
- Measure compiled: the developer's Emacs runs octocat uncompiled, 2.5
  times slower with twice the allocation of what users run.
- Step 7 broke `make screenshots`, which opened pages out of sight;
  2556fae fixed the harness.

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

One render of the list costs about 5 ms a row.  Step 9's profile shows
most of that was GC and code loaded uncompiled; see "Profile of a
render".

### Profile of a render

Renders timed by calling `vui-rerender` on the page's root, in a batch
Emacs on `test/screenshots/fixtures.el` (the PR list repeated to 30
rows), and in the developer's Emacs on a cached 15-row list:

| Where | One render |
|---|---|
| Developer's Emacs, 15 rows, uncompiled | 7 ms, and a 50 ms GC every other render |
| Batch, 30 rows, uncompiled | 12 ms, 0.4 ms a row |
| Batch, 30 rows, byte-compiled | 4.8 ms, 0.16 ms a row |

- The developer's Emacs runs octocat uncompiled, as the reload in
  `AGENTS.md` evaluates the source: 2.5 times slower and twice the
  allocation of an installed package.
- A render allocates about 1 MB of conses and 110 KB of string text.
  In a large heap that costs a GC of 50 ms every other render, seven
  times the render.  Fewer renders (steps 4–6) save more than cheaper
  ones.

Where a compiled render's time goes (CPU profile of 400 renders):

| Part | Share |
|---|---|
| GC | 33% |
| Building rows, `octocat-vui--pr-row` | 40% |
| – `truncate-string-to-width` | 10% |
| – `octocat--key-help` → `where-is-internal`, the Full/Compact hint, every render | 7% |
| – parsing timestamps for ages, `date-to-time` | 6% |
| – label colours | 5% |
| vui's commit: diff, widening, region properties | 19% |

Cuts, smallest first: compute the key hint once; parse each timestamp
once; allocate less per row.  Together perhaps 20–30% of a 5 ms render.
Memoizing rows (step 10) saves more than all of them.

#### Memoizing rows

Every render rebuilds every row: `octocat-vui--pr-row` runs for all 30
when one changed, or none.  React skips such rows with `React.memo`,
which compares a row's props by identity: an immutable store makes a
new object only for what changed, so the other rows' props are the same
objects as before.

vui has the same: `:memo t` on a component skips its render while its
props are shallow-equal, compared with `equal`.  A row as a component:

```elisp
(vui-defcomponent octocat-vui--pr-row-memo (repo pr width bg compact stack marked)
  :memo t
  :render (octocat-vui--pr-row repo pr width bg compact nil stack marked))
```

As things are, it would never skip.  `octocat-vui-use-resource` keeps
its read while the resource's version is unchanged, so a page's memos
hold between notifications; but once one PR changes, the list is read
again whole, and `equal` compares hash tables by identity, so all 30
rows get a new `pr`.  Two ways out:

1. **A version per entity (chosen).**  The `entity` table gains a
   `version`, bumped by `octocat-sync--write` when a value really
   changes, the same signal step 4 needs.  A read gives each table its
   version.  A row's props are its key and version, plus what else it
   draws: width, background, compact, marked, stack, and its pending
   edits, which change what it shows without a write.  Comparing them
   is a few `eq` checks.  A missed version only renders too often:
   slower, never wrong.
2. **The store returns the same table while an entity is unchanged**,
   as an immutable store shares structure in React.  Rejected: our
   tables are mutable (`octocat-sync--edit` may change a body, and code
   `puthash`es what it reads), so a change on one page would leak to
   every page sharing the table.

A render where one row changed then builds one row, not 30, and
allocates as much less, so GC less.  To check first: that vui leaves a
skipped row's buffer text as it is, without rewriting it; else only the
building is saved, not the commit (19%).

### What helps most

Across octocat.el, two layers, each helping every page:

1. **Fewer renders** (steps 3–7): a store change re-renders only the
   pages that draw what changed, once each, and only on screen.  Most
   of the cost found came from renders that should not have happened.
   It decides how often anything renders, so it comes first.
2. **Renders that cost what changed** (step 10): with entity versions,
   any component drawing one entity can be `:memo`: the rows of PR,
   issue, run, commit and search lists, the dashboard's items.  Lists
   and the dashboard gain most; a PR page is mostly one entity, and its
   timeline entries are memoized on their item already.

Step 9's cuts help one list's render by 20–30%, and come after.

### A faster GC: Emacs's MPS branch

Emacs's GC walks the whole heap: in a 60 MB session each collection
takes 60–80 ms, and a render allocating 1 MB triggers one every other
render.  The `feature/igc3` branch replaces it with an incremental,
generational GC on Ravenbrook's MPS.  We timed it on commit
`898bbc7d9f` (2026-11-22), built with and without MPS from the same
source, in a Linux container under podman; octocat and its
dependencies byte-compiled, with 60 MB of long-lived data held to stand
in for a session.  Two runs agreed:

| Render | Without MPS: median / p95 / max | With MPS |
|---|---|---|
| PR list, 30 rows | 4.1 / 4.7 / 74 ms | 5.5 / 21 / 68 ms |
| Long PR page (1,004 lines) | 10.8 / 15 / 83 ms | 32 / 148 / 1,141 ms |
| That PR's markdown, all entries | 50 / 126 / 126 ms | 59 / 64 / 64 ms |

- It removes the occasional full GC where many strings are built in
  one pass, the markdown: its worst case halves.
- It slows the typical render, and the PR page stalls past a second;
  with 200 MB held, once for 4.3 s.  Without MPS the worst was one
  258 ms GC.
- Caveats: a branch still being stabilized; MPS relies on page
  protection faults, which cost more in a VM than on bare metal; and it
  reports no `gcs-done` or `gc-elapsed`, so its stalls are seen only
  in wall time.  Not looked into: whether the stalls are the collector
  or how vui writes the buffer.

So a faster GC won't rescue us soon.  Fewer renders and less
allocation per render help under either collector.

The harness, not in the repository: a Dockerfile cloning the branch and
building it twice (`--with-mps=yes` and `no`, `--without-x
--without-native-compilation --with-sqlite3`; MPS ships in the
branch), and a bench script that loads the screenshot fixtures, holds
the ballast, and times re-renders of the list and the PR page.

#### A long PR timeline

PR #128 of the fixtures grown to 60 comments and 10 reviews, each a
markdown body with a list, a code block and a quote, and 30 commits:
101 items, 1,004 lines.  Batch, byte-compiled:

| Render | Time |
|---|---|
| Re-render, no item changed | 17 ms |
| – `octocat--current-branch`, from `octocat-pr--header` | 9 ms |
| Building every entry's text, when all items change | 55 ms |
| – markdown, nearly all `string-match` in `octocat-markdown--inline` | 50 ms |

- `octocat-pr--header` runs `git symbolic-ref` synchronously on every
  render, 9 ms in a clone or not, in batch and in the developer's
  Emacs: half of each re-render of every PR page.
- **Local git state bypasses the sync layer.**  The sync store holds
  GitHub's data, fetched async through `gh`; the clone's branch and
  HEAD are read by `octocat--current-branch` and `octocat--head-info`
  with `shell-command-to-string`, synchronous, through the shell.  They
  came with "Indicate current branch" (bfb9227, June 2026), before the
  store, and their docstrings call them cheap enough for render time.
  Callers at render time:

  | Page | Call | Per render? |
  |---|---|---|
  | PR header, `octocat-pr--header` | `octocat--current-branch` | yes |
  | Repo root, tree, file, blame, commits (`octocat-repo-vui--*`) | `octocat--head-info` | yes |
  | Run list and run page, `octocat-actions.el` | `octocat--current-branch` | no, `vui-use-memo` once per mount |

  Done (ef70ab4): HEAD is the `clone-head` resource, read with git
  without waiting as a :local and polled every 10 s; pages read it
  with `octocat-vui-use-clone-head`, the run pages too.
  `octocat--head-info` stays for commands.  Still synchronous, but not
  per render: the repo page's `octocat-clone-tracked-branch` when its
  window is selected, and `octocat-clone-unpushed` on refresh.
- Each entry's text is memoized on its item (compared with `equal`),
  so only changed items rebuild it.  A body costs about 0.8 ms of
  markdown; the first render pays it for all of them.
- The rest is vui: widening, commit, restoring point, 15–20%.

Opening `razzmatazz/octocat.el` #5, the largest PR in the developer's
store, through `emacsclient --eval` blocked over 20 s and opened
nothing.  Not looked into yet.

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

Each step is a commit of its own, with `make ci-all` passing and the
test of its rule (see "Tests").  The cheap fixes (3–5) come before the
flush (6): they fix the freeze in small diffs, and the flush, which
touches the most tests, lands apart from them.

1. **Name the `gh` sentinel.**  The lambda in `octocat--gh`
   (`octocat-core.el`) becomes `octocat--gh-sentinel`, the values it
   closes over kept with `process-put`; the sync callbacks run in it
   are named too.  No change in behaviour; every later profile reads.
2. **Measure renders (rule 6).**  `octocat-vui--on-sync-change` and
   `octocat-vui--rerender-pages`, the only callers of `vui-rerender`,
   render through one function that counts and times each page's
   renders.  `octocat-vui-refresh-status` returns them for
   `octocat-doctor`, and a render over 50 ms goes to the debug log with
   the keys that caused it.  Each later step shows its effect in these
   numbers.
3. **Drop status notifications (rule 2).**  `octocat-sync--invalidate`
   stops notifying: it only runs `octocat-sync-invalidate-functions`.
   `octocat-sync--set-loading` no longer notifies for outdated data,
   only for a resource with none.  `octocat-sync--done` stops counting
   `invalidated_at` as shown.  No page reads `:outdated`.
   `CHANGELOG.md` gains the entry for the fixed freeze.
4. **Spread only changed values (rule 3).**  `octocat-sync--merge`
   writes fields it gained, but reports separately whether a value it
   had changed.  `octocat-sync--write` notifies linked resources, and
   `octocat-sync--answered` too, only for changed values.
5. **Invalidate on membership fields (rule 4).**  `octocat-model.el`
   names, per entity type, the fields its lists filter on, say `state`,
   `isDraft`, `labels`, `assignees` and the review state for a PR, next
   to `octocat-model--item-lists`.  `octocat-sync--done` compares only
   those, not the whole stored JSON.  First log, uncommitted, on the
   machine that froze, which fields changed when it did, to check that
   these are the ones.  Mutations keep their own `:invalidates`.
6. **Flush renders once (rule 1).**  `octocat-vui--on-sync-change` adds
   the buffers to a dirty set and starts a 0-delay timer unless one is
   pending, as `octocat-vui--on-theme-change` does.  The flush renders
   each live dirty page.  Our own timer: vui's deferred rendering is
   internal, and `vui-flush-sync` covers the current buffer only.  Tests
   that read a page right after a store write call the flush through a
   helper: `octocat-vui-test-use-resource`, and those of search, repo
   and timeline that do.
7. **Render visible pages only (rule 5).**  Done ahead of 4–6, as it
   needs no flush: `octocat-vui--render-page` renders a page on screen at
   once and keeps, in `octocat-vui--stale`, what changed for one out of
   sight; `window-buffer-change-functions` renders it once shown.  The
   flush of step 6 renders through it.
8. **Make the spinner cheap.**  Done: it first turns after 0.3 s
   (`octocat--spinner-delay`), so most fetches never redraw for it, and
   `octocat--spinner-tick` skips a frame while `input-pending-p`.  It
   keeps 10 frames a second, as spinner.el does, and already updated
   only the mode lines showing it: `(force-mode-line-update t)` runs
   only while a change is sent, when every mode line shows it.
9. **Cut what dominates a render**, profiled in "Profile of a render",
   a commit per cut, each with its numbers.  Done: the `git` calls of
   PR and repo pages.  Left: the list's key hint, timestamps and
   allocation.
10. **Memoize rows**, see "Memoizing rows": entities get a version,
    and rows become `:memo` components on it.  Measure, compiled, a
    render where one row changed, before and after.
11. **Write it down.**  `docs/sync.md` states the rules, how a change
    reaches the screen, and how to add a resource, a notification or a
    status without breaking them.  "Reading the sync store" in
    `docs/using-vui.md` shortens to a link to it, as does
    `plans/github-sync-mechanism.md` for what is built.  `AGENTS.md`
    gains a rule: a store change never renders; see `docs/sync.md`.

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
