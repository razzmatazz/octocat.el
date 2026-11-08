;;; octocat-actions-tests.el --- ERT tests for octocat-actions.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-actions-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
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

(ert-deftest octocat-job-test-steps-log-loading ()
  "While the log comes, the steps show without folds or Expand all, over a grey bar."
  (let* ((job   (make-hash-table :test #'equal))
         (_     (puthash "steps" (vector (octocat-job-test--step 1 "Set up job" 0 1)) job))
         (nodes (octocat-job--steps job 'loading nil #'ignore))
         (bar   (vui-vnode-text-content (car (last nodes)))))
    (should (vui-vnode-text-p (car nodes)))
    (should (vui-vnode-text-p (cadr nodes)))
    (should (eq (get-text-property 2 'face bar) 'octocat-skeleton))))

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

(ert-deftest octocat-job-test-artifact-cleanup ()
  "A previewed artifact is deleted once the last buffer showing it is killed."
  (let* ((octocat--artifact-preview-dir (file-truename (make-temp-file "octocat-test-" t)))
         (art (expand-file-name "7" octocat--artifact-preview-dir))
         (sub (expand-file-name "logs" art)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (let ((a (generate-new-buffer "a")) (b (generate-new-buffer "b")))
            (with-current-buffer a (setq default-directory (file-name-as-directory art)))
            (with-current-buffer b (setq default-directory (file-name-as-directory sub)))
            (with-current-buffer a (octocat--artifact-cleanup))
            (kill-buffer a)
            (should (file-directory-p art))
            (with-current-buffer b (octocat--artifact-cleanup))
            (kill-buffer b)
            (should-not (file-directory-p art))
            (should (file-directory-p octocat--artifact-preview-dir))))
      (delete-directory octocat--artifact-preview-dir t))))

(ert-deftest octocat-job-test-fetch-artifact-lone-file ()
  "An artifact that is not a zip is saved under its name, as it came."
  (let ((dir (make-temp-file "octocat-test-" t))
        (art (make-hash-table :test #'equal))
        result)
    (puthash "id" 7 art)
    (puthash "name" "build.dockerbuild" art)
    (unwind-protect
        (cl-letf (((symbol-function 'octocat--run-gh)
                   (lambda (_name args _parse callback)
                     (should (equal args '("api" "repos/o/r/actions/artifacts/7/zip")))
                     (funcall callback "\x1f\x8b\x08 bytes"))))
          (octocat--fetch-artifact "o/r" art dir (lambda (r) (setq result (list r))))
          (should (equal result '(nil)))
          (should (equal (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally
                            (expand-file-name "build.dockerbuild" dir))
                           (buffer-string))
                         "\x1f\x8b\x08 bytes")))
      (delete-directory dir t))))

(ert-deftest octocat-job-test-artifact-shown-p ()
  "Text and files Emacs draws are shown; other binary files are not."
  (let ((dir (make-temp-file "octocat-test-" t)))
    (unwind-protect
        (cl-flet ((file (name bytes)
                    (let ((f (expand-file-name name dir))
                          (coding-system-for-write 'no-conversion))
                      (write-region bytes nil f nil 'silent)
                      f)))
          (should (octocat--artifact-shown-p (file "report.html" "<html>\n")))
          (should (octocat--artifact-shown-p (file "shot.png" "\x89PNG\0\0")))
          (should-not (octocat--artifact-shown-p (file "b.dockerbuild" "\x1f\x8b\0\0"))))
      (delete-directory dir t))))

(defun octocat-run-tests--job (id name &optional status steps-done)
  "Return job ID, NAME, as `gh run view' gives it, of STATUS.
It has five steps, STEPS-DONE of them done and the next running."
  (json-parse-string
   (json-serialize
    `(:databaseId ,id :name ,name :status ,(or status "completed")
                  :conclusion ,(if (member status '("in_progress" "queued")) "" "success")
                  :startedAt "2026-10-12T07:00:00Z" :completedAt "2026-10-12T07:02:00Z"
                  :steps ,(vconcat (cl-loop for n from 1 to 5
                                            collect `(:name ,(format "Step %d" n)
                                                            :status ,(cond ((<= n (or steps-done 5)) "completed")
                                                                           ((= n (1+ steps-done)) "in_progress")
                                                                           (t "queued")))))))))

(defun octocat-run-tests--spec (id &optional name &rest needs)
  "Return the job ID of a workflow file, NAME, waiting for NEEDS."
  (let ((h (make-hash-table :test #'equal)))
    (puthash "id" id h)
    (when name (puthash "name" name h))
    (puthash "needs" (vconcat needs) h)
    h))

(ert-deftest octocat-run-test-job-edges ()
  "Run jobs are matched to the file's by name, matrix and reusable ones too."
  (let ((jobs (list (octocat-run-tests--job 1 "lint")
                    (octocat-run-tests--job 2 "Test stable")
                    (octocat-run-tests--job 3 "Test beta")
                    (octocat-run-tests--job 4 "deploy / upload")
                    (octocat-run-tests--job 5 "docs (ubuntu, 1.80)")
                    (octocat-run-tests--job 6 "stray")))
        (specs (list (octocat-run-tests--spec "lint")
                     (octocat-run-tests--spec "test" "Test ${{ matrix.rust }}" "lint")
                     (octocat-run-tests--spec "docs" nil "test")
                     (octocat-run-tests--spec "deploy" nil "docs" "lint"))))
    (should (equal (octocat-run--job-edges jobs specs)
                   '((1 2) (1 3) (5 4) (1 4) (2 5) (3 5))))
    (should-not (octocat-run--job-edges jobs nil))))

(ert-deftest octocat-run-test-job-order ()
  "A job comes after those it waits for, else where it was."
  (let ((jobs (mapcar (lambda (id) (octocat-run-tests--job id (format "j%d" id))) '(1 2 3))))
    (should (equal (mapcar (lambda (j) (gethash "databaseId" j))
                           (octocat-run--job-order jobs '((3 1))))
                   '(2 3 1)))))

(ert-deftest octocat-run-test-mermaid-graph ()
  "One-line nodes are joined left to right, and keep their properties."
  (let ((lines (octocat-mermaid-graph
                (list (list 'a (propertize "A" 'tag 'a)) (list 'b "B") (list 'c "C"))
                '((a b) (a c)))))
    (should (equal (mapcar #'substring-no-properties lines)
                   '("  A ─┬─── B" "     ╰─── C")))
    (should (eq (get-text-property 2 'tag (nth 0 lines)) 'a))
    (should-not (octocat-mermaid-graph '((a "A") (b "B")) '((a b)) 5))))

(ert-deftest octocat-run-test-graph-ret ()
  "RET on a job of the graph opens it, and TAB steps from job to job."
  (let* ((jobs (list (octocat-run-tests--job 1 "lint")
                     (octocat-run-tests--job 2 "test" "in_progress" 3)))
         (specs (list (octocat-run-tests--spec "lint") (octocat-run-tests--spec "test" nil "lint")))
         opened)
    (cl-letf (((symbol-function 'octocat-job-open)
               (lambda (_repo _run id _name) (setq opened id))))
      (with-temp-buffer
        (vui-render (apply #'vui-vstack (octocat-run--jobs-section "o/r" 9 jobs specs 'graph 80))
                    (current-buffer))
        (should (string-search "✓ lint 2m00s ───── ● test 3/5" (buffer-string)))
        (goto-char (point-min))
        (search-forward "test 3/5")
        (call-interactively (key-binding (kbd "RET")))
        (should (equal opened 2))
        ;; On the icon too, not only on the name.
        (goto-char (point-min))
        (search-forward "✓")
        (backward-char)
        (call-interactively (key-binding (kbd "RET")))
        (should (equal opened 1))
        (goto-char (point-min))
        (search-forward "Graph")
        (vui-forward)
        (should (looking-at "lint"))
        (vui-forward)
        (should (looking-at "test"))))))

(ert-deftest octocat-run-test-table ()
  "The table shows the graph, the status, the steps done and the step running."
  (let ((jobs (list (octocat-run-tests--job 1 "lint")
                    (octocat-run-tests--job 2 "test" "in_progress" 3)))
        (specs (list (octocat-run-tests--spec "lint") (octocat-run-tests--spec "test" nil "lint"))))
    (with-temp-buffer
      (vui-render (apply #'vui-vstack (octocat-run--jobs-section "o/r" 9 jobs specs 'table 80))
                  (current-buffer))
      (should (string-search "  ✓─╮  lint  success        5/5   2m00s\n    ●  test  in_progress    3/5          Step 4"
                             (buffer-string))))))

(ert-deftest octocat-workflow-test-url ()
  "A workflow's page is named by its file, as on GitHub; by ID when unknown."
  (should (equal (octocat-workflow--url "o/r" 7 ".github/workflows/ci.yml")
                 "https://github.com/o/r/actions/workflows/ci.yml"))
  (should (equal (octocat-workflow--url "o/r" 7 nil)
                 "https://github.com/o/r/actions/workflows/7")))

(ert-deftest octocat-workflow-test-dispatch-spec ()
  "Inputs keep their order, options and description, a block scalar too."
  (let* ((spec (octocat-model--workflow-dispatch-spec
                "on:
  workflow_dispatch:
    inputs:
      env:
        description: 'Where to deploy'
        type: choice
        options:
        - staging
        - production
      version:
        required: true
        description: |
          Version to tag
          like v1.0
jobs:
  deploy:
    steps:
      - run: |
          echo \"on: no\"
"))
         (inputs (gethash "inputs" spec)))
    (should (eq (gethash "dispatch" spec) t))
    (should (equal (mapcar (lambda (in) (gethash "name" in)) inputs) '("env" "version")))
    (should (equal (gethash "options" (aref inputs 0)) ["staging" "production"]))
    (should (equal (gethash "description" (aref inputs 0)) "Where to deploy"))
    (should (eq (gethash "required" (aref inputs 0)) :false))
    (should (eq (gethash "required" (aref inputs 1)) t))
    (should (equal (gethash "type" (aref inputs 1)) "string"))
    (should (equal (gethash "description" (aref inputs 1)) "Version to tag\nlike v1.0"))
    (should (equal (octocat-workflow--input-label (aref inputs 1)) "Version to tag *"))
    ;; Cut to fit, the mark stays.
    (should (equal (octocat-workflow--input-label (aref inputs 1) 12) "Version t… *")))
  (should (eq (gethash "dispatch" (octocat-model--workflow-dispatch-spec "on: push\n")) :false)))

(ert-deftest octocat-workflow-test-dispatch-spec-typed ()
  "Booleans and numbers in a workflow file are read as the text they are."
  (let ((in (aref (gethash "inputs" (octocat-model--workflow-dispatch-spec "on:
  workflow_dispatch:
    inputs:
      n: {type: choice, options: [1, 2], default: 2, required: false}
      dry: {type: boolean, default: false}
"))
                  0)))
    (should (equal (gethash "options" in) ["1" "2"]))
    (should (equal (gethash "default" in) "2"))
    (should (eq (gethash "required" in) :false))))

(ert-deftest octocat-workflow-test-input-values-and-errors ()
  "Unset inputs take their default; required, number and choice are checked."
  (let* ((inputs (append (gethash "inputs" (octocat-model--workflow-dispatch-spec
                                            "on:
  workflow_dispatch:
    inputs:
      env: {type: choice, options: [a, b]}
      dry: {type: boolean}
      n: {type: number, default: '3'}
      tag: {required: true}
"))
                         nil))
         (values (octocat-workflow--input-values inputs '(("n" . "x")))))
    (should (equal values '(("env" . "a") ("dry" . "false") ("n" . "x") ("tag" . ""))))
    (should (equal (octocat-workflow--input-errors inputs values)
                   '(("n" . "not a number") ("tag" . "required"))))
    (should-not (octocat-workflow--input-errors
                 inputs (octocat-workflow--input-values inputs '(("n" . "-1.5e3") ("tag" . "v1")))))))

(ert-deftest octocat-checks-test-from-rest ()
  "A REST check-run takes the shape of a statusCheckRollup entry."
  (let ((entry (octocat-checks-from-rest
                (json-parse-string
                 "{\"name\":\"test\",\"status\":\"completed\",\"conclusion\":\"success\",\"started_at\":\"2026-01-01T00:00:00Z\",\"completed_at\":null,\"app\":{\"name\":\"GitHub Actions\"}}"))))
    (should (equal (gethash "name" entry) "test"))
    (should (equal (gethash "workflowName" entry) "GitHub Actions"))
    (should (equal (gethash "status" entry) "COMPLETED"))
    (should (equal (gethash "conclusion" entry) "SUCCESS"))
    (should (equal (gethash "startedAt" entry) "2026-01-01T00:00:00Z"))
    (should-not (gethash "completedAt" entry))))

(ert-deftest octocat-checks-test-check-run-id ()
  "The workflow run ID comes from the details URL, not the check suite."
  (should (equal (octocat--check-run-id
                  (json-parse-string
                   "{\"details_url\":\"https://github.com/o/r/actions/runs/38218268003/job/1\",\"check_suite\":{\"id\":103543467452}}"))
                 38218268003))
  (should-not (octocat--check-run-id
               (json-parse-string "{\"details_url\":\"https://ci.example.com/build/7\"}"))))

(provide 'octocat-actions-tests)
;;; octocat-actions-tests.el ends here
