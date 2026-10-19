;;; octocat-issue-tests.el --- ERT tests for octocat-issue.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-issue-tests.el

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
    (should (member "list" (octocat-sync--write db "issue" (octocat-sync-detail 'issue "o/r" issue '("comments")) 2.0)))
    (let ((row (aref (gethash "nodes" (car (octocat-sync--read db "list"))) 0)))
      (should (equal (gethash "title" row) "Crash"))
      (should (= (gethash "commentCount" row) 1))
      (should-not (gethash "comments" row)))
    (let ((page (octocat-sync-detail-item (car (octocat-sync--read db "issue")))))
      (should (equal (gethash "login" (gethash "author" page)) "alice"))
      (should (equal (gethash "body" (aref (gethash "comments" page) 0)) "me too")))))

(provide 'octocat-issue-tests)
;;; octocat-issue-tests.el ends here
