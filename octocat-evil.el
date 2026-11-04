;;; octocat-evil.el --- Evil keybindings for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5

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

;; Optional Evil integration for octocat.el.  Loaded automatically by
;; octocat.el when `evil-mode' is active; do not load this file
;; directly.
;;
;; Defines `octocat-evil-setup', which installs normal-state bindings
;; for `octocat-mode-map' (dashboard), `octocat-repo-mode-map' (repo
;; view), `octocat-pr-mode-map', `octocat-commit-mode-map', and others.

;;; Code:

(declare-function evil-define-key*          "ext:evil-core" (state keymap key def &rest bindings))
(declare-function evil-normalize-keymaps    "ext:evil-core" (&optional hook))
(declare-function evil-set-initial-state    "ext:evil-core" (mode state))
(declare-function evil-local-set-key        "ext:evil-core" (state key def))
;; Defined by Evil's own macros, which `check-declare' cannot read: the
;; t says to check only that the file exists.
(declare-function evil-insert-state         "ext:evil-states" (&optional arg) t)
(declare-function evil-normal-state         "ext:evil-states" (&optional arg) t)
(declare-function evil-ret                  "ext:evil-commands" (&optional count) t)
(declare-function evil-backward-char        "ext:evil-commands"
                  (&optional count crosslines noerror) t)
(declare-function evil-forward-char         "ext:evil-commands"
                  (&optional count crosslines noerror) t)

;; octocat.el loads this file last, once it has required every other
;; module, so requiring them here costs nothing.
(require 'octocat-actions)
(require 'octocat-core)
(require 'octocat-dashboard)
(require 'octocat-diff)
(require 'octocat-doctor)
(require 'octocat-issue)
(require 'octocat-pr)
(require 'octocat-repo)
(require 'octocat-search)
(require 'octocat-user)
(require 'octocat-vui)

(defvar evil-local-mode)

(defun octocat-evil-list-edit-query ()
  "Move into the query field of the current list, in insert state."
  (interactive)
  (octocat-vui-list-edit-query)
  (evil-insert-state))

(defun octocat-evil-list-ret ()
  "Start editing the query field when on it, else `evil-ret'.
`evil-ret' would treat the field as a button without an action and
insert a newline into it."
  (interactive)
  (let ((widget (octocat-vui-list--query-widget)))
    (if (and widget (eq (widget-field-at (point)) widget))
        (octocat-evil-list-edit-query)
      (call-interactively #'evil-ret))))

(defun octocat-evil-field-ret ()
  "Edit the field at point from the end of its text, else `evil-ret'.
`evil-ret' would insert a newline into the field."
  (interactive)
  (if-let* ((widget (widget-field-at (point))))
      (progn (goto-char (octocat-vui-field-value-end widget))
             (evil-insert-state))
    (call-interactively #'evil-ret)))

(defun octocat-evil--field-setup ()
  "Bind RET to `octocat-evil-field-ret' in the current buffer.
Buffer-local, as a field's keymap hides the mode's Evil bindings."
  (evil-local-set-key 'normal (kbd "RET") #'octocat-evil-field-ret))

(defconst octocat-evil--list-bindings
  '(("RET"     . octocat-evil-list-ret)
    ("o"       . octocat-visit)
    ("O"       . octocat-visit-other-window)
    ("C-c C-o" . octocat-browse)
    ("C-c C-j" . octocat-jump)
    ("C-c C-v" . octocat-vui-list-toggle-compact)
    ("gs"      . octocat-search-repo)
    ("gr"      . octocat-vui-refresh)
    ("F"       . octocat-vui-list-filter)
    ("q"       . octocat-quit-window))
  "Normal-state bindings of the PR, issue and Actions list pages.")

(defun octocat-evil--list-setup ()
  "Bind `octocat-evil--list-bindings' in the current list buffer.
Buffer-local, as the query field's keymap replaces the mode's keymap,
and with it the mode's Evil bindings: after ESC in the field, `q'
would start recording a macro."
  (pcase-dolist (`(,key . ,def) octocat-evil--list-bindings)
    (evil-local-set-key 'normal (kbd key) def))
  (when (derived-mode-p 'octocat-pr-list-mode 'octocat-issue-list-mode)
    (evil-local-set-key 'normal (kbd "C-c C-n") #'octocat-issue-new)
    ;; Visual state too: `V' then `m' marks the lines selected.
    (map-keymap (lambda (key def)
                  (evil-local-set-key 'normal (vector key) def)
                  (evil-local-set-key 'visual (vector key) def))
                octocat-vui-list-mark-map)))

(defun octocat-evil--field-left ()
  "Leave insert state once a field is submitted or left by RET."
  (when evil-local-mode
    (evil-normal-state)))

(defun octocat-evil-tree-l ()
  "Open the file or the directory at point, as in treemacs-evil.
Off an entry, such as on the header, move right."
  (interactive)
  (if (octocat-tree--entry-at-point-p)
      (octocat-tree-visit)
    (call-interactively #'evil-forward-char)))

(defun octocat-evil-tree-h ()
  "Move to the directory containing the entry at point, as in treemacs-evil.
Off an entry, such as on the header, move left."
  (interactive)
  (if (octocat-tree--entry-at-point-p)
      (octocat-repo-up)
    (call-interactively #'evil-backward-char)))


;;;###autoload
(defun octocat-evil-setup ()
  "Install Evil normal-state keybindings for all octocat modes."
  ;; ── octocat-mode (dashboard) ──────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode below: each row binds its own
  ;; RET via a `keymap' text property, so only the global bindings go here.
  (evil-define-key* 'normal octocat-mode-map
    (kbd "+")       #'octocat-feed-load-more
    (kbd "C-c C-o") #'octocat-browse
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-repo-mode ─────────────────────────────────────────────────
  ;; Each row binds its own RET via a `keymap' text property, so only the
  ;; global bindings go here, and the file tree's, as in treemacs-evil.
  ;; The commits page derives from this mode, so it has these too.
  (evil-define-key* 'normal octocat-repo-mode-map
    (kbd "l")       #'octocat-evil-tree-l
    (kbd "h")       #'octocat-evil-tree-h
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "C-c C-f") #'octocat-tree-find-file
    (kbd "C-c C-b") #'octocat-repo-switch-branch
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-user-mode ─────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode: rows bind their own RET.
  (evil-define-key* 'normal octocat-user-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-doctor-mode ───────────────────────────────────────────────
  (evil-define-key* 'normal octocat-doctor-mode-map
    (kbd "gr")      #'revert-buffer
    (kbd "q")       #'quit-window)

  ;; ── PR / issue list pages and the run list ──────────────────────────────────
  ;; Normal state is bound per buffer by `octocat-evil--list-setup'.
  ;; Motion state on each derived mode's own map: Evil's auxiliary keymaps
  ;; are not reliably found through the parent `octocat-vui-list-mode-map'.
  (dolist (map (list octocat-pr-list-mode-map
                     octocat-issue-list-mode-map
                     octocat-run-list-mode-map))
    (evil-define-key* 'motion map
      (kbd "F")       #'octocat-vui-list-filter))
  (add-hook 'octocat-vui-list-mode-hook #'octocat-evil--list-setup)
  (add-hook 'octocat-vui-list-query-submit-hook #'octocat-evil--field-left)
  (add-hook 'octocat-vui-field-next-hook #'octocat-evil--field-left)

  ;; ── octocat-pr-mode ───────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-issue-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-pr-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-a") #'octocat-pr-add-comment
    (kbd "C-c C-e") #'octocat-pr-edit
    (kbd "C-c C-l") #'octocat-pr-react
    (kbd "C-c C-n") #'octocat-issue-new
    (kbd "C-c C-m") #'octocat-pr-merge
    (kbd "C-c C-r") #'octocat-pr-diff-review
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-commit-mode ───────────────────────────────────────────────
  ;; vui.el-rendered like octocat-pr-diff-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-commit-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-v") #'octocat-commit-toggle-patch
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-compare-mode ──────────────────────────────────────────────
  (evil-define-key* 'normal octocat-compare-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-checks-mode ───────────────────────────────────────────────
  (evil-define-key* 'normal octocat-checks-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-pr-diff-mode ──────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode, so only the global commands
  ;; are bound here.
  (evil-define-key* 'normal octocat-pr-diff-mode-map
    (kbd "C-c C-a") #'octocat-diff-add-comment
    (kbd "C-c C-e") #'octocat-diff-edit-comment
    (kbd "C-c C-r") #'octocat-pr-diff-review
    (kbd "C-c C-m") #'octocat-pr-merge
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-v") #'octocat-diff-toggle-comments
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; A region of lines, marked with `V', is commented on as one.
  (evil-define-key* 'visual octocat-pr-diff-mode-map
    (kbd "C-c C-a") #'octocat-diff-add-comment)

  ;; ── octocat-pr-commits-mode ───────────────────────────────────────────
  (evil-define-key* 'normal octocat-pr-commits-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-m") #'octocat-pr-merge
    (kbd "C-c C-r") #'octocat-pr-diff-review
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-issue-mode ────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-issue-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-a") #'octocat-issue-add-comment
    (kbd "C-c C-e") #'octocat-issue-edit
    (kbd "C-c C-l") #'octocat-issue-react
    (kbd "C-c C-n") #'octocat-issue-new
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-workflow-mode ─────────────────────────────────────────────
  (evil-define-key* 'normal octocat-workflow-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)
  (add-hook 'octocat-workflow-mode-hook #'octocat-evil--field-setup)

  ;; ── octocat-run-mode ──────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-run-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-v") #'octocat-run-toggle-view
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-job-mode ──────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-job-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-vui-refresh
    (kbd "q")       #'octocat-quit-window)

  ;; ── octocat-file-mode ─────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode: links and buttons bind RET.
  (evil-define-key* 'normal octocat-file-mode-map
    (kbd "C-c C-o") #'octocat-browse
    (kbd "C-c C-f") #'octocat-tree-find-file
    (kbd "C-c C-l") #'octocat-file-log-open
    (kbd "C-c C-b") #'octocat-file-switch-branch
    (kbd "C-c C-v") #'octocat-file-cycle-view
    (kbd "q")       #'octocat-quit-window
    (kbd "gr")      #'octocat-vui-refresh)
  (evil-define-key* 'motion octocat-file-mode-map
    (kbd "gr")      #'octocat-vui-refresh)

  ;; ── Keys every page but the lists (see above) shares ─────────────────
  ;; As treemacs-evil: `o' is RET and `O' opens in another window.  Each
  ;; mode's own map, as Evil's auxiliary keymaps are not reliably found
  ;; through the shared parent `octocat-common-map'.
  (dolist (map (list octocat-mode-map octocat-repo-mode-map
                     octocat-user-mode-map octocat-pr-mode-map
                     octocat-commit-mode-map octocat-compare-mode-map
                     octocat-checks-mode-map octocat-pr-diff-mode-map
                     octocat-pr-commits-mode-map octocat-issue-mode-map
                     octocat-workflow-mode-map octocat-run-mode-map
                     octocat-job-mode-map octocat-file-mode-map))
    (evil-define-key* 'normal map
      (kbd "o")          #'octocat-visit
      (kbd "O")          #'octocat-visit-other-window
      (kbd "S-<return>") #'octocat-visit-other-window
      (kbd "C-c C-j")    #'octocat-jump))

  ;; ── octocat-edit-mode ─────────────────────────────────────────────────
  ;; Comment, review and body editors open to be typed in.
  (evil-set-initial-state 'octocat-edit-mode 'insert)

  ;; Refresh all octocat keymaps so the new bindings take effect in any
  ;; already-open buffers.
  (evil-normalize-keymaps))

(provide 'octocat-evil)
;;; octocat-evil.el ends here
