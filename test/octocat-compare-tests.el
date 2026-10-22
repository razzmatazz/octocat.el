;;; octocat-compare-tests.el --- ERT tests for octocat-compare.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-compare-tests.el

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

(provide 'octocat-compare-tests)
;;; octocat-compare-tests.el ends here
