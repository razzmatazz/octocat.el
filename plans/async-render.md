# Plan: Highlighting and rendering in a child Emacs

## Status

- Branch `async-render`.  Step 1 built, not committed:
  `octocat-async.el`, `test/octocat-async-tests.el`.
- Next: step 2 (doctor), step 3 (cache), step 4 (file viewer and
  blame).

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
- The worker: pid, uptime, jobs run, RSS and CPU time (from
  `process-attributes`), the end of its stderr.
- Per kind, last 5 min and last hour: jobs, failures by outcome, median
  and slowest wall time, parent and worker time, jobs run here.
- The most recent 20 jobs.

## 3. Cache in the sync store

Results in a table of the sync store, so a file shown before is never
highlighted again, across sessions too.

- Key: a hash of the job's function, arguments, Emacs version and the
  mtime of the job's code.  Faces are symbols, so a theme change
  doesn't stale it.
- TTL: `octocat-sync-collect` deletes rows unused for some days.
- Reading one back is a `read`: 1–2 ms per 100 KB.
- Sync is above `octocat-async`, so the lookup is in the page's hook
  calling it, not in the runner.

## 4. File viewer and blame

`octocat-tree--fontify` through `octocat-async-call`.  A page shows
the plain text first, and the highlighted text once it lands; the
result is dropped when its page shows other content by then.

## 5. Diffs

One job per file's patch, with all its hunk sides: startup dominates
small jobs.

## 6. Rendering off the main thread (later)

Markdown, Mermaid, RST: the worker loads octocat, once.  Closures in
text properties (buttons, actions) may not survive printing, nor
anything printed as `#<...>`; the parent adds those after.  Width,
theme colours and the like go to the job as arguments.
