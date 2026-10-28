;;; octocat-issue-tests.el --- ERT tests for octocat-issue.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-issue-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-issue-test-shares-entity-with-list ()
  "The issue page and the list store one entity; the comments stay with the page."
  (let ((db (octocat-sync--create (sqlite-open nil)))
        (issue (json-parse-string
                (concat "{\"number\":12,\"title\":\"Crash\",\"state\":\"OPEN\","
                        "\"author\":{\"login\":\"alice\",\"is_bot\":false},"
                        "\"labels\":[],\"comments\":[{\"body\":\"me too\"}]}"))))
    (octocat-sync--write db "list"
                         (octocat-vui--list-tree
                          'issues "o/r"
                          (list :items (list (json-parse-string
                                              "{\"number\":12,\"title\":\"Old\",\"commentCount\":0}"))))
                         1.0)
    (should (member "list"
                    (octocat-sync--write
                     db "issue"
                     (octocat-sync-detail issue '("comments")
                                          (lambda (f) (octocat-sync-item 'issue "o/r" f)))
                     2.0)))
    (let ((row (aref (gethash "nodes" (car (octocat-sync--read db "list"))) 0)))
      (should (equal (gethash "title" row) "Crash"))
      (should (= (gethash "commentCount" row) 1))
      (should-not (gethash "comments" row)))
    (let ((page (octocat-sync-detail-item (car (octocat-sync--read db "issue")))))
      (should (equal (gethash "login" (gethash "author" page)) "alice"))
      (should (equal (gethash "body" (aref (gethash "comments" page) 0)) "me too")))))

(ert-deftest octocat-issue-test-parse-message ()
  "The first line is the title, the rest the body."
  (should (equal (octocat-issue--parse-message "  Crash on start \n\nSteps:\n1. run\n")
                 '("Crash on start" . "Steps:\n1. run")))
  (should (equal (octocat-issue--parse-message "Title only") '("Title only" . ""))))

(ert-deftest octocat-issue-test-parse-created ()
  "The number is read from the URL `gh issue create' prints."
  (should (= (octocat-issue--parse-created
              "https://github.com/o/r/issues/42\n")
             42))
  (should-error (octocat-issue--parse-created "oops")))

(ert-deftest octocat-issue-test-url ()
  "The URL is the item's own, so an Enterprise host is kept, or else github.com's."
  (should (equal (octocat-issue--url
                  (json-parse-string "{\"url\":\"https://ghe.example/a/b/issues/7\"}")
                  "a/b" 7)
                 "https://ghe.example/a/b/issues/7"))
  (should (equal (octocat-issue--url nil "a/b" 7) "https://github.com/a/b/issues/7")))

(provide 'octocat-issue-tests)
;;; octocat-issue-tests.el ends here
