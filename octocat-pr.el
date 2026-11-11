;;; octocat-pr.el --- Pull Request detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; PR data fetching, the PR timeline view, and the octocat-pr-mode major
;; mode.  Like the issue view, the detail view is vui.el-rendered as a
;; GitHub-style timeline (octocat-timeline.el), here with reviews and
;; commits in it and the checks below it.  Depends on octocat-core.el for
;; shared infrastructure; must not depend on octocat.el to avoid a
;; circular require.
;;
;; Its Commits and Files changed tabs are pages of their own, further
;; down.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-actions)
(require 'octocat-diff)
(require 'octocat-sync)
(require 'octocat-model)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)

;; Forward declarations for buffer-locals defined later in this file.
;; Needed so the byte-compiler doesn't warn about free variables in
;; rendering functions that run in `octocat-pr-mode' buffers.
(defvar octocat--pr-repo)
(defvar octocat--pr-number)
(defvar octocat--pr-commits-repo)
(defvar octocat--pr-commits-number)
(defvar octocat--pr-diff-repo)
(defvar octocat--pr-diff-number)

(defun octocat-pr--current ()
  "Return (REPO . NUMBER) of the PR shown by this buffer, or nil.
The buffer is one of its pages: conversation, commits or files changed."
  (cond ((and octocat--pr-repo octocat--pr-number)
         (cons octocat--pr-repo octocat--pr-number))
        ((and octocat--pr-commits-repo octocat--pr-commits-number)
         (cons octocat--pr-commits-repo octocat--pr-commits-number))
        ((and (bound-and-true-p octocat--pr-diff-repo) octocat--pr-diff-number)
         (cons octocat--pr-diff-repo octocat--pr-diff-number))))

(defun octocat-pr--busy (repo number slot)
  "Return the label of a change to PR NUMBER of REPO under way in SLOT, or nil.
SLOT is as for `octocat-sync-define-mutation', such as `merge'."
  (alist-get slot (plist-get (octocat-sync-read (list 'pr repo number)) :mutating)))

;;;; Edit / comment commands — submit helpers

(defun octocat-pr--submit-comment (body source on-success _on-error)
  "Submit BODY as a new comment on the PR in SOURCE buffer.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   (with-current-buffer source `(comment "pr" ,octocat--pr-repo ,octocat--pr-number ,body))
   body source on-success))

(defun octocat-pr--submit-edit-body (body source on-success _on-error)
  "Replace the body of the PR in SOURCE buffer with BODY.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   (with-current-buffer source `(edit-body "pr" ,octocat--pr-repo ,octocat--pr-number ,body))
   body source on-success))

(defun octocat-pr--submit-edit-comment (body source on-success _on-error)
  "Edit the comment identified in `octocat-edit-user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the PR.
See `octocat-timeline-submit' for ON-SUCCESS."
  (let ((comment-id (plist-get octocat-edit-user-data :comment-id)))
    (octocat-timeline-submit
     (with-current-buffer source
       `(edit-comment "pr" ,octocat--pr-repo ,octocat--pr-number ,comment-id ,body))
     body source on-success)))

;;;; Edit / comment commands

(defun octocat-pr-add-comment ()
  "Open an edit buffer to add a comment to the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-ensure-idle (list 'pr octocat--pr-repo octocat--pr-number))
  (octocat-timeline-prepare-comment)
  (octocat-edit-open
   (format "New comment on PR #%d" octocat--pr-number)
   #'octocat-pr--submit-comment
   #'ignore))

(defun octocat-pr-edit-body ()
  "Open an edit buffer to replace the body of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-ensure-idle (list 'pr octocat--pr-repo octocat--pr-number))
  ;; Pre-populate with the current body so the user can edit in place
  ;; rather than retyping everything.
  (let* ((pr   (octocat-model-detail-read (list 'pr octocat--pr-repo octocat--pr-number)))
         (body (and pr (octocat--nonempty (gethash "body" pr)))))
    (octocat-edit-open
     (format "Edit body of PR #%d" octocat--pr-number)
     #'octocat-pr--submit-edit-body
     #'ignore
     body)))

(defun octocat-pr-edit-title ()
  "Prompt in the minibuffer to rename the title of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-rename "pr" octocat--pr-repo octocat--pr-number))

(defun octocat-pr-edit ()
  "Edit the thing at point in the current PR buffer.
On the title: rename the PR.
On the opening post: replace the PR body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error.
On a field such as Labels: pick its values."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let ((target (octocat-timeline-target)))
    (cond
     ((eq target 'title) (octocat-pr-edit-title))
     ((eq target 'body)  (octocat-pr-edit-body))
     ((stringp target)
      (octocat-timeline-edit-values "pr" octocat--pr-repo octocat--pr-number target))
     ((hash-table-p target)
      (let* ((authored   (eq (gethash "viewerDidAuthor" target) t))
             (comment-id (octocat-model-comment-numeric-id target))
             (body       (octocat--nonempty (gethash "body" target))))
        (unless authored
          (user-error "Octocat: You can't edit someone else's comment"))
        ;; A comment being posted has no URL yet.
        (octocat-timeline-ensure-idle (list 'pr octocat--pr-repo octocat--pr-number))
        (unless comment-id
          (user-error "Octocat: Could not determine comment ID from URL"))
        (octocat-edit-open
         (format "Edit comment on PR #%d" octocat--pr-number)
         #'octocat-pr--submit-edit-comment
         #'ignore
         body
         (list :comment-id comment-id))))
     (t
      (user-error "Octocat: Nothing to edit here")))))

(defun octocat-pr-react ()
  "Pick a reaction to toggle on the PR or comment at point."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-react "pr" octocat--pr-repo octocat--pr-number))

(defun octocat-pr--page-url ()
  "Return the URL of the comment at point, or else of the whole PR."
  (let* ((target (octocat-timeline-target))
         (url    (and (hash-table-p target) (gethash "url" target))))
    (cond ((stringp url) url)
          ((and octocat--pr-repo octocat--pr-number)
           (octocat--item-url
            'pr octocat--pr-repo octocat--pr-number
            (octocat-model-detail-read (list 'pr octocat--pr-repo octocat--pr-number)))))))

(defun octocat-pr--change-state (verb)
  "Close or reopen (VERB) the current PR, after asking."
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-state-change "pr" verb octocat--pr-repo
                                 octocat--pr-number))

(defun octocat-pr-close ()
  "Close the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "close"))

(defun octocat-pr-reopen ()
  "Reopen the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "reopen"))


;;;; Merge

(defconst octocat-pr--merge-labels
  '((merge . "Merge") (squash . "Squash") (rebase . "Rebase"))
  "The label of each of `octocat-model-pr-merge-methods'.")

(defun octocat-pr--merge-initial-method (methods last)
  "Return the merge dialog's initial method, one of METHODS or nil.
LAST is the method last used in the repo; it is kept only while the
repo still allows it.  Otherwise, with several METHODS none is picked,
so a merge is never the accidental choice."
  (cond ((null (cdr methods)) (car methods))
        ((member last methods) last)))

(defun octocat-pr--merge-message (method pr)
  "Return GitHub's default commit message for a METHOD merge of PR.
The first line is the subject; a rebase keeps the commits, so has none."
  (let ((number (gethash "number" pr))
        (title  (or (gethash "title" pr) "")))
    (pcase method
      ('merge
       (format "Merge pull request #%d from %s/%s\n\n%s" number
               (or (octocat--get pr "headRepositoryOwner" "login") "")
               (or (gethash "headRefName" pr) "")
               title))
      ('squash
       (concat (format "%s (#%d)" title number)
               (let ((commits (append (octocat--get pr "commits") nil)))
                 (and commits
                      (concat "\n\n"
                              (mapconcat (lambda (c)
                                           (concat "* " (or (gethash "messageHeadline" c) "")))
                                         commits "\n"))))))
      (_ ""))))

(defun octocat-pr--check-counts (rollup)
  "Return the outcome tally of ROLLUP: (FAILING PENDING SKIPPED SUCCESSFUL).
ROLLUP is a `statusCheckRollup' vector; outcomes are as in
`octocat--checks-ci-status'."
  (let ((counts (list 0 0 0 0)))
    (seq-doseq (c rollup)
      (let ((outcome (upcase (or (octocat--nonempty (gethash "conclusion" c))
                                 (octocat--nonempty (gethash "state" c))
                                 "PENDING"))))
        (cl-incf (nth (cond ((member outcome '("SUCCESS" "NEUTRAL")) 3)
                            ((equal outcome "SKIPPED") 2)
                            ((member outcome '("PENDING" "EXPECTED" "QUEUED"
                                               "IN_PROGRESS" "WAITING"))
                             1)
                            (t 0))
                      counts))))
    counts))

(defun octocat-pr--merge-icon (kind)
  "Return the merge box icon of KIND: `ok', `fail' or `wait'."
  (pcase kind
    ('ok   (propertize "✓" 'face 'octocat-ci-success))
    ('fail (propertize "✗" 'face 'octocat-ci-failure))
    (_     (propertize "●" 'face 'octocat-ci-pending))))

(defun octocat-pr--merge-rows (pr &optional awaiting)
  "Return the status rows of PR's merge box, as GitHub words them.
Each is (KIND TITLE SUBTITLE BELOW), KIND as for `octocat-pr--merge-icon'
and SUBTITLE nil or a line under TITLE; BELOW is `checks' on the row of
the checks, listed under it, and `approval' on that of the AWAITING
workflow runs, with the button approving them under it."
  (let* ((checks  (or (octocat--get pr "statusCheckRollup") []))
         (counts  (octocat-pr--check-counts checks))
         (approvals (seq-count (lambda (r) (equal (gethash "state" r) "APPROVED"))
                               (or (octocat--get pr "latestReviews") []))))
    (delq nil
          (list
           (pcase (octocat--get pr "reviewDecision")
             ("APPROVED"
              (list 'ok "Changes approved"
                    (format "%d approving review%s" approvals (if (= approvals 1) "" "s"))))
             ("CHANGES_REQUESTED"
              (list 'fail "Changes requested"
                    "Changes must be addressed before merging."))
             ("REVIEW_REQUIRED"
              (list 'fail "Review required"
                    "At least 1 approving review is required by reviewers with write access.")))
           (unless (zerop (length checks))
             (list (cond ((> (nth 0 counts) 0) 'fail) ((> (nth 1 counts) 0) 'wait) (t 'ok))
                   (cond ((> (nth 0 counts) 0) "Some checks were not successful")
                         ((> (nth 1 counts) 0) "Some checks haven't completed yet")
                         (t "All checks have passed"))
                   (concat (string-join
                            (delq nil (cl-mapcar (lambda (n label)
                                                   (and (> n 0) (format "%d %s" n label)))
                                                 counts
                                                 '("failing" "in progress" "skipped" "successful")))
                            ", ")
                           (if (= (length checks) 1) " check" " checks"))
                   'checks))
           (and awaiting
                (list 'wait
                      (if (cdr awaiting)
                          (format "%d workflows awaiting approval" (length awaiting))
                        "1 workflow awaiting approval")
                      (if (cdr awaiting)
                          "These workflows require approval from a maintainer."
                        "This workflow requires approval from a maintainer.")
                      'approval))
           (cond
            ((octocat-pr--conflicts-p pr)
             (list 'fail "This branch has conflicts that must be resolved"
                   "Use the web editor or the command line to resolve conflicts."))
            ((equal (octocat--get pr "mergeStateStatus") "BEHIND")
             (list 'wait "This branch is out-of-date with the base branch"
                   (format "Merge the latest changes from %s into this branch."
                           (or (gethash "baseRefName" pr) "the base branch"))))
            ((equal (octocat--get pr "mergeable") "MERGEABLE")
             (list 'ok "No conflicts with base branch"
                   (and (not (eq (gethash "isDraft" pr) t))
                        (not (octocat-pr--blocked-p pr))
                        "Merging can be performed automatically.")))
            (t (list 'wait "Checking for the ability to merge automatically…")))
           ;; Blocked by reviews or branch protection, not by conflicts.
           (and (octocat-pr--blocked-p pr)
                (not (octocat-pr--conflicts-p pr))
                (list 'fail "Merging is blocked"))))))

(defun octocat-pr--blocked-p (pr)
  "Return non-nil when PR's merge is blocked, as by a required review."
  (equal (octocat--get pr "mergeStateStatus") "BLOCKED"))

(defun octocat-pr--conflicts-p (pr)
  "Return non-nil when PR conflicts with its base branch."
  (or (equal (octocat--get pr "mergeable") "CONFLICTING")
      (equal (octocat--get pr "mergeStateStatus") "DIRTY")))

(defun octocat-pr--merge-refusal (pr)
  "Return why PR cannot be merged at all, or nil.
A blocked merge is not refused: it may pass with admin rights."
  (cond ((eq (gethash "isDraft" pr) t) "Draft pull requests cannot be merged.")
        ((octocat-pr--conflicts-p pr) "This branch has conflicts that must be resolved")))

(defun octocat-pr--merge-section (pr width on-visit-check merging &optional awaiting approving)
  "Return the vnodes of the merge box of open PR, or nil.
Like GitHub's, it holds the review, checks and conflict status, then
the merge (or, for a draft, the ready for review) button.  Its heading
is underlined across WIDTH columns, setting it apart from the timeline.
ON-VISIT-CHECK is called by RET on a check.  MERGING, a label such as
\"Merging pull request…\", shows a change under way in place of the
buttons.  AWAITING are the workflow runs awaiting approval, under the
checks with a button approving them; APPROVING, a label, shows that
under way in its place."
  (when (equal (gethash "state" pr) "OPEN")
    (let* ((draft  (eq (gethash "isDraft" pr) t))
           (checks (or (octocat--get pr "statusCheckRollup") []))
           (rows   (octocat-pr--merge-rows pr awaiting))
           (first  (car rows)))
      (append
       (list (octocat-vui-section-heading "Merge" width))
       (mapcan (lambda (row)
                 (pcase-let ((`(,kind ,title ,subtitle ,below) row))
                   (append
                    ;; A blank line between rows, else they run together.
                    (and (not (eq row first)) (list (vui-newline)))
                    (delq nil
                          (list (vui-text (concat "  " (octocat-pr--merge-icon kind) " " title))
                                (and subtitle
                                     (vui-text (concat "    " subtitle) :face 'octocat-dimmed))
                                (and (eq below 'checks)
                                     (octocat-checks-rows checks on-visit-check "    "))))
                    (and (eq below 'approval)
                         (octocat-pr--approval-row awaiting approving)))))
               rows)
       (list (vui-newline))
       (cond
        (merging
         (list (vui-text (concat "  " (octocat-spinner) " " merging)
                 :face 'bold)))
        (draft
         (append
          (list (vui-text "  This pull request is still a work in progress" :face 'bold))
          (octocat-timeline-buttons
           '(("Ready for review" "RET: mark this pull request ready for review"
              octocat-pr-ready "Draft pull requests cannot be merged."))
           'tight)))
        (t
         (octocat-timeline-buttons
          (list (and (not (octocat-pr--conflicts-p pr))
                     '("Merge pull request" "RET: merge this pull request"
                       octocat-pr-merge))
                '("Convert to draft" "RET: convert this pull request to a draft"
                  octocat-pr-convert-to-draft "Still in progress?"))
          'tight)))))))

(defun octocat-pr--approval-row (awaiting approving)
  "Return the indented button approving each workflow run in AWAITING.
APPROVING, a label or nil, shows the approval under way instead."
  (if approving
      (list (vui-text (concat "    " (octocat-spinner) " " approving) :face 'bold))
    ;; Indented a further two, under its row's title.
    (list (vui-hstack
           :spacing 0
           (vui-text "  ")
           (car (octocat-timeline-buttons
                 (list (list "Approve workflows to run"
                             "RET: let these workflow runs from an outside contributor start"
                             (let ((ids (mapcar (lambda (run) (gethash "id" run)) awaiting)))
                               (lambda () (octocat-pr-approve-workflows ids)))))
                 'tight))))))

(defun octocat-pr--merge-data (method methods defaults delete &optional delete-picked)
  "Return the merge dialog's user data for METHOD, one of METHODS or nil.
DEFAULTS is an alist of each method's default message; DELETE whether
to delete the head branch, DELETE-PICKED whether the user chose it."
  (list :method method :methods methods :defaults defaults :delete delete
        :delete-picked delete-picked :allow-empty (memq method '(nil rebase))))

(defun octocat-pr--merge-with-options (data options)
  "Return the merge dialog's user DATA updated for the repo's OPTIONS.
OPTIONS is the data of `merge-options'.  A method the repo does not
allow is unpicked, as `octocat-pr--merge-initial-method' picks; the
branch is deleted as the repo's setting says, unless the user chose."
  (let ((methods (octocat-model-pr-merge-allowed options)))
    (octocat-pr--merge-data
     (octocat-pr--merge-initial-method methods (plist-get data :method))
     methods (plist-get data :defaults)
     (if (plist-get data :delete-picked)
         (plist-get data :delete)
       (eq (gethash "deleteBranchOnMerge" options) t))
     (plist-get data :delete-picked))))

(defun octocat-pr--merge-header (title data)
  "Return the merge dialog's two header lines for TITLE with user DATA.
The first shows the choices, the second their keys: one line overflows
a narrow window."
  (let ((method (plist-get data :method))
        (key    (lambda (k) (propertize k 'face 'help-key-binding))))
    (list
     (concat "  " title "    "
             (mapconcat (lambda (m)
                          (let ((label (alist-get m octocat-pr--merge-labels)))
                            (if (eq m method)
                                (propertize (format "(•) %s" label) 'face 'bold)
                              (propertize (format "( ) %s" label) 'face 'octocat-dimmed))))
                        (plist-get data :methods) "  ")
             "    "
             (if (plist-get data :delete)
                 (propertize "[x] Delete branch" 'face 'bold)
               (propertize "[ ] Delete branch" 'face 'octocat-dimmed))
             (pcase method
               ('nil (propertize "    (pick a method)" 'face 'warning))
               ('rebase (propertize "    (message unused)" 'face 'octocat-dimmed))))
     (concat "  "
             (funcall key "C-c C-t") " method   "
             (funcall key "C-c C-d") " delete branch   "
             (funcall key "C-c C-c") " merge   "
             (funcall key "C-c C-k") " cancel"))))

(defun octocat-pr--merge-update (data)
  "Store DATA as the merge dialog's user data and redraw its header."
  (setq octocat-edit-user-data data)
  (let ((lines (octocat-pr--merge-header octocat-edit-title data)))
    ;; The tab line sits above the header line, giving a second line.
    (setq tab-line-format    (car lines)
          header-line-format (cadr lines)))
  (force-mode-line-update))

(defun octocat-pr--submit-merge (text source on-success on-error)
  "Merge the PR in SOURCE buffer with commit message TEXT.
The method and branch deletion are read from the edit buffer's user
data.  The dialog closes at once, through ON-SUCCESS, and the PR's pages
show the merge under way until it ends, so a slow GitHub does not
block; ON-ERROR is called only for a missing method."
  (let ((method (plist-get octocat-edit-user-data :method))
        (delete (plist-get octocat-edit-user-data :delete)))
    (if (not method)
        (funcall on-error (substitute-command-keys
                           "Pick a merge method with \\[octocat-pr-merge-cycle]"))
      (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
        (octocat--setting-put (list 'merge-method repo) method)
        (octocat-sync-submit `(merge-pr ,repo ,number ,method ,text ,delete)
                             (lambda (result)
                               (unless (eq (car-safe result) 'error)
                                 (message "Octocat: Merged PR #%d" number)))))
      (funcall on-success))))

(defun octocat-pr--merge-switch (data)
  "Switch the merge dialog to its user DATA.
An unedited default message is replaced by the new method's."
  (let* ((defaults (plist-get data :defaults))
         (method   (plist-get octocat-edit-user-data :method))
         (next     (plist-get data :method)))
    (when (and (not (eq method next))
               (equal (string-trim (buffer-string))
                      (string-trim (or (cdr (assoc method defaults)) ""))))
      (erase-buffer)
      (insert (or (cdr (assoc next defaults)) ""))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (octocat-pr--merge-update data)))

(defun octocat-pr-merge-cycle ()
  "Switch the merge dialog to the next allowed method.
An unedited default message is replaced by the next method's."
  (interactive)
  (let* ((data    octocat-edit-user-data)
         (methods (plist-get data :methods))
         (next    (or (cadr (member (plist-get data :method) methods)) (car methods))))
    (octocat-pr--merge-switch
     (octocat-pr--merge-data next methods (plist-get data :defaults)
                             (plist-get data :delete) (plist-get data :delete-picked)))))

(defun octocat-pr-merge-toggle-delete ()
  "Toggle whether the merge dialog deletes the head branch."
  (interactive)
  (let ((data octocat-edit-user-data))
    (octocat-pr--merge-update
     (plist-put (plist-put (copy-sequence data) :delete (not (plist-get data :delete)))
                :delete-picked t))))

(defvar octocat-pr-merge-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'octocat-pr-merge-cycle)
    (define-key map (kbd "C-c C-d") #'octocat-pr-merge-toggle-delete)
    map)
  "Keymap for `octocat-pr-merge-mode'.")

;; A minor mode so the dialog keys live only in merge dialogs.
(define-minor-mode octocat-pr-merge-mode
  "Pick the method of a PR merge in its edit buffer."
  :keymap octocat-pr-merge-mode-map)

(defun octocat-pr--open-merge-dialog (repo pr methods delete)
  "Open the dialog merging PR (a hash-table) of REPO by one of METHODS.
DELETE is the initial choice to delete the head branch.  The method
starts as in `octocat-pr--merge-initial-method'.  Return its buffer."
  (let* ((title    (format "Merge PR #%d" (gethash "number" pr)))
         (defaults (mapcar (lambda (m) (cons m (octocat-pr--merge-message m pr)))
                           methods))
         (method   (octocat-pr--merge-initial-method
                    methods (octocat--setting (list 'merge-method repo))))
         (data     (octocat-pr--merge-data method methods defaults delete))
         (win      (octocat-edit-open
                    title #'octocat-pr--submit-merge
                    #'ignore
                    (cdr (assoc method defaults)) data)))
    (with-current-buffer (window-buffer win)
      (goto-char (point-min))
      ;; Draw the tab line used as a second header line like the header
      ;; line; themes style it for tabs, some hiding its text.
      (face-remap-set-base 'tab-line 'header-line)
      (octocat-pr-merge-mode 1)
      (octocat-pr--merge-update octocat-edit-user-data)
      (current-buffer))))

(defun octocat-pr-merge ()
  "Open the dialog to merge the current PR, from any of its pages.
Edit the commit message and pick the method with
\\<octocat-pr-merge-mode-map>\\[octocat-pr-merge-cycle]; submitting the dialog
is the confirmation."
  (interactive)
  (pcase-let* ((`(,repo . ,number)
                (or (octocat-pr--current)
                    (user-error "Octocat: Buffer is not associated with a pull request")))
               (pr      (octocat-model-detail-read (list 'pr repo number)))
               (refusal (and pr (octocat-pr--merge-refusal pr))))
    (cond
     ((not pr) (user-error "Octocat: PR not loaded yet"))
     ((octocat-pr--busy repo number 'merge)
      (user-error "Octocat: Wait for \"%s\" to finish" (octocat-pr--busy repo number 'merge)))
     ((not (equal (gethash "state" pr) "OPEN"))
      (user-error "Octocat: PR #%d is not open" number))
     (refusal (user-error "Octocat: %s" refusal)))
    (let* ((spec    (list 'merge-options repo))
           (options (plist-get (octocat-sync-read spec) :data))
           (methods (if options
                        (or (octocat-model-pr-merge-allowed options)
                            (user-error "Octocat: The repo allows no merge method"))
                      ;; Until the repo's options land, offer every method.
                      (mapcar #'car octocat-model-pr-merge-methods)))
           (dialog  (octocat-pr--open-merge-dialog
                     repo pr methods
                     (and options (eq (gethash "deleteBranchOnMerge" options) t)))))
      (octocat-sync-get
       spec
       (lambda (result)
         (when (and (hash-table-p result) (buffer-live-p dialog)
                    (buffer-local-value 'octocat-pr-merge-mode dialog))
           (with-current-buffer dialog
             (octocat-pr--merge-switch
              (octocat-pr--merge-with-options octocat-edit-user-data result)))))))))

(defun octocat-pr-approve-workflows (ids)
  "Approve the current PR's workflow run of each of IDS to let it start.
GitHub holds the runs of a PR from an outside contributor until a
maintainer approves them."
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (when-let* ((label (octocat-pr--busy octocat--pr-repo octocat--pr-number 'approve)))
    (user-error "Octocat: Wait for \"%s\" to finish" label))
  (octocat-sync-submit `(approve-runs ,octocat--pr-repo ,octocat--pr-number ,ids)
                       (lambda (result)
                         (unless (eq (car-safe result) 'error)
                           (message "Octocat: Workflows approved")))))

(defun octocat-pr--set-draft (draft)
  "Mark the current PR a draft if DRAFT, else ready for review."
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (when-let* ((label (octocat-pr--busy octocat--pr-repo octocat--pr-number 'merge)))
    (user-error "Octocat: Wait for \"%s\" to finish" label))
  (octocat-sync-submit `(set-draft ,octocat--pr-repo ,octocat--pr-number ,draft)))

(defun octocat-pr-ready ()
  "Mark the current draft PR ready for review."
  (interactive)
  (octocat-pr--set-draft nil))

(defun octocat-pr-convert-to-draft ()
  "Convert the current PR to a draft, after asking, as GitHub does."
  (interactive)
  (when (y-or-n-p (format "Convert PR #%d to draft? " octocat--pr-number))
    (octocat-pr--set-draft t)))


;;;; Rendering

(defun octocat-pr--use-awaiting-runs (repo sha tick)
  "Return each workflow run of commit SHA in REPO awaiting approval.
Nil until they are fetched, when SHA is nil, or when they cannot be,
as for a repo without Actions.  A new TICK fetches them again.  Must be
called during render, like any hook."
  (append (plist-get (octocat-vui-use-resource (list 'awaiting-runs repo sha) tick) :data)
          nil))

;; A stack (see https://github.com/github/gh-stack) chains PRs, each
;; based on the one below it.  `gh pr view' does not give it, so it is
;; fetched on its own; a GitHub without stacks answers with an error,
;; and the page shows none.

(defun octocat-pr--use-stack (repo number tick)
  "Return the stack pull request NUMBER of REPO is in, a hash-table, or nil.
Nil too until it is fetched, or when it cannot be.  A new TICK fetches
it again.  Must be called during render, like any hook."
  (octocat--get (plist-get (octocat-vui-use-resource (list 'pr-stack repo number) tick)
                           :data)
                "stack"))

(defun octocat-pr--stack-entries (stack)
  "Return the pull requests of STACK, top first as `gh stack view' lists them.
Each is the hash-table of one, with its \"position\" in STACK, 1 at the
bottom."
  (sort (delq nil (mapcar (lambda (e)
                            (when-let* ((pr (octocat--get e "pullRequest")))
                              (puthash "position" (gethash "position" e) pr)
                              pr))
                          (octocat--get stack "entries" "nodes")))
        (lambda (a b) (> (gethash "position" a) (gethash "position" b)))))

(defun octocat-pr--stack-label (stack number)
  "Return where pull request NUMBER sits in STACK, as \"≡ 2/3\", or nil.
1 is the bottom, as on GitHub."
  (let* ((prs  (octocat-pr--stack-entries stack))
         (here (seq-find (lambda (pr) (eql (gethash "number" pr) number)) prs)))
    (and here (format "≡ %d/%d" (gethash "position" here) (length prs)))))

(defun octocat-pr--stack-choices (stack number)
  "Return the pull requests of STACK to pick from, an alist, top first.
Each is (\"2/3 #N TITLE\" . N); NUMBER's own is marked \"(this)\"."
  (let ((size (length (octocat-pr--stack-entries stack))))
    (mapcar (lambda (pr)
              (let ((n (gethash "number" pr)))
                (cons (format "%d/%d #%d %s%s" (gethash "position" pr) size n
                              (or (octocat--nonempty (gethash "title" pr)) "")
                              (if (eql n number) " (this)" ""))
                      n)))
            (octocat-pr--stack-entries stack))))

(defun octocat-pr--stack-badge (repo stack number)
  "Return the header badge of pull request NUMBER of REPO in STACK, or nil.
As for `octocat-vui--detail-header': where NUMBER sits in STACK,
on which RET reads another pull request of it, in its order, and opens
it."
  (when-let* ((label (octocat-pr--stack-label stack number)))
    (list label
          (format "RET: open a pull request of stack #%d" (gethash "number" stack))
          (lambda ()
            (let* ((choices (octocat-pr--stack-choices stack number))
                   (table   (lambda (string pred action)
                              (if (eq action 'metadata)
                                  '(metadata (display-sort-function . identity)
                                             (cycle-sort-function . identity))
                                (complete-with-action action choices string pred))))
                   (choice  (completing-read
                             (format "Stack #%d, open: " (gethash "number" stack))
                             table nil t)))
              (octocat-pr-open repo (cdr (assoc choice choices))))))))

;; The PR list marks each PR's place in its stack.  One call gets the
;; stacks of a repo; its search query is left without them, so a GitHub
;; without stacks still lists its PRs.

(defun octocat-pr--stacks-index (stacks)
  "Return a hash-table from each PR number in STACKS to its \"≡ 2/3\".
STACKS is a vector of stacks, as the REST API gives them, whose pull
requests are listed bottom first."
  (let ((index (make-hash-table)))
    (seq-doseq (stack stacks)
      (let ((prs (octocat--get stack "pull_requests")))
        (seq-do-indexed (lambda (pr i)
                          (puthash (gethash "number" pr)
                                   (format "≡ %d/%d" (1+ i) (length prs))
                                   index))
                        prs)))
    index))

(defun octocat-pr--use-repo-stacks (repo tick)
  "Return the PR numbers of REPO in a stack, by `octocat-pr--stacks-index'.
Nil until they are fetched, or when they cannot be, as where stacks are
off.  A new TICK fetches them again.  Must be called during render, like
any hook."
  (let ((stacks (octocat--get (plist-get (octocat-vui-use-resource
                                          (list 'repo-stacks repo) tick)
                                         :data)
                              "stacks")))
    (vui-use-memo (stacks) (and stacks (octocat-pr--stacks-index stacks)))))

(defun octocat-pr--stacks-label (index number)
  "Return where pull request NUMBER sits in its stack, by INDEX, or nil.
INDEX is from `octocat-pr--use-repo-stacks'."
  (and index (gethash number index)))

(defun octocat-pr--stack-merging (stack number)
  "Return the pull requests of STACK merged by merging NUMBER, bottom first.
A stacked pull request merges with those under it not merged yet; nil
when NUMBER is not in STACK."
  (let* ((prs  (octocat-pr--stack-entries stack))
         (here (seq-find (lambda (pr) (eql (gethash "number" pr) number)) prs)))
    (and here
         (reverse (seq-filter (lambda (pr)
                                (and (<= (gethash "position" pr) (gethash "position" here))
                                     (not (equal (gethash "state" pr) "MERGED"))))
                              prs)))))

(defun octocat-pr--stack-blocker (pr)
  "Return why PR, of a stack, stops the stack merging, or nil."
  (cond ((equal (gethash "state" pr) "CLOSED") "is closed")
        ((eq (gethash "isDraft" pr) t) "is a draft")
        ((equal (gethash "mergeable" pr) "CONFLICTING") "has conflicts")))

(defun octocat-pr--stack-merge-row (number stack)
  "Return the merge box row of STACK for its pull request NUMBER, or nil.
As for `octocat-pr--merge-rows'.  Any of the pull requests merged with
NUMBER (see `octocat-pr--stack-merging') a draft, closed or conflicting
stops it; their rows say why.  Nil when NUMBER is not in STACK."
  (when-let* ((with (octocat-pr--stack-merging stack number)))
    (if (seq-some #'octocat-pr--stack-blocker with)
        (list 'fail "Unable to merge as stack" nil)
      (let ((into (or (octocat--get stack "baseRefName") "the base branch")))
        (list 'ok "Ready to merge as stack"
              (if (cdr with)
                  (format "Merging this merges %s into %s."
                          (string-join (mapcar (lambda (pr) (format "#%d" (gethash "number" pr)))
                                               with)
                                       ", ")
                          into)
                ;; Its section's heading already names INTO.
                nil))))))

(defun octocat-pr--stack-section (repo pr stack width)
  "Return the vnodes of STACK, which PR of REPO is in, or nil when it is empty.
A section of its own, its heading underlined across WIDTH.  An open
PR's heading ends saying whether the stack can merge up to PR, and each
pull request that stops it says why after its title.  The pull requests
are listed top first, each opening its page but PR's own, in bold;
their titles are cut to fit WIDTH."
  (when-let* ((prs (octocat-pr--stack-entries stack)))
    (let* ((number (gethash "number" pr))
           (row    (and (equal (gethash "state" pr) "OPEN")
                        (octocat-pr--stack-merge-row number stack)))
           (with   (and row (octocat-pr--stack-merging stack number))))
      (append
       (pcase-let ((`(,kind ,title ,subtitle) row))
         (delq nil
               (list (octocat-vui-section-heading
                      (format "≡ Stack #%d" (gethash "number" stack)) width
                      (vui-text (concat (propertize "into " 'face 'octocat-dimmed)
                                        (propertize (or (octocat--get stack "baseRefName") "")
                                                    'face 'octocat-branch)))
                      ;; The verdict; the rows below say what stops it.
                      (and row (vui-text (concat (octocat-pr--merge-icon kind) " " title))))
                     (and subtitle
                          (vui-text (concat "  " subtitle) :face 'octocat-dimmed)))))
       (mapcar
        (lambda (p)
          (let* ((n     (gethash "number" p))
                 ;; A draft says so, as in a compact list.
                 (state (if (eq (gethash "isDraft" p) t) "(draft) " ""))
                 (head  (concat "  "
                                (propertize (format "#%d  " n) 'face 'octocat-pr-number)
                                (propertize state 'face 'octocat-dimmed)))
                 (why   (and (memq p with) (octocat-pr--stack-blocker p)))
                 ;; After the title, which gives way to it.
                 (tail  (if why
                            (concat "  " (octocat-pr--merge-icon 'fail) " "
                                    (propertize why 'face 'octocat-ci-failure))
                          ""))
                 (title (octocat-vui--fit-title
                         (or (octocat--nonempty (gethash "title" p)) "")
                         (- width (string-width head) (string-width tail)))))
            (if (eql n number)
                (vui-text (concat head (propertize title 'face 'bold) tail))
              (octocat-vui-row (concat head title tail)
                               (lambda () (octocat-pr-open repo n))
                               (format "RET: open pull request #%d" n)))))
        prs)))))

(defun octocat-pr--commit-items (repo pr)
  "Return a timeline item for each commit of PR (a hash-table) in REPO.
Each is a RET-able line opening the commit; the newest commit also shows
the CI status."
  (let* ((commits  (or (octocat--get pr "commits") []))
         (head-oid (and (> (length commits) 0)
                        (gethash "oid" (aref commits (1- (length commits)))))))
    (mapcar
     (lambda (commit)
       (let* ((oid     (or (gethash "oid" commit) ""))
              (writers (octocat--get commit "authors"))
              (login   (and writers (> (length writers) 0)
                            (octocat--get (aref writers 0) "login"))))
         (list :time (or (gethash "committedDate" commit) "")
               :kind 'commit
               :actor (if login (concat "@" login) "")
               :text (concat "committed "
                             (propertize (substring oid 0 (min 7 (length oid)))
                                         'face 'octocat-commit-sha)
                             " " (or (gethash "messageHeadline" commit) ""))
               :suffix (and (equal oid head-oid) (concat "  " (octocat--ci-label pr)))
               :on-visit (lambda () (octocat-commit-open repo oid))
               :help "RET: view commit")))
     commits)))

(defun octocat-pr--review-items (pr)
  "Return a timeline item for each review of PR (a hash-table)."
  (mapcar
   (lambda (review)
     (let ((state (or (gethash "state" review) "")))
       (list :time (or (octocat--get review "submittedAt") "")
             :kind 'review
             :actor (octocat--author-login review)
             :verb (pcase state
                     ("APPROVED"          "approved these changes")
                     ("CHANGES_REQUESTED" "requested changes")
                     ("DISMISSED"         "had a review dismissed")
                     (_                   "reviewed"))
             :body (or (octocat--get review "body") "")
             :state (downcase state)
             :reactions (octocat--reactions-string review))))
   (or (octocat--get pr "reviews") [])))

(defun octocat-pr--items (repo pr events bg)
  "Return the timeline items of PR in REPO, with its EVENTS (or nil).
BG is as for `octocat--label-face'."
  (octocat-timeline-items pr "opened this pull request" events bg
                          (append (octocat-pr--review-items pr)
                                  (octocat-pr--commit-items repo pr))))

(defun octocat-pr--head-sha (pr)
  "Return the SHA of the newest commit of PR (a hash-table), or nil."
  (let ((commits (octocat--get pr "commits")))
    (and commits (> (length commits) 0)
         (gethash "oid" (aref commits (1- (length commits)))))))

(defun octocat-pr--rest-commit (commit)
  "Return COMMIT of `gh pr view' shaped as the REST commits endpoint has it.
That is what `octocat-vui--commit-row' reads."
  (let* ((writers (octocat--get commit "authors"))
         (writer  (and writers (> (length writers) 0) (aref writers 0)))
         (login   (and writer (octocat--nonempty (octocat--get writer "login"))))
         (c       (make-hash-table :test #'equal))
         (ca      (make-hash-table :test #'equal))
         (cc      (make-hash-table :test #'equal))
         (rest    (make-hash-table :test #'equal)))
    (puthash "name" (or (and writer (octocat--get writer "name")) "") ca)
    (puthash "date" (or (octocat--get commit "authoredDate") "") ca)
    (puthash "date" (or (octocat--get commit "committedDate") "") cc)
    (puthash "message" (or (octocat--get commit "messageHeadline") "") c)
    (puthash "author" ca c)
    (puthash "committer" cc c)
    (puthash "sha" (or (octocat--get commit "oid") "") rest)
    (puthash "commit" c rest)
    (puthash "author" (if login
                          (let ((u (make-hash-table :test #'equal)))
                            (puthash "login" login u)
                            u)
                        :null)
             rest)
    rest))

(defun octocat-pr--commits (pr)
  "Return the commits of PR, oldest first, shaped by `octocat-pr--rest-commit'."
  (mapcar #'octocat-pr--rest-commit (or (octocat--get pr "commits") [])))

(defconst octocat-pr--tab-labels '("Conversation" "Commits" "Files changed")
  "The labels of a PR page's tabs (see `octocat-pr--tabs'), for its skeleton.")

(defun octocat-pr--tabs (current repo number width &optional files commits)
  "Return the \"Conversation | Commits | Files changed\" tab strip of a PR.
CURRENT is `conversation', `commits' or `files', the tab shown by this
buffer; the others open that page of pull request NUMBER of REPO.
FILES and COMMITS, when non-nil, are the counts shown on their tabs, as
GitHub does.  See `octocat-vui-tab-row' for WIDTH."
  (octocat-vui-tab-row
   (list (list "Conversation" "RET: show the conversation"
               (unless (eq current 'conversation)
                 (lambda () (octocat-pr-open repo number))))
         (list (if commits (format "Commits (%d)" commits) "Commits")
               "RET: show the commits"
               (unless (eq current 'commits)
                 (lambda () (octocat-pr-commits-open repo number))))
         (list (if files (format "Files changed (%d)" files) "Files changed")
               "RET: show the files changed"
               (unless (eq current 'files)
                 (lambda () (octocat-pr-diff-open repo number)))))
   width))

(defun octocat-pr--pin (number snap width bg)
  "Return the pin of a page of PR NUMBER, SNAP its data's snapshot.
WIDTH and BG are as for `octocat-vui-detail-pin'.  See `octocat-vui-page'."
  (if-let* ((pr (or (plist-get snap :data) (plist-get snap :partial))))
      (octocat-vui-detail-pin pr (octocat-vui--state-label (or (gethash "state" pr) "OPEN")
                                                           (gethash "isDraft" pr))
                              width bg)
    (octocat-vui-number-pin number)))

(defun octocat-pr--header (repo pr bg width &optional tab stack)
  "Return the vnodes above the body: repo, title, branches, labels, tabs.
PR is the hash-table of the pull request in REPO.  BG is as for
`octocat--label-face'.  WIDTH is that of the title and the tabs, see
`octocat-pr--tabs'.
TAB is the page showing it, `conversation' (the default), `commits' or
`files'.  STACK, when non-nil, is the stack PR is in, from
`octocat-pr--use-stack': where PR sits in it ends the first line, see
`octocat-pr--stack-badge'."
  (let* ((number   (gethash "number" pr))
         (state    (or (gethash "state" pr) "OPEN"))
         (head    (or (gethash "headRefName" pr) ""))
         (base     (or (gethash "baseRefName" pr) ""))
         (local    (octocat--current-branch))
         (reviewers (octocat-pr--reviewers pr)))
    (append
     (octocat-vui--detail-header
      repo pr
      (octocat-vui--state-label state (gethash "isDraft" pr))
      (lambda () (octocat-timeline-rename "pr" repo number))
      bg width
      ;; Several assignees, reviewers or labels go on a line of their own.
      (list (cons (octocat-timeline-edit-field "pr" repo pr "assignee")
                  (cl-list* :line ", " (octocat-vui--login-items (gethash "assignees" pr))))
            (cons (octocat-timeline-edit-field "pr" repo pr "reviewer")
                  (cl-list* :line ", " reviewers))
            (cons (octocat-timeline-edit-field "pr" repo pr "label")
                  (cl-list* :line " " (octocat-vui--label-items (gethash "labels" pr) bg))))
      (list (cons "Milestone" (octocat-vui--milestone pr))
            (cons "Closes"    (octocat-vui--numbers
                               repo (gethash "closingIssuesReferences" pr)
                               (apply-partially #'octocat-open 'issue))))
      ;; The list leaves the branch out; the page shows it and its base,
      ;; once known: a header painted from a list's copy lacks them.
      (unless (string-empty-p head)
        (concat (propertize head 'face (if (equal head local)
                                           'octocat-branch-current
                                         'octocat-branch))
                (propertize " → " 'face 'octocat-dimmed)
                (propertize base 'face 'octocat-branch)))
      ;; The checks and comments are further down the page.
      '(:ci :comments)
      (octocat-pr--stack-badge repo stack number))
     (list
      (vui-newline)
      (octocat-pr--tabs (or tab 'conversation) repo number width
                        (gethash "changedFiles" pr)
                        ;; Absent from a header painted from a list's copy.
                        (let ((commits (octocat--get pr "commits")))
                          (and commits (length commits))))))))

(defun octocat-pr--use-data (repo number tick)
  "Return the snapshot of the pull request NUMBER of REPO.
See `octocat-vui-use-detail', for TICK too.  Must be called during
render, like any hook; the conversation, commits and diff pages share
it, so they share its fetch."
  (octocat-vui-use-detail (list 'pr repo number) tick))

(defun octocat-pr--reviewers (pr)
  "Return the reviewers of PR, each a list of vnodes, or nil when there are none.
Each is \"@login (state)\": the state of their latest review, or
\"pending\" for a requested review not yet given; the login opens the
user's page."
  (let* ((reviews  (octocat--get pr "latestReviews"))
         (requests (octocat--get pr "reviewRequests"))
         (reviewer (lambda (login name state)
                     (list (if (octocat--nonempty login)
                               (octocat-vui--login-link login)
                             (vui-text (concat "@" (or name ""))))
                           (vui-text (format " (%s)" state)))))
         (parts
          (append
           (and (vectorp reviews)
                (mapcar (lambda (r)
                          (funcall reviewer
                                   (string-remove-prefix "@" (octocat--author-login r))
                                   nil
                                   (downcase (replace-regexp-in-string
                                              "_" " " (or (gethash "state" r) "")))))
                        reviews))
           (and (vectorp requests)
                (mapcar (lambda (u)
                          (funcall reviewer (gethash "login" u) (gethash "name" u)
                                   "pending"))
                        requests)))))
    parts))

(vui-defcomponent octocat-pr--page (repo number raw tick)
  "Pull request NUMBER of REPO as a timeline; RAW shows markdown verbatim.
A change under way shows where it acts: in the merge box, by the runs
it approves, or under the timeline.  A new TICK fetches everything
again."
  :render
  (let* ((width    (octocat-vui-window-width))
         (bg       (octocat--label-background))
         (snap     (octocat-pr--use-data repo number tick))
         (stack    (octocat-pr--use-stack repo number tick))
         (timeline (octocat-timeline-use-events repo number tick))
         (pr       (plist-get snap :data))
         (mutating (plist-get snap :mutating))
         ;; Only an open PR's runs can be approved.
         (awaiting (octocat-pr--use-awaiting-runs
                    repo (and pr (equal (gethash "state" pr) "OPEN")
                              (octocat-pr--head-sha pr))
                    tick))
         ;; Unused here: read ahead, so the merge dialog opens with them.
         (_options (octocat-vui-use-resource (list 'merge-options repo) tick))
         (events   (car timeline))
         ;; WIDTH is a dependency: tables are laid out for the window.
         (entries  (vui-use-memo (pr events raw width bg)
                     (and pr
                          (octocat-timeline-entries
                           (octocat-pr--items repo pr events bg)
                           raw (octocat--markdown-width))))))
    (octocat-vui-page
     (octocat-pr--pin number snap width bg)
     (octocat-vui-resource-view
      snap
      :skeleton (lambda (partial)
                  (if partial
                      ;; The list fetched the PR: its header paints at once.
                      (apply #'vui-vstack
                             (append (delq nil (octocat-pr--header repo partial bg
                                                                   (octocat--markdown-width)
                                                                   nil stack))
                                     (list (vui-text (octocat-vui-post-skeleton width)))))
                    (vui-text (octocat-vui-detail-skeleton repo number width
                                                           octocat-pr--tab-labels))))
      :render
      (lambda (_)
        (let ((on-visit-check
               (lambda ()
                 (octocat-checks-open repo (or (octocat-pr--head-sha pr) "")
                                      (octocat--nonempty (gethash "headRefName" pr))))))
          (apply #'vui-vstack
                 (append
                  (delq nil (octocat-pr--header repo pr bg (octocat--markdown-width) nil stack))
                  entries
                  ;; Under the timeline, as they add to it; the checks and
                  ;; merge are about the PR as a whole.
                  (octocat-timeline-buttons-or-action
                   (list '("+ Add a comment" "RET: write a comment" octocat-pr-add-comment)
                         (pcase (gethash "state" pr)
                           ("OPEN"   '("Close pull request" "RET: close this pull request"
                                       octocat-pr-close))
                           ("CLOSED" '("Reopen pull request" "RET: reopen this pull request"
                                       octocat-pr-reopen))))
                   (alist-get 'action mutating))
                  (list (vui-newline))
                  ;; Before the merge box: what stops the stack is read
                  ;; before its buttons.
                  (when-let* ((section (octocat-pr--stack-section
                                        repo pr stack (octocat--markdown-width))))
                    (append section (list (vui-newline))))
                  ;; An open PR's checks are in its merge box, as on GitHub.
                  (or (octocat-pr--merge-section pr (octocat--markdown-width) on-visit-check
                                                 (alist-get 'merge mutating)
                                                 awaiting (alist-get 'approve mutating))
                      (octocat-checks-block
                       (or (octocat--get pr "statusCheckRollup") [])
                       on-visit-check (octocat--markdown-width)))))))))))


(vui-defcomponent octocat-pr-commits--page (repo number tick)
  "The commits of pull request NUMBER of REPO, under the PR page's header.
A new TICK fetches them again."
  :render
  (let* ((width (octocat--markdown-width))
         (snap  (octocat-pr--use-data repo number tick))
         (stack (octocat-pr--use-stack repo number tick))
         (pr    (plist-get snap :data))
         (merges (plist-get (octocat-vui-use-resource (list 'pr-merges repo number) tick) :data))
         (commits (vui-use-memo (pr merges)
                    (and pr (mapcar (lambda (c)
                                      (when (seq-contains-p merges (gethash "sha" c))
                                        (puthash "merge" t c))
                                      c)
                                    (octocat-pr--commits pr))))))
    (octocat-vui-page
     (octocat-pr--pin number snap width (octocat--label-background))
     (octocat-vui-resource-view
      snap
      :skeleton (lambda (_)
                  (vui-text (octocat-vui-detail-skeleton repo number (octocat-vui-window-width)
                                                         octocat-pr--tab-labels)))
      :render
      (lambda (_)
        (let* ((author-w  (octocat-vui--author-width commits))
               (subject-w (octocat-vui--subject-width commits width author-w))
               (date-w    (octocat-vui--date-width commits)))
          (apply #'vui-vstack
                 (append
                  (delq nil (octocat-pr--header repo pr (octocat--label-background) width
                                                'commits stack))
                  (mapcar (lambda (c)
                            (octocat-vui--commit-row repo c nil author-w subject-w date-w))
                          commits)))))))))


;;;; Major mode

(defvar octocat-pr-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-a") #'octocat-pr-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-pr-edit)
    (define-key map (kbd "C-c C-l") #'octocat-pr-react)
    (define-key map (kbd "C-c C-n") 'octocat-issue-new) ; in octocat-issue
    (define-key map (kbd "C-c C-m") #'octocat-pr-merge)
    (define-key map (kbd "C-c C-r") #'octocat-pr-diff-review)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-pr-mode'.")

(define-derived-mode octocat-pr-mode octocat-page-mode "Octocat-PR"
  "Major mode for viewing a GitHub Pull Request as a timeline.

\\{octocat-pr-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-refresh)
  (setq-local octocat--url-function #'octocat-pr--page-url)
  (setq-local octocat--repo-function (lambda () octocat--pr-repo)))

(defvar-local octocat--pr-number nil
  "The PR number this buffer is displaying.")

(defvar-local octocat--pr-repo nil
  "The \"owner/repo\" this PR buffer belongs to.")


;;;; Refresh

(defun octocat-pr-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR buffer.
The page paints from the sync store at once and fetches fresh data in
the background, in place: what is unfolded stays so."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-vui-refresh-page 'octocat-pr--page (cons octocat--pr-repo octocat--pr-number)
                            (list :repo octocat--pr-repo
                                  :number octocat--pr-number
                                  :raw octocat--markdown-raw)))

(defun octocat-pr-open (repo number)
  "Show pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-mode)
      (octocat-pr-mode))
    (setq octocat--pr-repo   repo
          octocat--pr-number number)
    (octocat-pr-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'pr)) repo number)
  "Open PR NUMBER of REPO, as `octocat-pr-open'."
  (octocat-pr-open repo number))


;;;; Commits page

(defvar-local octocat--pr-commits-repo nil
  "The \"owner/repo\" this PR commits buffer belongs to.")

(defvar-local octocat--pr-commits-number nil
  "The PR number this buffer is listing the commits of.")

(defun octocat-pr-commits--page-url ()
  "Return the URL of the commits of this pull request."
  (and octocat--pr-commits-repo octocat--pr-commits-number
       (octocat--web-url "%s/pull/%d/commits"
                         octocat--pr-commits-repo octocat--pr-commits-number)))

(defvar octocat-pr-commits-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-m") #'octocat-pr-merge)
    (define-key map (kbd "C-c C-r") #'octocat-pr-diff-review)
    map)
  "Keymap for `octocat-pr-commits-mode'.")

(define-derived-mode octocat-pr-commits-mode octocat-page-mode "Octocat-PR-Commits"
  "Major mode for the commits of a GitHub Pull Request.

\\{octocat-pr-commits-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-commits-refresh)
  (setq-local octocat--url-function #'octocat-pr-commits--page-url)
  (setq-local octocat--repo-function (lambda () octocat--pr-commits-repo)))

(defun octocat-pr-commits-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR commits buffer."
  (interactive)
  (unless (and octocat--pr-commits-repo octocat--pr-commits-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-vui-refresh-page 'octocat-pr-commits--page
                            (cons octocat--pr-commits-repo octocat--pr-commits-number)
                            (list :repo octocat--pr-commits-repo
                                  :number octocat--pr-commits-number)))

(defun octocat-pr-commits-open (repo number)
  "Show the commits of pull request NUMBER of REPO in their own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d commits*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-commits-mode)
      (octocat-pr-commits-mode))
    (setq octocat--pr-commits-repo   repo
          octocat--pr-commits-number number)
    (octocat-pr-commits-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'pr-commits)) repo number)
  "Open the commits of PR NUMBER of REPO, as `octocat-pr-commits-open'."
  (octocat-pr-commits-open repo number))


;;;; Files changed page
;;
;; Full-diff view for a GitHub Pull Request, opened by pressing RET on the
;; "Changes" line of the PR page.  Fetches per-file patches from the REST
;; API and the review threads from GraphQL, and renders one collapsible
;; section per file, drawn by octocat-diff.el as on the commit page.
;;
;; The two fetches are independent resources, so the diff shows as soon
;; as the files arrive and the review comments appear in it when theirs
;; do.  Each file is a component of its own, whose patch text is only
;; rebuilt when that file or its comments change.
;;
;; A review is written here as on GitHub's "Files changed": comments on
;; lines are drafts in your pending review, which GitHub keeps, until the
;; review is submitted or discarded.

;;;;; Buffer-local declarations

(defvar-local octocat--pr-diff-repo nil
  "The \"owner/repo\" this PR diff buffer belongs to.")

(defvar-local octocat--pr-diff-number nil
  "The PR number this buffer is displaying a diff for.")


;;;;; Data fetching

;; The review comments are read as GitHub's threads, from GraphQL: REST
;; has no thread, whose id replying and resolving need, and no drafts.
;; Your drafts are the comments of your pending review, which only you
;; see; they come with the threads.

(defun octocat-pr-diff--null (v)
  "Return V, or nil for JSON's null."
  (unless (eq v :null) v))

(defun octocat-pr-diff--thread-comments (threads)
  "Return the comments of review THREADS, from GraphQL, as `octocat-diff' takes.
That is a vector in the REST shape (\"id\", \"path\", \"line\",
\"side\", \"user\", \"in_reply_to_id\" the first comment's id...), each
also carrying its \"node_id\" and \"thread_id\", \"pending\" for a
draft and \"can_edit\" for one you may edit.  The first comment of a
thread also has its \"resolved\", \"resolved_by\", \"can_resolve\" and
\"can_unresolve\"."
  (let (out)
    (seq-doseq (thread threads)
      (let ((root-id nil))
        (seq-doseq (c (octocat--get thread "comments" "nodes"))
          (let ((h    (make-hash-table :test #'equal))
                (user (make-hash-table :test #'equal))
                (line  (octocat-pr-diff--null (gethash "line" thread)))
                (start (octocat-pr-diff--null (gethash "startLine" thread))))
            (puthash "login" (octocat--get c "author" "login") user)
            (puthash "id" (octocat-pr-diff--null (gethash "databaseId" c)) h)
            (puthash "node_id" (gethash "id" c) h)
            (puthash "thread_id" (gethash "id" thread) h)
            (puthash "path" (gethash "path" thread) h)
            (puthash "line" line h)
            (puthash "side" (octocat-pr-diff--null (gethash "diffSide" thread)) h)
            (when (and start (not (eql start line)))
              (puthash "start_line" start h)
              (puthash "start_side" (octocat-pr-diff--null (gethash "startDiffSide" thread)) h))
            (puthash "subject_type"
                     (downcase (or (octocat-pr-diff--null (gethash "subjectType" thread)) "line"))
                     h)
            (puthash "body" (string-replace "\r\n" "\n" (or (gethash "body" c) "")) h)
            (puthash "created_at" (gethash "createdAt" c) h)
            (puthash "user" user h)
            (puthash "reactionGroups" (gethash "reactionGroups" c) h)
            (puthash "pending" (equal (gethash "state" c) "PENDING") h)
            (puthash "can_edit" (eq (gethash "viewerCanUpdate" c) t) h)
            (if root-id
                (puthash "in_reply_to_id" root-id h)
              (setq root-id (or (gethash "id" h) 0))
              (puthash "resolved" (eq (gethash "isResolved" thread) t) h)
              (puthash "resolved_by" (octocat--get thread "resolvedBy" "login") h)
              ;; A draft's thread is not one yet.
              (puthash "can_resolve" (and (eq (gethash "viewerCanResolve" thread) t)
                                          (not (gethash "pending" h)))
                       h)
              (puthash "can_unresolve" (eq (gethash "viewerCanUnresolve" thread) t) h))
            (push h out)))))
    (vconcat (nreverse out))))

(defun octocat-pr-diff--pending-count (data)
  "Return the count of draft comments in DATA, the `pr-review-threads'."
  (let ((n 0))
    (seq-doseq (thread (and data (gethash "threads" data)))
      (seq-doseq (c (octocat--get thread "comments" "nodes"))
        (when (equal (gethash "state" c) "PENDING") (cl-incf n))))
    n))


;;;;; The page's comment backend
;;
;; The diff's commands (`octocat-diff-add-comment' and the others) call
;; these through `octocat-diff--comment-backend'.

(defun octocat-pr-diff--threads ()
  "Return the stored `pr-review-threads' of this page's PR, or signal."
  (pcase-let ((`(,repo . ,number) (octocat-pr--current)))
    (or (plist-get (octocat-sync-read (octocat-model-review-threads-spec repo number)) :data)
        (user-error "Octocat: The review comments are still loading"))))

(defun octocat-pr-diff--login ()
  "Return your login, as the store has it, or nil."
  (octocat--get (plist-get (octocat-sync-read '(viewer)) :data) "login"))

(defun octocat-pr-diff--submitter (make-spec)
  "Return an edit buffer's submit function sending (MAKE-SPEC BODY)."
  (lambda (body source on-success _on-error)
    (with-current-buffer source
      (octocat-sync-submit (funcall make-spec body)))
    (funcall on-success)))

(defun octocat-pr-diff--add (range)
  "Open the edit buffer of a draft comment on RANGE; return its window."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (data   (octocat-pr-diff--threads))
               (review (gethash "pending" data)))
    (octocat-timeline-prepare-comment)
    (octocat-edit-open
     (format "Comment on %s" (octocat-diff-range-label range))
     (octocat-pr-diff--submitter
      (lambda (body)
        `(review-draft-add ,repo ,number ,(gethash "id" data)
                           ,(and review (gethash "id" review))
                           ,(if review (gethash "commit" review) (gethash "head" data))
                           ,range ,body ,(octocat-pr-diff--login))))
     #'ignore)))

(defun octocat-pr-diff--reply (comment)
  "Open the edit buffer of a reply to the thread of COMMENT.
With a pending review the reply is a draft in it; without one, you
pick between replying now and starting a review."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (data   (octocat-pr-diff--threads))
               (review (gethash "pending" data))
               (thread (gethash "thread_id" comment))
               (draft  (or review
                           (eq (car (read-multiple-choice
                                     "Reply: " '((?n "now" "post the reply at once")
                                                 (?r "review" "start a review with it"))))
                               ?r))))
    (octocat-timeline-prepare-comment)
    (octocat-edit-open
     (format "Reply on %s" (octocat-diff-range-label
                            (list :path (gethash "path" comment)
                                  :line (or (gethash "line" comment) 0)
                                  :side (gethash "side" comment))))
     (octocat-pr-diff--submitter
      (lambda (body)
        (if draft
            `(review-draft-reply ,repo ,number ,(gethash "id" data)
                                 ,(and review (gethash "id" review))
                                 ,(if review (gethash "commit" review) (gethash "head" data))
                                 ,thread ,body ,(octocat-pr-diff--login))
          `(review-reply-now ,repo ,number ,thread
                             ,(or (gethash "in_reply_to_id" comment) (gethash "id" comment))
                             ,body ,(octocat-pr-diff--login)))))
     #'ignore)))

(defvar octocat-pr-diff-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d") #'octocat-pr-diff-delete-comment)
    map)
  "Keymap for `octocat-pr-diff-comment-mode'.")

(define-minor-mode octocat-pr-diff-comment-mode
  "Delete the review comment being edited in its edit buffer."
  :keymap octocat-pr-diff-comment-mode-map)

(defun octocat-pr-diff--delete (source node-id)
  "Delete review comment NODE-ID of the PR of SOURCE, after asking."
  (when (y-or-n-p "Delete this comment? ")
    (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
      (octocat-sync-submit `(review-comment-delete ,repo ,number ,node-id)))
    t))

(defun octocat-pr-diff-delete-comment ()
  "Delete the review comment this buffer edits, after asking."
  (interactive)
  (when (octocat-pr-diff--delete octocat-edit-source-buffer
                                 (plist-get octocat-edit-user-data :node-id))
    (set-buffer-modified-p nil)
    (quit-window t octocat-edit-window)))

(defun octocat-pr-diff--edit (comment)
  "Open the edit buffer of your review COMMENT."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (node-id (gethash "node_id" comment))
               (title   (format "Edit comment on %s"
                                (octocat-diff-range-label
                                 (list :path (gethash "path" comment)
                                       :line (or (gethash "line" comment) 0)
                                       :side (gethash "side" comment)))))
               (win (octocat-edit-open
                     title
                     (lambda (body source on-success on-error)
                       (cond ((not (string-empty-p body))
                              (octocat-sync-submit
                               `(review-comment-edit ,repo ,number ,node-id ,body))
                              (funcall on-success))
                             ((octocat-pr-diff--delete source node-id)
                              (funcall on-success))
                             (t (funcall on-error "Nothing to save"))))
                     #'ignore
                     (gethash "body" comment)
                     (list :node-id node-id :allow-empty t))))
    (with-current-buffer (window-buffer win)
      (octocat-pr-diff-comment-mode 1)
      (setq header-line-format
            (concat (octocat-edit-header-line title) "   "
                    (propertize "C-c C-d" 'face 'help-key-binding) "  delete")))
    win))

(defun octocat-pr-diff--resolve (root)
  "Resolve the thread of ROOT, its first comment, or unresolve it."
  (pcase-let ((`(,repo . ,number) (octocat-pr--current)))
    (octocat-sync-submit `(review-thread-resolve ,repo ,number ,(gethash "thread_id" root)
                                                 ,(not (eq (gethash "resolved" root) t))))))

(defconst octocat-pr-diff--comment-backend
  (list :add #'octocat-pr-diff--add
        :reply #'octocat-pr-diff--reply
        :edit #'octocat-pr-diff--edit
        :resolve #'octocat-pr-diff--resolve)
  "The PR diff's comments, drafts in your pending review, see `octocat-diff'.")


;;;;; Review submission

(defconst octocat-pr-diff--review-labels
  '((comment . "Comment") (approve . "Approve") (request-changes . "Request changes"))
  "The label of each of `octocat-model-review-events'.")

(defun octocat-pr-diff--review-data (event &optional review-id pending)
  "Return the edit buffer's user data for an EVENT review, or nil EVENT.
REVIEW-ID is your pending review's, holding PENDING drafts.  Only an
approval may be submitted without text, or a comment with drafts."
  (list :event event :review-id review-id :pending pending
        :allow-empty (or (eq event 'approve)
                         (and (eq event 'comment) (natnump pending) (> pending 0)))))

(defun octocat-pr-diff--review-header (title event &optional pending)
  "Return the review dialog's header line for TITLE with EVENT chosen.
PENDING is how many drafts the review holds."
  (concat "  " title
          (if (and pending (> pending 0))
              (propertize (format "  %d pending comment%s" pending (if (= pending 1) "" "s"))
                          'face 'octocat-review-pending)
            "")
          "    "
          (mapconcat (lambda (e)
                       (let ((label (alist-get (car e) octocat-pr-diff--review-labels)))
                         (if (eq (car e) event)
                             (propertize (format "(•) %s" label) 'face 'bold)
                           (propertize (format "( ) %s" label) 'face 'octocat-dimmed))))
                     octocat-model-review-events "  ")
          "    "
          (propertize "C-c C-t" 'face 'help-key-binding) " decision   "
          (propertize "C-c C-c" 'face 'help-key-binding) " submit   "
          (propertize "C-c C-k" 'face 'help-key-binding) " close"
          (if pending
              (concat "   " (propertize "C-c C-d" 'face 'help-key-binding) " discard review")
            "")))

(defun octocat-pr-diff--submit-review (body source on-success on-error)
  "Submit BODY as a review of the PR in SOURCE buffer.
The review event is read from the edit buffer's :event user data;
there is none until the user picks a decision.  The dialog closes at
once, through ON-SUCCESS, and the PR's pages show the review under way
until it is sent, so a slow GitHub does not block; ON-ERROR is called
only for a missing decision."
  (let ((event (plist-get octocat-edit-user-data :event))
        (review-id (plist-get octocat-edit-user-data :review-id)))
    (cond
     ((not event)
      (funcall on-error "Pick a decision with C-c C-t first"))
     ((and (string-empty-p body) (not (plist-get octocat-edit-user-data :allow-empty)))
      (funcall on-error "Write the review's text first"))
     (t
      (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
        (octocat-sync-submit `(review-pr ,repo ,number ,event ,body ,review-id)
                             (lambda (result)
                               (unless (eq (car-safe result) 'error)
                                 (message "Octocat: Reviewed PR #%d" number)))))
      (funcall on-success)))))

(defun octocat-pr-diff-review-cycle ()
  "Switch the review dialog to the next decision."
  (interactive)
  (let* ((events  (mapcar #'car octocat-model-review-events))
         (next    (or (cadr (member (plist-get octocat-edit-user-data :event) events))
                      (car events)))
         (pending (plist-get octocat-edit-user-data :pending)))
    (setq octocat-edit-user-data
          (octocat-pr-diff--review-data
           next (plist-get octocat-edit-user-data :review-id) pending))
    (setq header-line-format
          (octocat-pr-diff--review-header octocat-edit-title next pending))
    (force-mode-line-update)))

(defun octocat-pr-diff--discard (source review-id pending)
  "Discard pending review REVIEW-ID of the PR of SOURCE, after asking.
PENDING is how many drafts it holds.  Return non-nil when discarded."
  (when (y-or-n-p (format "Discard your review and its %d draft%s? "
                          pending (if (= pending 1) "" "s")))
    (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
      (octocat-sync-submit `(review-discard ,repo ,number ,review-id)))
    t))

(defun octocat-pr-diff-review-discard ()
  "Discard your pending review, its drafts with it, after asking."
  (interactive)
  (let ((review-id (or (plist-get octocat-edit-user-data :review-id)
                       (user-error "Octocat: No review to discard"))))
    (when (octocat-pr-diff--discard octocat-edit-source-buffer review-id
                                    (plist-get octocat-edit-user-data :pending))
      (set-buffer-modified-p nil)
      (quit-window t octocat-edit-window))))

(defvar octocat-pr-diff-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'octocat-pr-diff-review-cycle)
    (define-key map (kbd "C-c C-d") #'octocat-pr-diff-review-discard)
    map)
  "Keymap for `octocat-pr-diff-review-mode'.")

;; A minor mode so the decision key lives only in review dialogs, not in
;; every `octocat-edit-mode' buffer.
(define-minor-mode octocat-pr-diff-review-mode
  "Pick the decision of a PR review in its edit buffer."
  :keymap octocat-pr-diff-review-mode-map)

(defun octocat-pr-diff--pending-review (repo number)
  "Return your pending review of PR NUMBER of REPO and its drafts, or nil.
That is (ID . COUNT), from the store."
  (let* ((data   (plist-get (octocat-sync-read (octocat-model-review-threads-spec repo number))
                            :data))
         (review (and data (gethash "pending" data))))
    (and review (cons (gethash "id" review) (octocat-pr-diff--pending-count data)))))

(defun octocat-pr-diff-review ()
  "Open the dialog to submit a review of this PR, from any of its pages.
Write the review text, pick Comment, Approve or Request changes with
\\<octocat-pr-diff-review-mode-map>\\[octocat-pr-diff-review-cycle], then submit.
Your draft comments are submitted with it, or discarded with
\\[octocat-pr-diff-review-discard]."
  (interactive)
  (let* ((current (or (octocat-pr--current)
                      (user-error "Octocat: Buffer is not associated with a pull request")))
         (number  (cdr current))
         (_       (when (octocat-pr--busy (car current) number 'review)
                    (user-error "Octocat: A review of PR #%d is being submitted" number)))
         (pending (octocat-pr-diff--pending-review (car current) number))
         (title (format "Review PR #%d" number))
         (win   (octocat-edit-open
                 title
                 #'octocat-pr-diff--submit-review
                 #'ignore
                 nil
                 ;; No default decision: it must be a deliberate choice.
                 (octocat-pr-diff--review-data nil (car pending) (cdr pending)))))
    (with-current-buffer (window-buffer win)
      (octocat-pr-diff-review-mode 1)
      (setq header-line-format (octocat-pr-diff--review-header title nil (cdr pending))))))

(defun octocat-pr-diff--buttons (pending)
  "Return the buttons under the PR diff: submit, and discard with PENDING drafts.
PENDING is (REVIEW-ID . COUNT), your pending review, or nil."
  (apply #'vui-vstack
         (octocat-timeline-buttons
          (cons (list (if pending
                          (format "Submit review (%d pending)" (cdr pending))
                        "Submit review")
                      "RET: comment on, approve or request changes"
                      #'octocat-pr-diff-review)
                (and pending
                     (list (list "Discard review" "RET: delete your drafts"
                                 (lambda ()
                                   (octocat-pr-diff--discard (current-buffer) (car pending)
                                                             (cdr pending))))))))))


;;;;; Components

(defun octocat-pr-diff--revs (repo base head)
  "Return the commits a diff of REPO from branch BASE to HEAD compares.
That is as `octocat-diff-open-large' takes them, or nil without both.
The diff is from their merge base, looked up only when needed."
  (and base head
       (cons (lambda (k) (octocat-diff--merge-base repo base head k))
             head)))

(vui-defcomponent octocat-pr-diff--page (repo number hide-comments raw at tick)
  "The diff of pull request NUMBER of REPO, under the PR page's header.
HIDE-COMMENTS leaves the review comments out of the diff, and RAW shows
their markdown verbatim.  AT is the lines a link named, see
`octocat-diff--file'.  A review being
submitted shows in place of the submit button.  A new TICK fetches
everything again."
  :render
  (let* ((pr       (octocat-pr--use-data repo number tick))
         (stack    (octocat-pr--use-stack repo number tick))
         (tab-w    (octocat--markdown-width))
         (files    (octocat-vui-use-resource (list 'pr-files repo number) tick))
         (threads  (octocat-vui-use-resource (octocat-model-review-threads-spec repo number) tick))
         (data     (plist-get threads :data))
         (comments (vui-use-memo (data)
                     (and data (octocat-pr-diff--thread-comments (gethash "threads" data)))))
         (by-path  (vui-use-memo (comments) (octocat-diff-by-path comments)))
         (base     (octocat--get (plist-get pr :data) "baseRefName"))
         (head     (and data (gethash "head" data)))
         (revs     (vui-use-memo (base head) (octocat-pr-diff--revs repo base head)))
         (review   (and data (gethash "pending" data)))
         (pending  (and review (cons (gethash "id" review)
                                     (octocat-pr-diff--pending-count data)))))
    (octocat-vui-page
     (octocat-pr--pin number pr tab-w (octocat--label-background))
     (vui-vstack
      ;; The same header as the conversation, so the pages read as tabs.
      (cond
       ((or (plist-get pr :data) (plist-get pr :partial))
        (apply #'vui-vstack
               (delq nil (octocat-pr--header
                          repo (or (plist-get pr :data) (plist-get pr :partial))
                          (octocat--label-background) tab-w 'files stack))))
       ((and (plist-get pr :error) (not (plist-get pr :loading)))
        (vui-vstack
         (vui-text (octocat-vui-error-text pr) :face 'error)
         (octocat-pr--tabs 'files repo number tab-w)))
       (t (vui-vstack
           (vui-text (format "%s#%d  diff" repo number)
             :face 'octocat-dimmed)
           (octocat-pr--tabs 'files repo number tab-w))))
      (pcase (octocat-vui-snapshot-status files)
        ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28) ("  " 34)))))
        ('error   (vui-text (concat "  " (octocat-vui-error-text files)) :face 'error))
        (_ (octocat-diff-files-section repo (plist-get files :data) by-path
                                       hide-comments raw (octocat--markdown-width) nil at
                                       (octocat--get (plist-get pr :data) "changedFiles")
                                       revs)))
      (vui-newline)
      (octocat-diff-comments-section "Review Comments" (plist-put (copy-sequence threads)
                                                                  :data comments)
                                     raw (octocat--markdown-width))
      (if-let* ((reviewing (alist-get 'review (plist-get pr :mutating))))
          (vui-text (concat "  " (octocat-spinner) " " reviewing) :face 'bold)
        (octocat-pr-diff--buttons pending))))))


;;;;; Major mode

(defun octocat-pr-diff--page-url ()
  "Return the URL of the files changed of this pull request.
It is at the diff line of point or the region."
  (and octocat--pr-diff-repo octocat--pr-diff-number
       (concat (octocat--web-url "%s/pull/%d/files" octocat--pr-diff-repo
                                 octocat--pr-diff-number)
               (octocat-diff--url-fragment))))

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-a") #'octocat-diff-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-diff-edit-comment)
    (define-key map (kbd "C-c C-r") #'octocat-pr-diff-review)
    (define-key map (kbd "C-c C-m") #'octocat-pr-merge)
    (define-key map (kbd "C-c C-v") #'octocat-diff-toggle-comments)
    map)
  "Keymap for `octocat-pr-diff-mode'.")

(define-derived-mode octocat-pr-diff-mode octocat-page-mode "Octocat-PR-Diff"
  "Major mode for viewing the complete diff of a GitHub Pull Request.

\\{octocat-pr-diff-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh)
  (setq-local octocat--url-function #'octocat-pr-diff--page-url)
  (setq-local octocat-diff--comment-backend octocat-pr-diff--comment-backend)
  (setq-local octocat--repo-function (lambda () octocat--pr-diff-repo)))


;;;;; Refresh

(defun octocat-pr-diff-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR diff buffer.
The page fetches the file diffs and the review threads independently,
in place."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (octocat-vui-refresh-page 'octocat-pr-diff--page
                            (cons octocat--pr-diff-repo octocat--pr-diff-number)
                            (list :repo octocat--pr-diff-repo
                                  :number octocat--pr-diff-number
                                  :hide-comments octocat-diff--hide-comments
                                  :raw octocat--markdown-raw
                                  :at octocat-diff--at)))

(defun octocat-pr-diff-open (repo number &optional at)
  "Show the diff of pull request NUMBER of REPO in its own buffer.
AT is the lines a link named, see `octocat-diff--file'."
  (let ((buf (get-buffer-create (format "*%s pr %d diff*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-diff-mode)
      (octocat-pr-diff-mode))
    (setq octocat--pr-diff-repo   repo
          octocat--pr-diff-number number
          octocat-diff--hide-comments nil
          octocat-diff--at at)
    (octocat-pr-diff-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'pr-diff)) repo number &optional at)
  "Open the files changed by PR NUMBER of REPO, AT the lines a link named.
See `octocat-pr-diff-open'."
  (apply #'octocat-pr-diff-open repo number (and at (list at))))


;;;; PR list page
;;
;; Opened by `M-x octocat-pr-list' (octocat.el); the page is
;; `octocat-vui-search-list'.

(defun octocat-pr-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  ;; The rows read the label background as drawn, to follow a theme change.
  (let ((repo octocat-vui-list--repo))
    (octocat-vui-refresh-page 'octocat-vui-search-list repo
                              (list :repo repo
                                    :kind 'pulls
                                    :query (octocat-vui-list-query)
                                    :compact (octocat-vui-list-compact-p)
                                    :row-fn (lambda (pr width compact no-state stacks marked)
                                              (octocat-vui--pr-row
                                               repo pr width (octocat--label-background)
                                               compact no-state
                                               (octocat-pr--stacks-label
                                                stacks (gethash "number" pr))
                                               marked))
                                    :line-fn (lambda (pr no-state stacks)
                                               (octocat-vui--pr-compact-line
                                                repo pr (octocat--label-background) no-state nil
                                                (octocat-pr--stacks-label
                                                 stacks (gethash "number" pr))))
                                    :extra-fn (lambda (tick)
                                                (octocat-pr--use-repo-stacks repo tick))))))

(defvar octocat-pr-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (make-composed-keymap octocat-vui-list-mark-map
                                                 octocat-vui-list-mode-map))
    (define-key map (kbd "C-c C-n") 'octocat-issue-new) ; in octocat-issue
    map)
  "Keymap for `octocat-pr-list-mode'.")

(define-derived-mode octocat-pr-list-mode octocat-vui-list-mode "Octocat-PRs"
  "Major mode for the pull request list of a repository.

\\{octocat-pr-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "merged" "all"))
  (setq-local octocat-vui-list--facets
              '(("State"    . octocat-vui-list-filter-state)
                ("Author"   . octocat-vui-list-filter-author)
                ("Assignee" . octocat-vui-list-filter-assignee)
                ("Reviewer" . octocat-vui-list-filter-reviewer)
                ("Label"    . octocat-vui-list-filter-label)))
  (setq-local octocat-vui-list--view "pr-list")
  (setq-local octocat-vui-list--web-scope "is:pr")
  (setq-local revert-buffer-function #'octocat-pr-list-refresh))

(provide 'octocat-pr)
;;; octocat-pr.el ends here
