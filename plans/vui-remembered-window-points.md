# Report to vui.el: a re-render loses where windows return to a hidden buffer

## Status (2026-10-19): not filed yet; worked around in octocat

- **Upstream:** nothing filed.  Searched every issue and PR in
  d12frosted/vui.el (open and closed) for prev-buffers, quit-window,
  window point, cursor, marker, hidden and position: nothing covers it.
  The closest is PR #157, "fix(render): every window keeps its point
  across a re-render" (merged, by d12frosted), which fixed the same
  marker problem for windows that *show* the buffer and listed
  "a window configuration saved before the render" as not covered.
  PR #159 (anchors for the buffer's point) and the cursor PRs
  #101–#106 are about the buffer's point only.
- **Reproduced** on vui master 6ae6dd9 (2026-10-15), Emacs 31.1, with
  the standalone repro below.
- **Fix sketch** below: tested against the repro (all three paths come
  back to the row) and against vui's own suite (buttercup, 1183 specs,
  0 failed, same as without it).  Not yet written as a vui test.
- **Octocat workaround:** `octocat--resync-prev-buffers` in
  `octocat-core.el`, run first thing in `octocat-quit-window`; test
  `octocat-core-test-quit-window-returns-to-point` in
  `test/octocat-core-tests.el`; documented under "Windows: opening
  pages and `q`" in `docs/user-interface-conventions.md`.

## What the user sees in octocat

On the PR list, put point on a row in the middle and press RET.  The PR
page opens in the same window.  Press `q`: the list comes back with
point at the top of the buffer instead of on the PR's row.

Opening the PR refreshes it in the sync store (`octocat-sync.el`), and
the list reads the same entities, so the list re-renders while the PR
page covers it.  Any refresh of a hidden page does the same: a timer,
a mutation finishing, the store sweeping.

## The bug in vui terms

A window keeps, for each buffer it showed before, where to put that
buffer back: its `window-start` and its point.  Emacs keeps them in
three places:

| Where | Shape | Read by |
|---|---|---|
| `(window-prev-buffers WINDOW)` | `(BUFFER START-MARKER POINT-MARKER)` | `switch-to-prev-buffer` (`C-x <left>`), `quit-window` when nothing else applies, `switch-to-buffer` when `switch-to-buffer-preserve-window-point` is non-nil (the default) |
| window parameter `quit-restore` | `(TYPE (BUFFER START POINT-MARKER HEIGHT) WINDOW THIS-BUFFER)`, START a number | `quit-window` / `quit-restore-window`, recorded by `display-buffer-record-window`, i.e. every `display-buffer` / `pop-to-buffer` that reuses a window |
| window parameter `quit-restore-prev` (new in Emacs 31) | same as `quit-restore` | `quit-restore-window`, preferred over `quit-restore`; recorded when the window already has a `quit-restore` |

The point is a marker in every case.  `vui--rerender-buffer` rewrites the
text (`vui--commit-root` erases and rebuilds, or patches), and deleting
the text under a marker drops it at the start of the deletion: the top
of the buffer for a full render.

`vui--rerender-buffer` already saves and restores the buffer's point
(`vui--save-position`) and the point and start of every window that
*shows* the buffer (`vui--save-window-points`,
`vui--save-window-starts`).  It does nothing for windows that showed it
before, so a buffer re-rendered while hidden comes back at the top
however you return to it: `q`, `C-x b`, `C-x <left>`.

The buffer's own point is right throughout: vui restores it, and Emacs
copies a window's point into its buffer's point when the selected
window switches away from it.  It is only the windows' copies that are
lost.

## Repro (standalone, `emacs -Q`)

```elisp
;;; -*- lexical-binding: t -*-
(require 'vui)
(vui-defcomponent probe-list (tick)
  :render
  (vui-vstack
   (format "tick %s" tick)
   (apply #'vui-vstack
          (mapcar (lambda (i) (vui-button (format "row %d" i) :key i))
                  (number-sequence 1 60)))))

(let* ((root (vui-mount (vui-component 'probe-list :tick 0) "*probe-list*"))
       (list-buf (get-buffer "*probe-list*"))
       (other (get-buffer-create "*probe-other*")))
  (switch-to-buffer list-buf)
  (goto-char (point-min))
  (search-forward "row 40")
  (beginning-of-line)
  (let ((before (point)))
    ;; Open another page in the same window, as RET on a row does
    (switch-to-buffer other)
    (pcase-let ((`(,_ ,start ,pos) (assq list-buf (window-prev-buffers))))
      (message "remembered before render: start %s point %s (buffer point %s)"
               (marker-position start) (marker-position pos)
               (with-current-buffer list-buf (point))))
    ;; A background refresh re-renders the hidden list
    (vui-update-props root '(:tick 1))
    (pcase-let ((`(,_ ,start ,pos) (assq list-buf (window-prev-buffers))))
      (message "remembered after render:  start %s point %s (buffer point %s)"
               (marker-position start) (marker-position pos)
               (with-current-buffer list-buf (point))))
    ;; q
    (quit-window)
    (message "after quit-window: shows %s, window point %s, expected %s (line %s)"
             (buffer-name (window-buffer)) (window-point) before
             (line-number-at-pos (window-point)))))
```

Run with `emacs -Q --batch -L path/to/vui.el -l repro.el`.  On master
6ae6dd9:

```
remembered before render: start 1 point 350 (buffer point 350)
remembered after render:  start 1 point 1 (buffer point 350)
after quit-window: shows *probe-list*, window point 1, expected 350 (line 1)
```

Variants, each also landing on line 1 before the fix:

- `C-x b`: replace `(quit-window)` with `(switch-to-buffer list-buf)`.
- `display-buffer`, as octocat opens pages: replace
  `(switch-to-buffer other)` with
  `(pop-to-buffer other '(display-buffer-same-window))`.  This is the
  one that shows `window-prev-buffers` is not enough: `quit-window` then
  restores from `quit-restore-prev`, whose own point marker the render
  dropped too (print both parameters before quitting to see it):

  ```
  quit-restore-prev: (other (#<buffer *probe-list*> 1 #<marker at 1 in *probe-list*> 80) ...)
  ```

  The first version of the octocat workaround fixed only
  `window-prev-buffers` and missed this.

## Fix sketch

Save every remembered place of the buffer along with the windows'
points, and put it back after the render, through the same
`vui--save-position` / `vui--restored-position` machinery: an anchor
when the text under the place survived, the widget otherwise.  The
start is kept as a line offset from the point, as
`vui--save-window-starts` does for the selected window.

Against master 6ae6dd9:

```diff
--- a/vui.el	2026-10-15 20:57:59.687885513 +0300
+++ b/vui.el	2026-10-19 15:29:00.246029556 +0300
@@ -2987,6 +2987,59 @@
                    (eq (window-buffer window) buffer))
           (set-window-point window pos))))))
 
+(defun vui--remembered-places (buffer)
+  "Return the places windows remember for BUFFER while showing another.
+A window keeps a start and a point for each buffer it showed before:
+in `window-prev-buffers', for `switch-to-prev-buffer' and
+`switch-to-buffer' (with `switch-to-buffer-preserve-window-point'), and
+in its `quit-restore' and `quit-restore-prev' parameters, which
+`display-buffer' records and `quit-window' prefers.  Each place is a
+list (BUFFER START POINT ...) whose POINT is a marker and START a
+marker or a number."
+  (let (result)
+    (dolist (window (window-list-1 nil 'nomini t))
+      (unless (eq (window-buffer window) buffer)
+        (dolist (place (cons (assq buffer (window-prev-buffers window))
+                             (mapcar (lambda (parameter)
+                                       (nth 1 (window-parameter window parameter)))
+                                     '(quit-restore quit-restore-prev))))
+          (when (and (consp place)
+                     (eq (car-safe place) buffer)
+                     (markerp (nth 2 place))
+                     (marker-position (nth 2 place)))
+            (push place result)))))
+    result))
+
+(defun vui--save-remembered-places (buffer)
+  "Save where the windows that showed BUFFER before will put it back.
+Rewriting the text drops their point markers, as it does those of the
+windows showing it (see `vui--save-window-points').  Returns a list of
+(PLACE LINES . SAVED) for `vui--restore-remembered-places': PLACE from
+`vui--remembered-places', LINES how many lines its start is above its
+point, SAVED what `vui--save-position' returns at its point.  Call with
+BUFFER current."
+  (mapcar (lambda (place)
+            (save-excursion
+              (goto-char (nth 2 place))
+              (cons place
+                    (cons (count-lines (min (nth 1 place) (point))
+                                       (line-beginning-position))
+                          (vui--save-position)))))
+          (vui--remembered-places buffer)))
+
+(defun vui--restore-remembered-places (saved)
+  "Put back the places saved by `vui--save-remembered-places'."
+  (pcase-dolist (`(,place ,lines . ,position) saved)
+    (let* ((pos (vui--restored-position position))
+           (start (save-excursion
+                    (goto-char pos)
+                    (forward-line (- lines))
+                    (point))))
+      (set-marker (nth 2 place) pos)
+      (if (markerp (nth 1 place))
+          (set-marker (nth 1 place) start)
+        (setcar (cdr place) start)))))
+
 (defun vui--save-window-starts (buffer)
   "Save viewport restoration data for all windows showing BUFFER.
 Returns an alist of (WINDOW . SPEC).  The window that holds point (the
@@ -3294,6 +3347,8 @@
                ;; windows showing this buffer
                (window-points (vui--save-window-points buffer))
                (window-info (vui--save-window-starts buffer))
+               ;; And where windows that showed it before put it back
+               (remembered (vui--save-remembered-places buffer))
                (vui--root-instance instance)
                ;; Initialize render path for cursor tracking
                (vui--render-path nil)
@@ -3320,6 +3375,7 @@
                 ;; Restore the point, then the viewport, of all windows
                 (vui--restore-window-points window-points)
                 (vui--restore-window-starts window-info)
+                (vui--restore-remembered-places remembered)
                 ;; Run effects after commit
                 (vui--run-pending-effects))
             (setq vui--rendering-p nil)))
```

Notes on it:

- `window-list-1 nil 'nomini t` covers the windows of every frame.  A
  window showing the buffer is skipped: `vui--save-window-points`
  already handles it.
- `quit-restore` keeps its start as a number, which does not move with
  the text at all, so it is replaced in place (`setcar`).  The list is
  the window parameter itself, so no `set-window-parameter` is needed.
- One `vui--save-position` per place: its anchor markers are released
  by `vui--restored-position`, so nothing leaks.  The cost is a
  `count-lines` and an anchor per remembered place, only for windows
  that have the buffer in their history.

## Still to do before filing

- A buttercup spec in `test/vui-rerender-test.el` (or next to the specs
  #157 added) for each path: `quit-window` after `switch-to-buffer`,
  after `pop-to-buffer` with `display-buffer-same-window` (the
  `quit-restore-prev` case, Emacs 31 only: guard it), and
  `switch-to-buffer` back.  Batch Emacs is enough: the positions are
  read without redisplay.  Check that the start comes back too, which
  needs `test/vui-tty-test.el` as for #157.
- `vui--rerender-inline`: a region rewrite drops the markers the same
  way when they are inside the region.  It should save the places
  `vui--region-position-p` holds for, as `vui--save-window-points` does
  with START and END.
- Not covered, as in #157: window configurations saved before the
  render (`window-configuration-to-register`, tab-bar tabs, leaving the
  minibuffer), and `vui-stream-update`.
- Write the issue (or PR) text from "The bug in vui terms", the repro,
  and the fix.  Mention octocat as the case that hit it: a page
  re-rendered while hidden behind the page it opened.

## Once vui has it

- Remove `octocat--resync-prev-buffers`, its call in
  `octocat-quit-window`, and `octocat--window-start-lines` with the line
  that sets it in `octocat-display-buffer` (`octocat-core.el`).
- Keep `octocat-core-test-quit-window-returns-to-point`: it then tests
  vui through octocat.  It erases the buffer itself rather than
  rendering through vui, so rewrite it to render a vui page, or it fails
  once the workaround is gone.
- Trim the workaround sentences from the "`q` returns to where the user
  left the page" bullet in `docs/user-interface-conventions.md`, and
  drop the TODO.md entry.
- Bump the vui version in `Package-Requires` in `octocat.el` to the
  release with the fix.
