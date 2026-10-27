# Markdown: render HTML through libxml

## Status (2026-10-27): built, phases 1 and 2 together

Done as one design rather than two phases: the markdown rules render
as before, and what they render is held out (as `<x-md i="N">`
placeholders) of the text between them, which libxml then reads.  One
walker, `octocat-markdown--dom-inline`, renders paragraphs, table cells
and `<pre>`.  Whitespace outside tags is swapped for non-ASCII stand-ins
before parsing, as libxml drops blank text between some elements (two
`<img>`s).  `octocat-markdown.el` came out 6 lines shorter; a large
README renders about 8% slower.

## Goal

Less code that gets HTML right.  `octocat-markdown.el` parses HTML with
regexps, and each element has its own: inline tags are rules matched
non-greedily (`<b><b>x</b> y</b>` closes at the first `</b>`) and
carried across lines by `--balance`; `<table>` has its own tokenizer;
attributes are found by `--html-attr`, which a `>` in a quoted value
breaks; entities come from a hand-kept table; and `--mask-attributes`
keeps markdown out of tags.  Each fix adds code, and the next README
finds another gap.

Emacs has a real parser built in: `libxml-parse-html-region`, used by
`shr` and `eww`.  It returns a `dom.el` tree (`dom-tag`, `dom-attr`,
`dom-children`), decodes every entity, and repairs broken HTML the way
a browser does.

**Each phase must remove more lines than it adds.**  Phase 1 does that
clearly.  Phase 2 is done only if a prototype shows it does too.

## libxml is required, with no fallback

Emacs's `configure` turns on libxml2 by default whenever it finds the
library.  Distribution packages, the macOS builds (emacs-plus,
emacs-mac), the GNU Windows builds and our CI images (`libxml2-dev` in
the `Dockerfile`) all have it.  Only a build from source on a machine
without libxml2's headers lacks it.

So there is no second renderer.  Without libxml, HTML shows as its
source, and `M-x octocat-doctor` reports that libxml is missing.  That
costs a `libxml-available-p` check and nothing more.

## Phase 1: parse HTML blocks with libxml

The block layer stays as it is.  Blank lines decide where HTML ends and
markdown begins, as in CommonMark, and that part works.  The change is
how the gathered HTML is read.

- `<table>`: parse its source and walk `tr`/`th`/`td` with `dom.el` to
  get the same (ROWS . LOOSE) that the layouts take today (`--html-grid`,
  `--html-gallery`, `--html-stack`, all unchanged), with `colspan` and
  `align` read by `dom-attr`.  A cell is HTML up to its first blank
  line and markdown after it; libxml keeps that `\n\n` in a text node,
  so split the cell there.
- `<pre>`: parse its body and turn the tree into text, keeping its
  whitespace.
- One small walker, `octocat-markdown--dom-inline (node)`, turns a node
  into a propertized string, reusing `--link`, `--img`, `--face` and
  `--script`.  It is pure.

Removed: `--html-table-source`, `--html-table-parse`, `--html-attr`,
`--entities`, and the `html` path of `--balance` (about 100 lines).
Added: the walker and the table walk (about 50).

## Phase 2, only if it shrinks the code: inline HTML

Inline rules would return HTML instead of propertized strings: `*x*`
gives `<em>x</em>`, code spans give escaped `<code>`, and raw HTML
passes through.  Each paragraph is parsed once and rendered by the
same walker.  Nesting is then right by construction:
`*<a href="…">x</a>*` becomes `<em><a href="…">x</a></em>`.

This would remove `--html-rules`, `--span-tags`, `--balance` and
`--tag-re` (about 70 more lines).  But every inline rule changes, and
references, mentions, emoji and math need elements of their own for the
walker to turn back into buttons.  Prototype it on a branch, and keep it
only if the line count falls and the tests pass.

`<details>` is unchanged in both phases: it gathers lines to its closing
tag and renders the body as markdown, which is right.

## Before starting: check these

- **libxml2 versions.** libxml2 2.14 switched to an HTML5 tokenizer, so
  old and new versions can build different trees from the same broken
  HTML.  Pin what we rely on in tests: the `html`/`body`/`p` wrapping,
  whitespace-only text nodes, and unknown elements being kept.
- **Speed.** Each parse needs a temporary buffer.  Time a large README
  before and after; if it is slow, parse each block in a single call.

## Testing

- `test/octocat-markdown-tests.el` should pass unchanged.  Change a test
  only where its old output was wrong, and say so in the commit.
- Add tests for what regexps got wrong: nested same-name tags, `>` in a
  quoted attribute, an unclosed tag, and entities missing from the old
  table.
- `make screenshots`: the `.txt` diffs should be empty, or show only the
  intended fixes.
