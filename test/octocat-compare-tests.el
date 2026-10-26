;;; octocat-compare-tests.el --- ERT tests for octocat-compare.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-compare-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-compare-tests--json (s)
  "Parse the JSON string S as the API's response is."
  (json-parse-string s))

(ert-deftest octocat-compare-test-summary ()
  "The summary counts commits and files, and notes what differs from github.com."
  (let ((ahead (octocat-compare-tests--json
                "{\"status\":\"ahead\",\"total_commits\":1,\"behind_by\":0,
                  \"commits\":[{}],\"files\":[{},{}]}"))
        (diverged (octocat-compare-tests--json
                   "{\"status\":\"diverged\",\"total_commits\":3,\"behind_by\":2,
                     \"commits\":[{},{}],\"files\":[]}")))
    (should (equal (octocat-compare--summary ahead "..")
                   '("1 commit · 2 files changed")))
    (should (equal (octocat-compare--summary diverged "...")
                   '("3 commits · 0 files changed · 2 behind"
                     "2 of the 3 commits listed, as GitHub's API returns at most 2")))
    (should (string-search "two-dot" (nth 1 (octocat-compare--summary diverged ".."))))
    (should (equal (octocat-compare--summary
                    (octocat-compare-tests--json
                     "{\"status\":\"identical\",\"total_commits\":0,\"commits\":[],\"files\":[]}")
                    "...")
                   '("These refs are identical")))))

(ert-deftest octocat-compare-test-max-age ()
  "Only a comparison of two commits is kept, as a commit is; refs move."
  (let ((max-age (lambda (base head)
                   (plist-get (octocat-sync--props (list 'compare "o/r" base head)) :max-age))))
    (should (funcall max-age "abc1234" (make-string 40 ?f)))
    (should-not (funcall max-age "abc1234" "main"))
    (should-not (funcall max-age "v1.0" "v1.1"))))

(ert-deftest octocat-compare-test-page-renders-files ()
  "A loaded comparison shows its commits and its files."
  (let ((data (octocat-compare-tests--json
               "{\"status\":\"ahead\",\"total_commits\":0,\"behind_by\":0,\"commits\":[],
                 \"files\":[{\"filename\":\"a.el\",\"status\":\"modified\",
                             \"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"}]}"))
        (vui-render-delay nil))
    (cl-letf (((symbol-function 'octocat-vui-use-resource)
               (lambda (_spec _tick) (list :data data))))
      (unwind-protect
          (progn
            (vui-mount (vui-component 'octocat-compare--page
                                      :repo "o/r" :base "main" :dots "..." :head "topic"
                                      :raw nil :tick 0)
                       "*octocat-compare-test*")
            (with-current-buffer "*octocat-compare-test*"
              (should (string-search "Files (1)" (buffer-string)))))
        (kill-buffer "*octocat-compare-test*")))))

(provide 'octocat-compare-tests)
;;; octocat-compare-tests.el ends here
