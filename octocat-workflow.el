;;; octocat-workflow.el --- Workflow detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; A workflow and its runs: `octocat-workflow-mode', a vui.el page
;; opened from the workflow list (octocat-actions.el) or `C-c C-j'.  RET on a run opens
;; it (octocat-run.el).
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-run)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'vui)



;;;; Customisation

(defcustom octocat-workflow-runs-limit 20
  "Default number of runs to display in the workflow detail view."
  :type 'integer
  :group 'octocat)


;;;; Buffer-local declarations

(defvar-local octocat--workflow-repo nil
  "The \"owner/repo\" this workflow buffer belongs to.")

(defvar-local octocat--workflow-id nil
  "The workflow ID, or its file name, this buffer is displaying.")

(defvar-local octocat--workflow-name nil
  "The display name of the workflow this buffer is displaying.")

(defvar-local octocat--workflow-path nil
  "The workflow file, e.g. \".github/workflows/ci.yml\", or nil.")


;;;; Data fetching

(defun octocat--fetch-workflow (repo id limit callback)
  "Fetch detail for workflow ID in REPO asynchronously.
LIMIT controls how many run entries are requested.
Calls CALLBACK with a cons (WORKFLOW . RUNS) where WORKFLOW is a
hash-table of metadata and RUNS is a list of run hash-tables, or a
cons \\=(error . MSG) on failure."
  (let ((workflow-result 'pending)
        (runs-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq workflow-result 'pending)
                       (eq runs-result 'pending))
             (cond
              ((eq (car-safe workflow-result) 'error)
               (funcall callback workflow-result))
              ((eq (car-safe runs-result) 'error)
               (funcall callback runs-result))
              (t
               (funcall callback (cons workflow-result runs-result)))))))
      (octocat--run-gh
       "workflow-detail"
       (list "api" (format "repos/%s/actions/workflows/%s" repo id))
       (lambda (output) (json-parse-string (string-trim output)))
       (lambda (result) (setq workflow-result result) (maybe-done)))
      (octocat--run-gh
       "workflow-runs"
       (list "run" "list"
             "--repo"     repo
             "--workflow" (format "%s" id)
             "--limit"    (number-to-string limit)
             "--json"     "databaseId,displayTitle,status,conclusion,createdAt,headBranch")
       #'octocat--parse-json-list
       (lambda (result) (setq runs-result result) (maybe-done))))))


;;;; Rendering helpers

(defun octocat--workflow-run-icon (status conclusion)
  "Return a propertized status icon for a run with STATUS and CONCLUSION."
  (let ((st (or status ""))
        (co (octocat--nonempty conclusion)))
    (cond
     ((equal st "in_progress")
      (propertize "●" 'face 'octocat-ci-pending))
     ((equal co "success")
      (propertize "✓" 'face 'octocat-ci-success))
     ((member co '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "✗" 'face 'octocat-ci-failure))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--workflow-state-face (state)
  "Return the face for workflow STATE string."
  (if (equal state "active") 'success 'octocat-dimmed))

(defun octocat-workflow--url (repo id path)
  "Return the github.com page of workflow ID of REPO.
GitHub names it by its file, the last part of PATH, when known."
  (format "https://github.com/%s/actions/workflows/%s" repo
          (if (octocat--nonempty path) (file-name-nondirectory path) id)))


;;;; Page

(defun octocat-workflow--run-row (repo run branch-w)
  "Return a RET-able row for RUN of REPO; BRANCH-W is the branch column width."
  (let ((status     (downcase (or (gethash "status" run) "")))
        (conclusion (let ((c (gethash "conclusion" run)))
                      (and (octocat--nonempty c) (downcase c))))
        (id         (gethash "databaseId" run)))
    (octocat-vui-row
     (propertize
      (concat "  "
              (propertize (format "%-11s" (or (gethash "databaseId" run) 0))
                          'face 'octocat-pr-number)
              "  "
              (octocat--format-branch (or (gethash "headBranch" run) "") branch-w)
              "  "
              (octocat--workflow-run-icon status conclusion)
              "  "
              (octocat--format-title (or (gethash "displayTitle" run) ""))
              "  "
              (propertize (octocat--format-ts-relative (or (gethash "createdAt" run) ""))
                          'face 'octocat-dimmed))
      'octocat-sync-prefetch `((run ,repo ,id) (run-artifacts ,repo ,id)))
     (lambda () (octocat-run-open repo id))
     "RET: open workflow run")))

(defun octocat-workflow--header (workflow runs)
  "Return the vnodes under the top row: name, state and file of WORKFLOW.
The latest of RUNS gives the status icon after the state."
  (let ((state   (downcase (or (gethash "state" workflow) "")))
        (created (octocat--nonempty (gethash "created_at" workflow)))
        (updated (octocat--nonempty (gethash "updated_at" workflow)))
        (latest  (car runs)))
    (list
     (vui-text (concat (or (gethash "name" workflow) "")
                       "  " (propertize state 'face (octocat--workflow-state-face state))
                       (when latest
                         (concat "  " (octocat--workflow-run-icon
                                       (downcase (or (gethash "status" latest) ""))
                                       (downcase (or (gethash "conclusion" latest) "")))))))
     (vui-text (mapconcat
                #'identity
                (delq nil
                      (list (propertize (or (gethash "path" workflow) "") 'face 'octocat-branch)
                            (and created (concat (propertize "Created " 'face 'octocat-dimmed)
                                                 (octocat--format-ts-relative created)))
                            (and updated (concat (propertize "Updated " 'face 'octocat-dimmed)
                                                 (octocat--format-ts-relative updated)))))
                (propertize " · " 'face 'octocat-dimmed))))))

(defun octocat-workflow--runs (repo runs more on-more loading)
  "Return the vnodes of the section listing each workflow run of REPO.
RUNS is the list of them.  MORE says a further page may exist, loaded
by ON-MORE; LOADING is non-nil while that page is fetched."
  (cons
   (vui-text (propertize (format "%d workflow runs" (length runs))
                         'face 'octocat-section-heading))
   (if (null runs)
       (list (vui-text "  (no runs)" :face 'octocat-dimmed))
     (let ((branch-w (octocat--branch-column-width runs "headBranch")))
       (list (vui-fragment
              (octocat-vui-reveal-list
               runs
               (lambda (run) (octocat-workflow--run-row repo run branch-w))
               (lambda (run) (gethash "databaseId" run)))
              (when more
                (octocat-vui-load-more-button
                 'load-more-runs octocat-workflow-runs-limit
                 "RET: load more runs" on-more loading nil
                 (octocat-vui-line-skeleton)))))))))

(octocat-sync-define-resource workflow (repo id limit)
  :fetch (lambda (done)
           (octocat--fetch-workflow
            repo id limit
            (lambda (r)
              (funcall done
                       (if (eq (car-safe r) 'error)
                           r
                         (let ((tree (make-hash-table :test #'equal)))
                           (puthash "workflow" (car r) tree)
                           (puthash "runs" (vconcat (mapcar (lambda (run) (octocat-sync-run repo run))
                                                            (cdr r)))
                                    tree)
                           tree)))))))

(vui-defcomponent octocat-workflow--page (repo id name tick)
  "Workflow ID of REPO and its runs; NAME shows while it loads.
A new TICK fetches them again."
  :state ((limit octocat-workflow-runs-limit))
  :render
  (let* ((snap    (octocat-vui-use-resource (list 'workflow repo id limit) tick))
         (shown   (vui-use-ref nil))
         (loading (plist-get snap :loading)))
    ;; Each limit is its own resource: keep the shorter list while the
    ;; longer one loads.
    (when (plist-get snap :data) (setcar shown (plist-get snap :data)))
    (apply #'vui-vstack
           (octocat-vui-actions-top-row repo)
           (pcase (if (car shown) 'ready (octocat-vui-snapshot-status snap))
             ('pending (list (vui-text name) (vui-newline)
                             (vui-text (octocat-vui-line-skeleton))))
             ('error   (list (vui-text (concat "  " (octocat-vui-error-text snap))
                                       :face 'error)))
             (_ (let ((runs (append (gethash "runs" (car shown)) nil)))
                  (append (octocat-workflow--header (gethash "workflow" (car shown)) runs)
                          (list (vui-newline))
                          (octocat-workflow--runs
                           repo runs
                           (or (>= (length runs) limit)
                               (and loading (> limit octocat-workflow-runs-limit)))
                           (lambda () (vui-set-state :limit (+ limit octocat-workflow-runs-limit)))
                           (and loading (< (length runs) limit))))))))))


;;;; Major mode

(defun octocat-workflow-browse ()
  "Open this workflow in a browser."
  (interactive)
  (unless (and octocat--workflow-repo octocat--workflow-id)
    (user-error "Octocat: Buffer is not associated with a workflow"))
  (message "Octocat: Opening workflow in browser…")
  (octocat-browse-external (octocat-workflow--url octocat--workflow-repo octocat--workflow-id
                                                  octocat--workflow-path)))

(defvar octocat-workflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    map)
  "Keymap for `octocat-workflow-mode'.")
(define-key octocat-workflow-mode-map (kbd "C-c C-o") #'octocat-workflow-browse)

(define-derived-mode octocat-workflow-mode vui-mode "Octocat-Workflow"
  "Major mode for viewing a GitHub Actions Workflow.

\\{octocat-workflow-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-workflow-refresh)
  (add-hook 'post-command-hook #'octocat-vui--prefetch-schedule nil t)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-workflow-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow buffer.
The page paints from the sync store at once and fetches the workflow and
its runs in the background, in place."
  (interactive)
  (unless (and octocat--workflow-repo octocat--workflow-id)
    (user-error "Octocat: Buffer is not associated with a workflow"))
  (octocat-vui-refresh-page 'octocat-workflow--page
                            (cons octocat--workflow-repo octocat--workflow-id)
                            (list :repo octocat--workflow-repo
                                  :id octocat--workflow-id
                                  :name (or octocat--workflow-name ""))))

(defun octocat-workflow-open (repo id name path)
  "Show workflow ID of REPO in its own buffer.
NAME is its display name and PATH its file, or nil."
  (let ((buf (get-buffer-create (format "*%s workflow %s*" repo name))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-workflow-mode)
      (octocat-workflow-mode))
    (setq octocat--workflow-repo repo
          octocat--workflow-id   id
          octocat--workflow-name name
          octocat--workflow-path path)
    (octocat-workflow-refresh)))

(provide 'octocat-workflow)
;;; octocat-workflow.el ends here
