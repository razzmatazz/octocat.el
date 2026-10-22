;;; octocat-compare.el --- Compare view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
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

;; The `octocat-compare-mode' page: what github.com/OWNER/REPO/compare/
;; BASE...HEAD shows, the commits between two refs, oldest first, then
;; the changed files as on the commit and PR diff pages
;; (octocat-diff.el).  One `gh api' call fetches it all.
;;
;; GitHub's API compares from the merge base only (BASE...HEAD); it has
;; no two-dot BASE..HEAD.  The two agree whenever BASE is an ancestor of
;; HEAD, the usual case, so a two-dot link is shown as three-dot, with a
;; note when they differ.
;;
;; Depends on octocat-core.el; must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-diff)
(require 'octocat-sync)
(require 'octocat-vui)

(declare-function octocat-vui-repo-heading "octocat-vui" (repo))
(require 'vui)

(declare-function octocat-search-repo "octocat-search" ())
(declare-function octocat-repo-vui--commit-row "octocat-repo"
                  (repo commit head-info author-w &optional subject-w))
(declare-function octocat-repo-vui--author-width "octocat-repo" (commits))
(declare-function octocat-repo-vui--subject-width "octocat-repo" (commits width author-w))


;;;; Buffer-local declarations

(defvar-local octocat--compare-repo nil
  "The \"owner/repo\" this compare buffer belongs to.")

(defvar-local octocat--compare-refs nil
  "The (BASE DOTS HEAD) this buffer compares; DOTS is \"..\" or \"...\".")


;;;; Data fetching

(defun octocat-compare--sha-p (ref)
  "Return non-nil when REF is a commit SHA, as a commit link's is.
Unlike a branch or tag, it names the same commit for good."
  (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" ref))

(octocat-sync-define-resource compare (repo base head)
  ;; Comparing two commits never changes, as a commit doesn't; refs move.
  :max-age (and (octocat-compare--sha-p base)
                (octocat-compare--sha-p head)
                (* 30 24 60 60))
  :fetch (lambda (done)
           (octocat--run-gh
            "compare"
            (list "api" (format "repos/%s/compare/%s...%s" repo base head))
            (lambda (output) (json-parse-string (string-trim output)))
            done)))


;;;; Sections

(defun octocat-compare--summary (data dots)
  "Return the dimmed summary lines of the comparison DATA.
DOTS is as in `octocat--compare-refs': a two-dot comparison of refs that
have diverged gets a note that the three-dot one is shown."
  (let* ((total   (or (gethash "total_commits" data) 0))
         (shown   (length (gethash "commits" data)))
         (files   (length (gethash "files" data)))
         (behind  (or (gethash "behind_by" data) 0))
         (plural  (lambda (n word) (format "%d %s%s" n word (if (= n 1) "" "s")))))
    (delq nil
          (list
           (if (equal (gethash "status" data) "identical")
               "These refs are identical"
             (string-join
              (delq nil (list (funcall plural total "commit")
                              (concat (funcall plural files "file") " changed")
                              (and (> behind 0) (format "%d behind" behind))))
              " · "))
           (and (equal dots "..") (> behind 0)
                "Compared from the merge base (...): GitHub's API has no two-dot compare")
           (and (< shown total)
                (format "%d of the %d commits listed, as GitHub's API returns at most %d"
                        shown total shown))
           ;; GitHub returns at most 300 files and doesn't say how many more.
           (and (>= files 300) "GitHub's API lists at most 300 changed files")))))

(defun octocat-compare--commits (repo commits width)
  "Return the vnodes of COMMITS of REPO, a REST commits vector, fitted to WIDTH."
  (let* ((commits   (append commits nil))
         (author-w  (octocat-repo-vui--author-width commits))
         (subject-w (octocat-repo-vui--subject-width commits width author-w)))
    (and commits
         (append (mapcar (lambda (c)
                           (octocat-repo-vui--commit-row repo c nil author-w subject-w))
                         commits)
                 (list (vui-newline))))))

(defun octocat-compare--top-row (repo base dots head)
  "Return the top row of the comparison of BASE and HEAD of REPO.
That is `owner/repo BASE...HEAD', as the commit page's `owner/repo@sha'."
  (vui-hstack :spacing 0
    (octocat-vui-repo-heading repo)
    (vui-text (concat "  "
                      (propertize base 'face 'octocat-branch)
                      (propertize dots 'face 'octocat-dimmed)
                      (propertize head 'face 'octocat-branch)))))


;;;; Page

(vui-defcomponent octocat-compare--page (repo base dots head raw tick)
  "The comparison of BASE and HEAD of REPO: its commits, then its files.
DOTS is as in `octocat--compare-refs'.  RAW shows markdown verbatim.  A
new TICK fetches it again."
  :render
  (let* ((width    (octocat--markdown-width))
         (snap     (octocat-vui-use-resource (list 'compare repo base head) tick)))
    (vui-vstack
     (octocat-compare--top-row repo base dots head)
     (octocat-vui-resource-view
      snap
      :skeleton (lambda (_)
                  (vui-text (octocat-vui-skeleton
                             '((30) nil (26) ("  " 7 "  " 40) ("  " 7 "  " 34) nil
                               (12) ("  " 40) ("  " 28))
                             (octocat-vui-window-width))))
      :render
      (lambda (data)
        (apply #'vui-vstack
               (append
                (mapcar (lambda (line) (vui-text line :face 'octocat-dimmed))
                        (octocat-compare--summary data dots))
                (list (vui-newline))
                (octocat-compare--commits repo (or (gethash "commits" data) []) width)
                (list (octocat-diff-files-section
                       (or (gethash "files" data) []) nil raw width)))))))))


;;;; Major mode

(defun octocat-compare--url (repo refs)
  "Return the github.com page comparing REFS, as `octocat--compare-refs', of REPO."
  (format "https://github.com/%s/compare/%s" repo (apply #'concat refs)))

(defun octocat-compare-browse ()
  "Open this comparison in a browser."
  (interactive)
  (unless (and octocat--compare-repo octocat--compare-refs)
    (user-error "Octocat: Buffer is not associated with a comparison"))
  (message "Octocat: Opening comparison in browser…")
  (octocat-browse-external (octocat-compare--url octocat--compare-repo
                                                 octocat--compare-refs)))

(defvar octocat-compare-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    map)
  "Keymap for `octocat-compare-mode'.")
(define-key octocat-compare-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-compare-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-compare-mode-map (kbd "C-c C-o") #'octocat-compare-browse)
(define-key octocat-compare-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-compare-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-compare-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-compare-mode vui-mode "Octocat-Compare"
  "Major mode for viewing the comparison of two refs of a GitHub repository.

\\{octocat-compare-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-compare-refresh)
  (setq-local octocat--refresh-fn #'octocat-compare-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))


;;;; Refresh

(defun octocat-compare-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current compare buffer."
  (interactive)
  (unless (and octocat--compare-repo octocat--compare-refs)
    (user-error "Octocat: Buffer is not associated with a comparison"))
  (pcase-let ((`(,base ,dots ,head) octocat--compare-refs))
    (octocat-vui-refresh-page 'octocat-compare--page
                              (list octocat--compare-repo base head)
                              (list :repo octocat--compare-repo
                                    :base base :dots dots :head head
                                    :raw octocat--markdown-raw))))

(defun octocat-compare-open (repo base dots head)
  "Show the comparison of BASE and HEAD of REPO in its own buffer.
DOTS is \"...\", or \"..\" for a two-dot link (see the Commentary)."
  (let ((buf (get-buffer-create (format "*%s compare %s%s%s*" repo base dots head))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-compare-mode)
      (octocat-compare-mode))
    (setq octocat--compare-repo repo
          octocat--compare-refs (list base dots head))
    (octocat-compare-refresh)))

(provide 'octocat-compare)
;;; octocat-compare.el ends here
