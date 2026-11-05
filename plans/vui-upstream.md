# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master bcb1b76
(2026-11-05), and all but 2 are filed.  File a new one at
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

## 2. No sticky title for a page

vui pins a table's header row (`:sticky-header`), but nothing else:
octocat wants any page's title row kept in view.

- **Workaround:** `octocat-vui--sticky-update`, on
  `window-scroll-functions`, sets the window's `header-line-format`
  parameter to a copy of the first line once the window starts past
  it, and `octocat-vui--sticky-unpin` drops it from a window showing
  another buffer.  Its alignment copies `vui--table-sticky-header-padding`.
- **Other packages:** Info, `org-sticky-header`, `topsy` and
  `semantic-stickyfunc-mode` set a buffer-local `header-line-format`
  that is always shown, `:eval`ing what is at `(window-start)`.  The
  window parameter differs in showing no header line at the top, so no
  blank bar, and in leaving the buffer's own header line, octocat's
  notice, to be shown with it.
- **Ask:** a sticky region, as for a table's header: a vnode, or a
  `:sticky` prop on `vui-region` or a stack, pinned while the window is
  scrolled past it.  vui's tables could pin through the same code, and
  share the header line with it and with the page's own.
- **Not filed yet.**
