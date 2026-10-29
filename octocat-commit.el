;;; octocat-commit.el --- Commit detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Commit data fetching and the `octocat-commit-mode' page, rendered with
;; vui.el like the issue and PR pages.  The commit, its check-runs and its
;; comments are three sync resources, each painted from the store and
;; refetched behind it; the commit itself never changes, so it is kept.
;; The changed files are rendered by octocat-diff.el, like the PR diff
;; page's.
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

(declare-function octocat-repo-vui--link       "octocat-repo" (label face action &optional help))
(declare-function octocat-repo-vui--login-link "octocat-repo" (login))
(declare-function octocat-tree-open            "octocat-repo" (repo &optional ref path))




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


;; Not REST: it has no way to ask whether a branch holds a commit.
(defconst octocat-commit--branch-query
  (concat "query($owner:String!,$name:String!,$sha:String!){repository(owner:$owner,"
          "name:$name){defaultBranchRef{name compare(headRef:$sha){status}}}}")
  "GraphQL query behind the `commit-branch' resource.")

(defun octocat-commit--parse-branch (json-string)
  "Parse JSON-STRING, the response to `octocat-commit--branch-query'.
Return a hash-table whose \"name\" is the default branch when it holds
the commit, the commit being behind it or at its head, else :null."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (ref  (and (hash-table-p repo) (gethash "defaultBranchRef" repo)))
         (cmp  (and (hash-table-p ref) (gethash "compare" ref)))
         (out  (make-hash-table :test #'equal)))
    (puthash "name"
             (if (and (hash-table-p cmp)
                      (member (gethash "status" cmp) '("BEHIND" "IDENTICAL")))
                 (gethash "name" ref)
               :null)
             out)
    out))

(octocat-sync-define-resource commit-branch (repo sha)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (let ((parts (split-string repo "/")))
             (octocat--run-gh
              "commit-branch"
              (list "api" "graphql"
                    "-f" (concat "query=" octocat-commit--branch-query)
                    "-f" (concat "owner=" (car parts))
                    "-f" (concat "name=" (cadr parts))
                    "-f" (concat "sha=" sha))
              #'octocat-commit--parse-branch
              done))))


;;;; Internal helpers

;;;; Sections
;;
;; Each returns the vnodes of one part of the page.  The files reuse the
;; PR diff's file component: commit comments have the same shape as PR
;; review comments.

(defun octocat-commit--top-line (repo sha width)
  "Return the top line of commit SHA of REPO, as the tree browser's.
That is owner/repo@SHA, then a button to browse the files of the
repository at it.  SHA is cut to keep the line within WIDTH columns,
ElDoc showing it whole."
  (let ((browse "[Browse files]"))
    (vui-hstack :spacing 0
                (octocat-vui-repo-heading repo)
                (vui-text (concat "@" (octocat-vui--fit
                                       sha (- width (string-width repo) 1 2
                                              (string-width browse))))
                  :face 'octocat-commit-sha)
                (vui-text "  ")
                (vui-button browse
                  :no-decoration t
                  :face 'octocat-dimmed
                  :help-echo "RET: browse the repository's files at this commit"
                  :on-click (lambda () (octocat-tree-open repo sha))))))

(defun octocat-commit--person (commit role)
  "Return who COMMIT's ROLE is, as `git show' prints it, as nodes.
ROLE is \"author\" or \"committer\".  That is Name <email>, then the
GitHub account linked to it, @login, opening its page."
  (let* ((c     (gethash "commit" commit))
         (who   (and c (gethash role c)))
         (name  (and (hash-table-p who) (octocat--nonempty (gethash "name" who))))
         (email (and (hash-table-p who) (octocat--nonempty (gethash "email" who))))
         (user  (gethash role commit))
         (login (and (hash-table-p user) (octocat--nonempty (gethash "login" user)))))
    (delq nil
          (list (vui-text (string-join (delq nil (list name (and email (format "<%s>" email))))
                                       " ")
                  :face 'octocat-pr-author)
                (and login (vui-text " "))
                (and login (octocat-repo-vui--login-link login))))))

(defun octocat-commit--date (commit role)
  "Return the date of COMMIT's ROLE as `git show' prints it, then its age.
ROLE is as for `octocat-commit--person'.  Nil when it has none."
  (let* ((c   (gethash "commit" commit))
         (who (and c (gethash role c)))
         (ts  (and (hash-table-p who) (octocat--nonempty (gethash "date" who)))))
    (and ts
         (concat (format-time-string "%a %b %-d %H:%M:%S %Y %z" (date-to-time ts))
                 "  "
                 (propertize (concat "(" (octocat--format-ts-relative ts) ")")
                             'face 'octocat-dimmed)))))

(defun octocat-commit--field (label nodes)
  "Return a field row of the commit header: LABEL, dimmed, then NODES.
LABEL is padded as `git show --format=fuller' pads them.  NODES are
strings or vnodes; nil when there are none."
  (when nodes
    (apply #'vui-hstack :spacing 0
           (vui-text (format "%-12s" (concat label ":")) :face 'octocat-dimmed)
           (mapcar (lambda (n) (if (stringp n) (vui-text n) n)) nodes))))

(defun octocat-commit--fields (repo commit branch)
  "Return the rows naming COMMIT of REPO, as `git show --format=fuller'.
Its author and committer, with their dates, then its parents and, from
BRANCH, the `commit-branch' snapshot, the default branch when it holds
the commit.  Each parent and the branch open their page."
  (let ((parents (append (gethash "parents" commit) nil))
        (holder  (let ((d (plist-get branch :data)))
                   (and d (octocat--nonempty (gethash "name" d))))))
    (delq nil
          (list
           (octocat-commit--field "Author" (octocat-commit--person commit "author"))
           (octocat-commit--field "AuthorDate"
                                  (delq nil (list (octocat-commit--date commit "author"))))
           (octocat-commit--field "Commit" (octocat-commit--person commit "committer"))
           (octocat-commit--field "CommitDate"
                                  (delq nil (list (octocat-commit--date commit "committer"))))
           (octocat-commit--field
            (if (cdr parents) "Parents" "Parent")
            (cdr (mapcan (lambda (p)
                           (let ((sha (or (gethash "sha" p) "")))
                             (list " "
                                   (octocat-repo-vui--link
                                    (substring sha 0 (min 7 (length sha))) 'octocat-commit-sha
                                    (lambda () (octocat-commit-open repo sha))
                                    "RET: view parent commit"))))
                         parents)))
           ;; Grey bars while it loads, so the message below holds still.
           (pcase (octocat-vui-snapshot-status branch)
             ('pending (octocat-commit--field "Branch" (list (octocat-vui-skeleton '((8))))))
             ('ready
              (and holder
                   (octocat-commit--field
                    "Branch"
                    (list (octocat-repo-vui--link
                           holder 'octocat-branch
                           (lambda () (octocat-tree-open repo holder))
                           (format "RET: browse %s, which holds this commit" holder)))))))))))

(defun octocat-commit--skeleton (width)
  "Return grey bars shaped like a commit page below its top line, cut to WIDTH.
Shown when there is neither a cache nor a response yet: the author and
committer rows, the message, then a few changed files."
  (octocat-vui-skeleton '((12 40) (12 30) (12 40) (12 30) nil ("    " 44) nil ("  " 40) ("  " 28))
                        width))

(defun octocat-commit--message (commit)
  "Return COMMIT's message, its subject bold, unindented so it copies as is.
Shown verbatim, not as markdown: git messages are plain text, wrapped
by their author.  A long one is folded as an opening post is (see
`octocat-timeline-body-lines')."
  (let* ((c     (gethash "commit" commit))
         (lines (split-string (string-trim-right (or (and c (gethash "message" c)) "")) "\n"))
         (text  (string-join (cons (propertize (car lines) 'face 'bold) (cdr lines)) "\n")))
    (octocat-vui-fold-lines text (octocat-vui-line-ends text)
                            octocat-timeline-body-lines 'message-fold "")))

(defun octocat-commit--async-status (snap empty)
  "Return a dimmed vnode for the sync snapshot SNAP if failed or empty, else nil.
EMPTY is the text shown when it is ready but has no data.  Grey bars
while it is pending."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28)))))
    ('error   (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'octocat-dimmed))
    (_ (and (zerop (length (plist-get snap :data)))
            (vui-text (concat "  " empty) :face 'octocat-dimmed)))))

(defun octocat-commit--heading (label snap width)
  "Return the section heading LABEL, with the count of SNAP's data once known.
It is underlined across WIDTH columns."
  (octocat-vui-section-heading (if (plist-get snap :data)
                                   (format "%s (%d)" label (length (plist-get snap :data)))
                                 label)
                               width))

(defun octocat-commit--checks (repo sha checks width)
  "Return the CI section of commit SHA of REPO, or nil when it has none.
Its check-runs are in CHECKS, a sync snapshot.  Its heading is
underlined across WIDTH columns."
  (unless (and (plist-get checks :data)
               (zerop (length (plist-get checks :data))))
    (or (and (eq (octocat-vui-snapshot-status checks) 'pending)
             (octocat-commit--heading "Checks" checks width))
        (when-let* ((status (octocat-commit--async-status checks "(no checks)")))
          (vui-vstack (octocat-commit--heading "Checks" checks width) status))
        (apply #'vui-vstack
               (octocat-checks-block
                (cl-map 'vector #'octocat-checks-from-rest (plist-get checks :data))
                (lambda () (octocat-checks-open repo sha nil))
                width)))))


;;;; Page

(vui-defcomponent octocat-commit--page (repo sha hide-comments raw tick)
  "Commit SHA of REPO: top line, then as `git show': who and when, the
message, then checks, files and comments.  HIDE-COMMENTS leaves the
inline comments out of the diff.  RAW shows markdown verbatim.  The
commit, its checks, its comments and the branch holding it are fetched
independently; each shows what the store holds until then.  A new TICK
fetches them again."
  :render
  (let* ((width    (octocat-vui-window-width))
         (commit   (octocat-vui-use-resource (list 'commit repo sha) tick))
         (checks   (octocat-vui-use-resource (list 'checks repo sha) tick))
         (comments (octocat-vui-use-resource (list 'commit-comments repo sha) tick))
         (branch   (octocat-vui-use-resource (list 'commit-branch repo sha) tick))
         (data     (plist-get commit :data))
         (md-width (progn width (octocat--markdown-width)))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data))))
         (message  (vui-use-memo (data)
                     (and data (octocat-commit--message data)))))
    (vui-vstack
     (octocat-commit--top-line repo (or (and data (gethash "sha" data)) sha) width)
     (octocat-vui-resource-view
      commit
      :skeleton (lambda (_) (vui-text (octocat-commit--skeleton width)))
      :render
      (lambda (_)
        (apply
         #'vui-vstack
         (append
          (octocat-commit--fields repo data branch)
          (delq nil
                (list (vui-newline)
                      message
                      (vui-newline)
                      (when-let* ((section (octocat-commit--checks repo sha checks width)))
                        (vui-fragment section (vui-newline)))
                      (octocat-diff-files-section
                       repo (or (gethash "files" data) []) by-path hide-comments raw md-width t)
                      ;; Most commits have none, so the section is left
                      ;; out unless there are any, or they failed to load.
                      (when (or (not (seq-empty-p (plist-get comments :data)))
                                (eq (octocat-vui-snapshot-status comments) 'error))
                        (vui-fragment
                         (vui-newline)
                         (octocat-diff-comments-section
                          "Comments" comments raw md-width))))))))))))


;;;; Major mode

(defun octocat-commit--page-url ()
  "Return the URL of this commit."
  (and octocat--commit-repo octocat--commit-sha
       (octocat--web-url "%s/commit/%s" octocat--commit-repo octocat--commit-sha)))

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-commit-mode'.")

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
  (octocat--max-width-setup)
  (setq-local octocat--url-function #'octocat-commit--page-url))


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
          octocat--commit-sha  sha
          octocat-diff--hide-comments nil)
    (octocat-commit-refresh)))

(provide 'octocat-commit)
;;; octocat-commit.el ends here
