;;; octocat-user-tests.el --- ERT tests for octocat-user.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-user-tests.el

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
    (octocat-sync--write db "p" (octocat-user--parse-profile
                                 "{\"login\":\"octocat\",\"name\":\"The Octocat\",\"type\":\"User\",\"bio\":\"Hi\",\"company\":\"@github\",\"location\":null,\"blog\":\"\",\"followers\":3,\"following\":1,\"public_repos\":8}")
                         1.0)
    (let ((lines (mapcar #'substring-no-properties
                         (octocat-user--profile-lines (car (octocat-sync--read db "p"))))))
      (should (equal (nth 0 lines) "@octocat  The Octocat"))
      (should (equal (nth 1 lines) "Hi"))
      (should (equal (nth 2 lines) "@github"))
      (should (equal (nth 3 lines) "3 followers  ·  1 following  ·  8 public repos")))))

(ert-deftest octocat-user-test-parse-pinned ()
  "Pinned repositories become repo entities; gists and unknown owners drop out."
  (let* ((tree (octocat-user--parse-pinned
                (concat "{\"data\":{\"repositoryOwner\":{\"pinnedItems\":{\"nodes\":["
                        "{\"nameWithOwner\":\"bob/App\",\"description\":null,"
                        "\"stargazerCount\":7,\"primaryLanguage\":{\"name\":\"Go\"},"
                        "\"pushedAt\":\"2026-01-01T10:00:00Z\",\"isFork\":false,\"isArchived\":true},"
                        "{}]}}}}")))
         (nodes (gethash "nodes" tree)))
    (should (= (length nodes) 1))
    (should (equal (octocat-sync--entity-key (aref nodes 0)) "repo:bob/app"))
    (should (eq (gethash "isArchived" (octocat-sync--entity-fields (aref nodes 0))) t))
    (should (equal (gethash "nodes" (octocat-user--parse-pinned
                                     "{\"data\":{\"repositoryOwner\":null}}"))
                   []))))

(ert-deftest octocat-user-test-repos-share-entities ()
  "The REST list and the pinned list write one entity per repository."
  (let ((db (octocat-sync--create (sqlite-open nil))))
    (octocat-sync--write
     db "pinned"
     (octocat-user--parse-pinned
      "{\"data\":{\"repositoryOwner\":{\"pinnedItems\":{\"nodes\":[{\"nameWithOwner\":\"bob/app\",\"description\":\"old\",\"isFork\":false}]}}}}")
     1.0)
    (should (equal (sort (octocat-sync--write
                          db "repos"
                    (octocat-user--parse-repos
                     "[{\"full_name\":\"bob/app\",\"description\":\"new\",\"language\":\"Go\",\"fork\":false}]")
                          2.0)
                         #'string<)
                   '("pinned" "repos")))
    (let ((repo (aref (gethash "nodes" (car (octocat-sync--read db "pinned"))) 0)))
      (should (equal (gethash "description" repo) "new"))
      (should (equal (gethash "name" (gethash "primaryLanguage" repo)) "Go")))))

(provide 'octocat-user-tests)
;;; octocat-user-tests.el ends here
