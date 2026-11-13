# Plan: Fast syntax highlighting of Markdown files and repeat renders

## Problem

Opening the diff of a Markdown file with fenced code blocks is slow.  A
10-second CPU profile spent 81% of its samples in one stack:

```
octocat-diff--fontify            (octocat-diff.el)
  font-lock-ensure               (hunk side in markdown-mode)
    markdown-fontify-code-block-natively
      markdown-get-lang-mode     ← all the time is here
```

`octocat--set-mode-for-path` (`octocat-core.el`) sets the mode from the
path, so a `.md` file gets `markdown-mode`.  With
`markdown-fontify-code-blocks-natively` on, markdown-mode highlights each
fence in its language's mode.  It picks the mode with
`markdown-get-lang-mode`, which calls `treesit-language-available-p`
twice per fence.  When no grammar is installed, each call searches for
the grammar library and fails, and nothing caches the miss.

Measured in a live Emacs (Emacs 31, Doom, no grammars installed):

| Call                                    | Time per call |
|-----------------------------------------|---------------|
| `(treesit-language-available-p 'elisp)` | ~37 ms        |
| `(markdown-get-lang-mode "elisp")`      | ~77 ms        |

Every fence costs about 80 ms.  The pages that pay it are the ones that
highlight a `.md` file in markdown-mode:

- the diff, on each side of each hunk (`octocat-diff--fontify`);
- the file viewer showing a Markdown file raw (`octocat-repo--file-text`,
  via `octocat-tree--fontify`);
- blame (`octocat-repo--source-text`, via `octocat-tree--fontify`).

Every page also highlights again from scratch whenever it re-renders:
on a width change, new comments, or toggling raw or folds.  This affects
all languages, not just Markdown:

- diffs (`octocat-diff--fontify`);
- the file viewer and blame (`octocat-tree--fontify`), on the whole file;
- fenced code in issue, PR and comment bodies (`octocat-markdown--highlight`).

## Constraints

- markdown-mode is not in `Package-Requires`, so octocat must not call its
  functions.  It may set one of its user options, declared with
  `defvar`, since that does nothing when markdown-mode is not loaded.
- Overriding `treesit-language-available-p` with `cl-letf` is not an
  option.  Native-compiled callers call primitives directly and would not
  see the override.

## 1. Turn off native fence highlighting where octocat highlights a file

Done.

**`octocat-core.el`:** in `octocat--set-mode-for-path`, after
`set-auto-mode`, add `(setq-local markdown-fontify-code-blocks-natively
nil)` and declare the variable with `(defvar
markdown-fontify-code-blocks-natively)`.  Every caller uses a scratch
buffer, so the setting stays there.  This one place covers the diff,
the file viewer and blame.

The fences keep markdown-mode's code face but lose their language's
colours:

- In a diff this costs little.  A hunk side is a fragment, and a fence
  is often cut off by the hunk boundary.
- In the raw file view and blame it is a real loss.  Accept it: the
  rendered view, the default for Markdown, still colours fences through
  `octocat-markdown-language-modes`.  If the loss turns out to matter,
  turn native highlighting back on there once step 2 makes repeat
  renders free.

Test (`test/octocat-core-test.el` or the diff tests): highlighting a
`.md` path with an `elisp` fence returns the text, and the fence has no
`font-lock-keyword-face`.  Skip the test when markdown-mode is not
installed.

## 2. Cache highlighted text per page

Do this only if a profile after step 1 still shows highlighting during
re-renders.

**Where:** a buffer-local hash table on the page,
`octocat--fontify-cache` (`:test #'equal`), created on first use in
`octocat-core.el`.  It lives in memory only, never in the sync store,
since the highlighted text is derived from content octocat already has.
It dies with the page buffer, so no expiry or size limit is needed: it
holds at most what the page shows.

**Key:** what the result depends on:

- `(path . text)` for `octocat-diff--fontify` (each hunk side) and
  `octocat-tree--fontify`;
- `(lang . code)` for `octocat-markdown--highlight`.

A key built from the content itself cannot go stale when GitHub data
changes: changed text simply misses the cache.

**No TTL.** The only thing that makes an entry wrong is a theme or
font-lock change.  Empty the table when the page is refreshed (`gr`), so
a refresh picks up a new theme.

**How:** one helper in `octocat-core.el`,
`(octocat--fontify-memo KEY FN)`.  It returns the cached value for KEY,
or calls FN and stores the result.  Wrap the three highlighters' bodies
with it.  The lookup must happen in the page buffer, before
`with-temp-buffer` switches buffers.  Check that the page buffer is
current while vui runs `:prepare` and renders components.  If it is not,
pass the table in explicitly.  The cache is a hidden side effect in
otherwise functional code, so say so in the helper's docstring.

A global table, like `octocat-image--cache`, would also share entries
across pages, for example a PR's diff and the same commit's diff.  It
would then need a size cap and a hook on `enable-theme-functions` to
clear it.  Don't build it unless a profile shows cross-page repeats.

## Verify

- Profile as before: `profiler-start 'cpu`, then for 10 s open a PR whose
  diff touches a Markdown file with several fences, and a raw view of
  that file.  Resize the window and toggle folds, then run
  `profiler-report`.  `markdown-get-lang-mode` should be gone.  After
  step 2, the highlighters should not appear during resizes either.
- `make screenshots`: diff and file screenshots that contain Markdown
  should change only in the fences' faces.
- Add a `CHANGELOG.md` entry, e.g. "Markdown files with code blocks open
  much faster in diffs and the file viewer".

## Upstream (separate from octocat)

- markdown-mode could cache `markdown-get-lang-mode` per language, or
  check `fboundp` before it asks tree-sitter.
- 37 ms for a failed `treesit-language-available-p` is unusually slow.
  It is worth checking whether the macOS dynamic-library search (the
  `DYLD_*` variables, Doom's paths) is causing it.
