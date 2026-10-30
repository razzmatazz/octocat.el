;;; octocat-workflow-tests.el --- ERT tests for octocat-workflow.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-workflow-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-workflow-test-url ()
  "A workflow's page is named by its file, as on GitHub; by ID when unknown."
  (should (equal (octocat-workflow--url "o/r" 7 ".github/workflows/ci.yml")
                 "https://github.com/o/r/actions/workflows/ci.yml"))
  (should (equal (octocat-workflow--url "o/r" 7 nil)
                 "https://github.com/o/r/actions/workflows/7")))

(ert-deftest octocat-workflow-test-yaml-on ()
  "The triggers are read in each way a workflow may write them."
  (should (equal (octocat-workflow--yaml-on "on: workflow_dispatch\n") "workflow_dispatch"))
  (should (equal (octocat-workflow--yaml-on "on: [push, workflow_dispatch]\n")
                 ["push" "workflow_dispatch"]))
  (should (equal (octocat-workflow--yaml-on "\"on\":\n  - push\n  - workflow_dispatch\n")
                 ["push" "workflow_dispatch"]))
  (should (equal (octocat-workflow--yaml-on
                  "name: CI\non:\n  workflow_dispatch:  # by hand\n  push: {branches: [main]}\njobs:\n  a:\n")
                 '(("workflow_dispatch") ("push" ("branches" . ["main"])))))
  (should-not (octocat-workflow--yaml-on "name: CI\njobs:\n")))

(ert-deftest octocat-workflow-test-dispatch-spec ()
  "Inputs keep their order, options and description, a block scalar too."
  (let* ((spec (octocat-workflow--dispatch-spec
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
  (should (eq (gethash "dispatch" (octocat-workflow--dispatch-spec "on: push\n")) :false)))

(ert-deftest octocat-workflow-test-input-values-and-errors ()
  "Unset inputs take their default; required, number and choice are checked."
  (let* ((inputs (append (gethash "inputs" (octocat-workflow--dispatch-spec
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

(ert-deftest octocat-workflow-test-parse-dispatched ()
  "The run's ID is read from the answer; an empty answer gives none."
  (should (= (octocat-workflow--parse-dispatched
              "{\"workflow_run_id\":42,\"run_url\":\"u\",\"html_url\":\"h\"}")
             42))
  (should-not (octocat-workflow--parse-dispatched "\n")))

(provide 'octocat-workflow-tests)
;;; octocat-workflow-tests.el ends here
