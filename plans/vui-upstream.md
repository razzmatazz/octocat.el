# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master bcb1b76
(2026-11-05), and all are filed.  File a new one at
https://github.com/d12frosted/vui.el/issues, each with a repro run
against vui master first: its code moves fast, and a fix can leave the
code that looked at fault in place
(a handler's remount was fixed that way, in vui 9ed056d).  Once one is
fixed in MELPA's vui, remove the workaround and its item here.

## 1. A fold growing below point scrolls the window

After a render vui keeps point on the same screen line, so each frame
of a fold unfolding below point scrolls the window by the lines it
added.

- **Workaround:** `octocat-vui-fold-rest` saves the window's start on RET and
  restores it in an effect after each frame (`octocat-vui--fold-pin`).
- **Ask:** keep `window-start` when nothing above point changed, or an
  option to.
- **Filed:** https://github.com/d12frosted/vui.el/issues/298, asking
  whether it is intended; no repro, as it needs a real window.

## 2. No sticky region

vui pins a table's header row (`:sticky-header`), but nothing else:
octocat wants any page's title row kept in view.

- **Workaround:** `octocat-vui--sticky-update`, on
  `window-scroll-functions`, sets the window's `header-line-format`
  parameter to a copy of the first line once the window starts past
  it, and `octocat-vui--sticky-unpin` checks it again in a window showing
  another buffer.  Its alignment copies `vui--table-sticky-header-padding`.
- **Other packages:** Info, `org-sticky-header`, `topsy` and
  `semantic-stickyfunc-mode` set a buffer-local `header-line-format`
  that is always shown, `:eval`ing what is at `(window-start)`.  The
  window parameter differs in showing no header line at the top, so no
  blank bar, and in leaving the buffer's own header line, octocat's
  notice, to be shown with it.
- **The web:** CSS `position: sticky` makes it a property of the
  element, with an edge and an offset (`top: 0`, `bottom: 0`, `left: 0`
  for a table's first column), against the nearest scrolling ancestor.
  The element stays within its parent: it is pinned only while the
  parent is in view, and the parent's end pushes it off, so a section's
  heading gives way to the next one's.  Several pin at once, stacked by
  their offsets.  CSS does not say whether an element is stuck: pages
  watch a sentinel with an `IntersectionObserver`, or, in newer
  browsers, query `scroll-state(stuck: top)`.  React adds nothing of
  its own: it renders that CSS.  Native toolkits pin the same way:
  SwiftUI's `LazyVStack(pinnedViews: [.sectionHeaders])`, Flutter's
  `SliverPersistentHeader(pinned: true)`.
- **What to take from it:**
  - sticky as a prop of any region, with an edge and an offset, not
    a page title in particular;
  - bounded by its parent, so a section's heading pins too, and a
    table's `:sticky-header` is one use of it;
  - a stuck state the region can render by, as octocat's underline
    under the pinned title;
  - the pin belongs to the buffer, not the window: octocat's, a window
    parameter, once stayed on a page opened from a scrolled one, over
    that page's own title.
- **Edges in Emacs:** the top is the header line, one row, with the
  tab line above it for a second.  The bottom has only the mode line,
  which is the page's own, and an offset has no line at all: both
  would need an overlay at the window's start or end, placed again on
  each scroll.  Left and right, for a window scrolled sideways with
  `truncate-lines`, could be the margins, which do not scroll.
- **Ask:** a `:sticky` prop on `vui-region` or a stack, taking an edge
  (top first, the others later) and an offset, pinned while the window
  is past it and its parent is in view.  vui's tables could pin through
  the same code, and share the header line with it and with the page's
  own.
- **Filed:** https://github.com/d12frosted/vui.el/issues/305, as a
  question, leaving the API and how it maps onto Emacs to upstream.
