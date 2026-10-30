;;; octocat-run.el --- Workflow run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; A GitHub Actions workflow run: `octocat-run-mode', a vui.el page
;; opened from a workflow, the run list or a check.  It shows the run's
;; metadata, its jobs (RET opens one, see octocat-job.el), its artifacts
;; and the annotations of all its jobs.  Also the run list,
;; `octocat-run-list-mode', the first page of the Actions tab.
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-job)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-workflow-open "octocat-workflow" (repo id name path))
(declare-function octocat-run-list      "octocat" (&optional repo))
(declare-function octocat-workflow-list "octocat" (&optional repo))



;;;; Buffer-local declarations

(defvar-local octocat--run-repo nil
  "The \"owner/repo\" this run buffer belongs to.")

(defvar-local octocat--run-id nil
  "The numeric database ID of the run this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-run (repo run-id callback)
  "Fetch detail for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a hash-table of run data (including a \\='jobs\\=' key
whose value is a vector of job hash-tables), or a cons \\=(error . MSG)."
  (octocat--run-gh
   "run-view"
   (list "run" "view"
         (number-to-string run-id)
         "--repo" repo
         "--json" (concat "databaseId,number,displayTitle,status,conclusion,"
                          "createdAt,updatedAt,headBranch,headSha,"
                          "event,workflowName,workflowDatabaseId,jobs"))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))


;;;; Annotations fetching

(defun octocat--fetch-run-annotations (repo jobs callback)
  "Fetch check-run annotations for every job in the JOBS vector from REPO.
Fires one async request per job in parallel.  Calls CALLBACK with a list
of (JOB-ID JOB-NAME ANNOTATIONS-VECTOR) in the order of JOBS, or nil when
JOBS is empty.
Individual job annotation failures are silently treated as empty vectors."
  (let* ((job-list (cl-coerce jobs 'list))
         (pending  (length job-list))
         (results  nil))
    (if (zerop pending)
        (funcall callback nil)
      (dolist (job job-list)
        (let* ((job-id   (gethash "databaseId" job))
               (job-name (or (gethash "name" job) "")))
          (octocat--run-gh
           "run-annotations"
           (list "api"
                 (format "repos/%s/check-runs/%s/annotations?per_page=100"
                         repo (number-to-string job-id)))
           (lambda (output)
             (condition-case nil
                 (let ((parsed (json-parse-string (string-trim output))))
                   (if (vectorp parsed) parsed []))
               (error [])))
           (lambda (ann-result)
             (let ((anns (if (eq (car-safe ann-result) 'error) [] ann-result)))
               (push (list job-id job-name anns) results))
             (cl-decf pending)
             ;; In the jobs' order, not the order their answers came in.
             (when (zerop pending)
               (funcall callback
                        (mapcar (lambda (job) (assq (gethash "databaseId" job) results))
                                job-list))))))))))


;;;; Artifacts fetching

(defun octocat--fetch-run-artifacts (repo run-id callback)
  "Fetch artifacts for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a vector of artifact hash-tables, or \\=[] on failure."
  (octocat--run-gh
   "run-artifacts"
   (list "api"
         (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                 repo (number-to-string run-id)))
   (lambda (output)
     (condition-case nil
         (let ((parsed (json-parse-string (string-trim output))))
           (or (and (hash-table-p parsed)
                    (gethash "artifacts" parsed))
               []))
       (error [])))
   (lambda (result)
     (funcall callback (if (eq (car-safe result) 'error) [] result)))))


;;;; Page

(defun octocat-run--jobs (run)
  "Return the jobs of RUN as a list."
  (let ((v (gethash "jobs" run)))
    (if (vectorp v) (append v nil) nil)))

(defun octocat-run--workflow-crumb (repo run)
  "Return the crumb of RUN's workflow in REPO, for `octocat-vui-actions-header'.
It links to the workflow when RUN names its ID; nil when RUN has no
workflow name."
  (when-let* ((name (octocat--nonempty (gethash "workflowName" run))))
    (let ((id (gethash "workflowDatabaseId" run)))
      (list name
            (and id (lambda () (octocat-workflow-open repo id name nil)))
            "RET: open workflow"))))

(defun octocat-run--label (run-id run)
  "Return the short name of run RUN-ID, its number as \"#42\", in a crumb.
RUN is its data, or nil before it is in; without its number, the ID."
  (let ((number (and run (gethash "number" run))))
    (if (numberp number)
        (propertize (format "#%d" number) 'face 'octocat-pr-number)
      (format "run %s" run-id))))

(defun octocat-run--header (repo run local-branch width)
  "Return the header vnodes of RUN of REPO, kept within WIDTH.
The top row names its workflow, number and title; under it its status
and details.  LOCAL-BRANCH, the checked-out branch, is highlighted when it
is the run's."
  (let* ((status     (downcase (or (gethash "status" run) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" run))))
                       (and c (downcase c))))
         (shown      (or conclusion (octocat--nonempty status) "unknown"))
         (created    (octocat--nonempty (gethash "createdAt" run)))
         (branch     (octocat--nonempty (gethash "headBranch" run)))
         (sha        (octocat--nonempty (gethash "headSha" run))))
    (octocat-vui-actions-header
     repo
     (delq nil (list (octocat-run--workflow-crumb repo run)
                     (list (concat (octocat-run--label (gethash "databaseId" run) run)
                                   "  " (or (gethash "displayTitle" run) "")))))
     width
     (propertize shown 'face (octocat--job-status-face shown))
     (list (list (cons "Event"  (octocat--nonempty (gethash "event" run)))
                 (cons "Branch" (and branch
                                     (propertize branch 'face
                                                 (if (equal branch local-branch)
                                                     'octocat-branch-current
                                                   'octocat-branch))))
                 (cons "SHA"    (and sha (propertize (substring sha 0 (min 7 (length sha)))
                                                     'face 'octocat-pr-number))))
           (list (cons "Run"      (and (gethash "databaseId" run)
                                       (format "%s" (gethash "databaseId" run))))
                 (cons "Created"  (and created (octocat--format-ts-relative created)))
                 (cons "Duration" (and conclusion
                                       (octocat--run-duration
                                        created
                                        (octocat--nonempty (gethash "updatedAt" run))))))))))

(defun octocat-run--job-row (repo run-id job)
  "Return a RET-able row for JOB of run RUN-ID of REPO."
  (let* ((status     (downcase (or (gethash "status" job) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" job))))
                       (and c (downcase c))))
         (duration   (and conclusion
                          (octocat--run-duration
                           (octocat--nonempty (gethash "startedAt" job))
                           (octocat--nonempty (gethash "completedAt" job)))))
         (name       (or (gethash "name" job) "")))
    (octocat-vui-row
     (string-trim-right
      (concat "  " (octocat--run-icon status conclusion) "  "
              (propertize (truncate-string-to-width name 45 nil ?\s "…")
                          'face 'octocat-run-job-name)
              (if duration (propertize (concat "  " duration) 'face 'octocat-dimmed) "")))
     (lambda () (octocat-job-open repo run-id (gethash "databaseId" job) name))
     "RET: open job"
     (octocat--web-url "%s/actions/runs/%s/job/%s" repo run-id (gethash "databaseId" job)))))

(defun octocat-run--jobs-section (repo run-id jobs)
  "Return the vnodes of the Jobs section: JOBS of run RUN-ID of REPO."
  (cons (vui-text (propertize (format "Jobs (%d)" (length jobs))
                              'face 'octocat-section-heading))
        (if (null jobs)
            (list (vui-text "  (no jobs)" :face 'octocat-dimmed))
          (mapcar (lambda (job) (octocat-run--job-row repo run-id job)) jobs))))

(defun octocat-run--annotation-entries (results)
  "Return the RESULTS of `octocat--fetch-run-annotations' as a vector.
Each entry is a hash-table of \"job\", its name, and \"annotations\", a
vector: a shape the store can hold as JSON."
  (vconcat
   (mapcar (lambda (r)
             (let ((h (make-hash-table :test #'equal)))
               (puthash "job" (nth 1 r) h)
               (puthash "annotations" (nth 2 r) h)
               h))
           results)))

(octocat-sync-define-resource run (repo run-id)
  :entity (format "run:%s/%s" (downcase repo) run-id)
  ;; Annotations come as the run's jobs finish.
  :invalidates (lambda () `((runs ,repo _ _) (workflow ,repo _ _)
                            (run-annotations ,repo ,run-id)))
  :poll (lambda (data) (octocat-sync-poll-status (octocat--get data "item" "status")))
  :fetch (lambda (done)
           (octocat--fetch-run
            repo run-id
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat-sync-detail r '("jobs")
                                                   (lambda (f) (octocat-sync-run repo f)))))))))

(octocat-sync-define-resource run-annotations (repo run-id)
  ;; The run's jobs are fetched here, not taken from the page: keyed by
  ;; them, the annotations would vanish whenever the jobs changed.
  :fetch (lambda (done)
           (octocat--fetch-run
            repo run-id
            (lambda (run)
              (if (eq (car-safe run) 'error)
                  (funcall done run)
                (octocat--fetch-run-annotations
                 repo (gethash "jobs" run)
                 (lambda (r) (funcall done (octocat-run--annotation-entries r)))))))))

(octocat-sync-define-resource run-artifacts (repo run-id)
  :fetch (lambda (done) (octocat--fetch-run-artifacts repo run-id done)))

(vui-defcomponent octocat-run--page (repo run-id tick)
  "Workflow run RUN-ID of REPO.
A new TICK refetches everything, keeping what is shown until the fresh
data replaces it."
  :render
  (let* ((local-branch (vui-use-memo () (octocat--current-branch)))
         (width (octocat-vui-window-width))
         (run   (octocat-vui-use-detail (list 'run repo run-id) tick))
         (data  (or (plist-get run :data) (plist-get run :partial)))
         (jobs  (and data (octocat-run--jobs data)))
         (anns  (octocat-vui-use-resource (list 'run-annotations repo run-id) tick))
         (arts  (octocat-vui-use-resource (list 'run-artifacts repo run-id) tick))
         (annotations (cl-loop for entry across (or (plist-get anns :data) [])
                               append (cl-loop for ann across (gethash "annotations" entry)
                                               collect (cons (gethash "job" entry) ann)))))
    (apply
     #'vui-vstack
     (append
      ;; A list's copy of the run gives its header before the jobs come.
      (if data
          (octocat-run--header repo data local-branch width)
        (octocat-vui-actions-header repo (list (list (octocat-run--label run-id nil))) width))
      (list
       (vui-newline)
       (octocat-vui-resource-view
        run
        :skeleton (lambda (_) (vui-text (octocat-vui-line-skeleton "  ")))
        :render
        (lambda (_)
          (apply #'vui-vstack
                 (append (octocat-run--jobs-section repo run-id jobs)
                         (when-let* ((section (octocat-job-artifacts
                                               repo (or (plist-get arts :data) []))))
                           (cons (vui-newline) section))
                         (when-let* ((section (octocat-job-annotations annotations width)))
                           (cons (vui-newline) section)))))))))))


;;;; Major mode

(defun octocat-run--page-url ()
  "Return the URL of this workflow run."
  (and octocat--run-repo octocat--run-id
       (octocat--web-url "%s/actions/runs/%s" octocat--run-repo octocat--run-id)))

(defvar octocat-run-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    map)
  "Keymap for `octocat-run-mode'.")

(define-derived-mode octocat-run-mode vui-mode "Octocat-Run"
  "Major mode for viewing a GitHub Actions workflow run.

\\{octocat-run-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-run-refresh)
  (octocat--ts-eldoc-setup)
  (setq-local octocat--url-function #'octocat-run--page-url))


;;;; Refresh

(defun octocat-run-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run buffer.
The page paints from the sync store at once and fetches the run, its
annotations and artifacts in the background.  A refresh keeps the old
content up until the fresh data arrives, for following a running job."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (octocat-vui-refresh-page 'octocat-run--page octocat--run-id
                            (list :repo octocat--run-repo :run-id octocat--run-id)))

(defun octocat-run-open (repo run-id)
  "Show workflow run RUN-ID of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s run %d*" repo run-id))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-run-mode)
      (octocat-run-mode))
    (setq octocat--run-repo repo
          octocat--run-id   run-id)
    (octocat-run-refresh)))

;;;; Run list
;;
;; `octocat-run-list-mode': a repository's recent runs across all its
;; workflows, as GitHub's Actions tab, filtered by a query.  A tab row
;; under the header leads to the workflow list (octocat-workflow.el),
;; whose workflow pages list their runs with the same section,
;; `octocat-run-list--runs'.

(defcustom octocat-run-list-page-size 30
  "Number of runs the run list and a workflow's page show, and load, at a time."
  :type 'integer
  :group 'octocat)

(defun octocat-run--list-runs (repo limit callback &optional args)
  "Fetch the LIMIT most recent workflow run entries across all workflows in REPO.
ARGS are more `gh run list' options, filtering the runs, such as
\\=(\"--branch\" \"main\").  Call CALLBACK with a list of run hash-tables
\(each including a \\='workflowName\\=' key), or a cons \\=(error . MSG) on
failure."
  (octocat--run-gh
   "recent-runs"
   (append
    (list "run" "list"
          "--repo"  repo
          "--limit" (number-to-string limit)
          "--json"  (concat "databaseId,number,displayTitle,status,conclusion,createdAt,"
                            "headBranch,workflowName,workflowDatabaseId"))
    args)
   #'octocat--parse-json-list
   callback))

(octocat-sync-define-resource runs (repo limit args)
  ;; ARGS are `gh run list' options filtering the runs.
  :fetch (lambda (done)
           (octocat-run--list-runs
            repo limit
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (let ((tree (make-hash-table :test #'equal)))
                                (puthash "nodes"
                                         (vconcat (mapcar (lambda (run) (octocat-sync-run repo run))
                                                          r))
                                         tree)
                                tree))))
            args)))

;;;; Run list filters
;;
;; The runs are filtered by a query of qualifiers, edited as a PR list's
;; (see "List filters" in octocat-vui.el).  `gh run list' takes no search
;; query, only one option per qualifier, so each becomes its option; a
;; repeated qualifier keeps its last value, as gh would.

(defconst octocat-run-list--qualifiers
  '(("branch:"   . "--branch")
    ("status:"   . "--status")
    ("workflow:" . "--workflow")
    ("actor:"    . "--user")
    ("event:"    . "--event")
    ("commit:"   . "--commit"))
  "Run query qualifiers and the `gh run list' option each becomes.")

(defconst octocat-run-list--statuses
  '("success" "failure" "in_progress" "queued" "completed" "cancelled"
    "skipped" "timed_out" "action_required" "waiting" "pending"
    "requested" "neutral" "stale" "startup_failure")
  "Values `gh run list --status' takes, the common ones first.")

(defun octocat-run-list--args (query)
  "Return the `gh run list' options of QUERY, and its other tokens.
That is (ARGS . IGNORED): ARGS a list of options and values, IGNORED the
tokens of QUERY that are no qualifier of `octocat-run-list--qualifiers'."
  (let (opts ignored)
    (dolist (token (octocat-vui-list--tokenize (or query "")))
      (if-let* ((q (seq-find (lambda (q) (string-prefix-p (car q) token))
                             octocat-run-list--qualifiers))
                (value (string-replace "\"" "" (substring token (length (car q)))))
                ((not (string-empty-p value))))
          (setf (alist-get (cdr q) opts nil nil #'equal) value)
        (push token ignored)))
    (cons (mapcan (lambda (o) (list (car o) (cdr o))) (nreverse opts))
          (nreverse ignored))))

(defun octocat-run-list--static-candidates (values)
  "Return a fetch function of `octocat-vui-list--edit-facet' giving VALUES."
  (lambda (_repo callback) (funcall callback values)))

(defun octocat-run-list-filter-branch ()
  "Filter by the branch of a run."
  (interactive)
  (octocat-vui-list--edit-facet "branch:" "Branch" nil #'octocat--list-branches nil))

(defun octocat-run-list-filter-status ()
  "Filter by the status or conclusion of a run."
  (interactive)
  (octocat-vui-list--edit-facet
   "status:" "Status" nil
   (octocat-run-list--static-candidates octocat-run-list--statuses) nil))

(defun octocat-run-list-filter-workflow ()
  "Filter by the workflow of a run."
  (interactive)
  (octocat-vui-list--edit-facet "workflow:" "Workflow" nil
                                (octocat-vui-list--stored
                                 'workflows (lambda (wf) (gethash "name" wf)))
                                nil))

(defun octocat-run-list-filter-actor ()
  "Filter by who triggered a run."
  (interactive)
  (octocat-vui-list--edit-facet "actor:" "Actor" nil #'octocat--list-people nil))

(defun octocat-run-list--filter-setup ()
  "Give the current list buffer the filter of the run list."
  (setq-local octocat-vui-list--states octocat-run-list--statuses
              octocat-vui-list--default-query ""
              octocat-vui-list--qualifiers
              (append (mapcar #'car octocat-run-list--qualifiers)
                      (mapcar (lambda (s) (concat "status:" s))
                              octocat-run-list--statuses)
                      '("event:push" "event:pull_request" "event:schedule"
                        "event:workflow_dispatch"))
              octocat-vui-list--facets
              '(("Branch"   . octocat-run-list-filter-branch)
                ("Status"   . octocat-run-list-filter-status)
                ("Workflow" . octocat-run-list-filter-workflow)
                ("Actor"    . octocat-run-list-filter-actor))))

;;;; Run list page

(defconst octocat-run-list--title-min-width 24
  "Narrowest title column of a run row.")

(defun octocat-run-list--title-width (runs width wf-w &optional branch-w)
  "Return the title column's width, that of the longest title.
The titles are those of RUNS.  It is at least
`octocat-run-list--title-min-width', and at most what WIDTH columns
leave beside the other columns of `octocat-run-list--row', the
workflow name WF-W wide, or none when nil, and the branch BRANCH-W."
  (let ((rest (+ (or branch-w octocat-branch-max-width) 2 11 2 (if wf-w (+ wf-w 2) 0)
                 1 2 2 1
                 (apply #'max 0 (mapcar (lambda (r)
                                          (string-width (octocat--format-ts-relative
                                                         (or (gethash "createdAt" r) ""))))
                                        runs)))))
    (max octocat-run-list--title-min-width
         (min (- width rest)
              (apply #'max 0 (mapcar (lambda (r) (string-width (or (gethash "displayTitle" r) "")))
                                     runs))))))

(defun octocat-run-list--row (repo run current-branch wf-w &optional title-w branch-w)
  "Return a RET-able row for RUN of REPO, laid out as on GitHub.
CURRENT-BRANCH, when non-nil, highlights a matching run branch.  WF-W
is the width to cut or pad the workflow name to, nil for no workflow
column, as on a workflow's own page.  TITLE-W is that of the title,
`octocat-title-width' by default, and BRANCH-W that of the branch,
`octocat-branch-max-width' by default."
  (let* ((run-id     (or (gethash "databaseId" run) 0))
         (status     (downcase (or (gethash "status" run) "")))
         (conclusion (let ((c (gethash "conclusion" run)))
                       (and (octocat--nonempty c) (downcase c))))
         (branch     (or (gethash "headBranch" run) ""))
         (branch-w   (or branch-w octocat-branch-max-width))
         (name       (truncate-string-to-width branch branch-w nil nil "…")))
    (octocat-vui-row
     (propertize
      ;; GitHub's order: what the run is about first, then where.
      (concat
       (octocat--run-icon status conclusion)
       "  "
       (octocat--format-title (or (gethash "displayTitle" run) "") title-w)
       "  "
       (when wf-w
         (concat (propertize (truncate-string-to-width
                              (or (gethash "workflowName" run) "") wf-w nil ?\s "…")
                             'face 'octocat-dimmed)
                 "  "))
       (propertize (format "%-11s" (number-to-string run-id)) 'face 'octocat-pr-number)
       "  "
       (propertize name 'face (if (and current-branch (string= branch current-branch))
                                  'octocat-branch-current
                                'octocat-branch))
       (make-string (- branch-w (string-width name)) ?\s)
       "  "
       (propertize (octocat--format-ts-relative (or (gethash "createdAt" run) ""))
                   'face 'octocat-dimmed))
      'octocat-sync-prefetch `((run ,repo ,run-id) (run-artifacts ,repo ,run-id)))
     (lambda () (octocat-run-open repo run-id))
     "RET: open workflow run"
     (octocat--web-url "%s/actions/runs/%s" repo run-id))))

(vui-defcomponent octocat-run-list--runs (repo current-branch tick query workflow)
  "The recent runs of REPO matching QUERY, laid out as GitHub lists them.
See `octocat-run-list--args' for QUERY.  WORKFLOW, an ID or file
name, keeps to that workflow's runs, as on its own page, and leaves the
workflow column out.  TICK is the page's refresh tick."
  :state ((limit octocat-run-list-page-size))
  :render
  (let* ((size    octocat-run-list-page-size)
         (parsed  (octocat-run-list--args query))
         (args    (append (car parsed)
                          (and workflow (list "--workflow" (format "%s" workflow)))))
         (snap    (octocat-vui-use-resource (list 'runs repo limit args) tick))
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
              (wf-w (cond (workflow nil)
                          (runs (min 25 (apply #'max 1
                                               (mapcar (lambda (r)
                                                         (length
                                                          (or (gethash "workflowName" r) "")))
                                                       runs))))
                          (t 1)))
              (branch-w (octocat--branch-column-width runs "headBranch"))
              (title-w (octocat-run-list--title-width
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
               (octocat-run-list--row
                repo r current-branch wf-w title-w branch-w))
             (lambda (r) (gethash "databaseId" r))))
          (when (and runs (or (>= (length runs) limit)
                              (and loading (> limit size))))
            (octocat-vui-load-more-button
             'load-more-runs size
             "RET: load more runs"
             (lambda () (vui-set-state :limit (+ limit size)))
             (and loading (< (length runs) limit)) 0
             (octocat-vui-line-skeleton)))))))))

(defun octocat-run-list--tab-row (repo current workflows)
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

(vui-defcomponent octocat-run-list--page (repo current-branch tick query)
  "The page of REPO's recent runs, those matching QUERY, filtered above them.
The workflows are fetched too, for the count on their tab.  A new TICK
refetches, keeping what is shown up until the fresh data replaces it."
  :render
  (vui-vstack
   (vui-component 'octocat-vui-list-header :repo repo :tab 'actions :tick tick)
   (octocat-run-list--tab-row repo 'runs
                              (octocat-vui-use-resource (list 'workflows repo) tick))
   (vui-newline)
   (octocat-vui-list-filter-bar query)
   (vui-component 'octocat-run-list--runs
     :key query
     :repo repo :current-branch current-branch :tick tick
     :query query)))

(defun octocat-run-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run list buffer.
The page paints from the sync store at once and fetches the runs in the
background; a refresh keeps the old content up meanwhile."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-run-list--page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo
                                  :current-branch (plist-get (octocat--head-info) :branch)
                                  :query (octocat-vui-list-query))))

(define-derived-mode octocat-run-list-mode octocat-vui-list-mode "Octocat-Runs"
  "Major mode for the list of a repository's recent workflow runs.

\\{octocat-run-list-mode-map}"
  :group 'octocat
  (octocat-run-list--filter-setup)
  (setq-local revert-buffer-function #'octocat-run-list-refresh))

(provide 'octocat-run)
;;; octocat-run.el ends here
