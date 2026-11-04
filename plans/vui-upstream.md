# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master 43ebe18
(2026-11-03), and all are filed.  File a new one at
https://github.com/d12frosted/vui.el/issues, each with a repro run
against vui master first: its code moves fast, and a fix can leave the
code that looked at fault in place
(a handler's remount was fixed that way, in vui 9ed056d).  Once one is
fixed and the `vui` dependency bumped, remove the workaround and its
item here.

## 1. `vui-button` replaces the faces of its label

`vui--insert-text-button` passes a single `face` to
`insert-text-button`, which replaces the faces the label's text
carries, such as a row's state, number and title faces.

- **Workaround:** a list row is a `vui-region :keymap` around a
  `vui-text`, with its RET handler wrapped in an `interactive` lambda
  (`octocat-vui-row`, and its copies in `octocat-actions.el` and
  `octocat-repo.el`).  Folds are `octocat-vui-fold`, not
  `vui-collapsible`, whose toggle draws the whole title in `link`.
- **Ask:** a button that keeps its text's faces, adding its own below
  them (`add-face-text-property`, appended); or a `:title` that takes a
  vnode in `vui-collapsible`; or a clickable row element.
- Removes the most code here of all the items.
- **Filed:** https://github.com/d12frosted/vui.el/issues/290, with the
  fix tried as advice: it keeps the label's faces.
- **Fixed** on vui master by #293: a button's face goes below the faces
  its label has, in `vui-collapsible`'s title and `vui-select` too, so a
  row can be a plain `vui-button`.  CI's vui (MELPA 20261024) predates
  it: drop the workaround once it has it.

## 2. No public way to find the field at point

`vui-field-value` returns a field's text, but not the field.

- **Workaround:** `octocat-vui-list--query-widget` searches
  `widget-field-list` for the query field and completes in it with
  `widget-field-start` and `widget-field-at`; `octocat-evil.el` calls
  `widget-field-at`.  Both depend on vui drawing fields as widgets,
  which vui's issue #113 says consumers should not.
- **Ask:** `vui-field-at` (the field at a position, or nil),
  `vui-element-bounds` (a field's start and end) and
  `vui-field-element` (the field with a key).
- **Filed:** https://github.com/d12frosted/vui.el/issues/291, as a
  follow-up to #113.
- **Fixed** on vui master by #294, as `vui-field-at`,
  `vui-element-bounds` and `vui-element-by-key` (buttons too); the issue
  has the three snippets rewritten on them.  As for 1, once CI's vui
  has it.

## 3. No timer hook

- **Workaround:** `octocat-vui-use-timer`, a repeating timer tied to its
  component: cancelled on unmount and when its dependencies change,
  when the callback returns nil, and when it signals, so a broken frame
  is reported once (see "Timers" in docs/using-vui.md).
- **Ask:** a `vui-use-interval` with the same lifetime.
- **Filed:** https://github.com/d12frosted/vui.el/issues/292.  Upstream
  proposes `(vui-use-interval DEPS SECONDS &rest BODY)`: nil SECONDS for
  no timer, BODY from the latest render, `:stop` to stop it (nil being
  what `vui-set-state` may return); agreed there.  Our four timers tick
  every 0.025s, past `vui-render-delay`'s 0.01, so each tick sees the
  last one's state and they port as they are.

## 4. No way to change some of a root's props

`vui-update-props` replaces all the props of an instance.

- **Workaround:** `octocat-vui-update-page` copies them out with the
  struct accessor `vui-instance-props`, changes some, and passes them
  all back.
- **Ask:** a variant, or a flag, that merges the props given into the
  current ones.
- **Filed:** https://github.com/d12frosted/vui.el/issues/296, with a
  repro on vui master e3f1795, as a question of how vui would have it.

## 5. A component's state is read from outside

- **Workaround:** `octocat-vui-list-marks` reads `:marks` off the page's
  root with the struct accessor `vui-instance-state`, for the commands
  that act on the marked items.
- **Ask:** a public getter, or the way vui would rather such state be
  shared with commands.
- **Filed:** https://github.com/d12frosted/vui.el/issues/297, as a
  question.

## 6. A fold growing below point scrolls the window

After a render vui keeps point on the same screen line, so each frame
of a fold unfolding below point scrolls the window by the lines it
added.

- **Workaround:** `octocat-vui-fold` saves the window's start on RET and
  restores it in an effect after each frame (`octocat-vui--fold-pin`).
- **Ask:** keep `window-start` when nothing above point changed, or an
  option to.
- **Filed:** https://github.com/d12frosted/vui.el/issues/298, asking
  whether it is intended; no repro, as it needs a real window.

## 7. Point cannot be put on a row after the first render

The first mount leaves point at `point-min` after its effects run, so an
effect cannot move point; `vui-render` does the same.  `vui-goto-key`
finds only widgets, and rows are text (see 1).

- **Workaround:** `octocat-tree--use-focus` and
  `octocat--goto-line-target` (the lines a link names) move point with
  `run-at-time 0`; a test of the latter mounts the component rather
  than `vui-render` it, and waits for the timer.
- **Ask:** a hook run after a render's cursor restoration, or
  `vui-goto-key` also matching a keyed `vui-region`.
- **Filed:** https://github.com/d12frosted/vui.el/issues/295, with a
  repro on vui master e3f1795, leaving the shape of a fix to upstream.
