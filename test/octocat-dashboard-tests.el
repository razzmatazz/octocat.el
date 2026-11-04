;;; octocat-dashboard-tests.el --- ERT tests for octocat-dashboard.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-dashboard-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-dashboard-test-items-query ()
  "The dashboard searches the user's open items of a kind, with their repo."
  (should (equal (octocat--dashboard-search-query 'pulls)
                 "is:open archived:false involves:@me sort:updated-desc type:pr"))
  (should (string-match-p "type:issue\\'" (octocat--dashboard-search-query 'issues)))
  (let ((q (octocat--dashboard-items-query 'issues)))
    (should (string-search "...on Issue{repository{nameWithOwner}}" q))
    (should (string-search (alist-get 'issues octocat--list-item-fields) q))))

(ert-deftest octocat-dashboard-test-items-tree ()
  "Each dashboard item keeps its repo beside its entity."
  (let* ((page (octocat--parse-list-items
                "{\"data\":{\"search\":{\"nodes\":[{\"repository\":{\"nameWithOwner\":\"O/R\"},\"number\":5,\"title\":\"T\",\"state\":\"OPEN\",\"comments\":{\"totalCount\":4}}],\"pageInfo\":{\"hasNextPage\":false}}}}"))
         (tree (octocat--dashboard-items-tree 'pulls page))
         (node (aref tree 0))
         (item (gethash "item" node)))
    (should (equal (gethash "repo" node) "O/R"))
    (should (octocat-sync--entity-p item))
    (should (equal (octocat-sync--entity-key item) "pr:o/r#5"))
    (should-not (gethash "repository" (octocat-sync--entity-fields item)))
    (should (equal (gethash "commentCount" (octocat-sync--entity-fields item)) 4))))

(ert-deftest octocat-dashboard-test-browse-item ()
  "C-c C-o on a dashboard PR or issue row opens that item, not its repo."
  (let (urls)
    (cl-letf (((symbol-function 'browse-url-with-browser-kind)
               (lambda (_kind url &rest _) (push url urls))))
      (with-temp-buffer
        (insert (propertize "row" 'octocat-url "https://github.com/o/r/pull/5"))
        (setq-local octocat--url-function #'octocat-dashboard--page-url)
        (goto-char (point-min))
        (octocat-browse)))
    (should (equal urls '("https://github.com/o/r/pull/5")))))

(provide 'octocat-dashboard-tests)
;;; octocat-dashboard-tests.el ends here
