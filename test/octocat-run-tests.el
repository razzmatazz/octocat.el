;;; octocat-run-tests.el --- ERT tests for octocat-run.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-run-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

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

(ert-deftest octocat-run-test-yaml-jobs ()
  "A job's needs are read in each form, and nothing else of the file."
  (let ((jobs (octocat-workflow--yaml-jobs "name: CI
on: push
jobs:
  lint:   # first
    runs-on: ubuntu-latest
    steps:
      - run: |
          needs: not-a-job
  test:
    name: Test ${{ matrix.rust }}
    needs: lint
  build:
    needs: [lint]

  docs:
    needs:
      - test
      - build
env:
  needs: nope
")))
    (should (equal (mapcar (lambda (j) (list (gethash "id" j) (gethash "name" j) (gethash "needs" j)))
                           jobs)
                   '(("lint" nil []) ("test" "Test ${{ matrix.rust }}" ["lint"])
                     ("build" nil ["lint"]) ("docs" nil ["test" "build"]))))
    (should (equal (octocat-workflow--yaml-jobs "on: push\n") []))))

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
                   '("  A ─┬─── B" "     └─── C")))
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
  "The table shows the graph, the steps done and the step running."
  (let ((jobs (list (octocat-run-tests--job 1 "lint")
                    (octocat-run-tests--job 2 "test" "in_progress" 3)))
        (specs (list (octocat-run-tests--spec "lint") (octocat-run-tests--spec "test" nil "lint"))))
    (with-temp-buffer
      (vui-render (apply #'vui-vstack (octocat-run--jobs-section "o/r" 9 jobs specs 'table 80))
                  (current-buffer))
      (should (string-search "  ✓  lint    5/5   2m00s\n  ●  test    3/5          Step 4"
                             (buffer-string))))))

(provide 'octocat-run-tests)
;;; octocat-run-tests.el ends here
