# Line links: scroll to and highlight the lines a link names

A github.com link can name lines after its `#`, and octocat drops the
fragment: `octocat--github-url-target` matches only the path, so the
page opens at its top.  Make it scroll to those lines and highlight
them, as GitHub does, on the file page and on every diff page.

## The links

| Page                          | Fragment                    | Names                              |
|-------------------------------|-----------------------------|------------------------------------|
| `blob/REF/PATH`               | `#L12`                      | line 12                            |
|                               | `#L12-L20`                  | lines 12 to 20                     |
|                               | `#L12C5-L20C9`              | the same; columns are ignored      |
| `commit/SHA`, `compare/A...B`, `pull/N/files`, `pull/N/commits/SHA` | `#diff-HASH` | file HASH, unfolded, at its heading |
|                               | `#diff-HASHR12`             | line 12 of the new file            |
|                               | `#diff-HASHL12`             | line 12 of the old file (removed)  |
|                               | `#diff-HASHL10-R14`         | a range; its ends may differ in side |

HASH is the hex SHA-256 of the file's path; older links have its MD5
(32 digits), so match either.  A range given backwards (`#L20-L12`) is
put in order.  A fragment of any other shape (`#mit`, a heading) is
ignored, as now.

A markdown or org file opens in its preview, where a source line has
no place: a line link opens it in the code view instead, as GitHub's
`?plain=1` does.

## Design

### Parsing (octocat-core.el, pure)

- `octocat--url-lines (url)`: the fragment as one of
  - `(lines START END)`, from `#L…`;
  - `(diff HASH)` or `(diff HASH (SIDE . LINE) (SIDE . LINE))`, SIDE
    being "LEFT" or "RIGHT", as the `octocat-diff-line` anchor names it;
  - nil.
- `octocat--github-url-target` stays as it is.  `octocat-browse-url`
  appends the fragment, as AT, to the opener's arguments when
  `octocat--url-lines` reads one of the page's form, so the openers of
  the pages that can use it take `&optional at`: `file` a `lines` one,
  `commit`, `compare` and `pr-diff` a `diff` one.
  `pull/N/commits/SHA` already opens `commit`.

### The file page (octocat-repo.el)

- `octocat-tree--open-file-by-path` takes AT and keeps it in a
  buffer-local `octocat-tree--file-lines`, passed to the page as
  `:lines`.  Opening the buffer again with a new link updates the prop.
- `octocat-repo--mark-lines (text start end)`, pure: TEXT with the
  face `octocat-line-highlight` appended (`add-face-text-property`) on
  lines START to END, and a `octocat-line-target` property on START.
  Used by the code and blame views; the memo takes `lines` as a dep.
  A text property, not an overlay, so it survives re-renders.
- An effect in `octocat-repo-vui--file-content` (and `--file-blame`)
  with deps `(lines ready)`, READY being whether the text has loaded:
  it moves point to the `octocat-line-target` text and recenters the
  window showing the buffer, if any.  It runs once when the content
  lands and again for a new range, not on each refresh, so a `g` does
  not pull point back.
- A range past the end of the file highlights what there is; a start
  past it leaves point at the top.

### Diff pages (octocat-diff.el)

- `octocat-diff-files-section` takes AT.  The file whose path hashes
  to HASH (`secure-hash` `sha256`, or `md5`) is unfolded, whatever
  FITS says, through its fold's `:bulk`.
- Each end of the range is mapped to a POSITION through the anchors
  the file's lines already carry (`octocat-diff-line`, `(PATH SIDE
  LINE POSITION HUNK)`), and the lines from one POSITION to the other
  get `octocat-line-highlight`.  That covers ranges whose ends are on
  different sides.  A line the patch does not show (outside its hunks)
  falls back to the file's heading.
- The same kind of effect as the file page's moves point there once the
  diff has rendered.

### Clearing the highlight

The user's refresh, `octocat-vui-refresh` (`g`, `gr`), resets the
page's view, so it clears the lines too: the file page sets
`octocat-tree--file-lines` to nil, and a diff page drops its AT, through
`octocat-vui-use-view-reset`.  A refresh after an action keeps them.

### Links back: the line or region at point

`octocat-browse` and `octocat-copy-url` go through each page's
`octocat--url-function`, which may already look at point.  Those of the
file page and of the diff pages add the lines at point, or of the
region when it is active, in the link's form above:

- **File page** (`octocat-file--page-url`): each line of the code and
  blame views carries its line in the file, an `octocat-file-line` text
  property put on by the same pure function as the highlight.  Point on
  one gives `#L12`; a region gives `#L12-L20`, from its first line to
  its last (a region ending at a line's start stops at the line before).
  Lines with none, the header above the content, are left out: a region
  entirely on them, or point on them, gives the bare link.  In the code
  view of a markdown or org file the link gets `?plain=1`, or GitHub
  would show the preview, where the lines have no place.  The preview
  gives the bare link.
- **Diff pages** (`octocat-commit--page-url`,
  `octocat-compare--page-url`, `octocat-pr-diff--page-url`): the
  anchor at point (`octocat-diff--line-anchor`) gives
  `#diff-HASHR12` or `L12`, the SHA-256 of its path; a file's heading,
  whose anchor is only (PATH), gives `#diff-HASH`.  A region gives the
  first and last anchors of `octocat-diff--anchors`, `#diff-HASHL10-R14`,
  when both are in one file; across files, the first file's link.
- One pure function per form builds the fragment from the anchors, so
  the parser and the builder are tested against each other: what one
  builds, the other reads back.

### Face

`octocat-line-highlight`, in octocat-core.el, inheriting `highlight`:
GitHub's yellow band, in the user's theme.

## Tests

- `octocat--url-lines`: each row of the table above, a backwards range,
  columns, MD5 and SHA-256 hashes, and fragments it must ignore (`#mit`,
  `#L`, `#Lx`, `#diff-zz`).
- `octocat-browse-url` passes `:at` to the right opener (stub
  `octocat-open`), and leaves the existing targets' arguments alone.
- `octocat-repo--mark-lines`: the face is on lines START to END only,
  the target on START; a range past the end; one line.
- The file page, mounted on fixture data: after the blob lands, point is
  on the start line and the range has the face; a `g` keeps point where
  the user moved it; a markdown file opens in the code view.
- A diff page on fixture data: the hashed file is unfolded and the
  others are not, point is on the anchored line, a mixed-side range is
  highlighted across both sides, and an unknown hash changes nothing.
- The user's refresh clears the highlight on both pages; a refresh after
  an action does not.
- Links back: the file page's URL with point on a line, on the header,
  with a region (one line, several, ending at a line's start), and in a
  markdown file's code view (`?plain=1`) and preview; a diff page's URL
  on a line of each side, on a file heading, with a region in one file
  and across two.
- Round trip: for each fragment the builder makes, `octocat--url-lines`
  reads back the same lines, and the page opened from the link
  highlights what the region covered.

## Docs

- CHANGELOG: one line under Unreleased.
- README: a sentence where `octocat-github-links-mode` is described.
- Screenshots: a file page with a range highlighted, as a new shot in
  `docs/screenshots/README.md`.
