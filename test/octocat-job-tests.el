;;; octocat-job-tests.el --- ERT tests for octocat-job.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-job-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-job-test-log-line-bom ()
  "A byte-order mark before the timestamp does not hide a group start."
  (let ((entry (octocat--job-parse-log-line
                "\uFEFF2026-10-12T07:32:34.8448215Z ##[group]Run make compile")))
    (should (eq (plist-get entry :kind) 'group-start))
    (should (equal (plist-get entry :text) "Run make compile"))
    (should (plist-get entry :ts))))

(ert-deftest octocat-job-test-log-blocks ()
  "Log lines are grouped by ##[group], unindented, so they copy out as-is."
  (let ((blocks (octocat-job--log-blocks
                 (mapcar #'octocat--job-parse-log-line
                         '("2026-10-12T07:32:34Z before"
                           "2026-10-12T07:32:35Z ##[group]Run make"
                           "2026-10-12T07:32:36Z inside"
                           "2026-10-12T07:32:37Z ##[endgroup]"
                           "after")))))
    (should (equal (mapcar #'car blocks) '(text group text)))
    (should (string-suffix-p " before" (substring-no-properties (nth 1 (nth 0 blocks)))))
    (should (equal (nth 1 (nth 1 blocks)) "Run make"))
    (should (string-suffix-p " inside" (substring-no-properties (nth 2 (nth 1 blocks)))))
    (should (equal (substring-no-properties (nth 1 (nth 2 blocks))) "after"))))

(ert-deftest octocat-job-test-log-colors ()
  "Color codes go, whether escape characters or spelled out as ^[."
  (should (equal (plist-get (octocat--job-parse-log-line
                             "2026-10-12T07:32:34Z ^[[36;1mmake compile^[[0m \e[32mok\e[0m")
                            :text)
                 "make compile ok")))

;; Steps and logs as `gh run view --log' and the REST API give them.

(defun octocat-job-test--step (number name started &optional completed conclusion)
  "Return step NUMBER, NAME, a REST hash-table, run from STARTED to COMPLETED.
STARTED and COMPLETED are seconds past 07:00:00, CONCLUSION its own."
  (let ((at   (lambda (s) (and s (format "2026-10-12T07:%02d:%02dZ" (/ s 60) (% s 60)))))
        (step (make-hash-table :test #'equal)))
    (puthash "number" number step)
    (puthash "name" name step)
    (puthash "started_at" (funcall at started) step)
    (puthash "completed_at" (funcall at completed) step)
    (puthash "conclusion" (or conclusion (and completed "success")) step)
    step))

(defun octocat-job-test--log (&rest lines)
  "Return LINES, each (SECONDS TEXT), as `gh run view --log' prints a log."
  (mapconcat (pcase-lambda (`(,s ,text))
               (format "build\tUNKNOWN STEP\t2026-10-12T07:%02d:%02d.1234567Z %s\n"
                       (/ s 60) (% s 60) text))
             lines ""))

(defun octocat-job-test--texts (log)
  "Return LOG, as `octocat--job-parse-log' gives it, as (NUMBER TEXTS...)."
  (mapcar (lambda (section)
            (cons (car section)
                  (mapcar (lambda (e) (plist-get e :text)) (cdr section))))
          log))

(ert-deftest octocat-job-test-parse-log-steps ()
  "A log naming no step is split at step starts, skipping skipped steps.
Steps that start in the same second take the starts in turn."
  (let ((steps (list (octocat-job-test--step 1 "Set up job" 0 1)
                     (octocat-job-test--step 2 "Check out" 1 4)
                     (octocat-job-test--step 3 "Lint" 4 4 "skipped")
                     (octocat-job-test--step 4 "Find deps" 4 4)
                     (octocat-job-test--step 5 "Compile" 4 9)
                     (octocat-job-test--step 6 "Post Check out" 9 10)
                     (octocat-job-test--step 7 "Complete job" 10 10))))
    (should (equal (octocat-job-test--texts
                    (octocat--job-parse-log
                     (octocat-job-test--log
                      '(0 "Current runner version: '2.338.0'")
                      '(1 "##[group]Run actions/checkout@v4")
                      '(1 "##[endgroup]")
                      '(4 "##[group]Run echo deps")
                      '(4 "##[group]Run make compile")
                      '(5 "ok")
                      '(9 "Post job cleanup.")
                      '(10 "Cleaning up orphan processes"))
                     steps))
                   '((1 "Current runner version: '2.338.0'")
                     (2 "Run actions/checkout@v4" nil)
                     (4 "Run echo deps")
                     (5 "Run make compile" "ok")
                     (6 "Post job cleanup.")
                     (7 "Cleaning up orphan processes"))))))

(ert-deftest octocat-job-test-parse-log-composite ()
  "A composite action's own Run groups stay in its step, until the next
starts; a step that wrote no start of its own is passed over."
  (let ((steps (list (octocat-job-test--step 1 "Set up job" 0 1)
                     (octocat-job-test--step 2 "Composite" 1 20)
                     (octocat-job-test--step 3 "Quiet" 20 21)
                     (octocat-job-test--step 4 "Test" 30 40))))
    (should (equal (octocat-job-test--texts
                    (octocat--job-parse-log
                     (octocat-job-test--log
                      '(0 "setting up")
                      '(1 "##[group]Run ./.github/actions/build")
                      '(5 "##[group]Run make")
                      '(30 "##[group]Run make test"))
                     steps))
                   '((1 "setting up")
                     (2 "Run ./.github/actions/build" "Run make")
                     (4 "Run make test"))))))

(ert-deftest octocat-job-test-parse-log-boms ()
  "Where steps open with a byte-order mark, only those start one: a runner
hook's Run group stays in its step."
  (let ((steps (list (octocat-job-test--step 1 "Set up job" 0 1)
                     (octocat-job-test--step 2 "Set up runner" 1 1)
                     (octocat-job-test--step 3 "Check out" 1 4))))
    (should (equal (octocat-job-test--texts
                    (octocat--job-parse-log
                     (concat "\uFEFF2026-10-12T07:00:00.1Z setting up\n"
                             "\uFEFF2026-10-12T07:00:01.1Z A job started hook\n"
                             "2026-10-12T07:00:01.2Z ##[group]Run ./hook.sh\n"
                             "\uFEFF2026-10-12T07:00:01.3Z ##[group]Run actions/checkout@v4\n")
                     steps))
                   '((1 "setting up")
                     (2 "A job started hook" "Run ./hook.sh")
                     (3 "Run actions/checkout@v4"))))))

(ert-deftest octocat-job-test-parse-log-running ()
  "A log as the REST API gives it, of a running job: no step names, a
byte-order mark, and steps yet to start that get none of it."
  (let ((steps (list (octocat-job-test--step 1 "Set up job" 0 1)
                     (octocat-job-test--step 2 "Test" 1)
                     (octocat-job-test--step 3 "Complete job" nil))))
    (should (equal (octocat-job-test--texts
                    (octocat--job-parse-log
                     (concat "\uFEFF2026-10-12T07:00:00.1Z setting up\n"
                             "2026-10-12T07:00:01.1Z ##[group]Run make test\n"
                             "2026-10-12T07:00:02.1Z running\tnow\n")
                     steps))
                   '((1 "setting up")
                     (2 "Run make test" "running\tnow"))))))

(ert-deftest octocat-job-test-annotations-wrap ()
  "A long annotation message wraps within the width, hung under the job."
  (let* ((ann (make-hash-table :test #'equal))
         (_   (progn (puthash "annotation_level" "warning" ann)
                     (puthash "message" (mapconcat #'identity (make-list 30 "word") " ") ann)))
         (row (vui-vnode-text-content
               (cadr (octocat-job-annotations (list (cons "build" ann)) 40))))
         (lines (split-string row "\n")))
    (should (> (length lines) 1))
    (should (seq-every-p (lambda (l) (<= (string-width l) 40)) lines))
    (should (string-prefix-p "     word" (cadr lines)))))

(ert-deftest octocat-job-test-run-annotations-order ()
  "A run's annotations come in its jobs' order, not their answers'."
  (let (calls result)
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name _args _parse callback) (push callback calls))))
      (octocat--fetch-run-annotations
       "o/r"
       (vector (let ((j (make-hash-table :test #'equal)))
                 (puthash "databaseId" 1 j) (puthash "name" "a" j) j)
               (let ((j (make-hash-table :test #'equal)))
                 (puthash "databaseId" 2 j) (puthash "name" "b" j) j))
       (lambda (r) (setq result r)))
      ;; CALLS is newest first, so job 2 answers first.
      (dolist (cb calls) (funcall cb [])))
    (should (equal (mapcar #'car result) '(1 2)))))

(provide 'octocat-job-tests)
;;; octocat-job-tests.el ends here
