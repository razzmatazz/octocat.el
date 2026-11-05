;;; octocat-dashboard-tests.el --- ERT tests for octocat-dashboard.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-dashboard-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

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
