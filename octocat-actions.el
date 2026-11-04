;;; octocat-actions.el --- GitHub Actions and commit checks for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; GitHub Actions, and the checks of a commit, as GitHub shows them:
;;
;;   `octocat-job-mode'           — a job: its steps, folded, with their log,
;;                                  its run's artifacts and its annotations
;;   `octocat-run-mode'           — a workflow run: its jobs, as a table or a
;;                                  graph, its artifacts and annotations
;;   `octocat-run-list-mode'      — the runs, the first page of the Actions tab
;;   `octocat-workflow-mode'      — a workflow and its runs, with a form to run
;;                                  it by hand
;;   `octocat-workflow-list-mode' — the workflows, the Actions tab's second page
;;   `octocat-checks-mode'        — the check-runs of a commit
;;
;; The pages come in that order, each built on the ones before: the run
;; page shows the job page's Artifacts and Annotations sections, and the
;; workflow page the run list's.  `octocat-checks-block' is the Checks
;; section of the PR and commit pages; RET on a GitHub Actions check
;; opens its run.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-mermaid)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list

(declare-function octocat-run-list      "octocat" (&optional repo))
(declare-function octocat-workflow-list "octocat" (&optional repo))


;;;; Jobs
;;
;; A job's metadata comes from the REST API,
;;   gh api repos/OWNER/REPO/actions/jobs/JOB-ID
;; and its log from
;;   gh run view --log --job JOB-ID --repo OWNER/REPO
;; The requests run in parallel.  A log-fetch failure is non-fatal: the
;; steps are shown without log lines, with a note below them.

;;;;; Buffer-local state

(defvar-local octocat--job-repo nil
  "The \"owner/repo\" this job buffer belongs to.")

(defvar-local octocat--job-run-id nil
  "The numeric run ID this job belongs to.")

(defvar-local octocat--job-id nil
  "The numeric database ID of the job this buffer is displaying.")

(defvar-local octocat--job-name nil
  "The display name of the job this buffer is displaying.")


;;;;; Data fetching

(defun octocat--fetch-job (repo run-id job-id callback)
  "Fetch job detail, log, annotations, and artifacts for JOB-ID in REPO.
RUN-ID is the numeric workflow run ID (used for the artifacts request).
Calls CALLBACK asynchronously with a hash-table, which the sync store
can store as JSON, of:
- \"job\", a hash-table from the GitHub REST API.
- \"log\", the raw `gh run view --log' text (see `octocat--job-parse-log'),
  or \"log_error\", the message when the log is unavailable.
- \"annotations\", a vector of annotation hash-tables from the Checks API
  (GET /check-runs/JOB-ID/annotations), \\=[] when unavailable.
- \"artifacts\", a vector of artifact hash-tables from the Actions API
  (GET /actions/runs/RUN-ID/artifacts), \\=[] when unavailable.
A job-metadata failure is fatal and CALLBACK receives \\=(error . MSG)."
  (let ((job-result 'pending)
        (log-result 'pending)
        (ann-result 'pending)
        (art-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq job-result 'pending)
                       (eq log-result 'pending)
                       (eq ann-result 'pending)
                       (eq art-result 'pending))
             ;; Metadata failure aborts the whole view; log/annotation/
             ;; artifact failures are passed through and rendered gracefully.
             (if (eq (car-safe job-result) 'error)
                 (funcall callback job-result)
               (let ((h (make-hash-table :test #'equal)))
                 (puthash "job" job-result h)
                 (if (eq (car-safe log-result) 'error)
                     (puthash "log_error" (cdr log-result) h)
                   (puthash "log" log-result h))
                 (puthash "annotations" ann-result h)
                 (puthash "artifacts" art-result h)
                 (funcall callback h))))))
      (octocat--run-gh
       "job-detail"
       (list "api" (format "repos/%s/actions/jobs/%s" repo
                           (number-to-string job-id)))
       (lambda (output) (json-parse-string (string-trim output)))
       (lambda (result) (setq job-result result) (maybe-done)))
      (octocat--run-gh
       "job-log"
       (list "run" "view"
             "--log"
             "--job" (number-to-string job-id)
             "--repo" repo)
       #'identity
       (lambda (result) (setq log-result result) (maybe-done)))
      (octocat--run-gh
       "job-annotations"
       (list "api"
             (format "repos/%s/check-runs/%s/annotations?per_page=100"
                     repo (number-to-string job-id)))
       (lambda (output)
         (condition-case nil
             (let ((parsed (json-parse-string (string-trim output))))
               (if (vectorp parsed) parsed []))
           (error [])))
       (lambda (result)
         (setq ann-result (if (eq (car-safe result) 'error) [] result))
         (maybe-done)))
      (if (not run-id)
          (progn (setq art-result []) (maybe-done))
        (octocat--run-gh
         "job-artifacts"
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
           (setq art-result (if (eq (car-safe result) 'error) [] result))
           (maybe-done)))))))


;;;;; Log parsing

(defun octocat-job--strip-colors (text)
  "Return TEXT without its ANSI color codes.
The log carries some as escape characters and some spelled out in caret
notation, \"^[[36;1m\"."
  (replace-regexp-in-string "\\^\\[\\[[0-9;]*m" "" (ansi-color-filter-apply text)))

(defun octocat--job-parse-log-line (rest)
  "Parse one raw log REST field (TIMESTAMP MESSAGE) into a tagged entry.
Returns a plist:
  (:ts FORMATTED-TIME :at TIMESTAMP :kind KIND :text CONTENT)
where KIND is one of `normal', `group-start', `group-end', or `command',
and CONTENT is the ANSI-stripped message text.
For `group-start' lines CONTENT is the group name.
For `group-end' lines CONTENT is nil."
  (let* ((rest    (if (string-prefix-p "\uFEFF" rest) ; a step's first line has one
                      (substring rest 1)
                    rest))
         (ts-raw  nil)
         (content nil))
    ;; Third field starts with an ISO-8601 timestamp.
    (if (string-match "^\\([0-9T:.Z-]+\\) \\(.*\\)$" rest)
        (let* ((ts  (match-string 1 rest))
               (msg (match-string 2 rest)))
          (setq ts-raw  ts
                content (octocat-job--strip-colors msg)))
      (setq content (octocat-job--strip-colors rest)))
    (let* ((fmt (when ts-raw
                  (condition-case nil
                      (format-time-string "%H:%M:%S" (date-to-time ts-raw))
                    (error (if (>= (length ts-raw) 19)
                               (substring ts-raw 11 19)
                             ts-raw)))))
           (kind (cond
                  ((string-match "^##\\[group\\]\\(.*\\)$" (or content ""))
                   'group-start)
                  ((string-match "^##\\[endgroup\\]" (or content ""))
                   'group-end)
                  ((string-match "^\\[command\\]" (or content ""))
                   'command)
                  (t 'normal)))
           (text (pcase kind
                   ('group-start (match-string 1 content))
                   ('group-end   nil)
                   (_            content))))
      (list :ts fmt :at ts-raw :kind kind :text text))))

(defun octocat--job-log-step-start-p (bom entry boms)
  "Return non-nil if log ENTRY, BOM if its line had one, may start a step.
Some runners open each step's log with a byte-order mark: when BOMS, the
log is from one, and only those count.  On others a step opens with
\"Run ...\" as a group, or as a post step or the job's end does; that
misses a step whose log opens otherwise, and takes a runner hook's Run
for one, so those are the fallback."
  (if boms
      bom
    (or (and (eq (plist-get entry :kind) 'group-start)
             (string-prefix-p "Run " (or (plist-get entry :text) "")))
        (member (plist-get entry :text)
                '("Post job cleanup." "Cleaning up orphan processes")))))

(defun octocat--job-log-second (timestamp)
  "Return ISO-8601 TIMESTAMP cut to the second, to compare as a string."
  (and timestamp (>= (length timestamp) 19) (substring timestamp 0 19)))

(defun octocat--job-parse-log (raw steps)
  "Split RAW job log text by step.
Return, for STEPS, its REST step hash-tables in order, an alist of
\(STEP-NUMBER . ENTRIES); each entry is a plist from
`octocat--job-parse-log-line'.

RAW is the job's log as one file, as the REST API gives it, or as `gh
run view --log' prints it, each line led by the job's and a step's name.
That name is \"UNKNOWN STEP\" now that GitHub keeps no log per step, so
lines are split at step starts (see `octocat--job-log-step-start-p'),
handed in turn to the steps that ran.  A start counts only once that step
has started, and a step that ended before it never wrote one: so the
\"Run\" groups of a composite action stay in its step."
  (let* ((queue (seq-filter (lambda (step)
                              (and (octocat--nonempty (gethash "started_at" step))
                                   (not (equal (gethash "conclusion" step) "skipped"))))
                            steps))
         ;; Drop the JOB<TAB>STEP<TAB> of `gh run view --log'.
         (raw-lines (mapcar (lambda (line)
                              (if (string-match "\\`\uFEFF?[0-9]\\{4\\}-" line)
                                  line
                                (replace-regexp-in-string "\\`[^\t]*\t[^\t]*\t" "" line)))
                            (split-string (string-trim-right raw) "\n")))
         (boms (seq-some (lambda (line) (string-prefix-p "\uFEFF" line)) (cdr raw-lines)))
         (current (pop queue))
         sections lines)
    (dolist (line raw-lines)
      (let* ((bom   (string-prefix-p "\uFEFF" line))
             (entry (octocat--job-parse-log-line line))
             (at    (octocat--job-log-second (plist-get entry :at))))
        (when (and current lines at queue
                   (octocat--job-log-step-start-p bom entry boms))
          ;; Steps that ended before this start wrote no start of their own.
          (while (and (cdr queue)
                      (let ((end (octocat--job-log-second
                                  (octocat--nonempty (gethash "completed_at" (car queue))))))
                        (and end (string< end at))))
            (pop queue))
          (let ((next (octocat--job-log-second (gethash "started_at" (car queue)))))
            (unless (and next (string< at next))
              (push (cons (gethash "number" current) (nreverse lines)) sections)
              (setq current (pop queue)
                    lines   nil))))
        (when current
          (push entry lines))))
    (when (and current lines)
      (push (cons (gethash "number" current) (nreverse lines)) sections))
    (nreverse sections)))


;;;;; Rendering helpers

(defun octocat--job-step-icon (status conclusion)
  "Return a propertized checkbox icon for a step with STATUS and CONCLUSION.
Uses bracket-checkbox glyphs to distinguish steps from job-level icons."
  (let ((s (or (and (equal status "in_progress") status)
               (octocat--nonempty conclusion)
               status
               "")))
    (cond
     ((equal s "success")
      (propertize "[✓]" 'face 'octocat-ci-success))
     ((member s '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "[✗]" 'face 'octocat-ci-failure))
     ((equal s "in_progress")
      (propertize "[●]" 'face 'octocat-ci-pending))
     ((equal s "skipped")
      (propertize "[-]" 'face 'octocat-dimmed))
     (t
      (propertize "[ ]" 'face 'octocat-dimmed)))))

(defun octocat--job-status-face (status)
  "Return the face for a job STATUS string."
  (cond
   ((equal status "success")
    'octocat-ci-success)
   ((member status '("failure" "timed_out" "startup_failure" "cancelled"))
    'octocat-ci-failure)
   (t 'octocat-ci-pending)))

(defun octocat--annotation-face (level)
  "Return the face for an annotation LEVEL string."
  (cond
   ((equal level "failure") 'octocat-annotation-error)
   ((equal level "warning") 'octocat-annotation-warning)
   (t                       'octocat-annotation-notice)))

(defun octocat--annotation-icon (level)
  "Return a propertized icon for an annotation LEVEL string."
  (cond
   ((equal level "failure") (propertize "✗" 'face 'octocat-annotation-error))
   ((equal level "warning") (propertize "⚠" 'face 'octocat-annotation-warning))
   (t                       (propertize "ℹ" 'face 'octocat-annotation-notice))))

(defun octocat--format-artifact-size (bytes)
  "Format BYTES as a human-readable size string."
  (cond
   ((null bytes)         "")
   ((< bytes 1024)       (format "%d B" bytes))
   ((< bytes 1048576)    (format "%.1f KB" (/ (float bytes) 1024)))
   (t                    (format "%.1f MB" (/ (float bytes) 1048576)))))

;;;;; Log

(defun octocat-job--log-line (entry)
  "Return log ENTRY, a plist from `octocat--job-parse-log-line', as a line.
It is not indented, so the log copies out as it is.  Commands are dimmed.
A line is cut at `octocat--max-line-length', see `octocat--clip-line'."
  (let ((ts   (plist-get entry :ts))
        (text (octocat--clip-line (or (plist-get entry :text) "")
                                  octocat--max-line-length)))
    (concat (if ts (propertize (concat ts " ") 'face 'octocat-dimmed) "")
            (if (eq (plist-get entry :kind) 'command)
                (propertize text 'face 'octocat-dimmed)
              text))))

(defun octocat-job--log-blocks (entries)
  "Return log ENTRIES as a list of blocks.
A block is (text STRING), a run of lines, or (group NAME STRING), the
lines of a ##[group].  An unclosed group ends at the next group or the
end."
  (let (blocks run group-name group)
    (cl-flet ((flush-run ()
                (when run
                  (push (list 'text (string-join (nreverse run) "\n")) blocks)
                  (setq run nil)))
              (flush-group ()
                (when group-name
                  (push (list 'group group-name (string-join (nreverse group) "\n")) blocks)
                  (setq group-name nil group nil))))
      (dolist (entry entries)
        (pcase (plist-get entry :kind)
          ('group-start (flush-run)
                        (flush-group)
                        (setq group-name (or (plist-get entry :text) "")))
          ('group-end   (flush-group))
          (_ (if group-name
                 (push (octocat-job--log-line entry) group)
               (push (octocat-job--log-line entry) run)))))
      (flush-run)
      (flush-group))
    (nreverse blocks)))

(defun octocat-job--log-group (name text index bulk)
  "Return a ##[group] of a step's log: NAME, folded over its TEXT.
INDEX, its position in the step, keys it.  BULK is as for `octocat-vui-fold'."
  (vui-component 'octocat-vui-fold
    :key index
    :bulk bulk
    :header (lambda (open toggle)
              (octocat-vui-fold-header "      " open toggle
                                       (propertize name 'face 'octocat-dimmed)
                                       '("RET: unfold" . "RET: fold")))
    :deps text
    :prepare (lambda ()
               (octocat-vui-text-body
                (if (string-empty-p text)
                    (propertize "(empty)" 'face 'octocat-dimmed)
                  text)))))

(defun octocat-job--step-body (lines bulk)
  "Return the log LINES of a step as the (TOTAL . RENDER) body of a fold.
A group counts as one line, its header; it unfolds on its own, or with
the others by BULK (see `octocat-vui-fold')."
  (let* ((blocks (mapcar (lambda (block)
                           (pcase block
                             (`(text ,text) (list 'text text (octocat-vui-line-ends text)))
                             (_ block)))
                         (octocat-job--log-blocks lines)))
         (total  (apply #'+ (mapcar (lambda (b) (if (eq (car b) 'text) (1+ (length (nth 2 b))) 1))
                                    blocks))))
    (cons total
          (lambda (n)
            (cl-loop for block in blocks
                     for i from 0
                     while (> n 0)
                     collect (pcase block
                               (`(text ,text ,ends)
                                (prog1 (vui-text (octocat-vui-take-lines text ends n))
                                  (cl-decf n (1+ (length ends)))))
                               (`(group ,name ,text)
                                (cl-decf n)
                                (octocat-job--log-group name text i bulk))))))))


;;;;; Steps

(defun octocat-job--step-title (step)
  "Return the heading of STEP, a REST hash-table: icon, name, status, duration."
  (let* ((status     (downcase (or (gethash "status" step) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" step))))
                       (and c (downcase c))))
         (duration   (and conclusion
                          (octocat--run-duration
                           (octocat--nonempty (gethash "started_at" step))
                           (octocat--nonempty (gethash "completed_at" step)))))
         (shown      (or conclusion status)))
    (concat (octocat--job-step-icon status conclusion)
            " "
            (propertize (truncate-string-to-width (or (gethash "name" step) "") 40 nil ?\s "…")
                        'face 'octocat-run-step-name)
            (unless (string-empty-p shown)
              (concat "  " (propertize shown 'face (octocat--job-status-face shown))))
            (when duration
              (propertize (concat "  " duration) 'face 'octocat-dimmed)))))

(defun octocat-job--step (step lines bulk)
  "Return STEP of a job, a REST hash-table, folded over its log LINES.
The log is laid out only once the step is unfolded: a log can be long.
BULK is as for `octocat-vui-fold'."
  (let ((title (octocat-job--step-title step)))
    (if (null lines)
        (vui-text (concat "    " title))
      ;; `octocat-vui-fold', not `vui-collapsible': its toggle button would
      ;; draw the whole title in the `link' face, losing the icon and
      ;; status faces.
      (vui-component 'octocat-vui-fold
        :key (gethash "number" step)
        :bulk bulk
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "  " open toggle title
                                           '("RET: show log" . "RET: hide log")))
        ;; BULK too, for the log groups it unfolds.
        :deps (cons lines bulk)
        :prepare (lambda () (octocat-job--step-body lines bulk))))))

(defun octocat-job--steps (job log bulk on-bulk)
  "Return the vnodes of the section listing each step of JOB.
LOG is the parsed log, as from `octocat--job-parse-log', or \\=(error . MSG).
The heading carries an \"Expand all\" button for the steps and their log
groups: BULK and ON-BULK are as for `octocat-vui-expand-all-button'."
  (let ((steps (let ((v (gethash "steps" job)))
                 (if (vectorp v) (append v nil) nil)))
        (failed (eq (car-safe log) 'error)))
    (append
     (list (if (and steps (not failed))
               (vui-hstack :spacing 2
                           (vui-text (propertize (format "Steps (%d)" (length steps))
                                                 'face 'octocat-section-heading))
                           (octocat-vui-expand-all-button bulk on-bulk))
             (vui-text (propertize (format "Steps (%d)" (length steps))
                                   'face 'octocat-section-heading))))
     (if (null steps)
         (list (vui-text "  (no steps)" :face 'octocat-dimmed))
       (mapcar (lambda (step)
                 (octocat-job--step step
                                    (unless failed
                                      (cdr (assoc (gethash "number" step) log)))
                                    bulk))
               steps))
     (when failed
       (list (vui-text (format "  (log unavailable: %s)" (cdr log)) :face 'octocat-dimmed))))))


;;;;; Artifacts and annotations
;;
;; Shared with the run page.

(defcustom octocat-artifact-preview-max-size (* 20 1024 1024)
  "Largest artifact, in bytes, that RET previews without asking first.
A preview downloads the whole artifact."
  :type 'integer
  :group 'octocat)

(defvar octocat--artifact-preview-dir nil
  "The directory this session unzips previewed artifacts into, or nil.
It is deleted when Emacs exits, and each artifact's directory in it once
no buffer shows it, see `octocat--artifact-cleanup'.")

(defun octocat--artifact-cleanup ()
  "Delete the previewed artifact of the current buffer, unless another is in it.
For `kill-buffer-hook'."
  (let ((root (and octocat--artifact-preview-dir
                   (file-name-as-directory octocat--artifact-preview-dir)))
        (dir  (expand-file-name default-directory)))
    (when (and root (string-prefix-p root dir) (not (equal root dir)))
      (let* ((art   (concat root (car (split-string (substring dir (length root)) "/"))
                            "/"))
             (shown (lambda (b)
                      (and (not (eq b (current-buffer)))
                           (string-prefix-p art (expand-file-name
                                                 (buffer-local-value 'default-directory b)))))))
        (unless (seq-some shown (buffer-list))
          (delete-directory art t))))))

(defun octocat--unzip (zip dir callback)
  "Unzip ZIP into DIR, then delete ZIP.
Calls CALLBACK with nil, or with (error . MESSAGE)."
  (if (not (executable-find "unzip"))
      (progn (delete-file zip)
             (funcall callback '(error . "`unzip' not found")))
    (let ((out (generate-new-buffer " *octocat-unzip*")))
      (make-process
       :name "octocat-unzip"
       :buffer out
       :command (list "unzip" "-o" "-q" zip "-d" dir)
       :sentinel
       (lambda (proc _event)
         (unless (process-live-p proc)
           (let ((ok     (and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc))))
                 (output (with-current-buffer out (string-trim (buffer-string)))))
             (kill-buffer out)
             (delete-file zip)
             (funcall callback (unless ok (cons 'error output))))))))))

(defun octocat--fetch-artifact (repo art dir callback)
  "Download artifact ART of REPO, a hash-table from the Actions API, into DIR.
A zip is unzipped there.  An artifact uploaded as a lone file is not a
zip, though GitHub serves it as one, so `gh run download' fails on it:
it is saved under its name.  Calls CALLBACK with nil, or with
\(error . MESSAGE)."
  ;; Bytes, through a pipe: on a pty `gh' would not print them.
  (let ((coding-system-for-read 'binary)
        (process-connection-type nil))
    (octocat--run-gh
     "artifact-download"
     (list "api" (format "repos/%s/actions/artifacts/%s/zip" repo (gethash "id" art)))
     #'identity
     (lambda (bytes)
       (if (eq (car-safe bytes) 'error)
           (funcall callback bytes)
         (let* ((zip  (string-prefix-p "PK\3\4" bytes))
                (file (if zip
                          (make-temp-file "octocat-artifact-" nil ".zip")
                        (expand-file-name
                         (file-name-nondirectory (or (gethash "name" art) "artifact"))
                         dir)))
                (coding-system-for-write 'no-conversion))
           (make-directory dir t)
           (write-region bytes nil file nil 'silent)
           (if zip
               (octocat--unzip file dir callback)
             (funcall callback nil))))))))

(defun octocat--do-download-artifact (repo art)
  "Download artifact ART (a hash-table) of REPO, asking for a directory."
  (let* ((name (or (gethash "name" art) ""))
         (dir  (read-directory-name
                (format "Download \"%s\" to: " name)
                default-directory)))
    (message "Octocat: Downloading \"%s\"…" name)
    (octocat--fetch-artifact
     repo art dir
     (lambda (result)
       (if (eq (car-safe result) 'error)
           (message "Octocat: Download failed: %s" (cdr result))
         (message "Octocat: Downloaded \"%s\" to %s" name dir))))))

(defconst octocat--artifact-binary-modes
  '(image-mode doc-view-mode doc-view-mode-maybe pdf-view-mode archive-mode tar-mode)
  "Major modes, from `auto-mode-alist', that show a binary file.")

(defun octocat--artifact-shown-p (file)
  "Return non-nil if Emacs can draw FILE as more than raw bytes.
It is text, as git tells it: no NUL in its first 8000 bytes; or its
name picks a mode in `octocat--artifact-binary-modes'."
  (or (not (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file nil 0 8000)
             (search-forward "\0" nil t)))
      (memq (assoc-default (file-name-nondirectory file) auto-mode-alist #'string-match)
            octocat--artifact-binary-modes)))

(defun octocat--artifact-show (dir)
  "Show the files of DIR, an unzipped artifact.
A lone file is visited, asking first if it is binary and Emacs would
show only its bytes; several are listed in Dired."
  (let ((files (directory-files-recursively dir "")))
    (cond
     ((/= (length files) 1)
      (octocat-display-buffer (dired-noselect dir)))
     ((or (octocat--artifact-shown-p (car files))
          (y-or-n-p (format "\"%s\" is binary; show its bytes? "
                            (file-name-nondirectory (car files)))))
      (octocat-display-buffer (find-file-noselect (car files))))
     (t (message "Octocat: Saved to %s" (car files))))))

(defun octocat--do-preview-artifact (repo art)
  "Show artifact ART (a hash-table) of REPO, unzipped.
It is downloaded again only once no buffer shows it, asking first when
it is larger than `octocat-artifact-preview-max-size'."
  (let* ((name (or (gethash "name" art) ""))
         (size (gethash "size_in_bytes" art))
         (buf  (current-buffer)))
    (unless octocat--artifact-preview-dir
      ;; The true name, as a visited file's buffer may show it.
      (setq octocat--artifact-preview-dir
            (file-truename (make-temp-file "octocat-artifacts-" t)))
      (add-hook 'kill-buffer-hook #'octocat--artifact-cleanup)
      (add-hook 'kill-emacs-hook
                (lambda ()
                  (when (file-directory-p octocat--artifact-preview-dir)
                    (delete-directory octocat--artifact-preview-dir t)))))
    (let ((dir (expand-file-name (format "%s" (gethash "id" art))
                                 octocat--artifact-preview-dir)))
      (cond
       ((and (file-directory-p dir) (directory-files-recursively dir ""))
        (octocat--artifact-show dir))
       ((and size (> size octocat-artifact-preview-max-size)
             (not (y-or-n-p (format "Download \"%s\" (%s) to preview it? "
                                    name (octocat--format-artifact-size size)))))
        (message "Octocat: Not previewed"))
       (t
        (message "Octocat: Downloading \"%s\"…" name)
        (octocat--fetch-artifact
         repo art dir
         (lambda (result)
           (cond
            ((eq (car-safe result) 'error)
             (message "Octocat: Download failed: %s" (cdr result)))
            ((octocat--still-selected-p buf)
             (message nil)
             (with-current-buffer buf (octocat--artifact-show dir)))
            (t (message "Octocat: \"%s\" is in %s" name dir))))))))))

(defun octocat--artifact-row (repo art)
  "Return the row of artifact ART of REPO.
RET previews it; \\`d' downloads it to a directory."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")
                (lambda () (interactive) (octocat--do-preview-artifact repo art)))
    (define-key map (kbd "d")
                (lambda () (interactive) (octocat--do-download-artifact repo art)))
    (vui-region :keymap map
                (octocat-vui-row--text
                 (concat "  \U0001f4e6 "
                         (propertize (or (gethash "name" art) "")
                                     'face 'octocat-run-job-name)
                         "  "
                         (propertize (octocat--format-artifact-size
                                      (gethash "size_in_bytes" art))
                                     'face 'octocat-dimmed))
                 "RET: preview artifact, d: download it"
                 nil))))

(defun octocat-job-artifacts (repo artifacts)
  "Return the vnodes of the Artifacts section, or nil when there are none.
ARTIFACTS is a vector from the Actions API of REPO, each a row of
`octocat--artifact-row'."
  (unless (zerop (length artifacts))
    (cons (vui-text (propertize (format "Artifacts (%d)" (length artifacts))
                                'face 'octocat-section-heading))
          (cl-loop for art across artifacts
                   collect (octocat--artifact-row repo art)))))

(defun octocat-job-annotations (entries width)
  "Return the vnodes of the Annotations section, or nil when there are none.
ENTRIES is a list of (JOB-NAME . ANNOTATION), the annotation a Checks API
hash-table; a nil JOB-NAME is not shown.  A message wider than WIDTH
wraps, hung under the job name."
  (when entries
    (cons (vui-text (propertize (format "Annotations (%d)" (length entries))
                                'face 'octocat-section-heading))
          (mapcar (lambda (entry)
                    (let* ((level  (downcase (or (gethash "annotation_level" (cdr entry))
                                                 "notice")))
                           (prefix (concat "  " (octocat--annotation-icon level) "  ")))
                      (vui-text
                          (string-join
                           (octocat-markdown-wrap-hung
                            (concat prefix
                                    (when (car entry)
                                      (concat (propertize (car entry) 'face 'octocat-run-job-name)
                                              "  "))
                                    (propertize (replace-regexp-in-string
                                                 "\n" " " (or (gethash "message" (cdr entry)) ""))
                                                'face (octocat--annotation-face level)))
                            width (string-width prefix))
                           "\n"))))
                  entries))))


(octocat-sync-define-resource job (repo run-id job-id)
  :poll (lambda (data) (octocat-sync-poll-status (octocat--get data "job" "status")))
  :fetch (lambda (done) (octocat--fetch-job repo run-id job-id done)))


;;;;; Page

(defun octocat-job--crumbs (repo run-id run name)
  "Return the crumbs of job NAME of run RUN-ID of REPO, from its workflow.
RUN is the run's data, or nil before it is in; see
`octocat-vui-actions-header'."
  (let ((title (and run (octocat--nonempty (gethash "displayTitle" run)))))
    (delq nil
          (list (and run (octocat-run--workflow-crumb repo run))
                ;; The run's number, not its title, keeps the row short.
                (list (octocat-run--label run-id run)
                      (lambda () (octocat-run-open repo run-id))
                      (if title (concat "RET: open run " title) "RET: open run"))
                (list (propertize name 'face 'octocat-run-job-name))))))

(defun octocat-job--header (repo crumbs job width)
  "Return the header vnodes of JOB of REPO, kept within WIDTH.
The top row is CRUMBS (see `octocat-job--crumbs'); under it the job's
status and details."
  (let* ((status     (downcase (or (gethash "status" job) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" job))))
                       (and c (downcase c))))
         (shown      (or conclusion (octocat--nonempty status) "unknown"))
         (started    (octocat--nonempty (gethash "started_at" job)))
         (completed  (octocat--nonempty (gethash "completed_at" job)))
         (labels     (let ((v (gethash "labels" job)))
                       (and (vectorp v) (> (length v) 0)
                            (mapconcat #'identity v ", ")))))
    (octocat-vui-actions-header
     repo crumbs width
     (propertize shown 'face (octocat--job-status-face shown))
     (list (list (cons "Duration"  (octocat--run-duration started completed))
                 (cons "Started"   (and started (octocat--format-ts-relative started)))
                 (cons "Completed" (and completed (octocat--format-ts-relative completed))))
           (list (cons "Runner"    (octocat--nonempty (gethash "runner_name" job)))
                 (cons "Labels"    (and labels (propertize labels 'face 'octocat-branch))))))))

(vui-defcomponent octocat-job--page (repo run-id job-id name tick)
  "Job JOB-ID of run RUN-ID of REPO; NAME shows while it loads.
A new TICK refetches the job, keeping what is shown, and which steps are
unfolded, until the fresh data replaces it."
  :state ((bulk nil))
  :render
  (let* ((_ (octocat-vui-use-view-reset (vui-async-callback () (vui-set-state :bulk nil))))
         (width   (octocat-vui-window-width))
         (result  (octocat-vui-use-resource (list 'job repo run-id job-id) tick))
         (run     (let ((snap (octocat-vui-use-detail (list 'run repo run-id) tick)))
                    (or (plist-get snap :data) (plist-get snap :partial))))
         (crumbs  (octocat-job--crumbs repo run-id run name))
         (data    (plist-get result :data))
         (raw     (and data (gethash "log" data)))
         (steps   (and data (append (octocat--get data "job" "steps") nil)))
         (log     (vui-use-memo (raw steps)
                    (if raw
                        (octocat--job-parse-log raw steps)
                      (cons 'error (or (and data (gethash "log_error" data)) ""))))))
    (apply #'vui-vstack
           (append
            (if data
                (octocat-job--header repo crumbs (gethash "job" data) width)
              (octocat-vui-actions-header repo crumbs width))
            (list
             (vui-newline)
             (octocat-vui-resource-view
              result
              :skeleton (lambda (_) (vui-text (octocat-vui-line-skeleton "  ")))
              :render
              (lambda (_)
                (let ((job (gethash "job" data)))
                  (apply
                   #'vui-vstack
                   (append (octocat-job--steps job log bulk
                                               (vui-async-callback (v) (vui-set-state :bulk v)))
                           (when-let* ((arts (octocat-job-artifacts
                                              repo (gethash "artifacts" data))))
                             (cons (vui-newline) arts))
                           (when-let* ((anns (octocat-job-annotations
                                              (mapcar (lambda (a) (cons nil a))
                                                      (gethash "annotations" data))
                                              width)))
                             (cons (vui-newline) anns))))))))))))


;;;;; Major mode

(defun octocat-job--page-url ()
  "Return the URL of this job."
  (and octocat--job-repo octocat--job-run-id octocat--job-id
       (octocat--web-url "%s/actions/runs/%s/job/%s"
                         octocat--job-repo octocat--job-run-id octocat--job-id)))

(defvar octocat-job-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    map)
  "Keymap for `octocat-job-mode'.")

(define-derived-mode octocat-job-mode vui-mode "Octocat-Job"
  "Major mode for viewing a GitHub Actions job.

\\{octocat-job-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-job-refresh)
  (octocat--ts-eldoc-setup)
  (setq-local octocat--url-function #'octocat-job--page-url))


;;;;; Refresh

(defun octocat-job-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current job buffer.
The page paints from the sync store at once and fetches the job and its log
in the background.  A refresh keeps the steps unfolded and the old
content up until the fresh data arrives, for following a running job."
  (interactive)
  (unless (and octocat--job-repo octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (octocat-vui-refresh-page 'octocat-job--page octocat--job-id
                            (list :repo octocat--job-repo
                                  :run-id octocat--job-run-id
                                  :job-id octocat--job-id
                                  :name (or octocat--job-name ""))))

(defun octocat-job-open (repo run-id job-id name)
  "Show job JOB-ID of run RUN-ID of REPO in its own buffer; NAME is its name."
  (let ((buf (get-buffer-create (format "*%s job %d*" repo job-id))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-job-mode)
      (octocat-job-mode))
    (setq octocat--job-repo   repo
          octocat--job-run-id run-id
          octocat--job-id     job-id
          octocat--job-name   name)
    (octocat-job-refresh)))


;;;; Runs

;;;;; Buffer-local declarations

(defvar-local octocat--run-repo nil
  "The \"owner/repo\" this run buffer belongs to.")

(defvar-local octocat--run-id nil
  "The numeric database ID of the run this buffer is displaying.")


;;;;; Data fetching

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


;;;;; Annotations fetching

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


;;;;; Artifacts fetching

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


;;;;; Page

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

;;;;; Jobs
;;
;; The jobs show as a graph of what waits for what, as GitHub draws
;; it, or as a table, `C-c C-v'.  GitHub's API doesn't give a job's
;; `needs': the workflow's file is read for it, at the run's commit
;; (`octocat-workflow--yaml-jobs').  A file's job is matched to the
;; run's jobs by its name, which GitHub follows with the matrix's
;; values, as "test (stable)", or the jobs of a reusable workflow, as
;; "deploy / build".

(defun octocat-run--job-steps (job)
  "Return (DONE TOTAL CURRENT FAILED), how far JOB has got.
DONE of its TOTAL steps are done; CURRENT is the name of the step
running, FAILED that of the first that failed; either may be nil."
  (let ((steps (append (gethash "steps" job) nil))
        (is (lambda (key value)
              (lambda (s)
                (and (equal (downcase (or (octocat--nonempty (gethash key s)) "")) value)
                     (gethash "name" s))))))
    (list (cl-count-if (funcall is "status" "completed") steps)
          (length steps)
          (seq-some (funcall is "status" "in_progress") steps)
          (seq-some (funcall is "conclusion" "failure") steps))))

(defun octocat-run--job-status (job)
  "Return (STATUS CONCLUSION DURATION) of JOB, downcased; each may be nil."
  (let ((conclusion (let ((c (octocat--nonempty (gethash "conclusion" job))))
                      (and c (downcase c)))))
    (list (downcase (or (gethash "status" job) ""))
          conclusion
          (and conclusion
               (octocat--run-duration (octocat--nonempty (gethash "startedAt" job))
                                      (octocat--nonempty (gethash "completedAt" job)))))))

(defun octocat-run--job-icon (status conclusion)
  "Return the icon of a job of STATUS and CONCLUSION.
One waiting to start is dimmed, set apart from one running."
  (if (and (member status '("queued" "waiting" "pending" "requested")) (null conclusion))
      (propertize "○" 'face 'octocat-dimmed)
    (octocat--run-icon status conclusion)))

(defun octocat-run--spec-regexp (spec)
  "Return a regexp matching the names of the run's jobs started from SPEC.
SPEC is a job of `octocat-workflow--yaml-jobs'; an expression in its
name, as \"${{ matrix.os }}\", matches anything.  Past a few, only what
comes before the first is matched, so the regexp can't backtrack for
long."
  (let ((parts (split-string (or (gethash "name" spec) (gethash "id" spec))
                             "\\${{[^}]*}}")))
    (if (> (length parts) 4)
        (concat "\\`" (regexp-quote (car parts)))
      (concat "\\`" (mapconcat #'regexp-quote parts ".*") "\\(?: (.*)\\| / .*\\)?\\'"))))

(defun octocat-run--job-edges (jobs specs)
  "Return what JOBS wait for, by SPECS, as edges (FROM TO) of their IDs.
SPECS are the jobs of the workflow's file, see
`octocat-workflow--yaml-jobs'.  A job no spec names waits for nothing."
  (let* ((regexps (mapcar (lambda (s) (cons (octocat-run--spec-regexp s) s)) specs))
         (spec-of (lambda (job)
                    (let ((name (or (gethash "name" job) "")))
                      (or (seq-find (lambda (s)
                                      (equal name (or (gethash "name" s) (gethash "id" s))))
                                    specs)
                          (cdr (seq-find (lambda (r) (string-match-p (car r) name)) regexps))))))
         (owners (mapcar (lambda (job) (cons job (funcall spec-of job))) jobs))
         (by-id (make-hash-table :test #'equal)))
    (pcase-dolist (`(,job . ,spec) (reverse owners))
      (when spec (push job (gethash (gethash "id" spec) by-id))))
    (cl-loop for (job . spec) in owners
             when spec
             append (cl-loop for need across (gethash "needs" spec)
                             append (mapcar (lambda (other)
                                              (list (gethash "databaseId" other)
                                                    (gethash "databaseId" job)))
                                            (gethash need by-id))))))

(defun octocat-run--job-order (jobs edges)
  "Return JOBS with each after those it waits for by EDGES, else in order."
  (let ((waits (make-hash-table :test #'equal))
        (targets (make-hash-table :test #'equal))
        out)
    (dolist (e edges)
      (cl-incf (gethash (nth 1 e) waits 0))
      (push (nth 1 e) (gethash (nth 0 e) targets)))
    (while jobs
      (let ((next (or (seq-find (lambda (job) (zerop (gethash (gethash "databaseId" job) waits 0)))
                                jobs)
                      (car jobs))))
        (dolist (target (gethash (gethash "databaseId" next) targets))
          (cl-decf (gethash target waits 0)))
        (push next out)
        (setq jobs (delq next jobs))))
    (nreverse out)))

(defun octocat-run--job-open (repo run-id job)
  "Return a function opening JOB of run RUN-ID of REPO."
  (lambda () (octocat-job-open repo run-id (gethash "databaseId" job) (gethash "name" job))))

(defun octocat-run--job-url (repo run-id job)
  "Return the web page of JOB of run RUN-ID of REPO."
  (octocat--web-url "%s/actions/runs/%s/job/%s" repo run-id (gethash "databaseId" job)))

(defun octocat-run--job-row (repo run-id job name-width &optional lane)
  "Return the table's RET-able row for JOB of run RUN-ID of REPO.
Its name takes NAME-WIDTH columns.  LANE, from `octocat-vui-lanes', is
drawn first, the job's status icon in its own cell."
  (pcase-let* ((`(,status ,conclusion ,duration) (octocat-run--job-status job))
               (`(,done ,total ,current ,failed) (octocat-run--job-steps job))
               (icon (octocat-run--job-icon status conclusion))
               (name (or (gethash "name" job) ""))
               (note (or current (and (equal conclusion "failure") failed))))
    (octocat-vui-row
     (string-trim-right
      (concat "  "
              (if lane (octocat-vui-lane-text lane icon) icon)
              "  "
              (propertize (truncate-string-to-width name name-width nil ?\s "…")
                          'face 'octocat-run-job-name)
              (propertize (format "  %5s  %6s" (if (> total 0) (format "%d/%d" done total) "")
                                  (or duration ""))
                          'face 'octocat-dimmed)
              (if note (propertize (concat "  " note) 'face 'octocat-dimmed) "")))
     (octocat-run--job-open repo run-id job)
     "RET: open job"
     (octocat-run--job-url repo run-id job))))

(defun octocat-run--table (repo run-id jobs edges)
  "Return the table rows of JOBS of run RUN-ID of REPO, with EDGES beside."
  (let* ((jobs (octocat-run--job-order jobs edges))
         (lanes (and edges (octocat-vui-lanes (mapcar (lambda (j) (gethash "databaseId" j)) jobs)
                                              edges)))
         (name-width (min 45 (apply #'max 1 (mapcar (lambda (j)
                                                      (string-width (or (gethash "name" j) "")))
                                                    jobs)))))
    (cl-loop for job in jobs
             for i from 0
             collect (octocat-run--job-row repo run-id job name-width (nth i lanes)))))

(defun octocat-run--node-parts (job)
  "Return (ICON NAME SUFFIX), the parts of JOB's node in the graph.
SUFFIX is how many of its steps are done while it runs, else how long
it took, or \"\"."
  (pcase-let* ((`(,status ,conclusion ,duration) (octocat-run--job-status job))
               (`(,done ,total) (octocat-run--job-steps job)))
    (list (octocat-run--job-icon status conclusion)
          (propertize (truncate-string-to-width (or (gethash "name" job) "") 30 nil nil "…")
                      'face 'octocat-run-job-name)
          (propertize (cond ((and (equal status "in_progress") (> total 0))
                             (format "%d/%d" done total))
                            (duration)
                            (t ""))
                      'face 'octocat-dimmed))))

(defun octocat-run--graph (jobs edges width)
  "Return JOBS drawn as a graph of EDGES within WIDTH, as a list of lines.
Each node's text has the property `octocat-run-job', its job.  Return
nil if the graph does not fit."
  (octocat-mermaid-graph
   (mapcar (lambda (job)
             (list (gethash "databaseId" job)
                   (propertize (string-trim-right (string-join (octocat-run--node-parts job) " "))
                               'octocat-run-job job)))
           jobs)
   edges width))

(defun octocat-run--graph-line (repo run-id line)
  "Return LINE of `octocat-run--graph' as a vnode, its jobs RET-able.
On a job, RET opens it, of run RUN-ID of REPO, and its name is a TAB
stop."
  (let ((pos 0) parts)
    (while (< pos (length line))
      (let* ((job (get-text-property pos 'octocat-run-job line))
             (next (next-single-property-change pos 'octocat-run-job line (length line))))
        (push (if (not job)
                  (vui-text (substring line pos next))
                (pcase-let ((`(,icon ,name ,suffix) (octocat-run--node-parts job))
                            (open (octocat-run--job-open repo run-id job)))
                  (octocat-vui-row
                   (list icon " "
                         (vui-button name :no-decoration t :face 'octocat-run-job-name
                                     :help-echo "RET: open job" :on-click open)
                         (if (string-empty-p suffix) "" (concat " " suffix)))
                   open "RET: open job" (octocat-run--job-url repo run-id job))))
              parts)
        (setq pos next)))
    (apply #'vui-hstack :spacing 0 (nreverse parts))))

(defun octocat-run--view-tabs (view)
  "Return the pill of the Jobs section's views, the one of VIEW filled in."
  (let ((key (substitute-command-keys "\\[octocat-run-toggle-view]")))
    (octocat-vui-segmented
     (list (list "Table" (eq view 'table)
                 (propertize (format "RET, %s: show the jobs as a table" key) 'octocat-key-help t)
                 #'octocat-run-toggle-view)
           (list "Graph" (eq view 'graph)
                 (propertize (format "RET, %s: show the jobs as a graph" key) 'octocat-key-help t)
                 #'octocat-run-toggle-view)))))

(defun octocat-run--jobs-section (repo run-id jobs specs view width)
  "Return the vnodes of the Jobs section: JOBS of run RUN-ID of REPO.
SPECS are the jobs of the workflow's file, for what each waits for, or
nil.  VIEW is `graph' or `table'; a graph wider than WIDTH shows as the
table."
  (let* ((edges (octocat-run--job-edges jobs specs))
         (lines (and jobs (eq view 'graph) (octocat-run--graph jobs edges width))))
    (append
     (list (vui-hstack :spacing 0
                       (vui-text (propertize (format "Jobs (%d)" (length jobs))
                                             'face 'octocat-section-heading))
                       (and jobs (vui-text "  "))
                       (and jobs (octocat-run--view-tabs view))))
     (cond ((null jobs) (list (vui-text "  (no jobs)" :face 'octocat-dimmed)))
           (lines (mapcar (lambda (line) (octocat-run--graph-line repo run-id line)) lines))
           (t (append (and (eq view 'graph)
                           (list (vui-text "  (too many jobs to draw as a graph)"
                                   :face 'octocat-dimmed)))
                      (octocat-run--table repo run-id jobs edges)))))))

(vui-defcomponent octocat-run--job-specs (repo run-id jobs path sha view width tick)
  "The Jobs section of run RUN-ID of REPO, JOBS by what each waits for.
That is read from the workflow file PATH at SHA.  VIEW, WIDTH and TICK
are the page's."
  :render
  (let ((snap (octocat-vui-use-resource (list 'workflow-jobs repo path sha) tick)))
    (apply #'vui-vstack
           (octocat-run--jobs-section repo run-id jobs
                                      (append (plist-get snap :data) nil)
                                      view width))))

(vui-defcomponent octocat-run--jobs (repo run-id jobs workflow-id sha view width tick)
  "The Jobs section of run RUN-ID of REPO, of workflow WORKFLOW-ID, at SHA.
The workflow is fetched for its file, which says what each of JOBS
waits for.  VIEW, WIDTH and TICK are the page's."
  :render
  (let* ((snap (octocat-vui-use-resource (list 'workflow repo workflow-id) tick))
         (path (let ((data (plist-get snap :data))) (and data (gethash "path" data)))))
    (if (and sha (octocat-workflow--dispatchable-path-p path))
        (vui-component 'octocat-run--job-specs
          :repo repo :run-id run-id :jobs jobs :path path :sha sha
          :view view :width width :tick tick)
      (apply #'vui-vstack (octocat-run--jobs-section repo run-id jobs nil view width)))))

(defun octocat-run--view ()
  "Return the view of the run page's jobs the reader last chose."
  (or (octocat--setting '(run-jobs-view)) 'table))

(defun octocat-run-toggle-view ()
  "Show the run's jobs as a graph, or back as a table.
The choice is remembered for every run."
  (interactive)
  (unless (derived-mode-p 'octocat-run-mode)
    (user-error "Octocat: Not in a run buffer"))
  (let ((view (if (eq (octocat-run--view) 'table) 'graph 'table)))
    (octocat--setting-put '(run-jobs-view) (and (eq view 'graph) view))
    (message "Jobs view: %s" view)
    (octocat-vui-update-page :view view)))

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

(vui-defcomponent octocat-run--page (repo run-id view tick)
  "Workflow run RUN-ID of REPO.
VIEW is how its jobs show, `graph' or `table'.  A new TICK refetches
everything, keeping what is shown until the fresh data replaces it."
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
                 (append (if-let* ((workflow-id (gethash "workflowDatabaseId" data)))
                             (list (vui-component 'octocat-run--jobs
                                     :repo repo :run-id run-id :jobs jobs
                                     :workflow-id workflow-id
                                     :sha (octocat--nonempty (gethash "headSha" data))
                                     :view view :width width :tick tick))
                           (octocat-run--jobs-section repo run-id jobs nil view width))
                         (when-let* ((section (octocat-job-artifacts
                                               repo (or (plist-get arts :data) []))))
                           (cons (vui-newline) section))
                         (when-let* ((section (octocat-job-annotations annotations width)))
                           (cons (vui-newline) section)))))))))))


;;;;; Major mode

(defun octocat-run--page-url ()
  "Return the URL of this workflow run."
  (and octocat--run-repo octocat--run-id
       (octocat--web-url "%s/actions/runs/%s" octocat--run-repo octocat--run-id)))

(defvar octocat-run-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-v") #'octocat-run-toggle-view)
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


;;;;; Refresh

(defun octocat-run-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run buffer.
The page paints from the sync store at once and fetches the run, its
annotations and artifacts in the background.  A refresh keeps the old
content up until the fresh data arrives, for following a running job."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (octocat-vui-refresh-page 'octocat-run--page octocat--run-id
                            (list :repo octocat--run-repo :run-id octocat--run-id
                                  :view (octocat-run--view))))

(defun octocat-run-open (repo run-id)
  "Show workflow run RUN-ID of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s run %d*" repo run-id))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-run-mode)
      (octocat-run-mode))
    (setq octocat--run-repo repo
          octocat--run-id   run-id)
    (octocat-run-refresh)))

;;;;; Run list
;;
;; `octocat-run-list-mode': a repository's recent runs across all its
;; workflows, as GitHub's Actions tab, filtered by a query.  A tab row
;; under the header leads to the workflow list, below,
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

;;;;; Run list filters
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

;;;;; Run list page

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


;;;; Workflows

;;;;; Buffer-local declarations

(defvar-local octocat--workflow-repo nil
  "The \"owner/repo\" this workflow buffer belongs to.")

(defvar-local octocat--workflow-id nil
  "The workflow ID, or its file name, this buffer is displaying.")

(defvar-local octocat--workflow-name nil
  "The display name of the workflow this buffer is displaying.")

(defvar-local octocat--workflow-path nil
  "The workflow file, e.g. \".github/workflows/ci.yml\", or nil.")


;;;;; Data fetching

(defun octocat--fetch-workflow (repo id callback)
  "Fetch workflow ID of REPO asynchronously.
Calls CALLBACK with a hash-table of it, or a cons \\=(error . MSG)."
  (octocat--run-gh
   "workflow-detail"
   (list "api" (format "repos/%s/actions/workflows/%s" repo id))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))


;;;;; Rendering helpers

(defun octocat--workflow-state-face (state)
  "Return the face for workflow STATE string."
  (if (equal state "active") 'success 'octocat-dimmed))

(defun octocat-workflow--url (repo id path)
  "Return the web page of workflow ID of REPO.
GitHub names it by its file, the last part of PATH, when known."
  (octocat--web-url "%s/actions/workflows/%s" repo
                    (if (octocat--nonempty path) (file-name-nondirectory path) id)))


;;;;; Running by hand
;;
;; GitHub's API doesn't say what a `workflow_dispatch' trigger asks:
;; it is read from the workflow's file, at the branch it is to run on.
;; Elisp has no YAML reader, so `octocat-workflow--yaml-parse' reads
;; the little of YAML that triggers are written in, and only the `on'
;; block is given to it.

(defun octocat-workflow--yaml-uncomment (line)
  "Return LINE without its comment and trailing blanks.
A comment starts at a `#' outside quotes, first or after a blank."
  (let ((i 0) (n (length line)) quote end)
    (while (and (< i n) (not end))
      (let ((c (aref line i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((and (eq c ?#) (or (zerop i) (memq (aref line (1- i)) '(?\s ?\t))))
               (setq end i))))
      (setq i (1+ i)))
    (string-trim-right (substring line 0 end))))

(defun octocat-workflow--yaml-item-p (text)
  "Return non-nil if TEXT, a trimmed line, is an item of a block sequence."
  (or (equal text "-") (string-prefix-p "- " text)))

(defun octocat-workflow--yaml-key (text)
  "Return (KEY . REST) if TEXT, a trimmed line, is a mapping entry.
REST is what follows the colon, \"\" when nothing does."
  (when (string-match (concat "\\`\\(\"[^\"]*\"\\|'[^']*'\\|[^\"' ][^:]*?\\)"
                              "[ \t]*:\\(?:[ \t]+\\(.*\\)\\)?\\'")
                      text)
    (cons (octocat-workflow--yaml-scalar (match-string 1 text))
          (or (match-string 2 text) ""))))

(defun octocat-workflow--yaml-split (text)
  "Return TEXT, the inside of a flow collection, split at its top commas."
  (let ((i 0) (start 0) (depth 0) quote parts)
    (while (< i (length text))
      (let ((c (aref text i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((memq c '(?\[ ?\{)) (setq depth (1+ depth)))
              ((memq c '(?\] ?\})) (setq depth (1- depth)))
              ((and (eq c ?,) (zerop depth))
               (push (substring text start i) parts)
               (setq start (1+ i)))))
      (setq i (1+ i)))
    (push (substring text start) parts)
    (seq-remove #'string-empty-p (mapcar #'string-trim (nreverse parts)))))

(defun octocat-workflow--yaml-scalar (text)
  "Return TEXT, a value on one line, as `octocat-workflow--yaml-parse' does."
  (cond
   ((member text '("" "~" "null" "Null" "NULL")) nil)
   ((string-match "\\`\"\\(.*\\)\"\\'" text)
    (condition-case nil (read text) (error (match-string 1 text))))
   ((string-match "\\`'\\(.*\\)'\\'" text)
    (string-replace "''" "'" (match-string 1 text)))
   ((string-match "\\`\\[\\(.*\\)\\]\\'" text)
    (vconcat (mapcar #'octocat-workflow--yaml-scalar
                     (octocat-workflow--yaml-split (match-string 1 text)))))
   ((string-match "\\`{\\(.*\\)}\\'" text)
    (delq nil (mapcar (lambda (part)
                        (when-let* ((pair (octocat-workflow--yaml-key part)))
                          (cons (car pair) (octocat-workflow--yaml-scalar (cdr pair)))))
                      (octocat-workflow--yaml-split (match-string 1 text)))))
   (t text)))

(defun octocat-workflow--yaml-parse (text)
  "Return TEXT, YAML, as Lisp.
A mapping is an alist of (KEY . VALUE), in order, a sequence a vector,
a scalar a string, and an empty value nil.  It reads block mappings
and sequences, flow ones on one line, quoted and plain scalars and
block scalars (`|', `>'): what triggers are written in.  Anchors, tags
and values over several lines otherwise are not read."
  (let* ((lines (vconcat
                 (mapcar (lambda (raw)
                           (let ((s (octocat-workflow--yaml-uncomment raw)))
                             ;; (INDENT TEXT RAW); INDENT nil for a blank line
                             (list (and (not (string-blank-p s))
                                        (- (length s) (length (string-trim-left s))))
                                   (string-trim s) raw)))
                         (split-string text "\n"))))
         (i 0))
    (cl-labels
        ((indent ()
           (while (and (< i (length lines)) (null (car (aref lines i))))
             (setq i (1+ i)))
           (and (< i (length lines)) (car (aref lines i))))
         (line () (nth 1 (aref lines i)))
         (node (min)
           (let ((ind (indent)))
             (cond ((or (null ind) (< ind min)) nil)
                   ((octocat-workflow--yaml-item-p (line)) (items ind))
                   (t (pairs ind)))))
         (items (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-workflow--yaml-item-p (line)))
               (let ((rest (string-trim-left (substring (line) 1))))
                 (cond ((string-empty-p rest)
                        (setq i (1+ i))
                        (push (node (1+ ind)) out))
                       ((octocat-workflow--yaml-key rest)
                        ;; "- key: value" starts a mapping at key's column.
                        (aset lines i (list (+ ind (- (length (line)) (length rest))) rest nil))
                        (push (pairs (car (aref lines i))) out))
                       (t (setq i (1+ i))
                          (push (octocat-workflow--yaml-scalar rest) out)))))
             (vconcat (nreverse out))))
         (pairs (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-workflow--yaml-key (line)))
               (pcase-let ((`(,key . ,rest) (octocat-workflow--yaml-key (line))))
                 (setq i (1+ i))
                 (push (cons key
                             (cond ((string-match-p "\\`[|>][-+0-9]*\\'" rest)
                                    (block ind (eq (aref rest 0) ?>)))
                                   ((not (string-empty-p rest))
                                    (octocat-workflow--yaml-scalar rest))
                                   ;; A sequence may sit at its key's indent.
                                   ((and (eql (indent) ind)
                                         (octocat-workflow--yaml-item-p (line)))
                                    (items ind))
                                   (t (node (1+ ind)))))
                       out)))
             (nreverse out)))
         (block (ind folded)
           (let (raws)
             (while (and (< i (length lines))
                         (let ((raw (nth 2 (aref lines i))))
                           (and raw (or (string-blank-p raw)
                                        (> (- (length raw) (length (string-trim-left raw)))
                                           ind)))))
               (push (nth 2 (aref lines i)) raws)
               (setq i (1+ i)))
             (let* ((raws (nreverse raws))
                    (cut  (apply #'min most-positive-fixnum
                                 (mapcar (lambda (r) (- (length r) (length (string-trim-left r))))
                                         (seq-remove #'string-blank-p raws)))))
               (string-trim-right
                (string-join (mapcar (lambda (r) (if (string-blank-p r) "" (substring r cut)))
                                     raws)
                             (if folded " " "\n")))))))
      (node 0))))

(defun octocat-workflow--yaml-on (yaml)
  "Return the triggers of workflow file YAML, its `on' value, as Lisp.
Only the `on' block is read, so what the jobs are written in does not
matter.  YAML 1.1 reads a bare `on' as true, so `true' is taken too."
  (let ((lines (split-string yaml "\n")) block)
    (while (and lines (not (string-match-p "\\`\\(on\\|\"on\"\\|'on'\\|true\\)[ \t]*:"
                                           (car lines))))
      (setq lines (cdr lines)))
    (when lines
      (push (car lines) block)
      (setq lines (cdr lines))
      (while (and lines (let ((l (octocat-workflow--yaml-uncomment (car lines))))
                          (or (string-empty-p l) (memq (aref l 0) '(?\s ?\t ?-)))))
        (push (car lines) block)
        (setq lines (cdr lines)))
      (cdar (octocat-workflow--yaml-parse (string-join (nreverse block) "\n"))))))

(defun octocat-workflow--dispatch-spec (yaml)
  "Return what running workflow file YAML by hand asks, as a hash-table.
\"dispatch\" is t when it has a `workflow_dispatch' trigger, else
`:false', and \"inputs\" a vector of its inputs, each with its
\"name\", \"type\", \"required\" (t or `:false'), \"options\" and,
when given, \"description\" and \"default\", strings."
  (let* ((on       (octocat-workflow--yaml-on yaml))
         (trigger  (cond ((stringp on) (and (equal on "workflow_dispatch") (list on)))
                         ((vectorp on) (and (seq-contains-p on "workflow_dispatch") (list on)))
                         ((consp on)   (assoc "workflow_dispatch" on))))
         (inputs   (let ((v (cdr trigger))) (and (consp v) (cdr (assoc "inputs" v)))))
         (spec     (make-hash-table :test #'equal)))
    (puthash "dispatch" (if trigger t :false) spec)
    (puthash "inputs"
             (vconcat
              (mapcar (pcase-lambda (`(,name . ,props))
                        (let ((in  (make-hash-table :test #'equal))
                              (get (lambda (k) (and (consp props) (cdr (assoc k props))))))
                          (puthash "name" name in)
                          (puthash "type" (or (funcall get "type") "string") in)
                          (puthash "required"
                                   (if (member (funcall get "required") '("true" "True" "TRUE"))
                                       t :false)
                                   in)
                          (puthash "options" (vconcat (funcall get "options")) in)
                          (dolist (k '("description" "default"))
                            (when (stringp (funcall get k))
                              (puthash k (funcall get k) in)))
                          in))
                      (and (consp inputs) inputs)))
             spec)
    spec))

;;;;; Jobs and their needs
;;
;; GitHub's API doesn't say which jobs of a run wait for which: their
;; `needs' is read from the workflow's file, at the run's commit, for
;; the run page's job graph (see "Jobs" under "Runs").

(defconst octocat-workflow--max-file-size (* 512 1024)
  "The longest workflow file read for its jobs; a longer one has none.")

(defun octocat-workflow--yaml-jobs (yaml)
  "Return the jobs of workflow file YAML as a vector of hash-tables.
Each has the job's \"id\", its \"name\" when it has one, and \"needs\",
a vector of the ids of the jobs it waits for.  Only those two keys of
each job are given to `octocat-workflow--yaml-parse', so what its steps
are written in does not matter.  A file longer than
`octocat-workflow--max-file-size' is not read."
  (let* ((lines (and (<= (length yaml) octocat-workflow--max-file-size)
                     (mapcar (lambda (l) (string-trim-right l "[ \t\r]+"))
                             (split-string yaml "\n"))))
         (indent (lambda (l) (- (length l) (length (string-trim-left l)))))
         (blank-p (lambda (l) (string-empty-p (octocat-workflow--yaml-uncomment l))))
         jobs)
    (while (and lines (not (string-match-p "\\`jobs[ \t]*:[ \t]*\\(#.*\\)?\\'" (car lines))))
      (setq lines (cdr lines)))
    (setq lines (cdr lines))
    ;; The jobs' block: what follows `jobs:', up to the next top-level key.
    (let* ((block (cl-loop for l in lines
                           until (and (not (funcall blank-p l)) (zerop (funcall indent l)))
                           unless (funcall blank-p l) collect l))
           (job-ind (and block (funcall indent (car block)))))
      (while block
        (let ((id (car (octocat-workflow--yaml-key (string-trim (car block)))))
              body)
          (setq block (cdr block))
          (while (and block (> (funcall indent (car block)) job-ind))
            (push (car block) body)
            (setq block (cdr block)))
          (setq body (nreverse body))
          (when (stringp id)
            (let* ((key-ind (and body (funcall indent (car body))))
                   (kept (cl-loop with keep = nil
                                  for l in body
                                  for ind = (funcall indent l)
                                  do (when (= ind key-ind)
                                       (setq keep (string-match-p
                                                   "\\`\\(name\\|needs\\)[ \t]*:"
                                                   (string-trim-left l))))
                                  when keep collect (substring l (min key-ind (length l)))))
                   (props (and kept (octocat-workflow--yaml-parse (string-join kept "\n"))))
                   (needs (cdr (assoc "needs" props)))
                   (name (cdr (assoc "name" props)))
                   (job (make-hash-table :test #'equal)))
              (puthash "id" id job)
              (when (stringp name) (puthash "name" name job))
              (puthash "needs" (vconcat (seq-filter #'stringp (if (stringp needs)
                                                                  (list needs)
                                                                (append needs nil))))
                       job)
              (push job jobs))))))
    (vconcat (nreverse jobs))))

(octocat-sync-define-resource workflow-jobs (repo path sha)
  ;; A file at a commit never changes.
  :max-age (* 30 24 60 60)
  :fetch (lambda (done)
           (octocat--run-gh
            "workflow-file"
            (list "api" "-X" "GET"
                  (format "repos/%s/contents/%s" repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
                  "-f" (concat "ref=" sha)
                  "-H" "Accept: application/vnd.github.raw")
            #'octocat-workflow--yaml-jobs
            done)))

(defun octocat-workflow--dispatchable-path-p (path)
  "Return non-nil if PATH is a workflow file, which can be run by hand.
Not one of GitHub's own, such as \"dynamic/pages/pages-build-deployment\"."
  (and (stringp path) (string-prefix-p ".github/workflows/" path)))

(octocat-sync-define-resource workflow-dispatch (repo path ref)
  :max-age 300
  :poll 300
  :fetch (lambda (done)
           (octocat--run-gh
            "workflow-file"
            (list "api" "-X" "GET"
                  (format "repos/%s/contents/%s" repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
                  "-f" (concat "ref=" ref)
                  "-H" "Accept: application/vnd.github.raw")
            #'octocat-workflow--dispatch-spec
            done)))

(defun octocat-workflow--input-default (input)
  "Return the first value of INPUT in the form, as GitHub's: a string."
  (or (gethash "default" input)
      (pcase (gethash "type" input)
        ("boolean" "false")
        ("choice"  (let ((options (gethash "options" input)))
                     (if (> (length options) 0) (aref options 0) "")))
        (_ ""))))

(defun octocat-workflow--input-values (inputs values)
  "Return the value of each of INPUTS, as an alist (NAME . STRING).
VALUES, an alist of the same, has those the user set; the others are
their defaults."
  (mapcar (lambda (in)
            (let ((name (gethash "name" in)))
              (cons name (or (cdr (assoc name values))
                             (octocat-workflow--input-default in)))))
          inputs))

(defun octocat-workflow--input-errors (inputs values)
  "Return what is wrong with VALUES of INPUTS, an alist (NAME . MESSAGE).
VALUES is as `octocat-workflow--input-values' returns.  GitHub refuses
a run missing a required input, a number that is none, or a choice not
among the options."
  (delq nil
        (mapcar (lambda (in)
                  (let* ((name  (gethash "name" in))
                         (value (or (cdr (assoc name values)) ""))
                         (blank (string-blank-p value)))
                    (cond
                     ((and blank (eq (gethash "required" in) t)) (cons name "required"))
                     ((and (not blank) (equal (gethash "type" in) "number")
                           (not (string-match-p
                                 (concat "\\`[-+]?\\([0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)"
                                         "\\([eE][-+]?[0-9]+\\)?\\'")
                                 (string-trim value))))
                      (cons name "not a number"))
                     ((and (equal (gethash "type" in) "choice")
                           (not (seq-contains-p (gethash "options" in) value)))
                      (cons name "not one of the options")))))
                inputs)))

(defun octocat-workflow--input-label (input &optional width)
  "Return the label of INPUT: its description's first line, or its name.
A required one is marked `*', as on GitHub.  With WIDTH, the text is
cut to keep the label within it, the mark kept."
  (let ((text (car (split-string (or (octocat--nonempty (gethash "description" input))
                                     (gethash "name" input))
                                 "\n")))
        (mark (if (eq (gethash "required" input) t) (propertize " *" 'face 'error) "")))
    (concat (if width (octocat-vui--fit text (- width (string-width mark))) text)
            mark)))

(defun octocat-workflow--parse-dispatched (output)
  "Return the ID of the run GitHub started, from OUTPUT, or nil.
Asked for with `return_run_details'; a GitHub without it answers with
nothing."
  (let ((text (string-trim output)))
    (and (not (string-empty-p text))
         (octocat--get (json-parse-string text) "workflow_run_id"))))

(octocat-sync-define-mutation dispatch-workflow (repo id ref inputs)
  :label "Starting workflow…"
  :slot 'dispatch
  :resources (lambda () `((workflow ,repo ,id)))
  :send (lambda (done)
          (octocat--run-gh "workflow-dispatch"
                           (append (list "api" "--method" "POST"
                                         (format "repos/%s/actions/workflows/%s/dispatches"
                                                 repo id)
                                         "-f" (concat "ref=" ref)
                                         "-F" "return_run_details=true")
                                   (mapcan (pcase-lambda (`(,name . ,value))
                                             (list "-f" (format "inputs[%s]=%s" name value)))
                                           inputs))
                           #'octocat-workflow--parse-dispatched done))
  :invalidates (lambda () `((runs ,repo _ _))))

(defun octocat-workflow--input-control (input value on-change on-submit)
  "Return the control of INPUT showing VALUE, a string.
ON-CHANGE is called with each new value; ON-SUBMIT runs on RET in a
text field."
  (let ((name (gethash "name" input)))
    (pcase (gethash "type" input)
      ("boolean" (vui-checkbox :key (list 'input name)
                               :checked (equal value "true")
                               :on-change (lambda (v) (funcall on-change (if v "true" "false")))))
      ("choice"  (vui-select :key (list 'input name)
                             :value value
                             :options (append (gethash "options" input) nil)
                             :prompt (format "%s: " name)
                             :on-change on-change))
      (_ (vui-field :key (list 'input name)
                    :value value
                    :size 30
                    :face 'octocat-filter-input
                    :on-change on-change
                    :on-submit (lambda (_) (funcall on-submit)))))))

(vui-defcomponent octocat-workflow--dispatch (repo id path default-branch local busy tick)
  "The \"Run workflow\" button of workflow ID of REPO, and its form.
PATH is the workflow's file, read at DEFAULT-BRANCH, or at the branch
picked, for its `workflow_dispatch' inputs; LOCAL is the clone's branch,
for the picker.  The form slides out under the button, as GitHub's
drops down, and closes as the run is sent.  BUSY is the label of the
run being started, shown in the button's place.  TICK is the page's."
  :state ((open nil) (shown 0) (ref nil) (values nil) (tried nil))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :open nil)
               (vui-set-state :shown 0))))
         (buf    (current-buffer))
         (shown-ref (or ref default-branch))
         (snap   (octocat-vui-use-resource (list 'workflow-dispatch repo path shown-ref) tick))
         (spec   (plist-get snap :data))
         (inputs (and spec (append (gethash "inputs" spec) nil)))
         (dispatch (and spec (eq (gethash "dispatch" spec) t)))
         (current (octocat-workflow--input-values inputs values))
         (errors (and tried (octocat-workflow--input-errors inputs current)))
         (set-state (vui-async-callback (key value) (vui-set-state key value)))
         (set-value (vui-async-callback (name value)
                      (vui-set-state :values
                                     (lambda (vs) (cons (cons name value)
                                                        (assoc-delete-all name (copy-alist vs)))))))
         (toggle (vui-async-callback () (vui-set-state :open (not open))))
         (run
          (vui-async-callback ()
            (cond
             ((not dispatch) (user-error "Octocat: No workflow_dispatch trigger on %s" shown-ref))
             ((octocat-workflow--input-errors inputs current)
              (vui-set-state :tried t)
              (message "Octocat: Fill in the inputs marked"))
             (t
              ;; Closed at once: the run is shown under way in the
              ;; button's place, and the form comes back if it fails.
              (vui-set-state :open nil)
              (vui-set-state :shown 0)
              (vui-set-state :tried nil)
              (octocat-sync-submit
               `(dispatch-workflow ,repo ,id ,shown-ref ,current)
               (lambda (result)
                 (cond
                  ((eq (car-safe result) 'error)
                   (funcall set-state :open t))
                  (t
                   (funcall set-state :values nil)
                   (cond ((and result (octocat--still-selected-p buf))
                          (with-current-buffer buf (octocat-run-open repo result)))
                         ((not result)
                          (message "Octocat: Workflow started on %s" shown-ref)))))))))))
         (pick-ref
          (lambda ()
            (let ((picked (octocat--read-branch repo default-branch local shown-ref)))
              (funcall set-state :ref (unless (equal picked default-branch) picked)))))
         (label-w (min 40 (apply #'max (string-width "Use workflow from")
                                 (mapcar (lambda (in) (string-width
                                                       (octocat-workflow--input-label in)))
                                         inputs))))
         (label   (lambda (text)
                    (vui-text (concat "  " (string-pad text label-w) "  "))))
         (rows
          (append
           (list (vui-hstack :spacing 0
                             (funcall label "Use workflow from")
                             (vui-button (format "%s ▾" shown-ref)
                               :key 'dispatch-ref
                               :help-echo "RET: pick the branch to run the workflow from"
                               :on-click pick-ref)))
           (cond
            ((eq (octocat-vui-snapshot-status snap) 'error)
             (list (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error)))
            ((not spec) (list (vui-text (octocat-vui-line-skeleton))))
            ((not dispatch)
             (list (vui-text (format "  No workflow_dispatch trigger on %s" shown-ref)
                     :face 'octocat-dimmed)))
            (t
             (mapcar (lambda (in)
                       (let* ((name  (gethash "name" in))
                              (error (cdr (assoc name errors))))
                         (vui-hstack :spacing 0
                                     (funcall label (octocat-workflow--input-label in label-w))
                                     (octocat-workflow--input-control
                                      in (cdr (assoc name current))
                                      (lambda (v) (funcall set-value name v))
                                      run)
                                     (and error (vui-text (concat "  " error) :face 'error)))))
                     inputs)))
           (list (vui-hstack :spacing 2
                             (vui-text (make-string (+ label-w 2) ?\s))
                             (vui-button "Run workflow"
                               :key 'dispatch-run
                               :face 'success
                               :disabled (not dispatch)
                               :help-echo "RET: start the workflow"
                               :on-click run)
                             (vui-button "Cancel"
                               :key 'dispatch-cancel
                               :face 'octocat-dimmed
                               :help-echo "RET: close without running"
                               :on-click toggle)))))
         (now (octocat-vui-use-unfold shown open (length rows))))
    ;; No button until the file is known to have the trigger: on another
    ;; branch it may lack one, and the form says so.
    (when (or busy open (> now 0) ref dispatch)
      (apply #'vui-vstack
             (vui-hstack :spacing 2
                         (vui-text "This workflow has a workflow_dispatch event trigger."
                           :face 'octocat-dimmed)
                         (if busy
                             (vui-text (concat (octocat-vui-spinner) " " busy) :face 'bold)
                           (vui-button (if open "Run workflow ▴" "Run workflow ▾")
                             :key 'dispatch-toggle
                             :help-echo (if open
                                            "RET: close the form"
                                          "RET: run the workflow by hand")
                             :on-click toggle)))
             (append (seq-take rows now) (list (vui-newline)))))))

;;;;; Page

(defun octocat-workflow--header (repo workflow width)
  "Return the header vnodes of WORKFLOW of REPO, kept within WIDTH.
The top row names it; under it its state, file and dates."
  (let ((state   (or (octocat--nonempty (downcase (or (gethash "state" workflow) "")))
                     "unknown"))
        (created (octocat--nonempty (gethash "created_at" workflow)))
        (updated (octocat--nonempty (gethash "updated_at" workflow))))
    (octocat-vui-actions-header
     repo
     (list (list (or (gethash "name" workflow) "")))
     width
     (propertize state 'face (octocat--workflow-state-face state))
     (list (list (cons nil (let ((path (octocat--nonempty (gethash "path" workflow))))
                             (and path (propertize path 'face 'octocat-branch))))
                 (cons "Created" (and created (octocat--format-ts-relative created)))
                 (cons "Updated" (and updated (octocat--format-ts-relative updated))))))))


(octocat-sync-define-resource workflow (repo id)
  :fetch (lambda (done) (octocat--fetch-workflow repo id done)))

(vui-defcomponent octocat-workflow--page (repo id name path tick)
  "Workflow ID of REPO and its runs, as the run list shows them.
NAME shows while it loads, and PATH, its file or nil, stands in for
the fetched one meanwhile.  A new TICK fetches them again."
  :render
  (let* ((width (octocat-vui-window-width))
         (local-branch (vui-use-memo () (octocat--current-branch)))
         (snap  (octocat-vui-use-resource (list 'workflow repo id) tick))
         (data  (plist-get snap :data))
         (summary (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick) :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (file  (or (and data (gethash "path" data)) path)))
    (apply #'vui-vstack
           (append
            (if data
                (octocat-workflow--header repo data width)
              (octocat-vui-actions-header repo (list (list name)) width))
            (list
             (vui-newline)
             (and data default-branch
                  (equal (gethash "state" data) "active")
                  (octocat-workflow--dispatchable-path-p file)
                  (vui-component 'octocat-workflow--dispatch
                    :key 'dispatch
                    :repo repo :id id :path file
                    :default-branch default-branch :local local-branch
                    :busy (alist-get 'dispatch (plist-get snap :mutating))
                    :tick tick))
             (octocat-vui-section-heading "Runs" width)
             (if (eq (octocat-vui-snapshot-status snap) 'error)
                 (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error)
               (vui-component 'octocat-run-list--runs
                 :repo repo
                 :current-branch local-branch
                 :tick tick :query "" :workflow id)))))))


;;;;; Major mode

(defun octocat-workflow--page-url ()
  "Return the URL of this workflow."
  (and octocat--workflow-repo octocat--workflow-id
       (octocat-workflow--url octocat--workflow-repo octocat--workflow-id
                              octocat--workflow-path)))

(defvar octocat-workflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    map)
  "Keymap for `octocat-workflow-mode'.")

(define-derived-mode octocat-workflow-mode vui-mode "Octocat-Workflow"
  "Major mode for viewing a GitHub Actions Workflow.

\\{octocat-workflow-mode-map}"
  :group 'octocat
  ;; Not read-only, so the run form's fields can be edited; see
  ;; `octocat-vui-list-mode'.
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-workflow-refresh)
  (add-hook 'post-command-hook #'octocat-vui--prefetch-schedule nil t)
  (octocat--ts-eldoc-setup)
  (setq-local octocat--url-function #'octocat-workflow--page-url))


;;;;; Refresh

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
                                  :name (or octocat--workflow-name "")
                                  :path octocat--workflow-path)))

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

;;;;; Workflow list
;;
;; `octocat-workflow-list-mode': a repository's workflows and whether
;; each is enabled, the second page of the Actions tab (see the run list
;; above).

(defun octocat-workflow--list (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(octocat-sync-define-resource workflows (repo)
  :fetch (lambda (done)
           (octocat-workflow--list
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(defun octocat-workflow--state (workflow)
  "Return the state of WORKFLOW as shown on its row, such as \"active\"."
  (downcase (or (gethash "state" workflow) "")))

(defun octocat-workflow--file (workflow)
  "Return the file name of WORKFLOW, such as \"test.yml\"."
  (file-name-nondirectory (or (gethash "path" workflow) "")))

(defun octocat-workflow-list--name-width (workflows width state-w)
  "Return the width of the name column of WORKFLOWS: the longest name.
It is at most what WIDTH columns leave beside the STATE-W wide state and
the longest file name, but cuts no name shorter than 10."
  (let ((longest (lambda (f) (apply #'max 0 (mapcar (lambda (wf) (string-width (funcall f wf)))
                                                    workflows)))))
    (min (funcall longest (lambda (wf) (or (gethash "name" wf) "")))
         (max 10 (- width 1 state-w 2 2
                    (funcall longest #'octocat-workflow--file))))))

(defun octocat-workflow-list--row (repo workflow &optional state-w name-w)
  "Return a row vnode for WORKFLOW in REPO: its state, name and file name.
The state is padded to STATE-W columns and the name to NAME-W, cut to
it when longer (40 by default), so the columns line up."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (octocat-workflow--state workflow))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
           (propertize (string-pad state (max (or state-w 0) (string-width state)))
                       'face state-face)
           "  "
           (truncate-string-to-width name (or name-w 40) nil ?\s "…")
           "  "
           (propertize (octocat-workflow--file workflow) 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-workflow-open repo (gethash "id" workflow) name
                                                       (gethash "path" workflow)))
                     "RET: open workflow"
                     (octocat-workflow--url repo (gethash "id" workflow)
                                            (gethash "path" workflow)))))

(defun octocat-workflow-list--workflows (repo snap)
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
                                                 (octocat-workflow--state wf)))
                                              workflows)))
                (name-w  (octocat-workflow-list--name-width
                          workflows (octocat-vui-window-width) state-w)))
           (vui-list workflows
                     (lambda (wf) (octocat-workflow-list--row repo wf state-w name-w))
                     (lambda (wf) (gethash "id" wf)))))))))

(vui-defcomponent octocat-workflow-list--page (repo tick)
  "The page of REPO's workflows.
Stored, they show at once; a new TICK refetches them, keeping what is
shown up until the fresh data replaces it."
  :render
  (let ((workflows (octocat-vui-use-resource (list 'workflows repo) tick)))
    (vui-vstack
     (vui-component 'octocat-vui-list-header :repo repo :tab 'actions :tick tick)
     (octocat-run-list--tab-row repo 'workflows workflows)
     (vui-newline)
     (octocat-workflow-list--workflows repo workflows))))

(defun octocat-workflow-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow list buffer, as `octocat-run-list-refresh'."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-workflow-list--page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo)))

(define-derived-mode octocat-workflow-list-mode octocat-vui-list-mode "Octocat-Workflows"
  "Major mode for the list of a repository's workflows.

\\{octocat-workflow-list-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-workflow-list-refresh))


;;;; Checks
;;
;; From the GitHub Checks REST API:
;;   GET /repos/{owner}/{repo}/commits/{ref}/check-runs?per_page=100

;;;;; Buffer-local declarations

(defvar-local octocat--checks-repo nil
  "The \"owner/repo\" this checks buffer is displaying.")

(defvar-local octocat--checks-sha nil
  "The full commit SHA whose check-runs this buffer shows.")

(defvar-local octocat--checks-ref nil
  "A human-readable ref label shown in the buffer header (branch name or PR head).
May be nil when only a SHA is available.")


;;;;; Data fetching

(defun octocat--fetch-checks (repo sha callback)
  "Fetch all check-runs for SHA in REPO asynchronously.
Calls CALLBACK with a list of check-run hash-tables (snake_case keys from
the GitHub Checks REST API), or a cons \\=(error . MSG) on failure.
Requests up to 100 check-runs; pagination is not yet supported."
  (octocat--run-gh
   "checks"
   (list "api"
         (format "repos/%s/commits/%s/check-runs?per_page=100" repo sha))
   (lambda (output)
     (let* ((parsed (json-parse-string (string-trim output)))
            (runs   (and (hash-table-p parsed)
                         (gethash "check_runs" parsed))))
       (cond
        ((null runs)    '())
        ((vectorp runs) (cl-coerce runs 'list))
        (t              '()))))
   callback))


(octocat-sync-define-resource checks (repo sha)
  ;; None yet: they may still start.
  :poll (lambda (data)
          (if (seq-empty-p data)
              octocat-sync-poll-interval
            (apply #'octocat-sync-poll-status
                   (mapcar (lambda (c) (gethash "status" c)) data))))
  :fetch (lambda (done)
           (octocat--fetch-checks
            repo sha
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))


;;;;; Rendering helpers

(defun octocat--check-run-id (check)
  "Return the GitHub Actions workflow run ID of the REST check-run CHECK, or nil.
It is read from the check's details URL, `.../actions/runs/ID/job/...';
a check not created by GitHub Actions has none."
  (let ((url (or (octocat--nonempty (gethash "details_url" check))
                 (octocat--nonempty (gethash "html_url" check)))))
    (and url (string-match "/actions/runs/\\([0-9]+\\)" url)
         (string-to-number (match-string 1 url)))))


;;;;; Checks section (vui)
;;
;; Shared by the PR and commit pages.

(defun octocat-checks-from-rest (check)
  "Return the REST check-run CHECK in the shape of a `statusCheckRollup' entry.
The REST API's snake_case, lowercase fields become the camelCase,
uppercase ones `gh pr view' gives; the app name stands in for the
workflow name, which the REST check-run does not carry."
  (let ((entry (make-hash-table :test #'equal)))
    (dolist (field `(("name"         . ,(gethash "name" check))
                     ("workflowName" . ,(octocat--get check "app" "name"))
                     ("status"       . ,(octocat--nonempty (gethash "status" check)))
                     ("conclusion"   . ,(octocat--nonempty (gethash "conclusion" check)))
                     ("startedAt"    . ,(octocat--nonempty (gethash "started_at" check)))
                     ("completedAt"  . ,(octocat--nonempty (gethash "completed_at" check)))
                     ("detailsUrl"   . ,(octocat--nonempty (gethash "html_url" check)))))
      (when (cdr field)
        (puthash (car field)
                 (if (member (car field) '("status" "conclusion"))
                     (upcase (cdr field))
                   (cdr field))
                 entry)))
    entry))

(defconst octocat-checks--column-max '(50 30)
  "Widest the name and workflow columns of the checks list grow.")

(defun octocat-checks--fields (check)
  "Return the text columns of status CHECK (a hash-table).
That is a list (NAME WORKFLOW DURATION STARTED); STARTED is the age,
with the exact time on hover (see `octocat--format-ts-relative')."
  (let ((started (octocat--get check "startedAt")))
    (list (or (gethash "name" check) "")
          (or (gethash "workflowName" check) "")
          (or (octocat--run-duration started (octocat--get check "completedAt")) "")
          (octocat--format-ts-relative started))))

(defun octocat-checks--widths (checks)
  "Return the width of each column: its widest field over all entries.
The entries are CHECKS.  The name and workflow columns stop at
`octocat-checks--column-max'."
  (let ((widths (list 0 0 0 0)))
    (seq-doseq (check checks)
      (setq widths (cl-mapcar (lambda (w field) (max w (string-width field)))
                              widths (octocat-checks--fields check))))
    (cl-mapcar (lambda (w cap) (if cap (min w cap) w))
               widths (append octocat-checks--column-max '(nil nil)))))

(defun octocat-checks--row (check widths on-visit &optional help-echo indent)
  "Return a RET-able vnode for the status CHECK (a hash-table).
WIDTHS are the column widths, as from `octocat-checks--widths'.  A
column no check has anything in takes no space.  ON-VISIT is called by
RET, described by HELP-ECHO.  INDENT starts the row, two spaces if nil."
  (let ((cells (cl-mapcar
                (lambda (field width face)
                  (and (> width 0)
                       (propertize (truncate-string-to-width field width nil ?\s "…")
                                   'face face)))
                (octocat-checks--fields check) widths
                '(nil octocat-dimmed octocat-dimmed octocat-dimmed))))
    (octocat-vui-row
     (string-trim-right
      (concat (or indent "  ")
              (octocat--run-icon (or (gethash "status" check) "")
                                 (octocat--get check "conclusion"))
              " "
              (mapconcat #'identity (delq nil cells) "  ")))
     on-visit
     (or help-echo "RET: view checks for this commit")
     ;; A check run's page, or a commit status's target.
     (or (octocat--nonempty (gethash "detailsUrl" check))
         (octocat--nonempty (gethash "targetUrl" check))))))

(define-obsolete-variable-alias 'octocat-pr-checks-shown 'octocat-checks-shown "0.1.0")
(defcustom octocat-checks-shown 5
  "Number of checks shown on a PR or commit page before the rest folds away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defun octocat-checks-rows (rollup on-visit &optional indent)
  "Return a vnode listing ROLLUP; all but a few fold away.
ROLLUP is a `statusCheckRollup' vector, as a PR has (see
`octocat-checks-from-rest' for a commit's check-runs).  ON-VISIT is
called by RET on a check.  INDENT starts each row, two spaces if nil."
  (let ((widths (octocat-checks--widths rollup))) ; Of all, so unfolding shifts no column.
    (vui-component 'octocat-vui-fold-rest
      :total (length rollup)
      :limit octocat-checks-shown
      :noun "checks"
      :key 'checks-fold
      :prefix (or indent "  ")
      :render (lambda (shown)
                (apply #'vui-vstack
                       (cl-loop for check across rollup
                                repeat shown
                                collect (octocat-checks--row check widths on-visit
                                                             nil indent)))))))

(defun octocat-checks-block (checks on-visit width)
  "Return the vnodes of the CI section, with a CI summary.
CHECKS and ON-VISIT are as for `octocat-checks-rows'.  The heading is
underlined across WIDTH columns."
  (list
   (octocat-vui-section-heading
    (format "Checks (%d)" (length checks)) width
    (unless (zerop (length checks))
      (vui-text (concat (propertize "CI:" 'face 'octocat-dimmed)
                        " " (octocat--checks-ci-status checks)))))
   (if (zerop (length checks))
       (vui-text (propertize "  (no checks)" 'face 'octocat-dimmed))
     (octocat-checks-rows checks on-visit))))

;;;;; Page

(defun octocat-checks--visit (repo check)
  "Open the workflow run of the REST check-run CHECK of REPO.
A check not created by GitHub Actions opens in the browser instead."
  (let ((run-id (octocat--check-run-id check)))
    (if run-id
        (octocat-run-open repo run-id)
      (when-let* ((url (octocat--nonempty (gethash "html_url" check))))
        (octocat-follow-url url)))))

(defun octocat-checks--list (repo checks)
  "Return the vnodes of the section of the CI results of REPO, one per row.
CHECKS is a sequence of REST check-runs."
  (let* ((checks  (append checks nil))
         (entries (mapcar #'octocat-checks-from-rest checks))
         (widths  (octocat-checks--widths entries)))
    (cons
     (vui-text (concat (propertize (format "Check runs (%d)" (length checks))
                                   'face 'octocat-section-heading)
                       (when checks
                         (concat "  " (propertize "CI:" 'face 'octocat-dimmed)
                                 " " (octocat--checks-ci-status entries)))))
     (if (null checks)
         (list (vui-text "  (no checks)" :face 'octocat-dimmed))
       (cl-mapcar (lambda (check entry)
                    (octocat-checks--row
                     entry widths
                     (lambda () (octocat-checks--visit repo check))
                     (if (octocat--check-run-id check)
                         "RET: open workflow run"
                       "RET: open in browser")))
                  checks entries)))))

(vui-defcomponent octocat-checks--page (repo sha ref tick)
  "The check-runs of commit SHA of REPO; REF is its branch, or nil.
A new TICK fetches them again."
  :render
  (let ((checks (octocat-vui-use-resource (list 'checks repo sha) tick)))
    (apply #'vui-vstack
           (octocat-vui-commit-top-row repo sha)
           (vui-text (concat "Checks"
                             (when ref (concat "  " (propertize ref 'face 'octocat-branch)))))
           (vui-newline)
           (list
            (octocat-vui-resource-view
             checks
             :skeleton (lambda (_) (vui-text (octocat-vui-line-skeleton "  ")))
             :render (lambda (data) (apply #'vui-vstack (octocat-checks--list repo data))))))))


;;;;; Major mode

(defun octocat-checks--page-url ()
  "Return the URL of the CI results of this commit."
  (and octocat--checks-repo octocat--checks-sha
       (octocat--web-url "%s/commit/%s/checks" octocat--checks-repo octocat--checks-sha)))

(defvar octocat-checks-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    map)
  "Keymap for `octocat-checks-mode'.")

(define-derived-mode octocat-checks-mode vui-mode "Octocat-Checks"
  "Major mode for viewing the GitHub check-runs of a commit.

\\{octocat-checks-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-checks-refresh)
  (octocat--ts-eldoc-setup)
  (setq-local octocat--url-function #'octocat-checks--page-url))


;;;;; Refresh

(defun octocat-checks-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current check-runs buffer.
The page paints from the sync store at once and fetches the check-runs
in the background, in place."
  (interactive)
  (unless (and octocat--checks-repo octocat--checks-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (octocat-vui-refresh-page 'octocat-checks--page
                            (cons octocat--checks-repo octocat--checks-sha)
                            (list :repo octocat--checks-repo
                                  :sha octocat--checks-sha
                                  :ref (octocat--nonempty octocat--checks-ref))))

(defun octocat-checks-open (repo sha ref)
  "Show the CI results of commit SHA of REPO in their own buffer.
REF is the branch the commit is the head of, or nil."
  (let ((buf (get-buffer-create
              (format "*%s checks %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-checks-mode)
      (octocat-checks-mode))
    (setq octocat--checks-repo repo
          octocat--checks-sha  sha
          octocat--checks-ref  ref)
    (octocat-checks-refresh)))

(provide 'octocat-actions)
;;; octocat-actions.el ends here
