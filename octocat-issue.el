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
(require 'octocat-sync)
(require 'octocat-model)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)

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
  "Edit the comment identified in `octocat-edit-user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the issue.
See `octocat-timeline-submit' for ON-SUCCESS."
  (let ((comment-id (plist-get octocat-edit-user-data :comment-id)))
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
  (octocat-edit-open
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
  (let* ((issue (octocat-model-detail-read (list 'issue octocat--issue-repo octocat--issue-number)))
         (body  (and issue (octocat--nonempty (gethash "body" issue)))))
    (octocat-edit-open
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
             (comment-id (octocat-model-comment-numeric-id target))
             (body       (octocat--nonempty (gethash "body" target))))
        (unless authored
          (user-error "Octocat: You can't edit someone else's comment"))
        ;; A comment being posted has no URL yet.
        (octocat-timeline-ensure-idle (list 'issue octocat--issue-repo octocat--issue-number))
        (unless comment-id
          (user-error "Octocat: Could not determine comment ID from URL"))
        (octocat-edit-open
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

(defun octocat-issue--submit-new (text source on-success on-error)
  "Create an issue from TEXT in the repo of `octocat-edit-user-data'.
Open it from SOURCE once GitHub answers; the editor stays open until
then, through ON-SUCCESS or ON-ERROR, as there is no page to show the
issue under way."
  (let ((repo (plist-get octocat-edit-user-data :repo))
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
    (octocat-edit-open
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
           (octocat--item-url
            'issue octocat--issue-repo octocat--issue-number
            (octocat-model-detail-read (list 'issue octocat--issue-repo octocat--issue-number)))))))

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


;;;; Rendering
;;
;; The timeline itself (items, entries, rail) is in octocat-timeline.el.

(defun octocat-issue--header (repo issue bg width)
  "Return the vnodes above the timeline: repo, title and labels of ISSUE in REPO.
BG is as for `octocat--label-face'; the title is cut to fit WIDTH."
  (append
   (octocat-vui--detail-header
    repo issue (octocat-vui--issue-state-label issue)
    #'octocat-issue-edit-title bg width
    (list (cons (octocat-timeline-edit-field "issue" repo issue "assignee")
                (cl-list* :line ", " (octocat-vui--login-items (gethash "assignees" issue))))
          (cons (octocat-timeline-edit-field "issue" repo issue "label")
                (cl-list* :line " " (octocat-vui--label-items (gethash "labels" issue) bg))))
    (list (cons "Milestone" (octocat-vui--milestone issue))
          (cons "Fixed by"  (octocat-vui--numbers
                             repo (gethash "closedByPullRequestsReferences" issue)
                             (apply-partially #'octocat-open 'pr))))
    nil '(:comments))
   (list (vui-newline))))

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
                           raw (octocat--markdown-width)))))
         (shown    (or issue (plist-get snap :partial))))
    (octocat-vui-page
     (if shown
         (octocat-vui-detail-pin shown (octocat-vui--issue-state-label shown) width bg)
       (octocat-vui-number-pin number))
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
                         (alist-get 'action (plist-get snap :mutating))))))))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-a") #'octocat-issue-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-issue-edit)
    (define-key map (kbd "C-c C-l") #'octocat-issue-react)
    (define-key map (kbd "C-c C-n") #'octocat-issue-new)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-issue-mode'.")

(define-derived-mode octocat-issue-mode octocat-page-mode "Octocat-Issue"
  "Major mode for viewing a GitHub Issue as a timeline.

\\{octocat-issue-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-issue-refresh)
  (setq-local octocat--url-function #'octocat-issue--page-url)
  (setq-local octocat--repo-function (lambda () octocat--issue-repo)))


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

(cl-defmethod octocat-open ((_kind (eql 'issue)) repo number)
  "Open issue NUMBER of REPO, as `octocat-issue-open'."
  (octocat-issue-open repo number))

(defun octocat-issue--stored-p (kind repo number)
  "Return non-nil when NUMBER of REPO is stored as a KIND, `pr' or `issue'."
  (let ((snap (octocat-sync-read (list kind repo number))))
    (or (plist-get snap :data) (plist-get snap :partial))))

(cl-defmethod octocat-open ((_kind (eql 'issue-or-pr)) repo number)
  "Open NUMBER of REPO, an issue or a pull request: they share numbers.
As what the store holds it as, else as an issue until GitHub says."
  (cond ((octocat-issue--stored-p 'pr repo number) (octocat-open 'pr repo number))
        ((octocat-issue--stored-p 'issue repo number) (octocat-open 'issue repo number))
        (t (octocat-vui-open-settled
            (list 'issue-kind repo number)
            (lambda (data)
              (list (if (and data (eq (gethash "pr" data) t)) 'pr 'issue) repo number))))))


;;;; Issue list page
;;
;; Opened by `M-x octocat-issue-list' (octocat.el); the page is
;; `octocat-vui-search-list'.

(defun octocat-issue-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  ;; The rows read the label background as drawn, to follow a theme change.
  (let ((repo octocat-vui-list--repo))
    (octocat-vui-refresh-page 'octocat-vui-search-list repo
                              (list :repo repo
                                    :kind 'issues
                                    :query (octocat-vui-list-query)
                                    :compact (octocat-vui-list-compact-p)
                                    :row-fn (lambda (issue width compact no-state _ marked)
                                              (octocat-vui--issue-row
                                               repo issue width (octocat--label-background)
                                               compact no-state marked))
                                    :line-fn (lambda (issue no-state _)
                                               (octocat-vui--issue-compact-line
                                                repo issue (octocat--label-background)
                                                no-state))))))

(defvar octocat-issue-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (make-composed-keymap octocat-vui-list-mark-map
                                                 octocat-vui-list-mode-map))
    (define-key map (kbd "C-c C-n") #'octocat-issue-new)
    map)
  "Keymap for `octocat-issue-list-mode'.")

(define-derived-mode octocat-issue-list-mode octocat-vui-list-mode "Octocat-Issues"
  "Major mode for the issue list of a repository.

\\{octocat-issue-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "all"))
  (setq-local octocat-vui-list--view "issue-list")
  (setq-local octocat-vui-list--web-scope "is:issue")
  (setq-local revert-buffer-function #'octocat-issue-list-refresh))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
