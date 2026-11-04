# What to ask of vui.el upstream

Places where octocat works around vui.el, and what upstream could
offer instead.  Each was checked against vui master 43ebe18
(2026-11-03).  File them at https://github.com/d12frosted/vui.el/issues
one at a time, with a repro like the one in TODO.md; once one is fixed
and the `vui` dependency bumped, remove the workaround and its item here.

## 1. A remount inside a handler is undone

A `vui-mount` from an `:on-click` or `:on-submit` handler is undone when
the handler returns, and the new tree leaks with its effects still
running.  The handler wrappers bind `vui--root-instance` in a `let`.

- **Workaround:** never remount a page, and defer any remount with
  `run-at-time 0` (see "Update a page in place" in docs/using-vui.md).
- **Ask:** carry a root replaced during the handler out of the `let`.
- The issue, written up in full with a repro and a fix, is the first
  item of TODO.md.

## 2. `vui-button` replaces the faces of its label

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

## 3. No public way to find the field at point

`vui-field-value` returns a field's text, but not the field.

- **Workaround:** `octocat-vui-list--query-widget` searches
  `widget-field-list` for the query field and completes in it with
  `widget-field-start` and `widget-field-at`; `octocat-evil.el` calls
  `widget-field-at`.  Both depend on vui drawing fields as widgets,
  which vui's issue #113 says consumers should not.
- **Ask:** `vui-field-at` (the field at a position, or nil) and
  `vui-field-bounds` (a field's start and end).

## 4. No timer hook

- **Workaround:** `octocat-vui-use-timer`, a repeating timer tied to its
  component: cancelled on unmount and when its dependencies change,
  when the callback returns nil, and when it signals, so a broken frame
  is reported once (see "Timers" in docs/using-vui.md).
- **Ask:** a `vui-use-interval` with the same lifetime.

## 5. No way to change some of a root's props

`vui-update-props` replaces all the props of an instance.

- **Workaround:** `octocat-vui-update-page` copies them out with the
  struct accessor `vui-instance-props`, changes some, and passes them
  all back.
- **Ask:** a variant, or a flag, that merges the props given into the
  current ones.

## 6. A component's state is read from outside

- **Workaround:** `octocat-vui-list-marks` reads `:marks` off the page's
  root with the struct accessor `vui-instance-state`, for the commands
  that act on the marked items.
- **Ask:** a public getter, or the way vui would rather such state be
  shared with commands.

## 7. A fold growing below point scrolls the window

After a render vui keeps point on the same screen line, so each frame
of a fold unfolding below point scrolls the window by the lines it
added.

- **Workaround:** `octocat-vui-fold` saves the window's start on RET and
  restores it in an effect after each frame (`octocat-vui--fold-pin`).
- **Ask:** keep `window-start` when nothing above point changed, or an
  option to.

## 8. Point cannot be put on a row after the first render

The first mount leaves point at `point-min` after its effects run, so an
effect cannot move point.  `vui-goto-key` finds only widgets, and rows
are text (see 2).

- **Workaround:** `octocat-tree--use-focus` moves point with
  `run-at-time 0`.
- **Ask:** a hook run after a render's cursor restoration, or
  `vui-goto-key` also matching a keyed `vui-region`.
