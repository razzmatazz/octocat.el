# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master 80a31b6
(2026-11-04), and all are filed.  File a new one at
https://github.com/d12frosted/vui.el/issues, each with a repro run
against vui master first: its code moves fast, and a fix can leave the
code that looked at fault in place
(a handler's remount was fixed that way, in vui 9ed056d).  Once one is
fixed and the `vui` dependency bumped, remove the workaround and its
item here.

## 1. No way to change some of a root's props

`vui-update-props` replaces all the props of an instance.

- **Workaround:** `octocat-vui-update-page` copies them out with the
  struct accessor `vui-instance-props`, changes some, and passes them
  all back.
- **Ask:** a variant, or a flag, that merges the props given into the
  current ones.
- **Filed:** https://github.com/d12frosted/vui.el/issues/296, with a
  repro on vui master e3f1795, as a question of how vui would have it.

## 2. A component's state is read from outside

- **Workaround:** `octocat-vui-list-marks` reads `:marks` off the page's
  root with the struct accessor `vui-instance-state`, for the commands
  that act on the marked items.
- **Ask:** a public getter, or the way vui would rather such state be
  shared with commands.
- **Filed:** https://github.com/d12frosted/vui.el/issues/297, as a
  question.

## 3. A fold growing below point scrolls the window

After a render vui keeps point on the same screen line, so each frame
of a fold unfolding below point scrolls the window by the lines it
added.

- **Workaround:** `octocat-vui-fold-rest` saves the window's start on RET and
  restores it in an effect after each frame (`octocat-vui--fold-pin`).
- **Ask:** keep `window-start` when nothing above point changed, or an
  option to.
- **Filed:** https://github.com/d12frosted/vui.el/issues/298, asking
  whether it is intended; no repro, as it needs a real window.

## 4. Point cannot be put on a row after the first render

The first mount leaves point at `point-min` after its effects run, so an
effect cannot move point; `vui-render` does the same.  `vui-goto-key`
finds only vui's elements, and a row is a `vui-region` (it may hold
link buttons, which a button's label cannot).

- **Workaround:** `octocat-tree--use-focus` and
  `octocat--goto-line-target` (the lines a link names) move point with
  `run-at-time 0`; a test of the latter mounts the component rather
  than `vui-render` it, and waits for the timer.
- **Ask:** a hook run after a render's cursor restoration, or
  `vui-goto-key` also matching a keyed `vui-region`.
- **Filed:** https://github.com/d12frosted/vui.el/issues/295, with a
  repro on vui master e3f1795, leaving the shape of a fix to upstream.
