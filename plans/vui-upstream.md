# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master 871f517
(2026-11-10, MELPA 20261110.814), and all are filed.  File a new one at
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

## 2. A scroll past a sticky region loses a row after it is measured

With `vui-sticky-keep-header-line` nil, the header line appears only
as Emacs redraws, so a line scrolled to the bottom row is then hidden
under it.

- **Workaround:** `octocat-vui--show-lines` redraws after it scrolls,
  and scrolls again if the text is still not shown whole.
- **Ask:** a public way to sync a window's sticky header line at once,
  or whatever upstream thinks fits better.
- **Filed:** https://github.com/d12frosted/vui.el/issues/312, with a
  repro on vui master 871f517.
