;;; octocat-user-tests.el --- ERT tests for octocat-user.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-user-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-user-test-normalize ()
  "A handle is accepted with or without \"@\"; anything else is rejected."
  (should (equal (octocat-user--normalize "@octocat") "octocat"))
  (should (equal (octocat-user--normalize "  octo-cat ") "octo-cat"))
  (should-not (octocat-user--normalize "octocat/hello"))
  (should-not (octocat-user--normalize "@"))
  (should-not (octocat-user--normalize "")))

(ert-deftest octocat-user-test-profile-lines ()
  "The header shows the handle, name, bio, details and counts."
  (let ((db (octocat-sync--create (sqlite-open nil))))
    (octocat-sync--write db "p" (octocat-model--user-parse-profile
                                 (octocat-sync--parse "{\"login\":\"octocat\",\"name\":\"The Octocat\",\"type\":\"User\",\"bio\":\"Hi\",\"company\":\"@github\",\"location\":null,\"blog\":\"\",\"followers\":3,\"following\":1,\"public_repos\":8}"))
                         1.0)
    (let ((lines (mapcar #'substring-no-properties
                         (octocat-user--profile-lines (car (octocat-sync--read db "p"))))))
      (should (equal (nth 0 lines) "@octocat  The Octocat"))
      (should (equal (nth 1 lines) "Hi"))
      (should (equal (nth 2 lines) "@github"))
      (should (equal (nth 3 lines) "3 followers  ·  1 following  ·  8 public repos")))))

(ert-deftest octocat-user-test-avatar-columns-follow-window-width ()
  "The avatar takes a quarter of the window, within its limits."
  (let ((octocat-user-avatar-max-columns 40))
    (should (= (octocat-user--avatar-columns 80) 20))
    (should (= (octocat-user--avatar-columns 120) 30))
    (should (= (octocat-user--avatar-columns 400) 40))
    (should (= (octocat-user--avatar-columns 40) 0))))

(ert-deftest octocat-user-test-beside-pads-the-shorter-side ()
  "Lines sit to the right of the avatar; the shorter list is padded."
  (should (equal (octocat-user--beside '("ab" "cd") "  " '("one"))
                 '("ab  one" "cd  ")))
  (should (equal (octocat-user--beside '("ab") "  " '("one" "two"))
                 '("ab  one" "    two"))))

(provide 'octocat-user-tests)
;;; octocat-user-tests.el ends here
