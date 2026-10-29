;;; octocat-commit-tests.el --- ERT tests for octocat-commit.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-commit-tests.el

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
    (should (equal (octocat-repo-vui--date both)
                   (octocat--format-ts-relative "2026-10-02T10:00:00Z")))))

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

(ert-deftest octocat-commit-test-patch-text ()
  "A commit as a patch is as `git format-patch' writes it, binary files included."
  (let* ((commit (json-parse-string
                  (concat "{\"sha\":\"abc123\",\"commit\":{\"message\":\"Fix it\\n\\nWhy.\","
                          "\"author\":{\"name\":\"Ann\",\"email\":\"a@x\","
                          "\"date\":\"2026-10-01T10:00:00Z\"}},\"files\":["
                          "{\"filename\":\"a.el\",\"status\":\"modified\","
                          "\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"},"
                          "{\"filename\":\"new.png\",\"status\":\"added\"}]}")))
         (text   (substring-no-properties (octocat-commit--patch-text commit))))
    (should (equal text (concat "From abc123 Mon Sep 17 00:00:00 2001\n"
                                "From: Ann <a@x>\n"
                                "Date: Thu, 01 Oct 2026 10:00:00 +0000\n"
                                "Subject: [PATCH] Fix it\n\n"
                                "Why.\n"
                                "---\n\n"
                                "diff --git a/a.el b/a.el\n"
                                "--- a/a.el\n+++ b/a.el\n"
                                "@@ -1 +1 @@\n-old\n+new\n"
                                "diff --git a/new.png b/new.png\n"
                                "new file mode 100644\n"
                                "Binary files /dev/null and b/new.png differ")))))

(provide 'octocat-commit-tests)
;;; octocat-commit-tests.el ends here
