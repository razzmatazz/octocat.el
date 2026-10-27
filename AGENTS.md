# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.
See [docs/user-interface-conventions.md](docs/user-interface-conventions.md) for UI conventions: how to signal interactivity, `mouse-face`/`help-echo` patterns, and the decision table for RET-able sections vs inline buttons.
See [docs/using-vui.md](docs/using-vui.md) for vui.el gotchas, e.g. updating a page in place instead of remounting it.
See "Functional core" in [CONTRIBUTING.md](CONTRIBUTING.md): keep functions as functional as possible, with context (e.g. width) passed in as arguments and side effects confined to commands and effects.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci-all`** (compile + lint + test, on every Emacs release CI runs, at once, plus melpazoid once) after making changes. Fix all errors and warnings before finishing; `make ci` runs one release, for a quicker check while working.
  Read `make ci-all`'s output unfiltered: on a failure it already ends
  with the failing lines, and a `grep` for "error" or "warn" drops
  checkdoc's, which read `FILE:LINE: message`.
- **Only call functions from declared dependencies.** The declared deps are in the `Package-Requires` header of `octocat.el`. Do not call into magit internals, transient internals, or any other package not listed there — even when taking inspiration from them. Re-implement the idea in plain Elisp instead.
- **Update `CHANGELOG.md` for significant changes**: anything a user would notice (features, key bindings, fixed bugs) or that changes which Emacs versions are supported or tested. Add a line under `## [Unreleased]`, worded for users, in the style of the entries already there.
  Keep an entry short, about 80 characters and rarely past 100: name
  what changed for the user, not every detail.
- **Keep `Assisted-by:` headers complete.** Every `.el` file, tests included, lists each model that has worked on it, one line per model, as MELPA asks (`;; Assisted-by: AGENT_NAME:MODEL_VERSION`, e.g. `;; Assisted-by: Claude:claude-opus-5-5`). When you edit or create a file and your model is not listed there, add a line after the existing `Assisted-by:` lines, or, in a file with none, after the title line. Never remove a line.
- **Keep docs and comments minimal.** Say only what the code doesn't: the why, the non-obvious. Short, but complete enough to understand.
  Docs (`README.md`, `docs/`) must not be too short either: a reader new to the feature should get what it does, why, and how to use or extend it, in full sentences.
  Keep new prose in docs short and to the point: the rule or fact, not
  the history or context that led to it.
- **Never modify source files through Emacs** (`emacs__eval-elisp`, buffer edits, `save-buffer`, etc.); it risks a live buffer and the file on disk drifting apart. Use the file-editing tools or any shell tool (`sed`, Python, etc.).

## Screenshots

[docs/screenshots](docs/screenshots/README.md) shows every page, drawn
from the made-up data in `test/screenshots/fixtures.el`.

- **After changing what a page shows, or adding one, run `make
  screenshots`** and check the diff of the `.txt` files it rewrites:
  they should change as you meant, and nothing else.  Read the PNGs of
  the pages you changed too.
- A new page or view gets a shot: add a marker to
  `docs/screenshots/README.md`, with a line on what it shows.
- If it fails naming a `gh` call with no fixture, add one to
  `fixtures.el`, in the JSON `gh` prints for it.
- Keep fixtures made up: never real repositories, people, hashes or
  anything from the user's sync store.

## Sub-agent parallelism

**Do not spawn multiple sub-agents that perform edits or run `make ci` concurrently.**
Both resources are singletons:

- **`make ci`** runs compile, lint, and tests inside a shared container.  Two
  parallel runs stomp on each other's `.elc` output, produce interleaved
  stderr, and make it impossible to attribute failures to a specific change.
- **The Emacs environment** (via `emacs__eval-elisp`) is a single live
  process.  Concurrent agents reloading files or querying buffer state will
  race, producing misleading results or corrupting the session.

Work sequentially: make all edits first (parallel read-only exploration is
fine), then reload into Emacs once, then run `make ci` once.  Only spawn
parallel sub-agents for **pure research / read-only** tasks.

## Checking paren structure

`make lint`'s elisp linter checks every line's indentation against
Emacs's own.  A `)` removed by mistake (e.g. along with a `(goto-char
(point-min))`) and made up by an extra one further on leaves the file
balanced but swallows the `defun`s in between; they then sit indented
inside the form above, and the linter names their lines.  `M-x
check-parens` finds a paren left unbalanced.

## Reloading into Emacs

Use `emacs__eval-elisp` to reload **all** `octocat*.el` files after every
edit.  **Issue one `emacs__eval-elisp` call per phase** — `dolist` returns
`nil`, so a single call with multiple phases returns `nil` whether it
succeeded or crashed; splitting makes failures attributable.

Load order: `octocat-mermaid.el` first (standalone), then
`octocat-markdown.el` (requires it), then `octocat-image.el` (requires
that; `octocat-core.el` requires both), then
`octocat-core.el` (everything else depends on it), then `octocat-sync.el`
(`octocat-vui.el` requires it), then `octocat-vui.el`
and `octocat-diff.el` (which the commit and PR diff pages require);
`octocat-evil.el` before `octocat.el` (the last lines of `octocat.el` call
`octocat-evil-setup`, and `require` is a no-op on an already-provided
feature, so a stale evil file silently wins).

**Do not kill the user's buffers by default.**  Calls 1 and 2 close their
open octocat buffers and visited source files, which loses their place.
Run only Call 3 (and Call 4 to verify) unless killing is actually
necessary, and tell the user to `gr` any already-open buffer to re-render
it with the new code.  Kill buffers only when the change would otherwise
not take effect, e.g.:

- a keymap or `evil` binding changed (stale keymaps stick to live
  buffers; also `makunbound` the affected map, see below);
- a source buffer is visited and stale on disk, or a stale `.elc`
  shadows the source (Call 2).

Mention in the final reply whether you killed anything and why.

**Call 1 — kill display buffers** (only when necessary, see above; stale
keymaps stick to live buffers):
```elisp
(dolist (buf (buffer-list))
  (when (string-prefix-p "octocat-"
                         (symbol-name (buffer-local-value 'major-mode buf)))
    (kill-buffer buf)))
"display-buffers-killed"
```

**Call 2 — kill visited source buffers and delete `.elc` files**
(only when necessary, see above; `insert-file-contents` prefers the visited buffer over disk; `.elc` shadows
source; `make ci` recreates `.elc`, so always delete even after a CI run):
```elisp
(dolist (f (directory-files "/Users/bob/src/octocat" t "\\.el$"))
  (let ((buf (find-buffer-visiting f)))
    (when buf (kill-buffer buf))))
(dolist (f (directory-files "/Users/bob/src/octocat" t "\\.elc$"))
  (delete-file f))
"source-buffers-killed-elc-deleted"
```

**Call 3 — load all files** (returns an alist; any entry whose value is a
string rather than `ok` is an error — fix it before proceeding):
```elisp
(let (results)
  (dolist (f (list "octocat-mermaid.el" "octocat-markdown.el"
                   "octocat-image.el" "octocat-core.el" "octocat-sync.el" "octocat-vui.el"
                   "octocat-diff.el"
                   "octocat-edit.el"
                   "octocat-commit.el" "octocat-compare.el" "octocat-job.el" "octocat-run.el"
                   "octocat-workflow.el" "octocat-pr-diff.el"
                   "octocat-timeline.el" "octocat-pr.el" "octocat-issue.el"
                   "octocat-checks.el" "octocat-tree.el" "octocat-repo.el"
                   "octocat-search.el" "octocat-avatar.el"
                   "octocat-user.el" "octocat-evil.el" "octocat.el"))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents (expand-file-name f "/Users/bob/src/octocat"))
          (emacs-lisp-mode)
          (eval-buffer)
          (push (cons f 'ok) results))
      (error (push (cons f (error-message-string err)) results))))
  (nreverse results))
```

**Call 4 — verify a changed function is live** (returns byte offset or `nil`):
```elisp
(string-search "some-token"
               (format "%s" (symbol-function 'some-fn)))
```

**`makunbound` mode-map vars when keymaps change.** `defvar` skips
re-initialisation if the variable is already bound, so new bindings are
silently ignored on reload. Unset affected maps first (guard with `boundp`
or `ignore-errors` — `makunbound` on a void symbol signals an error):
```elisp
(ignore-errors (makunbound 'octocat-pr-mode-map))
;; … then proceed with Call 1–4 above
```

**Do not use `unload-feature`.** It cascade-unloads dependent features,
leaving dangling advice and repeated `jit-lock` errors. The `with-temp-buffer` +
`eval-buffer` sequence re-evaluates every `defun`/`defvar` without it.

## melpazoid

`make melpazoid` runs MELPA's review checks, and any finding fails it
(see "Building and testing" in CONTRIBUTING.md).  What they rule out:

- No top-level `define-key`, `setq` or `add-hook`.  Bind keys inside the
  map's `defvar` (`(let ((map (make-sparse-keymap))) (define-key map ...)
  map)`); where a lower file calls into a higher one through a variable
  or hook, make the higher function its `defvar` default, with a
  `declare-function`, as `octocat-sync-change-functions` does.
- No `ignore-errors`: test for what can go wrong (`bound-and-true-p`, a
  nil check), or catch only the error meant (`condition-case` on
  `user-error`, `with-demoted-errors`).

## Byte-compiler warnings about functions "not known to be defined"

`make ci` compiles all files in parallel.  The compiler warns "the function
`foo' is not known to be defined" when it sees a call to `foo` in file A
before it has compiled file B (which defines `foo`).  This warning is
non-deterministic — it may appear in some runs and not others depending on
scheduling.

**Fix: add `declare-function` in the calling file.**  When file A calls a
function defined in file B (which A cannot `require` due to circular-load
constraints), suppress the warning by adding a `declare-function` near the
top of A, alongside the other declarations:

```elisp
(declare-function octocat-commit-mode    "octocat-commit" ())
(declare-function octocat-commit-refresh "octocat-commit" (&optional _ignore-auto _noconfirm))
```

The `declare-function` form tells the byte-compiler the function exists
without actually loading the file.  `make lint` checks every one with
`check-declare`: the file must define the function with that arglist.
Prefix the file with `ext:` when it may be missing: an optional package
(`"ext:evil-core"`) or a C primitive some builds lack (`"ext:sqlite.c"`).
Pass `t` as the fourth argument for a function defined by another
package's macro (Evil's `evil-define-motion`), which `check-declare`
cannot see.  At runtime, every `;;;###autoload`
entry point (`M-x octocat`, `M-x octocat-repo`, ...) is defined in
`octocat.el` itself (see "Entry points" in CONTRIBUTING.md), and
`octocat.el` unconditionally `require`s every other file — so any code path
a user can actually reach guarantees all files are loaded, and there is no
missing-definition risk. This is a structural guarantee, not just an
assumption: no other file is allowed to carry its own `;;;###autoload`
command, precisely so a second, independent load path (bypassing
`octocat.el`) can never exist. See `plans/repo-mode-evil-ret-binding.md`
for the bug this convention was introduced to fix (an Evil keybinding
trigger that only ran when `octocat.el` happened to be loaded first).


