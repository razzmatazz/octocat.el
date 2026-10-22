;;; octocat-commit.el --- Commit detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6

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

;; Commit data fetching and the `octocat-commit-mode' page, rendered with
;; vui.el like the issue and PR pages.  The commit, its check-runs and its
;; comments are three sync resources, each painted from the store and
;; refetched behind it; the commit itself never changes, so it is kept.  The changed files are rendered
;; by octocat-diff.el, like the PR diff page's.
;;
;; Depends on octocat-core.el; must not depend on octocat.el or
;; octocat-pr.el to avoid circular requires.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-checks)
(require 'octocat-diff)
(require 'octocat-sync)
(defvar octocat-timeline-body-lines) ; defcustom in octocat-timeline.el
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-search-repo "octocat-search" ())



;;;; Custom faces

(defface octocat-commit-sha
  '((t :inherit font-lock-constant-face))
  "Face for a commit SHA in the commit view."
  :group 'octocat)

;;;; Buffer-local declarations

(defvar-local octocat--commit-repo nil
  "The \"owner/repo\" this commit buffer belongs to.")

(defvar-local octocat--commit-sha nil
  "The full commit SHA this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-commit (repo sha callback)
  "Fetch commit detail for SHA in REPO asynchronously.
Calls CALLBACK with a single hash-table of commit data, or the
symbol `error'.  Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "commit"
   (list "api"
         (format "repos/%s/commits/%s" repo sha))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))

(defun octocat--fetch-commit-comments (repo sha callback)
  "Fetch all comments on commit SHA in REPO asynchronously.
Calls CALLBACK with a list of comment hash-tables (snake_case REST API
keys), or a cons \\=(error . MSG) on failure.  The list includes both
general comments (\\='path\\=' is :null or nil) and inline comments
\(\\='path\\=' is a file path string, \\='line\\=' is the target line number)."
  (octocat--run-gh
   "commit-comments"
   (list "api"
         (format "repos/%s/commits/%s/comments" repo sha))
   #'octocat--parse-json-list
   callback))


(octocat-sync-define-resource commit (repo sha)
  ;; What a SHA names never changes.
  :max-age (* 30 24 60 60)
  :fetch (lambda (done) (octocat--fetch-commit repo sha done)))

(octocat-sync-define-resource commit-comments (repo sha)
  :fetch (lambda (done)
           (octocat--fetch-commit-comments
            repo sha
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))


;;;; Internal helpers

;;;; Sections
;;
;; Each returns the vnodes of one part of the page.  The files reuse the
;; PR diff's file component: commit comments have the same shape as PR
;; review comments.

(defun octocat-commit--header (repo sha commit)
  "Return the header vnodes of commit SHA of REPO.
COMMIT is the commit hash-table, or nil while it loads.  The top row is
the repo and short SHA, as `owner/repo#N' on an issue, then the tab
strip.  The subject is on the row below, and
the author, date and full SHA under it."
  (let* ((c      (and commit (gethash "commit" commit)))
         (msg    (or (and c (gethash "message" c)) ""))
         (author (and c (gethash "author" c)))
         (login  (and commit (octocat--commit-author-login commit))))
    (delq nil
          (list
           (octocat-vui-commit-top-row repo sha)
           (and commit (vui-text (car (split-string msg "\n"))))
           (and commit
                (vui-text
                 (mapconcat
                  #'identity
                  (delq nil
                        (list (propertize (octocat--commit-author-full commit)
                                          'face 'octocat-pr-author)
                              (and login (propertize login 'face 'octocat-pr-author))
                              (octocat--format-ts-relative
                               (or (and author (octocat--nonempty (gethash "date" author)))
                                   ""))))
                  (propertize " · " 'face 'octocat-dimmed))))
           (and commit
                (vui-text (concat (propertize "SHA " 'face 'octocat-dimmed)
                                  (propertize (or (gethash "sha" commit) sha)
                                              'face 'octocat-commit-sha))))))))

(defun octocat-commit--skeleton (width)
  "Return grey bars shaped like a commit page below its top row, cut to WIDTH.
Shown when there is neither a cache nor a response yet: the subject,
author and SHA rows, then a few changed files."
  (octocat-vui-skeleton '((48) (30) (44) nil ("  " 40) ("  " 28)) width))

(defun octocat-commit--body (commit)
  "Return the Message section of COMMIT: the message below its subject.
Nil when the message is the subject alone.  Shown verbatim, not as
markdown: git messages are plain text, wrapped by their author.  A long
one is folded as an opening post is (see `octocat-timeline-body-lines')."
  (let* ((c    (gethash "commit" commit))
         (msg  (or (and c (gethash "message" c)) ""))
         (text (string-trim (mapconcat #'identity (cdr (split-string msg "\n")) "\n"))))
    (unless (string-empty-p text)
      (vui-vstack
       (vui-text (propertize "Message" 'face 'octocat-section-heading))
       (octocat-vui-fold-lines text (octocat-vui-line-ends text)
                               octocat-timeline-body-lines 'message-fold "")))))

(defun octocat-commit--async-status (snap empty)
  "Return a dimmed vnode for the sync snapshot SNAP if failed or empty, else nil.
EMPTY is the text shown when it is ready but has no data.  Grey bars
while it is pending."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28)))))
    ('error   (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'octocat-dimmed))
    (_ (and (zerop (length (plist-get snap :data)))
            (vui-text (concat "  " empty) :face 'octocat-dimmed)))))

(defun octocat-commit--heading (label snap)
  "Return the section heading LABEL, with the count of SNAP's data once known."
  (vui-text (propertize (if (plist-get snap :data)
                            (format "%s (%d)" label (length (plist-get snap :data)))
                          label)
                        'face 'octocat-section-heading)))

(defun octocat-commit--checks (repo sha checks)
  "Return the CI section of commit SHA of REPO, or nil when it has none.
Its check-runs are in CHECKS, a sync snapshot."
  (unless (and (plist-get checks :data)
               (zerop (length (plist-get checks :data))))
    (or (and (eq (octocat-vui-snapshot-status checks) 'pending)
             (octocat-commit--heading "Checks" checks))
        (when-let* ((status (octocat-commit--async-status checks "(no checks)")))
          (vui-vstack (octocat-commit--heading "Checks" checks) status))
        (apply #'vui-vstack
               (octocat-checks-block
                (cl-map 'vector #'octocat-checks-from-rest (plist-get checks :data))
                (lambda () (octocat-checks-open repo sha nil)))))))


;;;; Page

(vui-defcomponent octocat-commit--page (repo sha hide-comments raw tick)
  "Commit SHA of REPO: header, message, checks, files and comments.
HIDE-COMMENTS leaves the inline comments out of the diff.  RAW shows
markdown verbatim.  The commit, its checks and its comments
are fetched independently; each shows what the store holds until then.  A
new TICK fetches them again."
  :render
  (let* ((width    (octocat-vui-window-width))
         (commit   (octocat-vui-use-resource (list 'commit repo sha) tick))
         (checks   (octocat-vui-use-resource (list 'checks repo sha) tick))
         (comments (octocat-vui-use-resource (list 'commit-comments repo sha) tick))
         (data     (plist-get commit :data))
         (md-width (progn width (octocat--markdown-width)))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data))))
         (body     (vui-use-memo (data)
                     (and data (octocat-commit--body data)))))
    (apply #'vui-vstack
           (append
            (octocat-commit--header repo sha data)
            (list
             (octocat-vui-resource-view
              commit
              :skeleton (lambda (_) (vui-text (octocat-commit--skeleton width)))
              :render
              (lambda (_)
                (apply
                 #'vui-vstack
                 (delq nil
                       (list (and body (vui-newline))
                             body
                             (vui-newline)
                             (when-let* ((section (octocat-commit--checks repo sha checks)))
                               (vui-fragment section (vui-newline)))
                             (octocat-diff-files-section
                              (or (gethash "files" data) []) by-path hide-comments raw md-width)
                             ;; Most commits have none, so the section is left
                             ;; out unless there are any, or they failed to load.
                             (when (or (not (seq-empty-p (plist-get comments :data)))
                                       (eq (octocat-vui-snapshot-status comments) 'error))
                               (vui-fragment
                                (vui-newline)
                                (octocat-diff-comments-section
                                 "Comments" comments raw md-width)))))))))))))


;;;; Major mode

(defun octocat-commit-browse ()
  "Open this commit in a browser."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (message "Octocat: Opening commit %s in browser…"
           (substring octocat--commit-sha 0 (min 7 (length octocat--commit-sha))))
  (octocat-browse-external (format "https://github.com/%s/commit/%s"
                                   octocat--commit-repo octocat--commit-sha)))

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    map)
  "Keymap for `octocat-commit-mode'.")
(define-key octocat-commit-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-commit-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-commit-mode-map (kbd "C-c C-o") #'octocat-commit-browse)
(define-key octocat-commit-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-commit-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-commit-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-commit-mode vui-mode "Octocat-Commit"
  "Major mode for viewing a GitHub commit.

\\{octocat-commit-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-commit-refresh)
  (setq-local octocat--refresh-fn #'octocat-commit-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))


;;;; Refresh

(defun octocat-commit-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commit buffer.
The page paints from the sync store at once and fetches the commit's
checks and comments in the background, in place; the commit itself
only on `g'."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (octocat-vui-refresh-page 'octocat-commit--page
                            (cons octocat--commit-repo octocat--commit-sha)
                            (list :repo octocat--commit-repo
                                  :sha octocat--commit-sha
                                  :hide-comments octocat-diff--hide-comments
                                  :raw octocat--markdown-raw)))

(defun octocat-commit-open (repo sha)
  "Show commit SHA of REPO in its own buffer."
  (let ((buf (get-buffer-create
              (format "*%s commit %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-commit-mode)
      (octocat-commit-mode))
    (setq octocat--commit-repo repo
          octocat--commit-sha  sha)
    (octocat-commit-refresh)))

(provide 'octocat-commit)
;;; octocat-commit.el ends here
