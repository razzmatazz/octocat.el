;;; octocat-diff-tests.el --- ERT tests for octocat-diff.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-diff-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-diff-test-line-count ()
  "A file takes its heading line plus its patch lines; no patch, just one."
  (should (= (octocat-diff--line-count
              (vector (json-parse-string "{\"patch\":\"@@ -1 +1 @@\\n-a\\n+b\"}")
                      (json-parse-string "{\"filename\":\"logo.png\"}")))
             5)))

(ert-deftest octocat-diff-test-review-args ()
  "A review passes its flag, and its body only when there is one."
  (should (equal (octocat-pr-diff--review-args "o/r" 7 "--approve" "")
                 '("pr" "review" "7" "--repo" "o/r" "--approve")))
  (should (equal (octocat-pr-diff--review-args "o/r" 7 "--comment" "LGTM")
                 '("pr" "review" "7" "--repo" "o/r" "--comment" "--body" "LGTM"))))

(ert-deftest octocat-diff-test-review-data ()
  "Only an approval may be submitted without text."
  (should (plist-get (octocat-pr-diff--review-data "Approve") :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data "Comment") :allow-empty))
  (should (equal (plist-get (octocat-pr-diff--review-data "Request changes") :flag)
                 "--request-changes")))

(ert-deftest octocat-diff-test-comment-markdown ()
  "An inline comment's body is rendered markdown, unless raw."
  (let ((c (json-parse-string
            "{\"user\":{\"login\":\"me\"},\"body\":\"**hi**\",\"created_at\":\"\"}")))
    (should (equal (nth 1 (octocat-diff--comment-lines c nil 80)) "  │ hi"))
    (should (equal (nth 1 (octocat-diff--comment-lines c t 80)) "  │ **hi**"))))

(ert-deftest octocat-diff-test-comments-section ()
  "General comments are boxed; inline ones only counted.
The comments come as a sync snapshot."
  (let ((text (lambda (data)
                (with-temp-buffer
                  (vui-render (octocat-diff-comments-section
                               "Comments" (list :data data) nil 80))
                  (buffer-substring-no-properties (point-min) (point-max))))))
    (should (string-search "(no comments)" (funcall text [])))
    (let ((out (funcall text
                        (vector (json-parse-string
                               "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\"}")
                              (json-parse-string
                               "{\"path\":\"a.el\",\"body\":\"x\",\"created_at\":\"\"}")))))
      (should (string-search "Comments (2)" out))
      (should (string-search "(1 inline comment, in the diff above)" out))
      (should (string-search "┌─ @me" out))
      (should (string-search "│ hi" out)))))

(ert-deftest octocat-diff-test-files-hide-comments ()
  "Inline comments start hidden, their count on the button that shows them."
  (let* ((file (json-parse-string
                "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
         (c    (json-parse-string
                "{\"path\":\"a.el\",\"line\":1,\"body\":\"note\",\"created_at\":\"\"}"))
         (out  (with-temp-buffer
                 (vui-render (vui-component 'octocat-diff--files
                                            :files (vector file)
                                            :by-path (octocat-diff-by-path (vector c))
                                            :hide t
                                            :fits t :raw nil :width 80))
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (should (string-search "Show comments (1)" out))
    (should (string-search "+x" out))
    (should-not (string-search "note" out))))

(ert-deftest octocat-diff-test-outdated-comments-no-button ()
  "Comments the diff cannot place, as outdated ones, leave out the button."
  (let* ((file (json-parse-string
                "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
         (c    (json-parse-string
                "{\"path\":\"a.el\",\"line\":40,\"body\":\"gone\",\"created_at\":\"\"}"))
         (out  (with-temp-buffer
                 (vui-render (vui-component 'octocat-diff--files
                                            :files (vector file)
                                            :by-path (octocat-diff-by-path (vector c))
                                            :hide nil :fits t :raw nil :width 80))
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (should-not (string-search "comments (" out))
    (should (string-search "+x" out))))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
