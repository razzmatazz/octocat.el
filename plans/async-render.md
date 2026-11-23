# Plan: Highlighting and rendering in a child Emacs

## Status

- Branch `async-render`.
- Done: step 1 (9fb4ea8), step 2 (bde0e0f), step 4.  Step 3 built,
  then dropped: see why there.
- Next: step 5 (diffs).  Their slowness was mostly not highlighting:
  `octocat-diff--segments` joined lines in quadratic time, 2.8 s for a
  2,500-line added file, again on each width change.
- `octocat-clone-test-git-fails` can die of SIGPIPE: its fake git exits
  before `octocat-clone.el` writes to it.  Seen once on Emacs 30.2.

## Problem

Highlighting runs `font-lock-ensure` in the main Emacs, so the UI
blocks while it runs: about 50–80 ms for a 1,500–3,700 line Elisp
file, 540 ms for 1.2 MB, more in slow modes.  Emacs threads don't help:
they are cooperative, and font-lock never yields.

## 1. Runner (done)

`octocat-async.el`, standalone.  `octocat-async-call` runs a job in a
worker, one child Emacs kept for the session, and calls back with its
result; on any failure the job runs here, so the caller never handles
one.  No async.el: it starts an Emacs per job (about 50 ms each, more
for a job that loads octocat), and its results come back mangled
(`#(` rewritten).

- The caller decides what is worth the worker: `:here` runs a job here
  at once, as does any while the worker is off.  `:deadline` is the
  caller's too (default 10 s).  For highlighting, here under 20 KB
  (about 15 ms, as much as the round trip), and 1 s + 2 ms/KB.
- One job at a time; the rest queue.  The worker stops after 5 minutes
  idle, and is replaced when code it loaded changed on disk.
- Its first message passes `load-path`, the mode alists, and the
  autoloads of the modes they name, so it picks a file's mode as this
  Emacs does.
- A job over 4 KB goes through a temp file.  The worker reads stdin
  with `read-from-minibuffer`, about 0.35 ms per KB, and the parent's
  `process-send-string` waits until it has read all: 44 ms of UI stall
  for a 183 KB job.  macOS's pipe buffer is fixed at 64 KB, so a bigger
  one is no way out.

Failures, each logged, each falling back to here:

| Outcome      | When                                                  |
|--------------|-------------------------------------------------------|
| `no-start`   | the worker can't start                                |
| `error`      | the job signals in the worker                         |
| `crash`      | the worker exits mid-job                              |
| `unreadable` | its answer can't be read back                         |
| `timeout`    | past its deadline (+5 s on a fresh worker): killed    |

Three in a row turn the worker off until restart, with one message;
`octocat-async-turn-on` undoes it.  `octocat-async-cancel` drops a job.
`octocat-async-status` and `octocat-async--log` are for the doctor.

### Measured

Batch `emacs -Q`, emacs-lisp-mode, UI stall the longest gap between
ticks of a 5 ms timer while the job runs:

| Input  | Here (UI blocked) | UI stall | Wall       |
|--------|-------------------|----------|------------|
| 25 KB  | 17 ms             | 5 ms     | 13–22 ms   |
| 75 KB  | 41 ms             | 5–12 ms  | 50–58 ms   |
| 183 KB | 73 ms             | 5–16 ms  | 96 ms      |
| 1.2 MB | 541 ms            | 28–43 ms | 650–680 ms |

- Starting the worker: 70 ms; in a Doom Emacs, 90 ms.  A mode's first
  job loads it: markdown-mode 120 ms, python 54 ms, then 6–10 ms.
- What stays on the UI for 1.2 MB: writing the job file (22 ms),
  inserting the answer's 43 pieces (12 ms, under 1 ms each), and one
  `read` of it (26 ms), the longest stall.
- In Doom, one GC of 51 ms once landed in reading an answer; highlighting
  here allocates more.

## Highlighting as the user's Emacs does (open)

The worker's highlighting differs from the user's Emacs, where the user's
config changes it.  In a Doom Emacs, Python, Dockerfile and Makefile
came out the same; Elisp and Markdown didn't:

- Elisp: `font-lock-keywords-alist` adds keywords from Doom, evil,
  transient and magit, and `+emacs-lisp-highlight-vars-and-faces`
  colours every symbol bound in that Emacs, which the worker's isn't.
  The worker colours 34 function names where the user's Emacs colours 169.
- Markdown: user options such as `markdown-fontify-whole-heading-line`
  are set by the config, not passed.

Chosen: accept it.  The worker highlights as a stock Emacs with the
user's `load-path`, mode alists and mode autoloads: the same mode, not
the config's options or keywords.  Passing them would fit one config,
and can't match the one that differs most.  Measured in that Doom Emacs:

- Elisp's difference is all from keywords that are functions:
  `+emacs-lisp-highlight-vars-and-faces` and
  `shorthands-font-lock-shorthands`.  Its regexp keywords change
  nothing.  The Doom one colours a symbol by whether it is bound in the
  Emacs highlighting, so no worker without the whole session matches it.
- Markdown's is from options: 635 of 5,137 differ from their standard
  value (143 of them hooks), 76 KB printed, 116 ms to collect, on the
  UI, at each worker start.

## 2. Metrics in `octocat-doctor`

A section "Background work, last hour", next to the requests one:

- State: on, or off since when and why; failures in a row; running and
  queued.
- The worker: pid, uptime, jobs run and the time they took it, RSS
  (from `process-attributes`), the end of what workers printed on
  stderr, kept across restarts.  Not `process-attributes`'s CPU time:
  on Apple silicon Emacs reports it in Mach ticks, 40 times too small.
- When off, a button turns it back on.
- Per kind, last 5 min and last hour: jobs, failures by outcome, median
  and slowest wall time, parent and worker time, jobs run here.
- The most recent 20 jobs.

## 3. Cache in the sync store (dropped)

Built and measured, then reverted: with the worker, it saves little.
Results were kept in a `memo` table of the store, keyed by a SHA-1 of
the job, its arguments, the Emacs version and the job file's mtime.

| Input  | Here   | Worker: UI stall | Store hit | Storing a value |
|--------|--------|------------------|-----------|-----------------|
| 183 KB | 73 ms  | 5–16 ms          | 5 ms      | 6 ms, on the UI |
| 1.2 MB | 541 ms | 28–43 ms         | 43 ms     | 41–53 ms        |

- A hit's UI cost is about the worker's: reading a large value back is
  itself a large `read`.  What it saves is the wait with plain text
  shown, and the worker's CPU, on a repeat the page's own state
  doesn't cover: across restarts, rarely the same file at the same
  commit.
- It costs a schema bump (dropping every user's store once), twice the
  text's size on disk, a write on the UI per miss, and values stale
  for up to 14 days when a mode or config changes.

If repeats within a session show in the doctor, a small in-memory LRU
gives hits in under 1 ms, with none of that.  A store cache may pay for
rendering (step 6), if it repeats across sessions; its keys then hold
width and theme colours.

## 4. File viewer and blame (done)

`octocat-fontify.el`, on `octocat-async` alone so the worker loads it
cheaply, holds the highlighting: `octocat-fontify` (faces only, as the
diff's already was) and `octocat-fontify-async`, which runs it in the
worker from 20 KB on.  The hook `octocat-vui-use-fontified` returns a
small text highlighted at once, in the same render, and a large one nil
until the worker's result lands, which re-renders the page; a job whose
text is no longer shown is cancelled.  The file viewer and blame show
the plain text meanwhile.

Measured, the file viewer mounted in batch `emacs -Q`:

| File   | Before: UI blocked | First paint | Stall as it lands | Highlighted |
|--------|--------------------|-------------|-------------------|-------------|
| 25 KB  | 13–29 ms           | 3.5 ms      | none              | 17 ms       |
| 75 KB  | 45–58 ms           | 6 ms        | 9–10 ms           | 56 ms       |
| 184 KB | 101–104 ms         | 14 ms       | 19–35 ms          | 114–130 ms  |

The stall as it lands is reading the result and re-rendering the page
with it; not yet broken down.

## 5. Diffs

One job per file's patch, with all its hunk sides: startup dominates
small jobs.

## 6. Rendering off the main thread (later)

Markdown, Mermaid, RST: the worker loads octocat, once.  Closures in
text properties (buttons, actions) may not survive printing, nor
anything printed as `#<...>`; the parent adds those after.  Width,
theme colours and the like go to the job as arguments.
