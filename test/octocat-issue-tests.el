;;; octocat-issue-tests.el --- ERT tests for octocat-issue.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-issue-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-issue-test-issue-or-pr ()
  "A number opens as the store holds it, else as an issue until GitHub says."
  (let (opened answered)
    (cl-letf (((symbol-function 'octocat-sync-read)
               (lambda (spec) (and (equal spec '(pr "o/r" 1)) (list :partial t))))
              ((symbol-function 'octocat-sync-get) (lambda (_ k) (setq answered k)))
              ((symbol-function 'octocat-pr-open) (lambda (&rest a) (push (cons 'pr a) opened)))
              ((symbol-function 'octocat-issue-open) (lambda (&rest a) (push (cons 'issue a) opened))))
      (octocat-open 'issue-or-pr "o/r" 1)
      (should-not answered)
      (octocat-open 'issue-or-pr "o/r" 2)
      (funcall answered (octocat--table "pr" t)))
    (should (equal (nreverse opened) '((pr "o/r" 1) (issue "o/r" 2) (pr "o/r" 2))))))

(ert-deftest octocat-issue-test-parse-message ()
  "The first line is the title, the rest the body."
  (should (equal (octocat-issue--parse-message "  Crash on start \n\nSteps:\n1. run\n")
                 '("Crash on start" . "Steps:\n1. run")))
  (should (equal (octocat-issue--parse-message "Title only") '("Title only" . ""))))

(provide 'octocat-issue-tests)
;;; octocat-issue-tests.el ends here
