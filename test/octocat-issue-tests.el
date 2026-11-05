;;; octocat-issue-tests.el --- ERT tests for octocat-issue.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-issue-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-issue-test-parse-message ()
  "The first line is the title, the rest the body."
  (should (equal (octocat-issue--parse-message "  Crash on start \n\nSteps:\n1. run\n")
                 '("Crash on start" . "Steps:\n1. run")))
  (should (equal (octocat-issue--parse-message "Title only") '("Title only" . ""))))

(provide 'octocat-issue-tests)
;;; octocat-issue-tests.el ends here
