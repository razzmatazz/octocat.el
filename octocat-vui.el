;;; octocat-vui.el --- vui.el helpers and components for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5
;; Assisted-by: Claude:claude-opus-5-5

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Small building blocks on top of vui.el: hooks, components and vnode
;; builders shared by the vui-based buffers.  The generic ones (rows,
;; load-more, folds) know nothing about GitHub; the list-page
;; section below is the exception and knows just enough about a repo to
;; share the keymap, the header counts and the search-query filter.
;; Everything buffer-specific stays in the buffer's own file (e.g.
;; `octocat-repo.el').
;;
;; Contents:
;;
;;   `octocat-vui-page-map'          parent keymap of every vui page
;;   `octocat-vui-row'               RET-able, per-segment-styled line
;;   `octocat-vui-use-resource'      read a sync resource; re-render on change
;;   `octocat-vui-refresh-page'      mount a page, or refresh it in place
;;   `octocat-vui-load-more-button'  "[+] Load N more…" button
;;   `octocat-vui-reveal-list'       `vui-list' whose later-added rows
;;                                   unfold progressively
;;   `octocat-vui-fold'              header row with an animated fold
;;   `octocat-vui-fold-header'       its ▸/▾ header, a TAB stop
;;   `octocat-vui-expand-all-button' unfolds or folds every fold of a section
;;   `octocat-vui-list-mode'         base mode of the PR/issue list pages
;;                                   and the Actions page
;;   `octocat-vui-actions-header'    header of workflow, run and job pages
;;   `octocat-vui-repo-tabs'         Code / Issues / Pull requests / Actions
;;                                   tab strip shared by the repo pages
;;   `octocat-vui-list-header'       list page header with open/closed counts
;;   `octocat-vui-list-filter-bar'   query field + facet buttons

;;; Code:

(require 'octocat-core) ; `octocat-dimmed' face
(require 'octocat-sync)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'vui)
(require 'vui-components)

(defvar octocat-repo-vui--state-width)  ; defconst in octocat-repo.el
(defvar octocat-repo-vui--mark-width)   ; defconst in octocat-repo.el
(declare-function octocat-repo-vui--compact-width "octocat-repo" (lines width))

(defvar octocat-vui-page-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (make-composed-keymap octocat-common-map vui-mode-map))
    (define-key map (kbd "q") #'octocat-quit-window)
    (define-key map (kbd "g") #'octocat-vui-refresh)
    map)
  "Parent keymap of every vui-rendered octocat page, for the keys all share.")

(defvar-local octocat-vui--view-generation 0
  "Bumped by each `octocat-vui-refresh', see `octocat-vui-use-view-reset'.")

(defun octocat-vui-refresh ()
  "Refresh the page, and show it as it opens, every view toggle reset.
Images shown in place are links again, and <details>, folds and
expanded entries are as first drawn.  Point, filters, the ref shown
and what \"load more\" added stay.  A page refreshed by itself, as
after an action, keeps its view: only this command resets it."
  (interactive)
  (cl-incf octocat-vui--view-generation)
  (octocat-image-reset)
  (octocat-markdown-reset-details)
  (revert-buffer))

(defun octocat-vui-use-view-reset (reset)
  "Call RESET once the page is refreshed by `octocat-vui-refresh'.
RESET, made by `vui-async-callback' during render, puts the calling
component's view state back as it was when it mounted.  Must be called
during render, like any hook."
  (let ((seen (vui-use-ref octocat-vui--view-generation))
        (gen  octocat-vui--view-generation))
    (vui-use-effect (gen)
      (unless (eql (car seen) gen)
        (setcar seen gen)
        (funcall reset))
      nil)))

(defun octocat-vui-row (line on-visit &optional help-echo url)
  "Build a RET-able row vnode from already-propertized LINE.
LINE may instead be a list of strings and vnodes, laid out on one line:
its vnodes, such as buttons, keep their own RET and are TAB stops.
ON-VISIT is a zero-argument function invoked when RET is pressed on the
row.  HELP-ECHO defaults to a generic hint.  URL, if non-nil, is the
GitHub page of what the row opens, for `octocat-browse' and
`octocat-copy-url'.

A row is a `vui-region' wrapping a single `vui-text' line, with a tiny
keymap binding RET to the row's navigation.  `vui-text' inserts its
content as-is, preserving whatever per-segment `face' properties LINE
already carries (e.g. a different face for a branch column vs. the title
vs. the state); it is deliberately not a `vui-button', since a button
applies a single `face' across the whole label, which would clobber that
per-segment styling.

The keymap binds RET to a wrapper command, not ON-VISIT directly:
`command-execute' (what a real keypress dispatches through) requires
`commandp', which a plain lambda without `(interactive)' does not
satisfy -- binding ON-VISIT itself would look right but signal
`wrong-type-argument commandp' the moment RET is actually pressed.

HELP-ECHO goes only on the parts of LINE without a `help-echo' of their
own, so a segment such as a relative date keeps its own hover text
\(the exact time, see `octocat--format-ts-relative')."
  (let ((map (let ((m (make-sparse-keymap)))
               (define-key m (kbd "RET") (lambda () (interactive) (funcall on-visit)))
               m)))
    (vui-region :keymap map
                (if (stringp line)
                    (octocat-vui-row--text line help-echo url)
                  (vui-hstack :spacing 0
                              (mapcar (lambda (part)
                                        (if (stringp part)
                                            (octocat-vui-row--text part help-echo url)
                                          part))
                                      line))))))

(defun octocat-vui-row--text (string help-echo url)
  "Return a `vui-text' of STRING highlighted as part of a row with HELP-ECHO.
URL, if non-nil, goes on it as the text property `octocat-url'."
  (vui-text (octocat-vui--default-help-echo string (or help-echo "RET: view details"))
    'mouse-face 'highlight 'octocat-url url))

(defun octocat-vui--default-help-echo (string help-echo)
  "Return a copy of STRING with HELP-ECHO on the parts lacking a `help-echo'."
  (let ((s   (copy-sequence string))
        (pos 0))
    (while (< pos (length s))
      (let ((next (next-single-property-change pos 'help-echo s (length s))))
        (unless (get-text-property pos 'help-echo s)
          (put-text-property pos next 'help-echo help-echo s))
        (setq pos next)))
    s))

;; Pages read the sync store through `octocat-vui-use-resource'.  Each
;; hook registers its buffer and version ref under its resource key; a
;; change bumps the versions and re-renders each buffer once.

(defvar octocat-vui--subscriptions (make-hash-table :test #'equal)
  "Resource key to the (BUFFER . VERSION-REF) of each hook reading it.")

(defun octocat-vui--on-sync-change (keys)
  "Re-render, once each, the pages reading a resource in KEYS."
  (let (buffers)
    (dolist (key keys)
      (pcase-dolist (`(,buf . ,version) (gethash key octocat-vui--subscriptions))
        (setcar version (1+ (car version)))
        (cl-pushnew buf buffers)))
    (dolist (buf buffers)
      (when-let* ((root (and (buffer-live-p buf) (vui-get-instance buf))))
        (vui-rerender root)))))

(defvar-local octocat-vui--loading-keys nil
  "Keys of the resources this buffer's page reads that are being fetched.")

(defun octocat-vui--set-key-loading (buf key loading)
  "Record in BUF that resource KEY is LOADING, and show it in its mode line."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq octocat-vui--loading-keys
            (if loading
                (cl-adjoin key octocat-vui--loading-keys :test #'equal)
              (delete key octocat-vui--loading-keys)))
      (octocat-vui--show-busy))))

(defun octocat-vui--on-sync-loading (key loading)
  "Show in the mode line of each page reading KEY whether it is LOADING.
No re-render: a refetch shows only here until its data changes."
  (pcase-dolist (`(,buf . ,_) (gethash key octocat-vui--subscriptions))
    (octocat-vui--set-key-loading buf key loading)))

(defun octocat-vui--on-sync-invalidate (keys)
  "Refetch the resources of KEYS that are on a page; the rest wait to be opened."
  (dolist (key keys)
    (when (gethash key octocat-vui--subscriptions)
      (octocat-sync-request (car (read-from-string key)) t))))

(defvar-local octocat-vui--snapshots nil
  "Resource key to the snapshot this buffer's page reads, for its header line.")

(defun octocat-vui-header-notice (snapshots)
  "Return the header line notice for a page showing SNAPSHOTS, or nil.
There is one when the page shows data whose refresh failed: the data
stays, and the notice says it may be out of date.  A refetch shows only
in the mode line, as a passing notice would resize the window."
  (when-let* ((snap (seq-find (lambda (s)
                                (and (plist-get s :data) (plist-get s :error)
                                     (not (plist-get s :loading))))
                              snapshots)))
    (if (eq (plist-get snap :kind) 'offline)
        (format "Offline: showing data from %s; g to retry"
                (if-let* ((at (plist-get snap :fetched-at)))
                    (format-time-string "%H:%M" at)
                  "earlier"))
      (format "Refresh failed: %s; g to retry"
              (car (split-string (plist-get snap :error) "\n" t))))))

(defun octocat-vui--show-notice (buf)
  "Put in BUF's header line the notice for the snapshots of its page."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((notice (octocat-vui-header-notice
                     (and octocat-vui--snapshots
                          (hash-table-values octocat-vui--snapshots)))))
        (setq header-line-format
              (and notice (propertize notice 'face 'octocat-dimmed)))))))

(defvar-local octocat-vui--resource-ticks nil
  "Resource key to the page tick it was last requested with, in this buffer.
Kept per buffer, not per component, so a component remounted by a
refresh still sees that the tick is new.")

(defun octocat-vui-use-resource (spec tick)
  "Return the sync snapshot of SPEC, a plist (:data :loading :error …).
The page re-renders when the snapshot changes, and its mode line shows
when SPEC is being fetched; a refetch of shown data that changes nothing
renders nothing, so its :loading is only current while it has no data.
Opening fetches SPEC unless it was fetched just now; a new TICK (see
`octocat-vui-refresh-page') always does.  A component that reads it must
not be `:memo', since the change re-renders from the page's root.  When
a refresh fails over shown data, the header line says so, see
`octocat-vui-header-notice'.  Must be called during render, like any
hook."
  (let* ((key      (octocat-sync-spec-key spec))
         (buf      (current-buffer))
         (version  (vui-use-ref 0))
         (v        (car version)))
    (vui-use-effect (key)
      (let ((entry (cons buf version)))
        (push entry (gethash key octocat-vui--subscriptions))
        (when (and (gethash key octocat-sync--loading)
                   (not (gethash key octocat-sync--quiet)))
          (octocat-vui--set-key-loading buf key t))
        (octocat-vui--poll-start)
        (lambda ()
          (octocat-vui--set-key-loading buf key nil)
          (let ((rest (delq entry (gethash key octocat-vui--subscriptions))))
            (if rest
                (puthash key rest octocat-vui--subscriptions)
              (remhash key octocat-vui--subscriptions)
              (when (hash-table-empty-p octocat-vui--subscriptions)
                (octocat-vui--poll-stop t)))))))
    (vui-use-effect (key tick)
      ;; Only a new tick for a key this buffer asked for before is a refresh.
      (let* ((ticks (or octocat-vui--resource-ticks
                        (setq octocat-vui--resource-ticks (make-hash-table :test #'equal))))
             (seen  (gethash key ticks)))
        (puthash key tick ticks)
        (octocat-sync-request spec (and seen (not (equal seen tick)))))
      nil)
    (let ((snap (vui-use-memo (key v) (octocat-sync-read spec))))
      (vui-use-effect (key snap)
        (puthash key snap (or octocat-vui--snapshots
                              (setq octocat-vui--snapshots
                                    (make-hash-table :test #'equal))))
        (octocat-vui--show-notice buf)
        (lambda ()
          (when-let* ((snaps (and (buffer-live-p buf)
                                  (buffer-local-value 'octocat-vui--snapshots buf))))
            (remhash key snaps)
            (octocat-vui--show-notice buf))))
      snap)))

(defun octocat-vui-use-latest-resource (spec tick &optional same)
  "Return the snapshot of SPEC, or, while it has none, the last that had data.
That is of the last spec this component showed with data, for the same
SAME, so a page whose spec moves on, such as to a new tree SHA after a
push, keeps showing the old data until the new comes, rather than
flashing grey bars.  SAME tells apart specs that show different things,
such as another document.  See `octocat-vui-use-resource', whose TICK it
passes; a hook."
  (let* ((snap (octocat-vui-use-resource spec tick))
         (last (vui-use-ref nil)))
    (cond ((plist-get snap :data)
           (setcar last (cons same snap))
           snap)
          ((and (car last) (equal (caar last) same)
                (eq (octocat-vui-snapshot-status snap) 'pending))
           (cdar last))
          (t snap))))

(defvar-local octocat-vui--prefetch-timer nil
  "Timer that prefetches what the row at point opens, see below.")

(defun octocat-vui--prefetch-schedule ()
  "Prefetch the specs of the row at point once point rests there.
For `post-command-hook'.  A row names them in its text property, the
symbol `octocat-sync-prefetch'.  Each command restarts the wait, so
moving through rows prefetches nothing."
  (when (timerp octocat-vui--prefetch-timer)
    (cancel-timer octocat-vui--prefetch-timer))
  (setq octocat-vui--prefetch-timer
        (when-let* ((specs (and octocat-sync-prefetch
                                (get-text-property (point) 'octocat-sync-prefetch))))
          (run-with-timer octocat-sync-prefetch-delay nil #'octocat-sync-prefetch specs))))

;; Pages on screen refetch what they show; see "Keeping shown pages up to
;; date" in docs/user-interface-conventions.md.  The timer runs only
;; while a page is on screen; showing one starts it again.

(defconst octocat-vui--poll-tick 5
  "Seconds between checks for what pages on screen have due.")

(defvar octocat-vui--poll-timer nil
  "Timer of `octocat-vui--poll', while a page is on screen.")

(defvar octocat-vui--poll-shown nil
  "The buffers of the pages on screen at the last check.")

(defvar octocat-vui--poll-state nil
  "The last check, (TIME SLOWDOWN IDLE FOCUSED POWER), for `octocat-doctor'.")

(defun octocat-vui--shown-pages ()
  "Return the live buffers of the pages in a window of a visible frame."
  (let (bufs)
    (maphash (lambda (_ subs)
               (pcase-dolist (`(,buf . ,_) subs)
                 (when (and (not (memq buf bufs)) (buffer-live-p buf)
                            (get-buffer-window buf 'visible))
                   (push buf bufs))))
             octocat-vui--subscriptions)
    bufs))

(defun octocat-vui--page-specs (buffers)
  "Return the specs of the resources the pages in BUFFERS read."
  (let (specs)
    (maphash (lambda (key subs)
               (when (seq-some (lambda (s) (memq (car s) buffers)) subs)
                 (push (car (read-from-string key)) specs)))
             octocat-vui--subscriptions)
    specs))

(defun octocat-vui--focused-p ()
  "Return non-nil if an Emacs frame has focus, or none can tell."
  (seq-some #'frame-focus-state (frame-list)))

(defun octocat-vui--catch-up (&optional buffers)
  "Refetch at once what is due on the pages in BUFFERS, or on screen."
  (when-let* ((bufs (or buffers (octocat-vui--shown-pages))))
    (octocat-sync-poll (octocat-vui--page-specs bufs) 1 nil)))

(defun octocat-vui--resume ()
  "Catch up on the first command after a pause, see `octocat-vui--poll'."
  (remove-hook 'pre-command-hook #'octocat-vui--resume)
  (octocat-vui--catch-up))

(defun octocat-vui--on-focus ()
  "Catch up when an Emacs frame gets focus again.
Outside the hook, which runs during redisplay."
  (when (octocat-vui--focused-p)
    (run-at-time 0 nil #'octocat-vui--catch-up)))

(defun octocat-vui--on-window-buffers (&optional _frame)
  "Check the pages on screen once what windows show changed.
Outside the hook, which runs during redisplay."
  (run-at-time 0 nil #'octocat-vui--poll-shown-changed))

(defun octocat-vui--poll-shown-changed ()
  "Catch up on the pages newly on screen, and run the timer while there are any.
Return the pages on screen."
  (let* ((shown (octocat-vui--shown-pages))
         (new   (seq-difference shown octocat-vui--poll-shown #'eq)))
    (setq octocat-vui--poll-shown shown)
    (when new (octocat-vui--catch-up new))
    (if shown
        (unless (timerp octocat-vui--poll-timer)
          (setq octocat-vui--poll-timer
                (run-with-timer octocat-vui--poll-tick octocat-vui--poll-tick
                                #'octocat-vui--poll)))
      (octocat-vui--poll-stop))
    shown))

(defun octocat-vui--poll ()
  "Refetch quietly what the pages on screen have due, see `octocat-sync-poll'.
Past a long pause, catch up on the first command instead."
  (let* ((shown    (octocat-vui--poll-shown-changed))
         (idle     (float-time (or (current-idle-time) 0)))
         (focused  (octocat-vui--focused-p))
         (power    (octocat-power))
         (slowdown (octocat-sync-poll-slowdown idle focused power octocat-sync--offline)))
    (setq octocat-vui--poll-state (list (float-time) slowdown idle focused power))
    ;; Nil specs drop the refetches still queued.
    (octocat-sync-poll (and slowdown (octocat-vui--page-specs shown)) (or slowdown 1) t)
    (when (>= idle (* 6 octocat-sync-poll-idle-after))
      (add-hook 'pre-command-hook #'octocat-vui--resume))))

(defun octocat-vui--poll-start ()
  "Watch for pages coming on screen and focus coming back, and check now.
Nothing when `octocat-sync-poll-interval' is nil."
  (when octocat-sync-poll-interval
    (add-hook 'window-buffer-change-functions #'octocat-vui--on-window-buffers)
    (add-function :after after-focus-change-function #'octocat-vui--on-focus)
    (unless (timerp octocat-vui--poll-timer)
      (octocat-vui--on-window-buffers))))

(defun octocat-vui--poll-stop (&optional unwatch)
  "Stop the timer and drop the timed refetches queued; with UNWATCH, the hooks too."
  (when (timerp octocat-vui--poll-timer)
    (cancel-timer octocat-vui--poll-timer))
  (setq octocat-vui--poll-timer nil)
  (octocat-sync-poll nil 1 t)
  (when unwatch
    (setq octocat-vui--poll-shown nil)
    (remove-hook 'window-buffer-change-functions #'octocat-vui--on-window-buffers)
    (remove-hook 'pre-command-hook #'octocat-vui--resume)
    (remove-function after-focus-change-function #'octocat-vui--on-focus)))

(defun octocat-vui-snapshot-status (snap)
  "Return the state a page draws for the sync snapshot SNAP.
That is `ready' when it has data, `error' when it has none and its last
fetch failed, and `pending' while there is none yet."
  (cond ((plist-get snap :data) 'ready)
        ((and (plist-get snap :error) (not (plist-get snap :loading))) 'error)
        (t 'pending)))

(defun octocat-vui-error-text (snap)
  "Return the error text for SNAP, a snapshot that failed with no data."
  (let ((error (or (plist-get snap :error) "")))
    (concat
     (pcase (plist-get snap :kind)
       ('offline "Offline: GitHub can't be reached")
       ('permanent (if (string-match-p "HTTP 40[13]\\|not accessible\\|permission" error)
                       "No access"
                     "Not found"))
       (_ (concat "Error: " (car (split-string error "\n" t)))))
     "; g to retry")))

(cl-defun octocat-vui-resource-view (snap &key skeleton render)
  "Return the vnode of a page part showing SNAP, a sync snapshot.
RENDER is called with the data when there is some.  Else SKELETON is
called with the :partial data, or nil, for grey bars shaped like the
part to come, unless the fetch failed: then the error shows, as
`octocat-vui-error-text' words it."
  (pcase (octocat-vui-snapshot-status snap)
    ('ready (funcall render (plist-get snap :data)))
    ('error (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error))
    (_ (funcall skeleton (plist-get snap :partial)))))

(defun octocat-vui-use-detail (spec tick)
  "Return the snapshot of SPEC, an issue's or PR's page resource.
As `octocat-vui-use-resource', for TICK too, but :data is the item, its
parts put back (see `octocat-sync-detail-item').  Must be called during
render, like any hook."
  (let ((snap (octocat-vui-use-resource spec tick)))
    (vui-use-memo (snap)
      (let ((data (plist-get snap :data)))
        (if data
            (plist-put (copy-sequence snap) :data (octocat-sync-detail-item data))
          snap)))))

(defun octocat-vui-skeleton-bar (n)
  "Return a grey bar N columns wide (at least one) standing in for content."
  (propertize (make-string (max 1 n) ?\s) 'face 'octocat-skeleton))

(defun octocat-vui-skeleton (rows &optional width)
  "Return ROWS of grey bars, each cut short of WIDTH when it is given.
A row is a list of bar widths and literal strings, such as an indent or
a dimmed marker; nil is an empty line."
  (mapconcat (lambda (row)
               (let ((line (mapconcat (lambda (x)
                                        (if (numberp x) (octocat-vui-skeleton-bar x) x))
                                      row "")))
                 (if width (truncate-string-to-width line (max 10 (1- width))) line)))
             rows "\n"))

(defun octocat-vui-detail-skeleton (repo number width &optional tabs)
  "Return grey bars shaped like the issue or PR NUMBER of REPO, cut to WIDTH.
Shown when there is neither a cache nor a response yet: the header and
the opening timeline entry, laid out as the real page lays them out.
TABS, a list of tab labels, adds the tab strip of a PR page (see
`octocat-vui-tab-row')."
  (let* ((state  octocat-repo-vui--state-width)
         (indent (make-string (+ octocat-repo-vui--state-width 2) ?\s))
         (strip  (and tabs (string-join tabs "  "))))
    (octocat-vui-skeleton
     `((,(propertize repo 'face 'octocat-repo)
        ,(propertize (format "#%d" number) 'face 'octocat-pr-number)
        "  " 44 "  " 10)
       (,state "  " 16 "  " 22)
       (,indent 24)
       nil
       ,@(and tabs
              `((,(propertize strip 'face '(octocat-dimmed underline))
                 ,(propertize (make-string (max 0 (- width (string-width strip))) ?\s)
                              'face 'underline))))
       ,@(octocat-vui--post-skeleton-rows))
     width)))

(defun octocat-vui--post-skeleton-rows ()
  "Return the skeleton rows of an opening timeline post.
They are rows as `octocat-vui-skeleton' takes."
  (let ((rail (concat (propertize "│" 'face 'octocat-dimmed) " ")))
    `((,(propertize "●" 'face 'octocat-dimmed) " " 36)
      (,rail 64) (,rail 58) (,rail 62) (,rail 44) (,rail)
      (,rail 60) (,rail 52) (,rail 30)
      nil)))

(defun octocat-vui-post-skeleton (width)
  "Return grey bars shaped like an opening timeline post, cut to WIDTH.
Shown under a header painted from data another page fetched."
  (octocat-vui-skeleton (octocat-vui--post-skeleton-rows) width))

(defun octocat-vui-list-skeleton (width &optional compact no-state)
  "Return grey bars shaped like a page of two-line list rows, cut to WIDTH.
COMPACT shapes them as one-line rows instead, without the state when
NO-STATE is non-nil.  Each starts with a blank mark column.  Shown when
there is neither a cache nor a response yet; see
`octocat-repo-vui--item-row' for the layout it imitates."
  (let* ((mark   (make-string octocat-repo-vui--mark-width ?\s))
         (state  octocat-repo-vui--state-width)
         (indent (concat mark (make-string (+ state 2) ?\s))))
    (octocat-vui-skeleton
     (if compact
         (mapcar (lambda (title)
                   `(,mark ,@(unless no-state (list state "  ")) 4 "  " ,title "  " 12))
                 '(44 30 38 24))
       `((,mark ,state "  " 44 "  " 16) (,indent 32)
         (,mark ,state "  " 30 "  " 16) (,indent 18)))
     width)))

(defun octocat-vui-line-skeleton (&optional indent)
  "Return grey bars shaped like a few one-line rows: an id, a title, a date.
INDENT, a string, starts each row."
  (let ((indent (or indent "")))
    (octocat-vui-skeleton (mapcar (lambda (title) (list indent 7 "  " title "  " 12))
                                  '(44 30 38)))))

(defun octocat-vui-load-more-button (key count help-echo on-click
                                         &optional loading indent skeleton)
  "Return a \"Load COUNT more…\" vui-button with HELP-ECHO, invoking ON-CLICK.
KEY is a per-section symbol: it is the button's cursor identity, so point
stays on this section's button when growing the list re-renders it
instead of drifting to a neighbouring section's button.
LOADING is non-nil while the next page is fetched: the button is
disabled so it cannot be triggered twice, and SKELETON, grey bars
shaped like the rows (see `octocat-vui-list-skeleton'), unfolds above
it, folding away as the page's rows unfold.
Rows carry no trailing newline (`vui-list' only separates them), so the
skeleton and the button start on a fresh line and carry the same indent,
INDENT columns \(default two).  The flush-left list pages pass 0."
  (let ((pad (make-string (or indent 2) ?\s)))
    (vui-fragment
     (when skeleton
       (vui-component 'octocat-vui-unfolding-text
         :text (concat "\n" pad (string-replace "\n" (concat "\n" pad) skeleton))
         :open (and loading t)))
     (vui-newline)
     (vui-text pad)
     (vui-button (format "[+] Load %d more…" count)
       :no-decoration t
       :face 'octocat-dimmed
       :key key
       :disabled loading
       :help-echo (if loading nil help-echo)
       :on-click on-click))))

(defmacro octocat-vui-use-timer (deps interval active &rest body)
  "Run BODY every INTERVAL seconds while ACTIVE, tied to the component.
The timer is started when the component renders with ACTIVE true, and
restarted when DEPS, a list of variables like `vui-use-effect' takes,
change; ACTIVE should depend only on them.  It is cancelled when DEPS
change, when the component unmounts, when BODY returns nil (done), and
when BODY signals an error, so a broken frame is reported once instead
of on every tick.  BODY runs in the component's context, so it may call
`vui-set-state'.  Every octocat timer goes through here."
  (declare (indent 3))
  (let ((timer (make-symbol "timer")))
    `(vui-use-effect ,deps
       (when ,active
         (let ((,timer nil))
           (setq ,timer
                 (run-with-timer
                  ,interval ,interval
                  (vui-with-async-context
                   (condition-case err
                       (unless (progn ,@body)
                         (cancel-timer ,timer))
                     (error (cancel-timer ,timer)
                            (signal (car err) (cdr err)))))))
           (lambda () (cancel-timer ,timer)))))))

(defconst octocat-vui-unfold-growth 0.4
  "How much of the distance still to go each frame of an animation moves.
At least two things, so an animation eases out onto its end.")

(defconst octocat-vui-unfold-peak 0.15
  "Most of an animation's whole distance one frame may move.
Caps the speed at the start, so it begins at full speed rather than
jumping most of the way in its first frame.")

(defconst octocat-vui-unfold-interval 0.025
  "Seconds between the frames of an unfolding animation.")

(defun octocat-vui-unfold-step (now from to)
  "Return the position after NOW of an animation going FROM to TO.
Starts fast and eases out, see `octocat-vui-unfold-growth'."
  (let* ((span (abs (- to from)))
         (step (max 2 (min (ceiling (* octocat-vui-unfold-peak span))
                           (ceiling (* octocat-vui-unfold-growth (abs (- to now))))))))
    (if (< from to) (min to (+ now step)) (max to (- now step)))))

(defun octocat-vui--unfold-next (now from to)
  "Return the next frame of an animation going FROM to TO, now at NOW.
On low battery, it is TO: no animation, see `octocat-power'."
  (if (eq (octocat-power) 'low)
      to
    (octocat-vui-unfold-step now from to)))

;; A slide shows a column of text growing from the left edge, or
;; shrinking back into it: each frame, every span of the column shows
;; only its right part, through its `display' property, so the text
;; after it moves along and the page is not re-rendered.

(defconst octocat-vui-slide-max-spans 300
  "The most spans a column slides with; a longer one shows at once.
Each frame gives every span a `display' string of its own, so a long
column would grow the buffer by a copy of itself each frame.")

(defun octocat-vui--slide-long-p (prop)
  "Return non-nil if the current buffer has more spans of PROP than slide.
See `octocat-vui-slide-max-spans'."
  (let ((pos (point-min)) (n 0))
    (while (and (<= n octocat-vui-slide-max-spans)
                (setq pos (text-property-not-all pos (point-max) prop nil)))
      (setq n   (1+ n)
            pos (or (next-single-property-change pos prop) (point-max))))
    (> n octocat-vui-slide-max-spans)))

(defvar-local octocat-vui--slide-timer nil
  "The timer of this buffer's slide; one runs at a time.")

(defun octocat-vui--slide-show (prop width shown)
  "Show SHOWN of the WIDTH columns of each span of PROP, its right part.
SHOWN nil shows the spans whole."
  (let ((inhibit-read-only t)
        (pos (point-min)))
    (with-silent-modifications
      (while (setq pos (text-property-not-all pos (point-max) prop nil))
        (let ((end (or (next-single-property-change pos prop) (point-max))))
          (if shown
              (put-text-property
               pos end 'display
               (truncate-string-to-width (buffer-substring pos end) width (- width shown)))
            (remove-text-properties pos end '(display nil)))
          (setq pos end))))))

(defun octocat-vui-slide (buf prop direction &optional done)
  "Slide the column of BUF's text with PROP in or out, then call DONE.
DIRECTION is `in', from the left edge, or `out', back into it.  Each
line's span of PROP is a part of the column, all as wide.  DONE is
called in BUF after the last frame; slid out, the column stays hidden
until DONE re-renders the page without it.  A slide started stops the
one running.  On low battery there is no slide, see `octocat-power',
nor in a column too long, see `octocat-vui-slide-max-spans'."
  (with-current-buffer buf
    (when (timerp octocat-vui--slide-timer)
      (cancel-timer octocat-vui--slide-timer))
    (let* ((pos   (text-property-not-all (point-min) (point-max) prop nil))
           (width (if pos
                      (string-width (buffer-substring
                                     pos (or (next-single-property-change pos prop)
                                             (point-max))))
                    0))
           (from  (if (eq direction 'in) 0 width))
           (to    (- width from))
           (now   from)
           step)
      (setq step
            (lambda ()
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (octocat-vui--slide-show prop width now)
                  (if (/= now to)
                      (setq now (octocat-vui--unfold-next now from to)
                            octocat-vui--slide-timer
                            (run-at-time octocat-vui-unfold-interval nil step))
                    (setq octocat-vui--slide-timer nil)
                    (when (eq direction 'in)
                      (octocat-vui--slide-show prop width nil))
                    (when done (funcall done)))))))
      (if (or (zerop width) (eq (octocat-power) 'low)
              (octocat-vui--slide-long-p prop))
          (progn (octocat-vui--slide-show prop width nil)
                 (when done (funcall done)))
        (funcall step)))))

;; A roll shows boxes of lines, such as the comments in a diff, growing
;; downwards from their first line, or shrinking back into it: each
;; frame, the lines of every box past the ones shown are made invisible,
;; with the newline before them, so the page is not re-rendered.

(defvar-local octocat-vui--roll-timer nil
  "The timer of this buffer's roll; one runs at a time.")

(defun octocat-vui--roll-boxes (prop)
  "Return the boxes of the current buffer's lines with PROP, in order.
Each is a list of (START . END) of its lines, START taking in the
newline before the line; lines parted only by a newline are one box."
  (let ((pos (point-min)) boxes box last)
    (while (setq pos (text-property-not-all pos (point-max) prop nil))
      (let ((end (or (next-single-property-change pos prop) (point-max))))
        (unless (and last (= last (1- pos)))
          (when box (push (nreverse box) boxes))
          (setq box nil))
        (push (cons (max (point-min) (1- pos)) end) box)
        (setq last end
              pos  end)))
    (when box (push (nreverse box) boxes))
    (nreverse boxes)))

(defun octocat-vui--roll-show (boxes shown)
  "Show the first SHOWN lines of each of BOXES, or all of them if SHOWN is nil."
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (dolist (box boxes)
        (let ((i 0))
          (dolist (line box)
            (if (and shown (>= i shown))
                (put-text-property (car line) (cdr line) 'invisible t)
              (remove-text-properties (car line) (cdr line) '(invisible nil)))
            (setq i (1+ i))))))))

(defun octocat-vui-roll (buf prop direction &optional done)
  "Roll the boxes of BUF's lines with PROP in or out, then call DONE.
DIRECTION is `in', growing down from nothing, or `out', back into
nothing.  DONE is called in BUF after the last frame; rolled out, the
boxes stay hidden until DONE re-renders the page without them.  A roll
started stops the one running.  As for `octocat-vui-slide', there is no
roll on low battery, nor with too many lines."
  (with-current-buffer buf
    (when (timerp octocat-vui--roll-timer)
      (cancel-timer octocat-vui--roll-timer))
    (let* ((boxes  (octocat-vui--roll-boxes prop))
           (height (apply #'max 0 (mapcar #'length boxes)))
           (from   (if (eq direction 'in) 0 height))
           (to     (- height from))
           (now    from)
           step)
      (setq step
            (lambda ()
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (octocat-vui--roll-show boxes now)
                  (if (/= now to)
                      (setq now (octocat-vui--unfold-next now from to)
                            octocat-vui--roll-timer
                            (run-at-time octocat-vui-unfold-interval nil step))
                    (setq octocat-vui--roll-timer nil)
                    (when (eq direction 'in)
                      (octocat-vui--roll-show boxes nil))
                    (when done (funcall done)))))))
      (if (or (zerop height) (eq (octocat-power) 'low)
              (octocat-vui--slide-long-p prop))
          (progn (octocat-vui--roll-show boxes nil)
                 (when done (funcall done)))
        (funcall step)))))

(vui-defcomponent octocat-vui-fold-rest (total limit render prefix noun key)
  "Show the first LIMIT of TOTAL things, the rest folded behind a marker row.
RENDER is a function of the number of things to show, returning a vnode.
PREFIX starts the marker row and NOUN (\"lines\", \"checks\") names the
things in it.  KEY names the marker button, so point stays on it when
the view re-renders.  With LIMIT nil, or TOTAL not above it, nothing
folds.  RET on the marker unfolds the rest, easing out, and then
folds it back.  Unfolding leaves the window's view where it was: point
follows the marker while it stays in view, and otherwise stays on the
line RET was pressed on, where the rest starts."
  :state ((shown nil) (open nil) (closing nil))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :shown nil)
               (vui-set-state :open nil)
               (vui-set-state :closing nil))))
         (folds   (and limit (> total limit)))
         (visible (if folds (min total (or shown limit)) total))
         (done    (>= visible total))
         (unfolding (and open (not done) (not closing)))
         ;; (WINDOW START STAY) from RET, see `octocat-vui--fold-pin'
         (pin (vui-use-ref nil)))
    ;; vui keeps point on the marker at the same screen row, so each
    ;; frame would scroll the window by the lines it revealed.
    (vui-use-effect (visible)
      (pcase (car pin)
        (`(,window ,start ,stay)
         (when (and open (window-live-p window))
           (set-window-start window start t)
           (when stay (set-window-point window stay)))
         (unless unfolding (setcar pin nil))))
      nil)
    ;; Unfold progressively: a timer adds more things each frame (see
    ;; `octocat-vui-unfold-step') until all show.  It exists only while
    ;; that is going on.
    (let ((now visible))
      (octocat-vui-use-timer (unfolding) octocat-vui-unfold-interval unfolding
        (setq now (octocat-vui--unfold-next now limit total))
        (vui-set-state :shown now)
        (< now total)))
    ;; Fold back the same way, in reverse.
    (let ((now visible))
      (octocat-vui-use-timer (closing) octocat-vui-unfold-interval closing
        (setq now (octocat-vui--unfold-next now total limit))
        (if (> now limit)
            (vui-set-state :shown now)
          (vui-set-state :shown nil)
          (vui-set-state :open nil)
          (vui-set-state :closing nil))
        (> now limit)))
    (vui-fragment
     (funcall render visible)
     (when folds
       (vui-fragment
        (vui-newline)
        ;; A real button, so TAB / S-TAB stop on it like on the buttons
        ;; at the bottom of the buffer.
        (vui-text prefix)
        (vui-button (cond ((not open) (format "▸ %d more %s  (RET to expand)"
                                              (- total visible) noun))
                          ((or done closing) "▴ show less")
                          (t          (format "▾ %d more %s…" (- total visible) noun)))
          :no-decoration t
          :face 'octocat-dimmed
          :key key
          :help-echo (if open "RET: fold this back" "RET: show the rest")
          :on-click (vui-with-async-context
                     (cond (closing nil)
                           ((and open done) (vui-set-state :closing t))
                           (t (setcar pin (octocat-vui--fold-pin
                                           (selected-window) (- total visible)))
                              (vui-set-state :open t))))))))))

(defun octocat-vui--fold-pin (window rows)
  "Return how to keep WINDOW's view as a fold unfolds ROWS rows below point.
That is (WINDOW START STAY): START is WINDOW's start, and STAY is nil
when the marker at point still fits in WINDOW once moved ROWS rows
down, so point follows it, or else the start of the marker's line,
where the unfolded rows start.  Nil when point is not in view."
  (when-let* (((eq (window-buffer window) (current-buffer)))
              (posn (posn-at-point (point) window)))
    (list window (window-start window)
          (unless (< (+ (cdr (posn-col-row posn)) rows)
                     (window-body-height window))
            (line-beginning-position)))))

(defun octocat-vui-fold-lines (string ends limit key prefix &optional wrap)
  "Return STRING folded to its first LIMIT lines, the rest behind a marker.
ENDS are its newlines, from `octocat-vui-line-ends'.  KEY and PREFIX
are as for `octocat-vui-fold-rest'.  WRAP turns the shown text into a
vnode, `vui-text' by default."
  (vui-component 'octocat-vui-fold-rest
    :total (length ends)
    :limit limit
    :noun "lines"
    :key key
    :prefix prefix
    :render (lambda (shown)
              (funcall (or wrap #'vui-text)
                       (substring string 0 (if (< shown (length ends))
                                               (nth shown ends)
                                             (length string)))))))

(vui-defcomponent octocat-vui-reveal (items render)
  "Call RENDER with ITEMS, revealing items added later one frame at a time.
RENDER is a function of the list of items to show, returning a vnode.
The first render shows every item at once.  When ITEMS then grows (a
\"Load more\" page arrived), the new items unfold, easing out, like
the rest of a long comment (see `octocat-vui-fold-rest'), instead of
all appearing in one jump.  A list that shrinks just shows what is left.
The timer exists only while items are being revealed."
  :state ((tick 0))
  :render
  (let* ((cell  (vui-use-ref nil))
         (total (length items)))
    ;; The reveal state, [VISIBLE TOTAL BASE], lives in the ref so the
    ;; timer and the render read the same numbers: BASE is where the
    ;; current unfolding started, TOTAL what it unfolds towards.
    (cond
     ((null (car cell))
      (setcar cell (vector total total total)))
     ((/= total (aref (car cell) 1))
      (let ((v (car cell)))
        (cond ((<= total (aref v 0))
               (aset v 0 total)
               (aset v 2 total))
              ((>= (aref v 0) (aref v 1)) ; idle: this growth starts a new unfolding
               (aset v 2 (aref v 0))))
        (aset v 1 total))))
    (let* ((v          (car cell))
           (visible    (aref v 0))
           (unfolding  (< visible total)))
      (octocat-vui-use-timer (unfolding) octocat-vui-unfold-interval unfolding
        (let ((all (aref v 1)))
          (aset v 0 (octocat-vui--unfold-next (aref v 0) (aref v 2) all))
          (vui-set-state :tick (lambda (n) (1+ n)))
          (< (aref v 0) all)))
      (funcall render (seq-take items visible)))))

(vui-defcomponent octocat-vui-fold (header prepare deps bulk)
  "A header row and a folded body that unfolds and folds back animated.
HEADER is a function of whether the body is open and of a command that
toggles it, returning the header vnode; typically an `octocat-vui-row'
with the toggle as its RET.  PREPARE builds the body, only once it is
first unfolded and again when DEPS change: it returns (TOTAL . RENDER),
the body's number of lines and a function of how many of them to show
returning a list of vnodes.  Unfolding and folding start fast and ease
out, as `octocat-vui-fold-rest' does.  Lines added while open, say by a refresh, unfold too.
BULK, from an \"Expand all\" button (see `octocat-vui-expand-all-button'),
is nil or (GENERATION . OPEN): each new value unfolds or folds it.  A
fold that mounts while BULK says open starts open, without animating."
  :state ((open (cdr bulk)) (shown (if (cdr bulk) most-positive-fixnum 0)))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :open (cdr bulk))
               (vui-set-state :shown (if (cdr bulk) most-positive-fixnum 0)))))
         (active (or open (> shown 0)))
         (body   (vui-use-memo (deps active) (and active (funcall prepare))))
         (total  (or (car body) 0))
         (toggle (vui-async-callback () (vui-set-state :open (not open))))
         (set-open (vui-async-callback (v) (vui-set-state :open v))))
    (vui-use-effect (bulk)
      (when bulk (funcall set-open (cdr bulk)))
      nil)
    (let ((now (octocat-vui-use-unfold shown open total)))
      (apply #'vui-vstack
             (funcall header open toggle)
             (and body (> now 0) (funcall (cdr body) now))))))

(defun octocat-vui-use-unfold (shown open total)
  "Step the calling component's :shown state, SHOWN, towards TOTAL lines.
Towards 0 when OPEN is nil; return how many lines to show now.  Must be
called during render, like any hook."
  (let* ((now    (min shown total))
         (target (if open total 0))
         (moving (/= now target)))
    (octocat-vui-use-timer (moving open total) octocat-vui-unfold-interval moving
      (setq now (octocat-vui--unfold-next now (- total target) target))
      (vui-set-state :shown now)
      ;; Done at the target: setting the same value again would not
      ;; re-render, so the timer would never be cleaned up.
      (/= now target))
    now))

(vui-defcomponent octocat-vui-unfolding-text (text open)
  "TEXT, unfolding line by line when OPEN turns non-nil, folding back when nil.
It moves as `octocat-vui-fold' does, and mounts at rest."
  :state ((shown (if open most-positive-fixnum 0)))
  :render
  (let* ((ends (octocat-vui-line-ends text))
         (now  (octocat-vui-use-unfold shown open (1+ (length ends)))))
    (and (> now 0) (vui-text (octocat-vui-take-lines text ends now)))))

(defun octocat-vui-expand-all-button (bulk on-click)
  "Return an \"[Expand all]\" button, \"[Collapse all]\" once pressed.
BULK is the value the button last produced for its folds' BULK prop (see
`octocat-vui-fold'), or nil.  ON-CLICK is called with the next value,
which the caller keeps, typically in its state, and passes to every fold."
  (let ((gen  (or (car bulk) 0))
        (open (cdr bulk)))
    (vui-button (if open "Collapse all" "Expand all")
      :face 'octocat-dimmed
      :key 'expand-all
      :help-echo (if open "RET: fold everything" "RET: unfold everything")
      :on-click (lambda () (funcall on-click (cons (1+ gen) (not open)))))))

(defun octocat-vui-fold-header (indent open toggle title help)
  "Return a header row for `octocat-vui-fold': a ▸/▾ marker, then TITLE.
INDENT starts the row.  OPEN and TOGGLE are as the fold passes them;
HELP is a pair of hints, for when the fold is closed and open.  The
marker is a button, so TAB stops on it; the title is a row, so its own
faces show (a button would draw it in one face).  RET on either toggles."
  (let ((hint (if open (cdr help) (car help))))
    (vui-hstack
     :spacing 0
     (vui-text indent)
     (vui-button (if open "▾" "▸")
       :no-decoration t
       :face 'octocat-dimmed
       :key 'fold-toggle
       :help-echo hint
       :on-click toggle)
     (octocat-vui-row (concat " " title) toggle hint))))

(defun octocat-vui-text-body (text)
  "Return TEXT as the (TOTAL . RENDER) body of an `octocat-vui-fold'."
  (let ((ends (octocat-vui-line-ends text)))
    (cons (1+ (length ends))
          (lambda (n) (list (vui-text (octocat-vui-take-lines text ends n)))))))

(defun octocat-vui-line-ends (string)
  "Return the positions of the newlines in STRING, for `octocat-vui-take-lines'."
  (let ((start 0) ends)
    (while (string-match "\n" string start)
      (push (match-beginning 0) ends)
      (setq start (match-end 0)))
    (nreverse ends)))

(defun octocat-vui-take-lines (string ends n)
  "Return the first N lines of STRING, whose newlines are at ENDS."
  (cond ((<= n 0) "")
        ((nth (1- n) ends) (substring string 0 (nth (1- n) ends)))
        (t string)))

(defun octocat-vui-reveal-list (items row-fn key-fn)
  "Return a `vui-list' of ITEMS drawn by ROW-FN and keyed by KEY-FN.
Items that arrive after the first render unfold progressively, see
`octocat-vui-reveal'.  Lay columns out from all of ITEMS before calling
this, so they do not shift as the new rows appear."
  (vui-component 'octocat-vui-reveal
    :items items
    :render (lambda (shown) (vui-list shown row-fn key-fn))))

(defconst octocat-vui--spinner-frames ["▖" "▘" "▝" "▗"]
  "Frames of the busy spinner.")

(defvar octocat-vui--spinner (aref octocat-vui--spinner-frames 0)
  "The current spinner frame; mode-line constructs show it by name.")

(defvar octocat-vui--pending-mode-line nil
  "The `global-mode-string' entry of the changes being sent, or nil.")
(put 'octocat-vui--pending-mode-line 'risky-local-variable t)

(defvar octocat-vui--spinner-index 0)
(defvar octocat-vui--spinner-timer nil)

(defun octocat-vui--spinner-start ()
  "Start the spinner timer unless it is running, or on low battery.
Without it, spinners stand still on their first frame."
  (unless (or (timerp octocat-vui--spinner-timer) (eq (octocat-power) 'low))
    (setq octocat-vui--spinner-timer
          (run-at-time 0.1 0.1 #'octocat-vui--spinner-tick))))

(defun octocat-vui--mode-line-busy-p (buf)
  "Return non-nil if the mode line of BUF has the spinner."
  (let ((mlp (buffer-local-value 'mode-line-process buf)))
    (and (consp mlp) (memq 'octocat-vui--spinner mlp))))

(defvar-local octocat-vui--page-spinner nil
  "Non-nil if this buffer's text may hold a spinner, see `octocat-vui-spinner'.")

(defun octocat-vui--turn-page-spinners (buf)
  "Show the current frame on every spinner in BUF's text.
Return nil, and forget BUF, once it has none."
  (with-current-buffer buf
    (let ((pos (point-min)) found)
      (with-silent-modifications
        (while (setq pos (text-property-not-all pos (point-max) 'octocat-vui-spinner nil))
          (let ((spin (get-text-property pos 'octocat-vui-spinner))
                (end  (or (next-single-property-change pos 'octocat-vui-spinner)
                          (point-max))))
            (setq found t)
            (put-text-property pos end 'display (if (functionp spin)
                                                    (funcall spin octocat-vui--spinner)
                                                  octocat-vui--spinner))
            (setq pos end))))
      (setq octocat-vui--page-spinner found))))

(defun octocat-vui--spinner-tick ()
  "Advance the spinner in every visible mode line and page.
Stop the timer once no buffer shows it."
  (setq octocat-vui--spinner-index
        (% (1+ octocat-vui--spinner-index) (length octocat-vui--spinner-frames))
        octocat-vui--spinner
        (aref octocat-vui--spinner-frames octocat-vui--spinner-index))
  (let ((busy (and octocat-vui--pending-mode-line t)))
    (when busy (force-mode-line-update t))
    (dolist (buf (buffer-list))
      (when (octocat-vui--mode-line-busy-p buf)
        (setq busy t)
        (when (get-buffer-window buf 'visible)
          (with-current-buffer buf (force-mode-line-update))))
      (when (and (buffer-local-value 'octocat-vui--page-spinner buf)
                 (octocat-vui--turn-page-spinners buf))
        (setq busy t)))
    (unless (and busy (not (eq (octocat-power) 'low)))
      (cancel-timer octocat-vui--spinner-timer)
      (setq octocat-vui--spinner-timer nil))))

(defun octocat-vui-mode-line-busy (label)
  "Return a `mode-line-process' of a spinner, then LABEL, such as \":loading\".
The spinner leads, so a narrow mode line that cuts LABEL still shows it."
  (octocat-vui--spinner-start)
  (list " " 'octocat-vui--spinner label))

(defcustom octocat-mode-line-writes t
  "Whether every mode line shows the changes being sent to GitHub.
A merge, comment or review may take many seconds on a slow GitHub; this
shows it under way wherever you are, as well as on its page."
  :type 'boolean
  :group 'octocat)

(defun octocat-vui--pending-label (labels)
  "Return the mode line label of the pending mutations of LABELS, or nil."
  (pcase (length labels)
    (0 nil)
    (1 (concat "Octocat: " (car labels)))
    (n (format "Octocat: %d changes…" n))))

(defun octocat-vui--on-sync-pending (labels)
  "Show LABELS, those of the pending mutations, in every mode line.
For `octocat-sync-pending-functions'."
  (let ((label (and octocat-mode-line-writes (octocat-vui--pending-label labels))))
    (setq octocat-vui--pending-mode-line
          (and label (list " " 'octocat-vui--spinner " " label)))
    (if label
        (progn
          (unless (listp global-mode-string)
            (setq global-mode-string (list global-mode-string)))
          (unless (memq 'octocat-vui--pending-mode-line global-mode-string)
            (setq global-mode-string
                  (append global-mode-string '(octocat-vui--pending-mode-line))))
          (octocat-vui--spinner-start))
      (setq global-mode-string
            (if (listp global-mode-string)
                (delq 'octocat-vui--pending-mode-line global-mode-string)
              global-mode-string)))
    (force-mode-line-update t)))

(defun octocat-vui-spinner ()
  "Return a spinner to render in the current buffer's page.
It turns in step with the mode line's, through its `display' property,
so the page is not re-rendered for each frame; it stops once the page
no longer shows it.  Text whose `octocat-vui-spinner' is a function
turns too, displayed as what it returns for each frame."
  (setq octocat-vui--page-spinner t)
  (octocat-vui--spinner-start)
  (propertize (aref octocat-vui--spinner-frames 0) 'octocat-vui-spinner t))

(defvar-local octocat-vui--loading 0
  "How many components of this buffer are loading.")

(defun octocat-vui--show-busy ()
  "Show whether the current buffer is loading in its mode line."
  (setq mode-line-process
        (and (or (> octocat-vui--loading 0) octocat-vui--loading-keys)
             (octocat-vui-mode-line-busy ":loading")))
  (force-mode-line-update))

(defun octocat-vui--add-loading (buf n)
  "Add N to BUF's loading count; show \":loading\" while it is positive."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq octocat-vui--loading (max 0 (+ octocat-vui--loading n)))
      (octocat-vui--show-busy))))

(defun octocat-vui--image-loading (buf loading)
  "Show \":loading\" in BUF's mode line while an image it asked for is LOADING.
Its link's spinner turns with the mode line's.  For
`octocat-image-loading-function'."
  (when (and loading (buffer-live-p buf))
    (with-current-buffer buf (setq octocat-vui--page-spinner t)))
  (octocat-vui--add-loading buf (if loading 1 -1)))

(defmacro octocat-vui-use-mode-line-loading (loading)
  "Show \":loading\" in the mode line while LOADING, a variable, is true.
That is `mode-line-process', after the mode name, where Emacs shows that
a buffer is busy, as in \"(Compilation:run)\": noticeable, and it never
moves the page's text.  Any component may use it; the buffer shows the
indicator while any of them is loading."
  `(vui-use-effect (,loading)
     (when ,loading
       (let ((buf (current-buffer)))
         (octocat-vui--add-loading buf 1)
         (lambda () (octocat-vui--add-loading buf -1))))))

(defun octocat-vui-window-height ()
  "Return the body height of the window showing the current buffer, or 40."
  (let ((win (get-buffer-window (current-buffer) t)))
    (if win (window-body-height win) 40)))

(defun octocat-vui-window-width ()
  "Return the body width of the window showing the current buffer, or 80.
It is at most `octocat-max-width' on a capped page, see
`octocat--cap-width'."
  (let ((win (get-buffer-window (current-buffer) t)))
    (octocat--cap-width (if win (window-body-width win) 80))))

(defun octocat-vui-update-page (&rest props)
  "Re-render the current buffer's page with PROPS changed, in place.
PROPS is a plist of the props to change.  Unlike a remount, the page
keeps its state, and this is safe in a vui handler (see
docs/using-vui.md); a part that must start afresh for the new props takes
them as its :key.  Return nil when the buffer has no page."
  (when-let* ((root (vui-get-instance)))
    (let ((new (copy-sequence (vui-instance-props root))))
      (while props
        (setq new (plist-put new (pop props) (pop props))))
      (vui-update-props root new)
      t)))

(defvar-local octocat-vui--page nil
  "The page `octocat-vui-refresh-page' mounted here: (COMPONENT ID INSTANCE).")

(defvar-local octocat-vui--tick 0
  "Bumped by each `octocat-vui-refresh-page'.")

(defun octocat-vui-refresh-page (component id props)
  "Mount COMPONENT with PROPS in the current buffer, or refresh it in place.
ID names what the page shows.  When this buffer already shows COMPONENT
for ID, it is re-rendered with new props instead of remounted, so it
keeps its state, such as what is unfolded, and point.  PROPS get a
:tick, new on each call, for the page's fetch keys (see
`octocat-vui-use-resource').  Only the first call mounts, when the page is
opened: `vui-mount' also selects the buffer, which from an async refresh
would pull the user back to it (see docs/using-vui.md)."
  (let ((props (append props (list :tick (cl-incf octocat-vui--tick)))))
    (if (and (eq (nth 0 octocat-vui--page) component)
             (equal (nth 1 octocat-vui--page) id))
        (vui-update-props (nth 2 octocat-vui--page) props)
      (setq octocat-vui--page
            (list component id
                  (vui-mount (apply #'vui-component component props)
                             (buffer-name)))))))

(defun octocat-vui-revisit-page ()
  "Fetch the current page's resources unless fresh, unlike a refresh."
  (let ((buf (current-buffer)))
    (maphash (lambda (key subs)
               (when (assq buf subs)
                 (octocat-sync-request (car (read-from-string key)))))
             octocat-vui--subscriptions)))


;;;; List-page base mode
;;
;; Skeleton shared by the PR, issue, run and workflow list pages (defined
;; next to their detail pages, in octocat-pr.el and so on): the repo they
;; show, the github.com path `octocat-browse' opens, and the common
;; keymap.  Each page derives from this mode, sets its own
;; `revert-buffer-function', and is opened via `octocat--open-list'
;; (octocat.el).

(declare-function octocat--fetch-counts "octocat-core" (repo kind callback))
(declare-function octocat--list-labels "octocat-core" (repo callback))
(declare-function octocat--list-people "octocat-core" (repo callback))
(declare-function octocat--setting "octocat-core" (key))
(declare-function octocat--setting-put "octocat-core" (key value))
(declare-function octocat-visit-repo "octocat-core" (repo &optional ref))
(declare-function octocat-user-open "octocat-user" (login))
(declare-function octocat-issue-list "octocat" (&optional repo))
(declare-function octocat-pr-list "octocat" (&optional repo))
(declare-function octocat-actions "octocat" (&optional repo))

(defvar-local octocat-vui-list--repo nil
  "The \"owner/repo\" string this list buffer is tracking.")

(defvar-local octocat-vui-list--path nil
  "Path under github.com/OWNER/REPO that shows this list in a browser.")

(defvar-local octocat-vui-list--view nil
  "Name of this list page's view, such as \"pr-list\", or nil.
With the repo, the key under which the page remembers being compact.")

(defun octocat-vui-list-compact-p ()
  "Return non-nil when this list page is in its compact view."
  (and octocat-vui-list--view octocat-vui-list--repo
       (octocat--setting (list 'compact octocat-vui-list--repo octocat-vui-list--view))))

(defun octocat-vui-list-toggle-compact ()
  "Toggle this list page between its compact and full views.
The choice is remembered for this page of this repository."
  (interactive)
  (unless octocat-vui-list--view
    (user-error "Octocat: This page has no compact view"))
  (let ((compact (not (octocat-vui-list-compact-p))))
    (octocat--setting-put (list 'compact octocat-vui-list--repo octocat-vui-list--view)
                          compact)
    (or (octocat-vui-update-page :compact compact)
        (revert-buffer nil t))))

(defun octocat-vui-list--page-url ()
  "Return the URL of the GitHub page matching this list."
  (and octocat-vui-list--repo octocat-vui-list--path
       (octocat--web-url "%s/%s" octocat-vui-list--repo octocat-vui-list--path)))

(defvar octocat-vui-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-v") #'octocat-vui-list-toggle-compact)
    (define-key map (kbd "F") #'octocat-vui-list-filter)
    map)
  "Keymap for `octocat-vui-list-mode' and the list pages derived from it.")

(define-derived-mode octocat-vui-list-mode vui-mode "Octocat-List"
  "Base major mode for the octocat PR, issue and workflow list pages.

\\{octocat-vui-list-mode-map}"
  :group 'octocat
  ;; Not read-only, so the query field can be edited: as in any vui
  ;; buffer, `widget-setup' rejects edits outside widget fields.
  (setq-local truncate-lines t)
  (add-hook 'completion-at-point-functions
            #'octocat-vui-list--qualifier-capf nil t)
  (add-hook 'post-command-hook #'octocat-vui--prefetch-schedule nil t)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup)
  (setq-local octocat--url-function #'octocat-vui-list--page-url))

(defun octocat-vui-repo-heading (repo &optional linked)
  "Return REPO, \"owner/name\", as the heading vnode at the top of a page.
The owner links to its user or organization page; the name is plain,
being where the page sits (the Code tab reaches the repository page),
unless LINKED: then it opens the repository page, for a page under it
that has no tabs."
  (pcase-let ((`(,owner ,name) (split-string repo "/")))
    (vui-fragment
     (vui-button owner :no-decoration t :face '(link octocat-repo)
                 :help-echo "RET: open owner page"
                 :on-click (lambda () (octocat-user-open owner)))
     (if linked
         (vui-fragment
          (vui-text "/" :face 'octocat-repo)
          (vui-button name :no-decoration t :face '(link octocat-repo)
                      :help-echo "RET: open repo view"
                      :on-click (lambda () (octocat-visit-repo repo))))
       (vui-text (concat "/" name) :face 'octocat-repo)))))

(defun octocat-vui-commit-top-row (repo sha)
  "Return the top row of a page about commit SHA of REPO.
That is `owner/repo@sha', as `owner/repo#N' is on an issue."
  (vui-hstack :spacing 0
              (octocat-vui-repo-heading repo)
              (vui-text (concat "@" (substring sha 0 (min 7 (length sha))))
                :face 'octocat-commit-sha)))

(defun octocat-vui--fit (text width)
  "Return TEXT cut with an ellipsis to WIDTH columns, at least 10.
A cut TEXT carries its whole as `help-echo' and `octocat-full-text'."
  (let ((width (max 10 width)))
    (if (<= (string-width text) width)
        text
      (let ((full (substring-no-properties text)))
        (propertize (truncate-string-to-width text width nil nil "…")
                    'help-echo full 'octocat-full-text full)))))

(defun octocat-vui-actions-header (repo crumbs width &optional state lines)
  "Return the header vnodes of a workflow, run or job page of REPO.
The top row is REPO, then CRUMBS, the pages above this one from the
workflow down and last this page, as the number and title on an issue.
Each crumb is (TEXT ON-CLICK HELP): with ON-CLICK it is a link up to its
page.  The last is cut to keep the row within WIDTH.  Under it, STATE,
a propertized string, heads the first of LINES, each a list of fields
as for `octocat-vui-fields'; the others are lined up under it.  With no
STATE, there is only the top row."
  (let* ((sep    (propertize " › " 'face 'octocat-dimmed))
         (links  (butlast crumbs))
         (used   (+ (string-width repo) 2
                    (apply #'+ (mapcar (lambda (c) (+ (string-width (car c)) 3)) links))))
         (title  (octocat-vui--fit (car (car (last crumbs))) (- width used)))
         (fields (delq nil (mapcar #'octocat-vui-fields lines)))
         (head   (and state (concat state "  "))))
    (cons
     (apply #'vui-hstack :spacing 0
            (octocat-vui-repo-heading repo)
            (vui-text "  ")
            (append
             (mapcan (pcase-lambda (`(,text ,on-click ,help))
                       (list (if on-click
                                 (vui-button text :no-decoration t :face 'link
                                             :help-echo help :on-click on-click)
                               (vui-text text))
                             (vui-text sep)))
                     links)
             (list (vui-text title))))
     (cond ((not state) nil)
           ((null fields) (list (vui-text state)))
           (t (cons (vui-hstack :spacing 0 (vui-text head) (car fields))
                    (mapcar (lambda (node)
                              (vui-hstack :spacing 0
                                          (vui-text (make-string (string-width head) ?\s))
                                          node))
                            (cdr fields))))))))

(defun octocat-vui-fields (fields)
  "Return a vnode of FIELDS on one line, or nil when none has a value.
FIELDS is a list of (LABEL . VALUE): a nil or empty VALUE is skipped, a
nil LABEL shows VALUE alone.  Labels and separators are dimmed."
  (let ((parts (delq nil
                     (mapcar (lambda (f)
                               (and (cdr f) (not (equal (cdr f) ""))
                                    (if (car f)
                                        (concat (propertize (car f) 'face 'octocat-dimmed)
                                                " " (cdr f))
                                      (cdr f))))
                             fields))))
    (and parts
         (vui-text (mapconcat #'identity parts (propertize " · " 'face 'octocat-dimmed))))))

(defun octocat-vui-tab-row (tabs width)
  "Return a row of TABS underlined across WIDTH columns, as GitHub's tab bar.
Each tab is (LABEL HELP ON-CLICK); the current one has no ON-CLICK and is
a heading, the others are buttons.  The underline sets the row apart from
what is below it without a blank line."
  (let* ((ul    (lambda (face) (list face 'underline)))
         (nodes (mapcar (pcase-lambda (`(,label ,help ,on-click))
                          (if on-click
                              (vui-button label :face (funcall ul 'octocat-dimmed)
                                          :help-echo (octocat--button-help help on-click)
                                          :on-click on-click)
                            (vui-text label :face (funcall ul 'octocat-section-heading))))
                        tabs))
         ;; Buttons are drawn in brackets.
         (used  (+ (apply #'+ (mapcar (pcase-lambda (`(,label ,_ ,on-click))
                                        (+ (string-width label) (if on-click 2 0)))
                                      tabs))
                   (* 2 (1- (length tabs))))))
    (apply #'vui-hstack :spacing 0
           (append (cdr (mapcan (lambda (n) (list (vui-text "  " :face 'underline) n))
                                nodes))
                   (list (vui-text (make-string (max 0 (- width used)) ?\s)
                           :face 'underline))))))

(defun octocat-vui-segmented (segments)
  "Return SEGMENTS as one segmented control, a pill of choices.
Each is (LABEL CURRENT HELP ON-CLICK): the CURRENT one is filled in and
does nothing; the others are buttons running ON-CLICK, with HELP as
their hover text.  They touch, so their boxes make one outline, and
each label is padded so it reads without the outline, as in a terminal."
  (apply #'vui-hstack :spacing 0
         (mapcar (pcase-lambda (`(,label ,current ,help ,on-click))
                   (let ((text (concat " " label " ")))
                     (if current
                         (vui-text text :face 'octocat-segment-current)
                       (vui-button text
                         :no-decoration t
                         :face 'octocat-segment
                         :help-echo help
                         :on-click on-click))))
                 segments)))

(defun octocat-vui-underlined (width &rest nodes)
  "Return NODES on one line, underlined across WIDTH columns.
A full-width underline heads what is below it, as a tab row does."
  (apply #'vui-hstack :spacing 0 :face 'underline
         (append (delq nil nodes)
                 (list (vui-text (propertize " " 'display `(space :align-to ,width)))))))

(defun octocat-vui-section-heading (label width &rest after)
  "Return the heading LABEL, then AFTER, nodes or nils, underlined across WIDTH."
  (apply #'octocat-vui-underlined width
         (vui-text label :face 'octocat-section-heading)
         (mapcan (lambda (node) (list (vui-text "  ") node)) (delq nil after))))

(defcustom octocat-repo-summary-ttl 300
  "Seconds a repo's summary, with its open issue and PR counts, is reused.
Within this, opening a page with the repo tabs doesn't refetch it; `g',
or closing, reopening or merging an item of the repo, does.  It is at
least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(octocat-sync-define-resource repo-summary (repo)
  :max-age octocat-repo-summary-ttl
  :fetch (lambda (done)
           (octocat--fetch-repo-summary
            repo
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (let ((h (make-hash-table :test #'equal)))
                                (while r
                                  (puthash (substring (symbol-name (pop r)) 1) (pop r) h))
                                h)))))))

(defun octocat-vui-repo-tabs (repo current tick)
  "Return a list of vnodes: the tab strip of REPO's pages, as on GitHub.
The tabs are those of `octocat--repo-tabs'.  CURRENT is the symbol of
the page being shown; its tab is drawn as a heading and is not
clickable.  The others open their page for REPO.  The issue and PR tabs
show the open counts of the `repo-summary' resource, \"…\" while it
loads; a new TICK refetches it.  Reads the store, so call it during
render, like any hook."
  (let* ((snap    (octocat-vui-use-resource (list 'repo-summary repo) tick))
         (summary (plist-get snap :data))
         (count   (lambda (field)
                    (pcase (octocat-vui-snapshot-status snap)
                      ('ready   (gethash field summary))
                      ('pending "…"))))
         (nodes
          (mapcar
           (lambda (tab)
             (pcase-let* ((`(,sym ,label ,help ,fn) tab)
                          (n     (pcase sym
                                   ('issues (funcall count "open-issues"))
                                   ('pulls  (funcall count "open-prs"))))
                          (label (if n (format "%s (%s)" label n) label)))
               (if (eq sym current)
                   (vui-text label :face '(octocat-section-heading underline))
                 (vui-button label
                   :face '(octocat-dimmed underline)
                   :help-echo help
                   :on-click (lambda () (funcall fn repo))))))
           octocat--repo-tabs)))
    ;; One node, so the gaps between the tabs are underlined too.
    (list (apply #'vui-hstack :spacing 0
                 (cdr (mapcan (lambda (n) (list (vui-text "  " :face 'underline) n))
                              nodes))))))

(octocat-sync-define-resource counts (kind repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (let ((tree (make-hash-table :test #'equal)))
             (if (null kind)
                 (funcall done tree)
               (octocat--fetch-counts
                repo kind
                (lambda (r)
                  (if (eq (car-safe r) 'error)
                      (funcall done r)
                    (while r
                      (puthash (substring (symbol-name (pop r)) 1) (pop r) tree))
                    (funcall done tree))))))))

(vui-defcomponent octocat-vui-list-header (repo tab kind tick)
  "Header for a list page: REPO, the tab strip and, for KIND, item counts.
TAB is the symbol of the current tab (see `octocat-vui-repo-tabs').
KIND is `issues' or `pulls' to show \"N open · M closed\" (plus merged
for pulls) from one API call, or nil for no counts.  A new TICK fetches
them again."
  :render
  (let ((counts (plist-get (octocat-vui-use-resource (list 'counts kind repo) tick) :data)))
    (vui-fragment
     (apply #'vui-hstack :spacing 2
            (octocat-vui-repo-heading repo)
            (octocat-vui-repo-tabs repo tab tick))
     (vui-newline)
     (when (and counts (gethash "open" counts))
       (vui-fragment
        (vui-text (string-join
                   (delq nil
                         (list (format "%d open" (gethash "open" counts))
                               (format "%d closed" (gethash "closed" counts))
                               (and (gethash "merged" counts)
                                    (format "%d merged" (gethash "merged" counts)))))
                   " · ")
          :face 'octocat-dimmed)
        (vui-newline))))))

(defvar-local octocat-vui-list--set-marks-function nil
  "Function of a list of item numbers that makes them the page's marks.
A `vui-async-callback' the page sets as it mounts.")

(vui-defcomponent octocat-vui-search-list (repo kind query row-fn line-fn compact tick
                                                extra-fn)
  "List page of the KIND items of REPO, `issues' or `pulls', matching QUERY.
ROW-FN returns the row of an item, given it, the width, COMPACT, non-nil
for one-line rows, and NO-STATE, non-nil to leave a compact row's state
out: under the default query, every item is open.  LINE-FN returns the
uncut compact line of an item, given it and NO-STATE; the widest of them
sets the width the compact rows are laid out in (see
`octocat-repo-vui--compact-width').  EXTRA-FN, when non-nil, is called
with TICK during render, like a hook, for more the rows show, such as a
PR's place in its stack; ROW-FN and LINE-FN get what it returns, ROW-FN
as its last argument but one: its last is non-nil for a marked item.
The marks, the numbers of the marked items, are the page's state (see
`octocat-vui-list-mark').  A new QUERY or COMPACT re-renders in place:
the header keeps its counts, and the results start afresh, as the
compact view loads more at a time.  A new TICK refetches the counts and
starts the results afresh."
  :state ((marks nil))
  :render
  ;; What the actions on the marked items are doing, if anything.
  (let ((busy (alist-get 'batch (plist-get (octocat-vui-use-resource
                                            (list 'counts kind repo) tick)
                                           :mutating))))
    ;; The mark commands, run outside the page, set its marks with this.
    (vui-use-effect ()
      (setq octocat-vui-list--set-marks-function
            (vui-async-callback (marks) (vui-set-state :marks marks)))
      nil)
    (vui-vstack
     (vui-component 'octocat-vui-list-header :repo repo :tab kind :kind kind :tick tick)
     (vui-fragment
      ;; Two rows either way, so marking the first item and unmarking
      ;; the last does not move the list.
      (if marks
          (octocat-vui-list-apply-bar
           kind repo (octocat-vui--search-spec kind repo query compact) marks busy)
        (octocat-vui-list-filter-bar query)))
     (vui-component 'octocat-vui--search-results
       :key (list query (and compact t) tick)
       :repo repo :kind kind :query query :row-fn row-fn
       :line-fn line-fn :compact compact :tick tick :extra-fn extra-fn :marks marks))))

(defun octocat-vui--list-tree (kind repo page)
  "Return PAGE, a page of KIND items of REPO, as a list resource's tree.
PAGE is as `octocat--parse-list-items' returns; each item is an entity."
  (let ((tree (make-hash-table :test #'equal))
        (type (if (eq kind 'pulls) 'pr 'issue)))
    (puthash "nodes" (vconcat (mapcar (lambda (item) (octocat-sync-item type repo item))
                                      (plist-get page :items)))
             tree)
    (puthash "cursor" (plist-get page :cursor) tree)
    tree))

(defun octocat-vui--search-spec (kind repo query compact)
  "Return the spec of the KIND items of REPO matching QUERY, a page of them.
COMPACT pages are longer."
  (list 'list-items kind repo query
        (if compact octocat-list-compact-page-size octocat-list-page-size)))

(octocat-sync-define-resource list-items (kind repo query limit)
  :fetch (lambda (done)
           ;; As many as "load more" stored, so a refetch keeps them.
           (let ((data (plist-get (octocat-sync-read
                                   (list 'list-items kind repo query limit))
                                  :data)))
             (octocat--list-items
              kind repo
              (lambda (r)
                (funcall done (if (eq (car-safe r) 'error)
                                  r
                                (octocat-vui--list-tree kind repo r))))
              query nil (min 100 (max limit (length (and data (gethash "nodes" data)))))))))

(vui-defcomponent octocat-vui--search-results (repo kind query row-fn line-fn compact tick
                                                    extra-fn marks)
  "The KIND items of REPO matching QUERY, as for `octocat-vui-search-list'.
They are a sync resource, painted from the store while it is refetched;
\"load more\" appends the page after the last to it, by its cursor (see
`octocat-sync-more').  A new TICK refetches them.  MARKS are the page's
marks; once the items are in, those of items no longer among them are
dropped, so that only items shown are marked."
  :state ((fetching nil))
  :render
  (let* ((width  (octocat-vui-window-width))
         (type   (if (eq kind 'pulls) "prs" "issues"))
         (noun   (if (eq kind 'pulls) "pull requests" "issues"))
         (limit  (if compact octocat-list-compact-page-size octocat-list-page-size))
         (no-state (and compact (not (octocat-vui-list-filter-active-p query))))
         (spec   (octocat-vui--search-spec kind repo query compact))
         (snap   (octocat-vui-use-resource spec tick))
         (extra  (and extra-fn (funcall extra-fn tick)))
         (data   (plist-get snap :data))
         (shown  (and data (mapcar (lambda (item) (gethash "number" item))
                                   (gethash "nodes" data)))))
    ;; Not before the items are in: a skeleton shows none.
    (vui-use-effect (data shown marks)
      (when-let* ((gone (and data (seq-difference marks shown))))
        (vui-set-state :marks (lambda (old) (seq-difference old gone)))
        (message "Octocat: Unmarked %s, no longer listed"
                 (mapconcat (lambda (n) (format "#%d" n)) gone ", ")))
      nil)
    (octocat-vui-use-mode-line-loading fetching)
    (octocat-vui-resource-view
     snap
     :skeleton (lambda (_) (vui-text (octocat-vui-list-skeleton width compact no-state)))
     :render
     (lambda (data)
       (let* ((items  (append (gethash "nodes" data) nil))
              (cursor (gethash "cursor" data))
              (row-w  (if compact
                          (octocat-repo-vui--compact-width
                           (mapcar (lambda (item) (funcall line-fn item no-state extra)) items)
                           width)
                        width)))
         (vui-fragment
          (if (null items)
              (vui-text (format (if (octocat-vui-list-filter-active-p query)
                                    "(no %s match the filters)\n"
                                  "(no %s)\n")
                                noun)
                :face 'octocat-dimmed)
            (octocat-vui-reveal-list
             items
             (lambda (item)
               (funcall row-fn item row-w compact no-state extra
                        (and (memql (gethash "number" item) marks) t)))
             (lambda (item) (gethash "number" item))))
          (when (and items cursor)
            (octocat-vui-load-more-button
             (intern (format "load-more-%s" type)) limit
             (format "RET: load more %s" noun)
             (lambda ()
               (vui-set-state :fetching t)
               (octocat-sync-more
                spec
                (lambda (after done)
                  (octocat--list-items
                   kind repo
                   (lambda (r)
                     (funcall done (if (eq (car-safe r) 'error)
                                       r
                                     (octocat-vui--list-tree kind repo r))))
                   query after limit))
                (vui-async-callback (r)
                  (vui-set-state :fetching nil)
                  (when r (message "Octocat: %s" (cdr r))))))
             fetching 0
             (octocat-vui-list-skeleton width compact no-state)))))))))


;;;; List filters
;;
;; The PR and issue pages are filtered by a GitHub search query string
;; (see octocat-core.el, "List filters"), kept in `octocat-vui-list--query'
;; and edited in a field above the list (TAB reaches it), with
;; completion for the usual qualifiers; the State / Author / Assignee
;; buttons (or `F') edit single qualifiers through a toggle prompt:
;; choosing an item checks it, choosing the checked item unchecks it.
;; The Label button reads all labels at once, comma-separated.
;; Either way the buffer is refreshed with the new query.
;;
;; The default query, the buttons and the completions are buffer-local,
;; so a page with a query of its own, such as the run list
;; (octocat-run.el), sets its own.

(defvar-local octocat-vui-list--query nil
  "Current search query of this list buffer; nil means the default query.")

(defvar-local octocat-vui-list--states nil
  "State names this page can filter by, or nil when it has no filters.")

(defconst octocat-vui-list--state-tokens '("is:open" "is:closed" "is:merged")
  "Query tokens that select the state of the listed items.")

(defvar-local octocat-vui-list--default-query octocat--default-list-query
  "Query this list starts with, and goes back to when the filter is cleared.")

(defvar-local octocat-vui-list--qualifiers
  '("is:open" "is:closed" "is:merged" "is:draft" "author:" "author:@me"
    "assignee:" "assignee:@me" "label:" "-label:" "no:label" "no:assignee"
    "base:" "head:" "mentions:" "milestone:" "review-requested:"
    "review-requested:@me" "reviewed-by:" "reviewed-by:@me" "review:required"
    "review:approved" "review:changes_requested" "sort:updated-desc"
    "sort:created-desc" "sort:comments-desc")
  "Qualifier completions offered while editing a query.")

(defun octocat-vui-list-query ()
  "Return the search query of the current list buffer."
  (or octocat-vui-list--query octocat-vui-list--default-query))

(defun octocat-vui-list-filter-active-p (query)
  "Return non-nil when QUERY differs from the default query."
  (not (equal (string-trim (or query octocat-vui-list--default-query))
              octocat-vui-list--default-query)))

(defun octocat-vui-list--tokenize (query)
  "Split QUERY into whitespace-separated tokens, keeping quoted text whole."
  (let ((pos 0) tokens)
    (while (string-match "\\(?:[^[:space:]\"]\\|\"[^\"]*\"\\|\"\\)+" query pos)
      (push (match-string 0 query) tokens)
      (setq pos (match-end 0)))
    (nreverse tokens)))

(defun octocat-vui-list--quote (value)
  "Return VALUE, double-quoted if whitespace is part of it."
  (if (string-match-p "[[:space:]]" value)
      (format "\"%s\"" value)
    value))

(defun octocat-vui-list--values (query prefix)
  "Return the unquoted values of QUERY's tokens that start with PREFIX."
  (delq nil (mapcar (lambda (token)
                      (and (string-prefix-p prefix token)
                           (replace-regexp-in-string
                            "\"" "" (substring token (length prefix)))))
                    (octocat-vui-list--tokenize query))))

(defun octocat-vui-list--replace (query drop-p new-tokens)
  "Return QUERY without tokens satisfying DROP-P, plus NEW-TOKENS at the end."
  (string-join (append (seq-remove drop-p (octocat-vui-list--tokenize query))
                       new-tokens)
               " "))

(defun octocat-vui-list--state (query)
  "Return the state named in QUERY: \"open\", \"closed\", \"merged\" or \"all\"."
  (let ((token (seq-find (lambda (tok) (member tok octocat-vui-list--state-tokens))
                         (octocat-vui-list--tokenize query))))
    (if token (substring token 3) "all")))

(defun octocat-vui-list--with-state (query state)
  "Return QUERY with its state token set to STATE (\"all\" drops the token)."
  (let ((rest (octocat-vui-list--replace
               query (lambda (tok) (member tok octocat-vui-list--state-tokens)) nil)))
    (string-trim (if (equal state "all") rest (concat "is:" state " " rest)))))

(defun octocat-vui-list--with-values (query prefix values)
  "Return QUERY with the PREFIX qualifier set to VALUES (nil drops it)."
  (octocat-vui-list--replace
   query (lambda (tok) (string-prefix-p prefix tok))
   (mapcar (lambda (v) (concat prefix (octocat-vui-list--quote v))) values)))

(defun octocat-vui-list--toggle-read (prompt candidates selected)
  "Read one of CANDIDATES; return it in a list, or nil to clear it.
PROMPT names what is being chosen.  SELECTED is the currently chosen
value, shown first with a trailing check mark; choosing it clears it,
an empty answer keeps it.  Free text not in CANDIDATES is accepted as a
new value."
  (let* ((all (let ((all (delete-dups (append candidates selected))))
                (append (seq-filter (lambda (c) (member c selected)) all)
                        (seq-remove (lambda (c) (member c selected)) all))))
         (marked (mapcar (lambda (c) (if (member c selected) (concat c " ✓") c))
                         all))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action marked string pred))))
         (value (string-remove-suffix
                 " ✓" (string-trim
                       (completing-read (format "%s (✓ = selected): " prompt)
                                        table nil nil)))))
    (cond ((string-empty-p value) selected)
          ((member value selected) nil)
          (t (list value)))))

(defun octocat-vui-list--read-multiple (prompt candidates selected)
  "Read values from CANDIDATES in one prompt; return the list of them.
PROMPT names what is being chosen.  SELECTED are the current values,
given as initial input so RET alone keeps them.  Vertico's RET picks a
candidate for an empty last value, so the prompt names M-RET, which
takes the input as typed."
  (delete-dups
   (seq-remove #'string-empty-p
               (mapcar #'string-trim
                       (completing-read-multiple
                        (format "%s (comma-separated, M-RET: as typed): " prompt)
                        ;; Candidates first, keeping their faces over
                        ;; the plain selected strings.
                        (delete-dups (append candidates selected)) nil nil
                        (and selected (concat (string-join selected ",") ",")))))))

(defun octocat-vui-list--check-filterable ()
  "Signal a `user-error' unless the current buffer is a filterable list."
  (unless octocat-vui-list--states
    (user-error "Octocat: This page has no filters")))

(defun octocat-vui-list--apply (query)
  "Make QUERY the current query and refresh the buffer."
  (setq octocat-vui-list--query (string-trim query))
  (or (octocat-vui-update-page :query (octocat-vui-list-query))
      (revert-buffer nil t)))

(defvar octocat-vui-list-query-submit-hook nil
  "Hook run in a list buffer when its query field is submitted.")

(defun octocat-vui-list--query-widget ()
  "Return the query field widget of the current buffer, or nil."
  ;; `vui-field' keeps its :key as the widget's :vui-key.
  (seq-find (lambda (widget) (eq (widget-get widget :vui-key) :query))
            widget-field-list))

(defun octocat-vui-list--qualifier-capf ()
  "Complete a search qualifier before point in the query field.
See `octocat-vui-list--qualifiers'."
  (when-let* ((widget (octocat-vui-list--query-widget))
              ((eq (widget-field-at (point)) widget)))
    (let ((end (point))
          (beg (save-excursion
                 (skip-chars-backward "^[:space:]" (widget-field-start widget))
                 (point))))
      (list beg end octocat-vui-list--qualifiers))))

(defun octocat-vui-list-edit-query ()
  "Move point to the end of the search query in the query field."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let ((widget (or (octocat-vui-list--query-widget)
                    (user-error "Octocat: No query field on this page"))))
    ;; The field is padded with spaces, which its value leaves out.
    (goto-char (+ (widget-field-start widget)
                  (length (widget-value widget))))))

(defun octocat-vui-list--query-submitted (query)
  "Run QUERY, submitted by RET in the query field."
  (run-hooks 'octocat-vui-list-query-submit-hook)
  (octocat-vui-list--apply query))

(octocat-sync-define-resource labels (repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--list-labels
            repo (lambda (r)
                   (funcall done (if (eq (car-safe r) 'error)
                                     r
                                   (cl-map 'vector (lambda (l) (octocat-sync-label repo l))
                                           r)))))))

(octocat-sync-define-resource assignees (repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--list-people
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(defun octocat-vui-list--stored (resource &optional name)
  "Return a fetch function of `octocat-vui-list--edit-facet' reading RESOURCE.
RESOURCE is the name of a resource of the repo, holding a vector; NAME,
if given, turns each item into its candidate.  Stored data is given at
once, even when old: a prompt can't change its candidates once open, so
the refresh behind it is for the next prompt.  Only an empty store
waits for the fetch."
  (lambda (repo callback)
    (let ((spec    (list resource repo))
          (deliver (lambda (r)
                     (funcall callback (if (eq (car-safe r) 'error)
                                           r
                                         (mapcar (or name #'identity) r))))))
      (if-let* ((data (plist-get (octocat-sync-read spec) :data)))
          (progn (octocat-sync-request spec)
                 (funcall deliver data))
        (octocat-sync-get spec deliver)))))

(defun octocat-vui-list--label-name (label)
  "Return the name of LABEL, a table, in its face, for completion to show."
  (let ((face (octocat--label-face label (octocat--label-background))))
    (if face
        (propertize (gethash "name" label) 'face face)
      (gethash "name" label))))

(defun octocat-vui-list--edit-facet (prefix prompt multi fetch extra)
  "Toggle the PREFIX qualifier of the query through a prompt named PROMPT.
Candidates come from FETCH, a function of the repo and a callback, such
as `octocat-vui-list--stored' returns, plus EXTRA.  MULTI allows several
values, read with `octocat-vui-list--read-multiple'.  The
fetch may be asynchronous; the prompt opens once it completes, outside
the process sentinel.  A failed fetch only logs a message, leaving free
text as the way to enter a value."
  (let ((buf   (current-buffer))
        (repo  octocat-vui-list--repo)
        (query (octocat-vui-list-query)))
    (funcall fetch repo
             (lambda (result)
               (when (buffer-live-p buf)
                 (run-at-time
                  0 nil
                  (lambda ()
                    (when (octocat--still-selected-p buf)
                      (with-current-buffer buf
                        (let* ((names (if (eq (car-safe result) 'error)
                                          (progn (message "Octocat: %s" (cdr result)) nil)
                                        (append extra result)))
                               (picked (funcall
                                        (if multi
                                            #'octocat-vui-list--read-multiple
                                          #'octocat-vui-list--toggle-read)
                                        prompt names
                                        (octocat-vui-list--values query prefix))))
                          (octocat-vui-list--apply
                           (octocat-vui-list--with-values
                            (octocat-vui-list-query) prefix picked))))))))))))

(defun octocat-vui-list-filter-state ()
  "Choose which state to list."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let* ((query  (octocat-vui-list-query))
         (picked (octocat-vui-list--toggle-read
                  "State" octocat-vui-list--states
                  (list (octocat-vui-list--state query)))))
    (octocat-vui-list--apply
     (octocat-vui-list--with-state query (or (car picked) "all")))))

(defun octocat-vui-list-filter-author ()
  "Filter by author."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "author:" "Author" nil
                                (octocat-vui-list--stored 'assignees) '("@me")))

(defun octocat-vui-list-filter-assignee ()
  "Filter by assignee."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "assignee:" "Assignee" nil
                                (octocat-vui-list--stored 'assignees) '("@me")))

(defun octocat-vui-list-filter-reviewer ()
  "Filter by requested reviewer; @me lists the PRs awaiting your review."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "review-requested:" "Reviewer" nil
                                (octocat-vui-list--stored 'assignees) '("@me")))

(defun octocat-vui-list-filter-label ()
  "Filter by labels (all selected labels must match)."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "label:" "Label" t
                                (octocat-vui-list--stored 'labels #'octocat-vui-list--label-name)
                                nil))

(defun octocat-vui-list-clear-filter ()
  "Reset the query of the current list to the default."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--apply octocat-vui-list--default-query))

(defvar-local octocat-vui-list--facets
  '(("State"    . octocat-vui-list-filter-state)
    ("Author"   . octocat-vui-list-filter-author)
    ("Assignee" . octocat-vui-list-filter-assignee)
    ("Label"    . octocat-vui-list-filter-label))
  "Filter facets as (LABEL . COMMAND), in filter-bar order.")

(defun octocat-vui-list-filter ()
  "Pick a filter facet to change, like GitHub's filter menu."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let* ((choices (append octocat-vui-list--facets
                          '(("Query" . octocat-vui-list-edit-query)
                            ("Clear"  . octocat-vui-list-clear-filter))))
         (choice  (completing-read "Filter: " (mapcar #'car choices) nil t)))
    (call-interactively (cdr (assoc choice choices)))))

(vui-defcomponent octocat-vui-list-query-field (query)
  "Editable field holding QUERY.
RET in it runs the edited query."
  :render
  (let* ((draft (vui-use-ref nil))
         ;; Typed but unsubmitted text survives re-renders (a page
         ;; arriving) until the query itself changes.
         (value (if (equal (car (car draft)) query) (cdr (car draft)) query)))
    (vui-field :key :query
               :value value
               :size (max 40 (1+ (string-width value)))
               :face 'octocat-filter-input
               :placeholder "(everything)"
               :on-change (lambda (text) (setcar draft (cons query text)))
               :on-submit #'octocat-vui-list--query-submitted)))

(defun octocat-vui-list-filter-bar (query)
  "Return a vnode showing the search QUERY and one button per facet.
A [clear] button shows when it differs from the default."
  (let ((active (octocat-vui-list-filter-active-p query)))
    (vui-fragment
     ;; The label and the facet row's indent are both as wide as "Filter"
     ;; (plus the stack's spacing), so the query box and the facet buttons
     ;; start in the same column.
     (vui-hstack :spacing 2
                 (vui-text "Filter" :face 'octocat-dimmed)
                 (vui-component 'octocat-vui-list-query-field
                   :query (string-trim (or query "")))
                 (when active
                   (vui-button "[clear]"
                     :no-decoration t
                     :face 'octocat-dimmed
                     :key :clear
                     :help-echo (octocat--button-help "RET: reset the query"
                                                      #'octocat-vui-list-clear-filter)
                     :on-click #'octocat-vui-list-clear-filter)))
     (vui-newline)
     (apply #'vui-hstack :spacing 2
            (vui-text "      ")
            (mapcar (lambda (facet)
                      (vui-button (format "[%s]" (car facet))
                        :no-decoration t
                        :face 'octocat-dimmed
                        :key (car facet)
                        :help-echo (octocat--button-help
                                    (format "RET: filter by %s"
                                            (downcase (car facet)))
                                    (cdr facet))
                        :on-click (cdr facet)))
                    octocat-vui-list--facets))
     (vui-newline))))


;;;; Marks
;;
;; The PR and issue lists mark items as Dired marks files: `m' marks
;; the item at point, or every item in the region, `u' unmarks and `U'
;; unmarks all.  Marks are item numbers, the state of the list page
;; (`octocat-vui-search-list'), so they last through a redraw.  Only
;; items shown are marked, so that what is done to the marked items is
;; done to what one sees: an item that leaves the list, after a new
;; query or as it is closed, is unmarked.

(defun octocat-vui-list-marks ()
  "Return the numbers of the items marked in the current list buffer."
  (when-let* ((page (vui-get-instance)))
    (plist-get (vui-instance-state page) :marks)))

(defun octocat-vui-list--item-at (pos)
  "Return the number of the list item at POS, or nil."
  (get-text-property pos 'octocat-vui-list-item))

(defun octocat-vui-list--items-in (beg end)
  "Return the numbers of the list items with text between BEG and END."
  (let (items)
    (while (< beg end)
      (when-let* ((n (octocat-vui-list--item-at beg)))
        (cl-pushnew n items))
      (setq beg (next-single-property-change beg 'octocat-vui-list-item nil end)))
    (nreverse items)))

(defun octocat-vui-list--next-item (pos)
  "Return the start of the list item after the one at POS, or nil."
  (let ((here (octocat-vui-list--item-at pos)))
    (while (and (setq pos (next-single-property-change pos 'octocat-vui-list-item))
                (memql (octocat-vui-list--item-at pos) (list nil here))))
    pos))

(defun octocat-vui-list--goto-item (number)
  "Move to the start of the row of item NUMBER, if it is shown."
  (when-let* ((pos (text-property-any (point-min) (point-max)
                                      'octocat-vui-list-item number)))
    (goto-char pos)))

(defun octocat-vui-list--set-marks (marked)
  "Mark the items numbered in MARKED, alone; say how many there are."
  (unless octocat-vui-list--set-marks-function
    (user-error "Octocat: Nothing to mark on this page"))
  (funcall octocat-vui-list--set-marks-function marked)
  (message "Octocat: %s marked" (if marked (length marked) "None")))

(defun octocat-vui-list--with-marks (marked items mark)
  "Return MARKED, item numbers, with ITEMS added if MARK, else taken out."
  (if mark
      (append marked (seq-difference items marked))
    (seq-difference marked items)))

(defun octocat-vui-list--mark-items (mark)
  "Mark the items of the region, or the item at point, if MARK; else unmark.
A region counts from the start of its first line, as in Dired.  Without
one, move to the next item."
  (let* ((region (use-region-p))
         (items  (if region
                     (octocat-vui-list--items-in
                      (save-excursion (goto-char (region-beginning)) (line-beginning-position))
                      (region-end))
                   (list (or (octocat-vui-list--item-at (point))
                             (user-error "Octocat: No item at point")))))
         (next   (and (not region)
                      (when-let* ((pos (octocat-vui-list--next-item (point))))
                        (octocat-vui-list--item-at pos)))))
    (octocat-vui-list--set-marks
     (octocat-vui-list--with-marks (octocat-vui-list-marks) items mark))
    (if region
        (deactivate-mark)
      (when next
        (octocat-vui-list--goto-item next)))))

(defun octocat-vui-list-mark ()
  "Mark the item at point and move to the next; with a region, its items."
  (interactive)
  (octocat-vui-list--mark-items t))

(defun octocat-vui-list-unmark ()
  "Unmark the item at point and move to the next; with a region, its items."
  (interactive)
  (octocat-vui-list--mark-items nil))

(defun octocat-vui-list-unmark-all ()
  "Unmark every item."
  (interactive)
  (octocat-vui-list--set-marks nil))

;; While items are marked, a bar below the filters offers what can be
;; done to them.  An action sends one change per item, one after another
;; in the background (`octocat-sync-submit-each'); while it runs, the
;; bar and the mode line show how far it is, and the bar's actions wait.

(defun octocat-vui-list--noun (kind n)
  "Return what N items of KIND are called: \"PR\", \"issues\"..."
  (concat (if (eq kind 'pulls) "PR" "issue") (if (= n 1) "" "s")))

(defconst octocat-vui-list--toggles
  '(("label"    :button "[Label]" :name "Labels" :field "labels" :key "name"
     :resource labels :doing "Labelling" :done "Labelled")
    ("assignee" :button "[Assign]" :name "Assignees" :field "assignees" :key "login"
     :resource assignees :doing "Assigning" :done "Assigned" :prefix "@")
    ("reviewer" :button "[Request review]" :name "Reviewers"
     :field "requestedReviewers" :key "login" :resource assignees
     :doing "Requesting reviews" :done "Updated the reviewers of" :prefix "@"
     :kinds (pulls)))
  "What the Marked bar toggles on the marked items, by FLAG.
FLAG is as for `gh ... edit --add-FLAG'.  :button is its button, :name
what to call the values, :field and :key as for
`octocat-vui-list--value-counts', :resource the repo's resource of
candidates, :doing and :done as for `octocat-vui-list--send-each',
:prefix what goes before a value shown, \"@\" before a login, and
:kinds the lists it is on, all when absent.")

(defun octocat-vui-list-apply-bar (kind repo spec marked busy)
  "Return the bar of the actions on MARKED, numbers of KIND items of REPO.
It takes the place of the filter bar, in as many rows.  SPEC is the
list's resource.  BUSY, if non-nil, is what an action on them is doing:
shown instead of the actions."
  (vui-fragment
   (vui-hstack :spacing 2
               (vui-text "Marked" :face 'octocat-dimmed)
               (vui-text (format "%d %s" (length marked)
                                 (octocat-vui-list--noun kind (length marked))))
               (vui-button "[Unmark all]"
                 :no-decoration t
                 :face 'octocat-dimmed
                 :key :unmark
                 :help-echo (octocat--button-help "RET: unmark all"
                                                  #'octocat-vui-list-unmark-all)
                 :on-click #'octocat-vui-list-unmark-all))
   (vui-newline)
   (apply #'vui-hstack :spacing 2
          (vui-text "      ")
          (if busy
              (list (vui-text (concat (octocat-vui-spinner) " " busy) :face 'octocat-dimmed))
            (delq nil
                  (mapcar (pcase-lambda (`(,flag . ,props))
                            (when (memq kind (or (plist-get props :kinds) (list kind)))
                              (vui-button (plist-get props :button)
                                :no-decoration t
                                :face 'octocat-dimmed
                                :key flag
                                :help-echo (format "RET: add or remove %s of the marked %s"
                                                   (downcase (plist-get props :name))
                                                   (octocat-vui-list--noun kind 2))
                                :on-click (lambda ()
                                            (octocat-vui-list--toggle-marked
                                             flag kind repo spec marked)))))
                          octocat-vui-list--toggles))))
   (vui-newline)))

(defun octocat-vui-list--value-counts (items field key)
  "Return how many of ITEMS have each value of their FIELD, as (VALUE . N).
FIELD holds a vector of tables, KEY the name of their value."
  (let (counts)
    (dolist (item items)
      (seq-doseq (x (or (gethash field item) []))
        ;; A team asked to review has no login.
        (when-let* ((value (and (hash-table-p x) (gethash key x))))
          (let ((cell (assoc value counts)))
            (if cell (cl-incf (cdr cell)) (push (cons value 1) counts))))))
    (nreverse counts)))

(defun octocat-vui-list--toggle-changes (items picked field key)
  "Return the edits for toggling PICKED values on ITEMS: (NUMBER ADD REMOVE).
A value every item has is taken off them all; any other is added to
those without it.  FIELD and KEY are as for
`octocat-vui-list--value-counts'.  Items left as they are are left out."
  (let ((all    (length items))
        (counts (octocat-vui-list--value-counts items field key)))
    (delq nil
          (mapcar
           (lambda (item)
             (let ((has (mapcar (lambda (x) (gethash key x))
                                (or (gethash field item) [])))
                   add remove)
               (dolist (value picked)
                 (if (eql (cdr (assoc value counts)) all)
                     (push value remove)
                   (unless (member value has) (push value add))))
               (and (or add remove)
                    (list (gethash "number" item) (nreverse add) (nreverse remove)))))
           items))))

(defun octocat-vui-list--read-toggles (prompt candidates counts total)
  "Read values from CANDIDATES to toggle on TOTAL items; return them.
PROMPT names what they are.  COUNTS, as `octocat-vui-list--value-counts'
returns, says how many items have each: those all have are marked ✓ and
listed first, then those some have, marked –."
  (let* ((n      (lambda (c) (or (cdr (assoc (substring-no-properties c) counts)) 0)))
         (sorted (append (seq-filter (lambda (c) (= (funcall n c) total)) candidates)
                         (seq-filter (lambda (c) (< 0 (funcall n c) total)) candidates)
                         (seq-filter (lambda (c) (zerop (funcall n c))) candidates)))
         (annotate (lambda (c)
                     (let ((k (funcall n c)))
                       (cond ((= k total) "  ✓ all")
                             ((> k 0) (format "  – %d of %d" k total))
                             (t "")))))
         (table  (lambda (string pred action)
                   (if (eq action 'metadata)
                       `(metadata (annotation-function . ,annotate)
                                  (display-sort-function . identity))
                     (complete-with-action action sorted string pred)))))
    (delete-dups (mapcar #'substring-no-properties
                         (seq-remove #'string-empty-p
                                     (mapcar #'string-trim
                                             (completing-read-multiple
                                              (format "%s (✓ all have it, – some): " prompt)
                                              table nil t)))))))

(defun octocat-vui-list--toggle-marked (flag kind repo spec marked)
  "Toggle values of FLAG on MARKED, the numbers of KIND items of REPO.
FLAG is in `octocat-vui-list--toggles'.  SPEC is the list's resource,
which holds the items' values.  The values picked are toggled on them
all; with more than one item changing, ask first."
  (when-let* ((busy (alist-get 'batch (plist-get (octocat-sync-read (list 'counts kind repo))
                                                 :mutating))))
    (user-error "Octocat: Wait for \"%s\" to finish" busy))
  (let* ((props    (cdr (assoc flag octocat-vui-list--toggles)))
         (name     (plist-get props :name))
         (field    (plist-get props :field))
         (key      (plist-get props :key))
         (resource (plist-get props :resource))
         (prefix   (or (plist-get props :prefix) ""))
         (items    (seq-filter (lambda (item) (memql (gethash "number" item) marked))
                               (append (gethash "nodes" (plist-get (octocat-sync-read spec)
                                                                   :data))
                                       nil)))
         (buf      (current-buffer))
         (show     (lambda (value) (concat prefix value))))
    (funcall
     (if (equal flag "label")
         (octocat-vui-list--stored 'labels #'octocat-vui-list--label-name)
       (octocat-vui-list--stored resource))
     repo
     (lambda (result)
       ;; Outside the process sentinel, as the list filters do.
       (run-at-time
        0 nil
        (lambda ()
          (when (octocat--still-selected-p buf)
            (with-current-buffer buf
              (let* ((noun    (octocat-vui-list--noun kind (length items)))
                     (counts  (octocat-vui-list--value-counts items field key))
                     (picked  (octocat-vui-list--read-toggles
                               (format "%s of %d %s" name (length items) noun)
                               (delete-dups
                                (mapcar show
                                        (append (if (eq (car-safe result) 'error)
                                                    (progn (message "Octocat: %s" (cdr result))
                                                           nil)
                                                  result)
                                                (mapcar #'car counts))))
                               (mapcar (lambda (c) (cons (funcall show (car c)) (cdr c))) counts)
                               (length items)))
                     (changes (octocat-vui-list--toggle-changes
                               items (mapcar (lambda (p) (string-remove-prefix prefix p)) picked)
                               field key)))
                (when (and changes
                           (or (null (cdr changes))
                               (y-or-n-p (format "Change the %s of %d %s? "
                                                 (downcase name) (length changes)
                                                 (octocat-vui-list--noun kind (length changes))))))
                  (octocat-vui-list--send-each
                   kind repo (plist-get props :doing) (plist-get props :done)
                   (mapcar (pcase-lambda (`(,number ,add ,remove))
                             `(edit-values ,(if (eq kind 'pulls) "pr" "issue") ,repo ,number
                                           ,flag ,add ,remove))
                           changes))))))))))))

(defun octocat-vui-list--send-each (kind repo doing done specs)
  "Send SPECS, mutations of KIND items of REPO, one after another.
DOING, such as \"Labelling\", says what they do while they run, and DONE,
such as \"Labelled\", how it went once the last is answered."
  (octocat-sync-submit-each
   specs doing (list (list 'counts kind repo))
   (lambda (answers)
     (let* ((failed (seq-filter (lambda (a) (eq (car-safe (cdr a)) 'error)) answers))
            (total  (length answers))
            (noun   (octocat-vui-list--noun kind total)))
       (if failed
           (message "Octocat: %s %d of %d %s; failed: %s" done (- total (length failed))
                    total noun
                    (mapconcat (lambda (a) (format "#%d" (nth 3 (car a)))) failed ", "))
         (message "Octocat: %s %d %s" done total noun))))))

(defvar octocat-vui-list-mark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'octocat-vui-list-mark)
    (define-key map (kbd "u") #'octocat-vui-list-unmark)
    (define-key map (kbd "U") #'octocat-vui-list-unmark-all)
    map)
  "Keys that mark items, in the lists whose items can be marked.")

(provide 'octocat-vui)
;;; octocat-vui.el ends here
