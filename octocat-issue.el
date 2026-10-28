;;; octocat-issue.el --- Issue detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Issue data fetching, the issue timeline view, and the octocat-issue-mode
;; major mode.  The detail view is vui.el-rendered as a GitHub-style
;; timeline (opening post, comments and events in time order), built with
;; the pieces in octocat-timeline.el.  Depends on octocat-core.el for shared
;; infrastructure; must not depend on octocat.el to avoid a circular
;; require.

;;; Code:

(require 'octocat-core)
(require 'octocat-edit)
(require 'octocat-sync)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, vui-vstack, etc.

;; The issue list page below reuses the row builder and fetch plumbing
;; from octocat-repo.el, which requires this file (so cannot be required
;; here).
(declare-function octocat-repo-vui--issue-row "octocat-repo"
                  (repo issue width bg &optional compact no-state))
(declare-function octocat-repo-vui--issue-compact-line "octocat-repo"
                  (repo issue bg no-state &optional width))
(declare-function octocat-repo-vui--state-label "octocat-repo" (state &optional draft))
(declare-function octocat-repo-vui--detail-header "octocat-repo"
                  (repo item state on-edit-title bg width fields shown &optional branch omit))
(declare-function octocat-repo-vui--login-items "octocat-repo" (users))
(declare-function octocat-repo-vui--numbers "octocat-repo" (repo refs open))
(declare-function octocat-pr-open "octocat-pr" (repo number))
(declare-function octocat-repo-vui--milestone "octocat-repo" (item))

(defvar octocat--issue-repo)
(defvar octocat--issue-number)


;;;; Edit / comment commands — submit helpers

(defun octocat-issue--submit-comment (body source on-success _on-error)
  "Submit BODY as a new comment on the issue in SOURCE buffer.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   (with-current-buffer source `(comment "issue" ,octocat--issue-repo ,octocat--issue-number ,body))
   body source on-success))

(defun octocat-issue--submit-edit-body (body source on-success _on-error)
  "Replace the body of the issue in SOURCE buffer with BODY.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   (with-current-buffer source
     `(edit-body "issue" ,octocat--issue-repo ,octocat--issue-number ,body))
   body source on-success))

(defun octocat-issue--submit-edit-comment (body source on-success _on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the issue.
See `octocat-timeline-submit' for ON-SUCCESS."
  (let ((comment-id (plist-get octocat-edit--user-data :comment-id)))
    (octocat-timeline-submit
     (with-current-buffer source
       `(edit-comment "issue" ,octocat--issue-repo ,octocat--issue-number ,comment-id ,body))
     body source on-success)))

;;;; Edit / comment commands

(defun octocat-issue-add-comment ()
  "Open an edit buffer to add a comment to the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-ensure-idle (list 'issue octocat--issue-repo octocat--issue-number))
  (octocat-timeline-prepare-comment)
  (octocat--open-edit-buffer
   (format "New comment on issue #%d" octocat--issue-number)
   #'octocat-issue--submit-comment
   #'ignore))

(defun octocat-issue-edit-body ()
  "Open an edit buffer to replace the body of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-ensure-idle (list 'issue octocat--issue-repo octocat--issue-number))
  ;; Pre-populate with the current body so the user can edit in place
  ;; rather than retyping everything.
  (let* ((issue (octocat-sync-detail-read (list 'issue octocat--issue-repo octocat--issue-number)))
         (body  (and issue (octocat--nonempty (gethash "body" issue)))))
    (octocat--open-edit-buffer
     (format "Edit body of issue #%d" octocat--issue-number)
     #'octocat-issue--submit-edit-body
     #'ignore
     body)))

(defun octocat-issue-edit-title ()
  "Prompt in the minibuffer to rename the title of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-rename "issue" octocat--issue-repo octocat--issue-number))

(defun octocat-issue-edit ()
  "Edit the thing at point in the current issue buffer.
On the title: rename the issue.
On the opening post: replace the issue body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error.
On a field such as Labels: pick its values."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let ((target (octocat-timeline-target)))
    (cond
     ((eq target 'title) (octocat-issue-edit-title))
     ((eq target 'body)  (octocat-issue-edit-body))
     ((stringp target)
      (octocat-timeline-edit-values "issue" octocat--issue-repo octocat--issue-number target))
     ((hash-table-p target)
      (let* ((authored   (eq (gethash "viewerDidAuthor" target) t))
             (comment-id (octocat--comment-numeric-id target))
             (body       (octocat--nonempty (gethash "body" target))))
        (unless authored
          (user-error "Octocat: You can't edit someone else's comment"))
        ;; A comment being posted has no URL yet.
        (octocat-timeline-ensure-idle (list 'issue octocat--issue-repo octocat--issue-number))
        (unless comment-id
          (user-error "Octocat: Could not determine comment ID from URL"))
        (octocat--open-edit-buffer
         (format "Edit comment on issue #%d" octocat--issue-number)
         #'octocat-issue--submit-edit-comment
         #'ignore
         body
         (list :comment-id comment-id))))
     (t
      (user-error "Octocat: Nothing to edit here")))))

;;;; New issue

(defun octocat-issue--parse-message (text)
  "Split TEXT from the new-issue editor into (TITLE . BODY).
The first line is the title and the rest the body, as in a commit
message."
  (let* ((lines (split-string text "\n")))
    (cons (string-trim (car lines))
          (string-trim (string-join (cdr lines) "\n")))))

(defun octocat-issue--parse-created (output)
  "Return the number of the issue whose URL `gh issue create' printed in OUTPUT."
  (if (string-match "/issues/\\([0-9]+\\)" output)
      (string-to-number (match-string 1 output))
    (error "No issue URL in: %s" (string-trim output))))

(octocat-sync-define-mutation create-issue (repo title body)
  :label "Creating issue…"
  :send (lambda (done)
          (octocat--run-gh "issue-create"
                           (list "issue" "create" "--repo" repo
                                 "--title" title "--body" body)
                           #'octocat-issue--parse-created done))
  :invalidates (lambda () `((list-items issues ,repo _ _) (counts issues ,repo)
                            (repo-summary ,repo))))

(defun octocat-issue--submit-new (text source on-success on-error)
  "Create an issue from TEXT in the repo of `octocat-edit--user-data'.
Open it from SOURCE once GitHub answers; the editor stays open until
then, through ON-SUCCESS or ON-ERROR, as there is no page to show the
issue under way."
  (let ((repo (plist-get octocat-edit--user-data :repo))
        (msg  (octocat-issue--parse-message text)))
    (if (string-empty-p (car msg))
        (funcall on-error "the first line, the title, is empty")
      (octocat-sync-submit
       `(create-issue ,repo ,(car msg) ,(cdr msg))
       (lambda (result)
         (if (eq (car-safe result) 'error)
             (funcall on-error (cdr result))
           (funcall on-success)
           ;; In the window of the page it was written from.
           (when-let* ((win (get-buffer-window source)))
             (select-window win)
             (with-current-buffer source
               (octocat-issue-open repo result)))))))))

(defun octocat-issue-new ()
  "Open an editor to write a new issue for the repository shown.
The first line is the title, the rest the body."
  (interactive)
  (let ((repo (or octocat-vui-list--repo (octocat--search-repo--current-repo))))
    (unless repo
      (user-error "Octocat: Cannot determine current repository"))
    (octocat--open-edit-buffer
     (format "New issue in %s — title on the first line" repo)
     #'octocat-issue--submit-new
     #'ignore
     nil
     (list :repo repo))))

(defun octocat-issue-react ()
  "Pick a reaction to toggle on the issue or comment at point."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-react "issue" octocat--issue-repo octocat--issue-number))

(defun octocat-issue--page-url ()
  "Return the URL of the comment at point, or else of the whole issue."
  (let* ((target (octocat-timeline-target))
         (url    (and (hash-table-p target) (gethash "url" target))))
    (cond ((stringp url) url)
          ((and octocat--issue-repo octocat--issue-number)
           (octocat-issue--url
            (octocat-sync-detail-read (list 'issue octocat--issue-repo octocat--issue-number))
            octocat--issue-repo octocat--issue-number)))))

(defun octocat-issue--url (data repo number)
  "Return the URL of issue NUMBER in REPO: DATA's own, or else built.
DATA, the item's data, is nil before it loads."
  (let ((url (and data (gethash "url" data))))
    (if (stringp url) url
      (octocat--web-url "%s/issues/%d" repo number))))

(defun octocat-issue--change-state (verb)
  "Close or reopen (VERB) the current issue, after asking."
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-state-change "issue" verb octocat--issue-repo
                                 octocat--issue-number))

(defun octocat-issue-close ()
  "Close the current issue, after asking."
  (interactive)
  (octocat-issue--change-state "close"))

(defun octocat-issue-reopen ()
  "Reopen the current issue, after asking."
  (interactive)
  (octocat-issue--change-state "reopen"))


;;;; Buffer-local declarations

(defvar-local octocat--issue-repo nil
  "The \"owner/repo\" this issue buffer belongs to.")

(defvar-local octocat--issue-number nil
  "The issue number this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-issue (repo number callback)
  "Fetch detail for issue NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of issue data, or a cons \\=(error . MSG)."
  (octocat--run-gh "issue"
                   (list "issue" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "id,number,title,author,state,body,"
                                          "createdAt,closedAt,"
                                          "labels,comments,url,assignees,milestone,reactionGroups,"
                                          "closedByPullRequestsReferences"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))

(octocat-sync-define-resource issue (repo number)
  :entity (octocat-sync-item-key 'issue repo number)
  :invalidates (lambda () `((list-items issues ,repo _ _) (counts issues ,repo)
                            (repo-summary ,repo)))
  :fetch (lambda (done)
           (octocat--fetch-issue
            repo number
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat-sync-detail
                               r '("comments")
                               (lambda (f) (octocat-sync-item 'issue repo f)))))))))

;;;; Rendering
;;
;; The timeline itself (items, entries, rail) is in octocat-timeline.el.

(defun octocat-issue--header (repo issue bg width)
  "Return the vnodes above the timeline: repo, title and labels of ISSUE in REPO.
BG is as for `octocat--label-face'; the title is cut to fit WIDTH."
  (let ((state (or (gethash "state" issue) "OPEN")))
    (append
     (octocat-repo-vui--detail-header
      repo issue (octocat-repo-vui--state-label state)
      #'octocat-issue-edit-title bg width
      (list (cons (octocat-timeline-edit-field "issue" repo issue "assignee")
                  (cons :stack (octocat-repo-vui--login-items (gethash "assignees" issue))))
            (cons (octocat-timeline-edit-field "issue" repo issue "label")
                  (octocat--format-labels (gethash "labels" issue) bg)))
      (list (cons "Milestone" (octocat-repo-vui--milestone issue))
            (cons "Fixed by"  (octocat-repo-vui--numbers
                               repo (gethash "closedByPullRequestsReferences" issue)
                               #'octocat-pr-open)))
      nil '(:comments))
     (list (vui-newline)))))

(vui-defcomponent octocat-issue--page (repo number raw tick)
  "Issue NUMBER of REPO as a timeline; RAW shows markdown bodies verbatim.
A change under way, such as posting a comment, shows under the timeline.
A new TICK fetches everything again."
  :render
  (let* ((width    (octocat-vui-window-width))
         (bg       (octocat--label-background))
         (snap     (octocat-vui-use-detail (list 'issue repo number) tick))
         (timeline (octocat-timeline-use-events repo number tick))
         (issue    (plist-get snap :data))
         (events   (car timeline))
         ;; WIDTH is a dependency: tables are laid out for the window.
         (entries  (vui-use-memo (issue events raw width bg)
                     (and issue
                          (octocat-timeline-entries
                           (octocat-timeline-items issue "opened this issue" events bg)
                           raw (octocat--markdown-width))))))
    (octocat-vui-resource-view
     snap
     :skeleton (lambda (partial)
                 (if partial
                     ;; The list fetched the issue: its header paints at once.
                     (apply #'vui-vstack
                            (append (delq nil (octocat-issue--header repo partial bg
                                                                     (octocat--markdown-width)))
                                    (list (vui-text (octocat-vui-post-skeleton width)))))
                   (vui-text (octocat-vui-detail-skeleton repo number width))))
     :render (lambda (_)
               (apply #'vui-vstack
                      (append
                       (delq nil (octocat-issue--header repo issue bg (octocat--markdown-width)))
                       entries
                       (octocat-timeline-buttons-or-action
                        (list '("+ Add a comment" "RET: write a comment" octocat-issue-add-comment)
                              (if (equal (gethash "state" issue) "OPEN")
                                  '("Close issue" "RET: close this issue" octocat-issue-close)
                                '("Reopen issue" "RET: reopen this issue" octocat-issue-reopen)))
                        (alist-get 'action (plist-get snap :mutating)))))))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-a") #'octocat-issue-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-issue-edit)
    (define-key map (kbd "C-c C-l") #'octocat-issue-react)
    (define-key map (kbd "C-c C-n") #'octocat-issue-new)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-issue-mode'.")

(define-derived-mode octocat-issue-mode vui-mode "Octocat-Issue"
  "Major mode for viewing a GitHub Issue as a timeline.

\\{octocat-issue-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-issue-refresh)
  (setq-local octocat--refresh-fn #'octocat-issue-refresh)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup)
  (setq-local octocat--url-function #'octocat-issue--page-url))


;;;; Refresh

(defun octocat-issue-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue buffer.
The page paints from the sync store at once and fetches fresh data in
the background, in place: what is unfolded stays so."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-vui-refresh-page 'octocat-issue--page
                            (cons octocat--issue-repo octocat--issue-number)
                            (list :repo octocat--issue-repo
                                  :number octocat--issue-number
                                  :raw octocat--markdown-raw)))

(defun octocat-issue-open (repo number)
  "Show issue NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s issue %d*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-issue-mode)
      (octocat-issue-mode))
    (setq octocat--issue-repo   repo
          octocat--issue-number number)
    (octocat-issue-refresh)))



;;;; Issue list page
;;
;; Opened by `M-x octocat-issue-list' (octocat.el); the page is
;; `octocat-vui-search-list'.

(defun octocat-issue-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let ((repo octocat-vui-list--repo)
        (bg   (octocat--label-background)))
    (octocat-vui-refresh-page 'octocat-vui-search-list repo
                              (list :repo repo
                                    :kind 'issues
                                    :query (octocat-vui-list-query)
                                    :compact (octocat-vui-list-compact-p)
                                    :row-fn (lambda (issue width compact no-state)
                                              (octocat-repo-vui--issue-row
                                               repo issue width bg compact no-state))
                                    :line-fn (lambda (issue no-state)
                                               (octocat-repo-vui--issue-compact-line
                                                repo issue bg no-state))))))

(defvar octocat-issue-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-list-mode-map)
    (define-key map (kbd "C-c C-n") #'octocat-issue-new)
    map)
  "Keymap for `octocat-issue-list-mode'.")

(define-derived-mode octocat-issue-list-mode octocat-vui-list-mode "Octocat-Issues"
  "Major mode for the issue list of a repository.

\\{octocat-issue-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "all"))
  (setq-local octocat-vui-list--view "issue-list")
  (setq-local revert-buffer-function #'octocat-issue-list-refresh))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
