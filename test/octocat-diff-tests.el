;;; octocat-diff-tests.el --- ERT tests for octocat-diff.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-diff-tests.el

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

(ert-deftest octocat-diff-test-comment-reactions ()
  "An inline comment's reactions follow the date in its heading."
  (let ((c (json-parse-string
            (concat "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\","
                    "\"reactions\":{\"total_count\":1,\"heart\":1}}"))))
    (should (string-suffix-p "  ❤️ 1" (car (octocat-diff--comment-lines c nil 80))))))

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

(defun octocat-diff-tests--face-at (line col)
  "Return the faces at COL of LINE, as a list."
  (ensure-list (get-text-property col 'face line)))

(ert-deftest octocat-diff-test-highlight-sides ()
  "Each side of a hunk is highlighted apart, under the diff faces.
The old side's comment, left open, does not reach the added line."
  (pcase-let ((`(,_ ,removed ,added ,context)
               (octocat-diff--lines
                "@@ -1,2 +1,2 @@\n-/* int x;\n+int x;\n return;\n" "a.c")))
    (should (memq 'font-lock-comment-face (octocat-diff-tests--face-at removed 4)))
    (should (memq 'diff-removed (octocat-diff-tests--face-at removed 4)))
    (should (equal (octocat-diff-tests--face-at added 0) '(diff-indicator-added)))
    (should (equal (octocat-diff-tests--face-at added 1)
                   '(font-lock-type-face diff-added)))
    (should (memq 'font-lock-keyword-face (octocat-diff-tests--face-at context 1)))
    (should (equal (substring-no-properties context) " return;"))))

(ert-deftest octocat-diff-test-highlight-hunks ()
  "Every hunk is highlighted, each on its own."
  (should (memq 'font-lock-keyword-face
                (octocat-diff-tests--face-at
                 (car (last (octocat-diff--lines
                             "@@ -1 +1 @@\n-int a;\n+int b;\n@@ -9 +9 @@\n return;" "a.c")))
                 1))))

(ert-deftest octocat-diff-test-highlight-limit ()
  "A patch past `octocat-diff--highlight-limit' is only in the diff faces."
  (let ((octocat-diff--highlight-limit 10))
    (should (equal (octocat-diff-tests--face-at
                    (nth 1 (octocat-diff--lines "@@ -1 +1 @@\n+return 1;" "a.c"))
                    1)
                   '(diff-added)))))

(ert-deftest octocat-diff-test-highlight-no-mode ()
  "A file with no mode of its own is only in the diff faces."
  (should (equal (octocat-diff-tests--face-at
                  (nth 1 (octocat-diff--lines "@@ -1 +1 @@\n-int x;\n+int y;" "notes"))
                  1)
                 '(diff-removed))))

(ert-deftest octocat-diff-test-walk-note ()
  "A `\\ No newline' note takes no line of the new file."
  (let (seen)
    (octocat-diff--walk "@@ -1 +1,2 @@\n-a\n\\ No newline at end of file\n+a\n+b"
                        (octocat-diff--index
                         (list (json-parse-string "{\"line\":2,\"body\":\"x\"}")))
                        (lambda (line placed) (when placed (push line seen))))
    (should (equal seen '("+b")))))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
