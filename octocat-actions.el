;;; octocat-actions.el --- Actions page for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; The pages of GitHub's Actions tab, each its own buffer and major mode:
;; a repository's recent runs across all workflows (`octocat-run-list-mode')
;; and its workflows (`octocat-workflow-list-mode').  A tab row under the
;; header switches between them.  Opened by `M-x octocat-run-list',
;; `octocat-workflow-list' and `octocat-actions' (octocat.el).  See "UI
;; frameworks" in CONTRIBUTING.md.

;;; Code:

(require 'octocat-core)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, etc.
(require 'octocat-repo) ; row builders and fetchers

(declare-function octocat-run-list      "octocat" (&optional repo))
(declare-function octocat-workflow-list "octocat" (&optional repo))


(octocat-sync-define-resource runs (repo limit args)
  ;; ARGS are `gh run list' options filtering the runs.
  :fetch (lambda (done)
           (octocat-repo--list-recent-runs
            repo limit
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (let ((tree (make-hash-table :test #'equal)))
                                (puthash "nodes" (vconcat (mapcar (lambda (run) (octocat-sync-run repo run))
                                                                  r))
                                         tree)
                                tree))))
            args)))

(octocat-sync-define-resource workflows (repo)
  :fetch (lambda (done)
           (octocat-repo--list-workflows
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

;;;; Run filters
;;
;; The runs are filtered by a query of qualifiers, edited as a PR list's
;; (see "List filters" in octocat-vui.el).  `gh run list' takes no search
;; query, only one option per qualifier, so each becomes its option; a
;; repeated qualifier keeps its last value, as gh would.

(defconst octocat-actions--run-qualifiers
  '(("branch:"   . "--branch")
    ("status:"   . "--status")
    ("workflow:" . "--workflow")
    ("actor:"    . "--user")
    ("event:"    . "--event")
    ("commit:"   . "--commit"))
  "Run query qualifiers and the `gh run list' option each becomes.")

(defconst octocat-actions--run-statuses
  '("success" "failure" "in_progress" "queued" "completed" "cancelled"
    "skipped" "timed_out" "action_required" "waiting" "pending"
    "requested" "neutral" "stale" "startup_failure")
  "Values `gh run list --status' takes, the common ones first.")

(defun octocat-actions--run-args (query)
  "Return the `gh run list' options of QUERY, and its other tokens.
That is (ARGS . IGNORED): ARGS a list of options and values, IGNORED the
tokens of QUERY that are no qualifier of `octocat-actions--run-qualifiers'."
  (let (opts ignored)
    (dolist (token (octocat-vui-list--tokenize (or query "")))
      (if-let* ((q (seq-find (lambda (q) (string-prefix-p (car q) token))
                             octocat-actions--run-qualifiers))
                (value (string-replace "\"" "" (substring token (length (car q)))))
                ((not (string-empty-p value))))
          (setf (alist-get (cdr q) opts nil nil #'equal) value)
        (push token ignored)))
    (cons (mapcan (lambda (o) (list (car o) (cdr o))) (nreverse opts))
          (nreverse ignored))))

(defun octocat-actions--static-candidates (values)
  "Return a fetch function of `octocat-vui-list--edit-facet' giving VALUES."
  (lambda (_repo callback) (funcall callback values)))

(defun octocat-actions-filter-branch ()
  "Filter by the branch of a run."
  (interactive)
  (octocat-vui-list--edit-facet "branch:" "Branch" nil #'octocat--list-branches nil))

(defun octocat-actions-filter-status ()
  "Filter by the status or conclusion of a run."
  (interactive)
  (octocat-vui-list--edit-facet
   "status:" "Status" nil
   (octocat-actions--static-candidates octocat-actions--run-statuses) nil))

(defun octocat-actions-filter-workflow ()
  "Filter by the workflow of a run."
  (interactive)
  (octocat-vui-list--edit-facet "workflow:" "Workflow" nil
                                (octocat-vui-list--stored
                                 'workflows (lambda (wf) (gethash "name" wf)))
                                nil))

(defun octocat-actions-filter-actor ()
  "Filter by who triggered a run."
  (interactive)
  (octocat-vui-list--edit-facet "actor:" "Actor" nil #'octocat--list-people nil))

(defun octocat-actions--filter-setup ()
  "Give the current list buffer the filter of the run list."
  (setq-local octocat-vui-list--states octocat-actions--run-statuses
              octocat-vui-list--default-query ""
              octocat-vui-list--qualifiers
              (append (mapcar #'car octocat-actions--run-qualifiers)
                      (mapcar (lambda (s) (concat "status:" s))
                              octocat-actions--run-statuses)
                      '("event:push" "event:pull_request" "event:schedule"
                        "event:workflow_dispatch"))
              octocat-vui-list--facets
              '(("Branch"   . octocat-actions-filter-branch)
                ("Status"   . octocat-actions-filter-status)
                ("Workflow" . octocat-actions-filter-workflow)
                ("Actor"    . octocat-actions-filter-actor))))

;;;; Page

(vui-defcomponent octocat-actions--runs-section (repo current-branch tick query)
  "The recent runs of REPO matching QUERY.
See `octocat-actions--run-args' for QUERY.  TICK is the page's refresh
tick."
  :state ((limit octocat-actions-runs-page-size))
  :render
  (let* ((parsed  (octocat-actions--run-args query))
         (snap    (octocat-vui-use-resource (list 'runs repo limit (car parsed)) tick))
         (shown   (vui-use-ref nil))
         (data    (plist-get snap :data))
         (loading (plist-get snap :loading)))
    ;; Each limit is its own resource: keep the shorter list while the
    ;; longer one loads.
    (when data (setcar shown (append (gethash "nodes" data) nil)))
    (pcase (if (car shown) 'ready (octocat-vui-snapshot-status snap))
       ('pending (vui-text (octocat-vui-line-skeleton)))
       ('error   (vui-text (concat (octocat-vui-error-text snap) "\n") :face 'octocat-dimmed))
       ('ready
        (let* ((runs (car shown))
               (wf-w (if runs
                         (min 25 (apply #'max 1
                                        (mapcar (lambda (r) (length (or (gethash "workflowName" r) "")))
                                                runs)))
                       1))
               (branch-w (octocat--branch-column-width runs "headBranch"))
               (title-w (octocat-repo-vui--run-title-width
                         runs (octocat-vui-window-width) wf-w branch-w)))
          (vui-fragment
           (when (cdr parsed)
             (vui-text (format "Ignored, not a run filter: %s\n"
                               (string-join (cdr parsed) " "))
                       :face 'octocat-dimmed))
           (if (null runs)
               (vui-text (if (car parsed)
                             "(no workflow runs match the filters)\n"
                           "(no workflow runs)\n")
                         :face 'octocat-dimmed)
             (octocat-vui-reveal-list
              runs
              (lambda (r)
                (octocat-repo-vui--workflow-run-row
                 repo r current-branch wf-w title-w branch-w))
              (lambda (r) (gethash "databaseId" r))))
           (when (and runs (or (>= (length runs) limit)
                               (and loading (> limit octocat-actions-runs-page-size))))
             (octocat-vui-load-more-button
              'load-more-runs octocat-actions-runs-page-size
              "RET: load more runs"
              (lambda () (vui-set-state :limit (+ limit octocat-actions-runs-page-size)))
              (and loading (< (length runs) limit)) 0
              (octocat-vui-line-skeleton)))))))))

(defun octocat-actions--tab-row (repo current workflows)
  "Return the tab row of REPO's Actions pages.
CURRENT is the page shown, `runs' or `workflows'; the other tab opens
its page.  WORKFLOWS, their sync snapshot, gives their count."
  (let ((count (and (plist-get workflows :data) (length (plist-get workflows :data)))))
    (octocat-vui-tab-row
     (list (list "Runs" "RET: list the recent runs"
                 (unless (eq current 'runs) (lambda () (octocat-run-list repo))))
           (list (if count (format "Workflows (%d)" count) "Workflows")
                 "RET: list the workflows"
                 (unless (eq current 'workflows) (lambda () (octocat-workflow-list repo)))))
     (octocat-vui-window-width))))

(defun octocat-actions--workflows (repo snap)
  "Return the workflows of REPO, from SNAP, their sync snapshot.
No pagination: run history lives on the runs page."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-line-skeleton)))
    ('error   (vui-text (concat (octocat-vui-error-text snap) "\n") :face 'octocat-dimmed))
    ('ready
     (let ((workflows (append (plist-get snap :data) nil)))
       (if (null workflows)
           (vui-text "(no workflows)\n" :face 'octocat-dimmed)
         (let* ((state-w (apply #'max (mapcar (lambda (wf)
                                                (string-width
                                                 (octocat-repo-vui--workflow-state wf)))
                                              workflows)))
                (name-w  (octocat-repo-vui--workflow-name-width
                          workflows (octocat-vui-window-width) state-w)))
           (vui-list workflows
                     (lambda (wf) (octocat-repo-vui--workflow-row repo wf state-w name-w))
                     (lambda (wf) (gethash "id" wf)))))))))

(vui-defcomponent octocat-actions--runs-page (repo current-branch tick query)
  "The page of REPO's recent runs, those matching QUERY, filtered above them.
The workflows are fetched too, for the count on their tab.  A new TICK
refetches, keeping what is shown up until the fresh data replaces it."
  :render
  (vui-vstack
   (vui-component 'octocat-vui-list-header :repo repo :tab 'actions :tick tick)
   (octocat-actions--tab-row repo 'runs
                             (octocat-vui-use-resource (list 'workflows repo) tick))
   (vui-newline)
   (octocat-vui-list-filter-bar query)
   (vui-component 'octocat-actions--runs-section
                  :key query
                  :repo repo :current-branch current-branch :tick tick
                  :query query)))

(vui-defcomponent octocat-actions--workflows-page (repo tick)
  "The page of REPO's workflows.
Stored, they show at once; a new TICK refetches them, keeping what is
shown up until the fresh data replaces it."
  :render
  (let ((workflows (octocat-vui-use-resource (list 'workflows repo) tick)))
    (vui-vstack
     (vui-component 'octocat-vui-list-header :repo repo :tab 'actions :tick tick)
     (octocat-actions--tab-row repo 'workflows workflows)
     (vui-newline)
     (octocat-actions--workflows repo workflows))))

(defun octocat-run-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run list buffer.
The page paints from the sync store at once and fetches the runs in the
background; a refresh keeps the old content up meanwhile."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-actions--runs-page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo
                                  :current-branch (plist-get (octocat--head-info) :branch)
                                  :query (octocat-vui-list-query))))

(defun octocat-workflow-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow list buffer, as `octocat-run-list-refresh'."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-actions--workflows-page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo)))

(define-derived-mode octocat-run-list-mode octocat-vui-list-mode "Octocat-Runs"
  "Major mode for the list of a repository's recent workflow runs.

\\{octocat-run-list-mode-map}"
  :group 'octocat
  (octocat-actions--filter-setup)
  (setq-local revert-buffer-function #'octocat-run-list-refresh))

(define-derived-mode octocat-workflow-list-mode octocat-vui-list-mode "Octocat-Workflows"
  "Major mode for the list of a repository's workflows.

\\{octocat-workflow-list-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-workflow-list-refresh))

(provide 'octocat-actions)
;;; octocat-actions.el ends here
