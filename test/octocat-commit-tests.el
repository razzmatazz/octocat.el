;;; octocat-commit-tests.el --- ERT tests for octocat-commit.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-commit-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-commit-test-skeleton ()
  "The commit skeleton keeps its grey bars within WIDTH."
  (let ((text (octocat-commit--skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(ert-deftest octocat-commit-test-date-committed ()
  "Rows show when a commit was committed; its author date when it has no other."
  (let ((both (octocat-repo--history-commit
               (json-parse-string
                "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"committedDate\":\"2026-10-02T10:00:00Z\",\"author\":null}")))
        (old  (octocat-repo--history-commit
               (json-parse-string
                "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":null}"))))
    (should (equal (octocat--commit-date both) "2026-10-02T10:00:00Z"))
    (should (equal (octocat--commit-date old) "2026-10-01T10:00:00Z"))
    (should (string-prefix-p "committed " (octocat-repo-vui--date both)))))

(ert-deftest octocat-commit-test-parse-branch ()
  "The default branch holds a commit behind its head or at it, not one ahead."
  (dolist (case '(("BEHIND" . "main") ("IDENTICAL" . "main") ("AHEAD" . :null) ("DIVERGED" . :null)))
    (should (equal (gethash "name"
                            (octocat-commit--parse-branch
                             (format "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\",\"compare\":{\"status\":\"%s\"}}}}}"
                                     (car case))))
                   (cdr case)))))

(ert-deftest octocat-commit-test-date-as-git ()
  "A date reads as `git show' prints it, its age after it."
  (let ((commit (json-parse-string
                 "{\"commit\":{\"author\":{\"date\":\"2026-10-01T10:00:00Z\"}}}"))
        (process-environment (cons "TZ=UTC" process-environment)))
    (set-time-zone-rule "UTC")
    (unwind-protect
        (should (string-prefix-p "Thu Oct 1 10:00:00 2026 +0000  ("
                                 (octocat-commit--date commit "author")))
      (set-time-zone-rule nil))
    (should-not (octocat-commit--date commit "committer"))))

(provide 'octocat-commit-tests)
;;; octocat-commit-tests.el ends here
