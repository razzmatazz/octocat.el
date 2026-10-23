;;; octocat-search-tests.el --- ERT tests for octocat-search.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-search-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defmacro octocat-search-tests--with-store (&rest body)
  "Run BODY against an empty in-memory store and queue.
Each `gh' call is pushed to `calls' as (ARGS . CALLBACK), not run."
  (declare (indent 0))
  `(let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
         (octocat-sync--loading (make-hash-table :test #'equal))
         (octocat-sync--queue nil)
         (octocat-sync--prefetches nil)
         (octocat-sync--prefetching nil)
         (octocat-sync--running 0)
         (octocat-sync--waiters nil)
         (calls nil))
     (cl-letf (((symbol-function 'octocat--run-gh)
                (lambda (_name args parse callback)
                  (push (cons args (lambda (output) (funcall callback (funcall parse output))))
                        calls))))
       ,@body)))

(defun octocat-search-tests--sink (log)
  "Return a consult sink keeping its candidates in the car of LOG."
  (lambda (action)
    (pcase action
      ('flush (setcar log nil))
      ((pred consp) (setcar log (append (car log) action)))
      ((pred vectorp) (setcdr log action)))))

(ert-deftest octocat-search-test-repo-search ()
  "Stored results show at once; new input cancels a queued fetch."
  (octocat-search-tests--with-store
    (let* ((log (list nil))
           (stage (funcall (octocat--async-search-repos #'identity)
                           (octocat-search-tests--sink log))))
      (funcall stage "emacs")
      (should (equal (car (car calls)) '("search" "repos" "--limit" "30"
                                         "--json" "fullName" "--include-forks=true"
                                         "emacs")))
      (funcall (cdr (pop calls)) "[{\"fullName\":\"o/emacs\"}]")
      (should (equal (car log) '("o/emacs")))
      (should (equal (cdr log) [indicator finished]))
      ;; Fresh: shown again with no fetch.
      (funcall stage "emacs")
      (should-not calls)
      (should (equal (car log) '("o/emacs")))
      ;; Users; a fetch queued behind full slots is dropped by new input.
      (let ((octocat-sync--running octocat-sync-max-requests))
        (funcall stage "@ali")
        (should (assoc "(repo-search \"@ali\")" octocat-sync--queue))
        (funcall stage "@alice")
        (should-not (assoc "(repo-search \"@ali\")" octocat-sync--queue)))
      (setq octocat-sync--queue nil)
      (setq octocat-sync--running 0)
      (clrhash octocat-sync--loading)
      (funcall stage "@alice")
      (funcall (cdr (pop calls)) "[{\"login\":\"alice\"}]")
      (should (equal (car log) '("@alice"))))))

(ert-deftest octocat-search-test-repo-search-args ()
  "Forks are searched; \"owner/name\" searches the repos of owner."
  (should (equal (octocat--repo-search-args "razzmatazz/open")
                 '("search" "repos" "--limit" "30" "--json" "fullName"
                   "--include-forks=true" "--owner=razzmatazz" "open")))
  (should (equal (last (octocat--repo-search-args "razzmatazz/"))
                 '("--owner=razzmatazz")))
  (should (equal (last (octocat--repo-search-args "openra")) '("openra"))))

;; Fields as `gh repo view' gives them, no more than the entity needs.
(defun octocat-search-tests--repo (name)
  "Return the `repo' entity of NAME."
  (let ((h (make-hash-table :test #'equal)))
    (puthash "nameWithOwner" name h)
    (octocat-sync-repo h)))

(ert-deftest octocat-search-test-repo-search-stored ()
  "Stored repos and users matching the input show at once, newest first;
GitHub's results lead once in, the stored ones it lacks after them."
  (octocat-search-tests--with-store
    (let ((now (float-time)))
      (octocat-sync--write octocat-sync--db "(repo-summary \"a/octocat.el\")"
                           (octocat-search-tests--repo "a/octocat.el") (- now 2))
      (octocat-sync--write octocat-sync--db "(repo-summary \"b/other\")"
                           (octocat-search-tests--repo "b/other") (- now 2))
      (octocat-sync--write octocat-sync--db "(repo-search \"oct\")"
                           ["c/octo" "A/Octocat.el" "@octo-org"] (- now 3))
      ;; Too old to lend its names.
      (octocat-sync--write octocat-sync--db "(repo-search \"o\")"
                           ["e/octo-old"] (- now octocat-search-reuse-for 1))
      (octocat-sync--write octocat-sync--db "(user-profile \"octavia\")"
                           (octocat-sync-user (let ((h (make-hash-table :test #'equal)))
                                                (puthash "login" "octavia" h)
                                                h))
                           (- now 1))
      (let* ((log (list nil))
             (stage (funcall (octocat--async-search-repos #'identity)
                             (octocat-search-tests--sink log))))
        (funcall stage "octo")
        (should (equal (car log) '("a/octocat.el" "c/octo")))
        (should (equal (cdr log) [indicator running]))
        (funcall (cdr (pop calls)) "[{\"fullName\":\"A/OCTOCAT.EL\"},{\"fullName\":\"d/octo\"}]")
        (should (equal (car log) '("A/OCTOCAT.EL" "d/octo" "c/octo")))
        (should (equal (cdr log) [indicator finished]))
        (funcall stage "@oct")
        (should (equal (car log) '("@octavia" "@octo-org")))))))

(ert-deftest octocat-search-test-repo-objects ()
  "Each type's stored result shows at once; its fetched one replaces it."
  (octocat-search-tests--with-store
    (cl-letf (((symbol-function 'octocat-tree--fetch-all-files)
               (lambda (_repo _sha callback) (funcall callback '(error . "no files")))))
      (octocat-sync--write octocat-sync--db
                           (octocat-sync-spec-key '(object-search "o/r" "issues" "crash"))
                           (vector (let ((h (make-hash-table :test #'equal)))
                                     (puthash "number" 1 h)
                                     (puthash "title" "Old crash" h)
                                     h))
                           0.0)
      (let* ((log (list nil))
             (stage (funcall (octocat--async-search-repo-objects "o/r" nil #'identity)
                             (octocat-search-tests--sink log)))
             (titles (lambda ()
                       (mapcar (lambda (c) (plist-get (get-text-property
                                                       0 'octocat-search-item c)
                                                      :title))
                               (car log)))))
        (funcall stage " Crash ")
        (should (equal (funcall titles) '("Old crash")))
        (should (equal (cdr log) [indicator running]))
        (should (= (length calls) 3))
        (dolist (call calls)
          (should (equal (car (last (car call))) "crash")))
        (pcase-dolist (`(,args . ,deliver) calls)
          (funcall deliver (if (member "issues" args)
                               "[{\"number\":2,\"title\":\"New crash\"}]"
                             "[]")))
        (should (equal (funcall titles) '("New crash")))
        (should (equal (cdr log) [indicator finished]))))))

;; Commits as the REST API gives them, no more than the search reads.
(defun octocat-search-tests--commit (sha message)
  "Return a commit of SHA and MESSAGE."
  (let ((commit (make-hash-table :test #'equal))
        (c      (make-hash-table :test #'equal)))
    (puthash "message" message c)
    (puthash "sha" sha commit)
    (puthash "commit" c commit)
    commit))

(ert-deftest octocat-search-test-repo-objects-stored ()
  "Stored PRs and commits matching the input show at once, and the commits
of the local clone once git is done; GitHub's results lead once in, each
item once."
  (octocat-search-tests--with-store
    (let ((now (float-time))
          (git-calls nil))
      (octocat-sync--write octocat-sync--db "(pr \"o/r\" 7)"
                           (octocat-sync-item 'pr "O/R"
                                              (let ((h (make-hash-table :test #'equal)))
                                                (puthash "number" 7 h)
                                                (puthash "title" "Fix the crash" h)
                                                (puthash "state" "OPEN" h)
                                                h))
                           (- now 1))
      (octocat-sync--write octocat-sync--db "(pr \"x/y\" 8)"
                           (octocat-sync-item 'pr "x/y"
                                              (let ((h (make-hash-table :test #'equal)))
                                                (puthash "number" 8 h)
                                                (puthash "title" "Another crash" h)
                                                h))
                           (- now 1))
      (octocat-sync--write octocat-sync--db "(commits \"o/r\" nil nil)"
                           (vector (octocat-search-tests--commit "aaa111" "Crash on start")
                                   (octocat-search-tests--commit "bbb222" "Unrelated"))
                           (- now 2))
      (cl-letf (((symbol-function 'octocat-tree--fetch-all-files)
                 (lambda (_repo _sha callback) (funcall callback '(error . "no files"))))
                ((symbol-function 'octocat--search-git)
                 (lambda (_dir args callback) (push (cons args callback) git-calls) #'ignore)))
        (let* ((log (list nil))
               (stage (funcall (octocat--async-search-repo-objects "o/r" "/clone/" #'identity)
                               (octocat-search-tests--sink log)))
               (items (lambda ()
                        (mapcar (lambda (c)
                                  (let ((item (get-text-property 0 'octocat-search-item c)))
                                    (or (plist-get item :number) (plist-get item :sha))))
                                (car log)))))
          (funcall stage "crash")
          (should (equal (funcall items) '(7 "aaa111")))
          (should (equal (cdr log) [indicator running]))
          (funcall (cdr (pop git-calls))
                   (list "ccc333\0Ann\0Another crash" "aaa111\0Ann\0Crash on start"))
          (should (equal (funcall items) '(7 "aaa111" "ccc333")))
          (pcase-dolist (`(,args . ,deliver) calls)
            (funcall deliver (cond ((member "prs" args)
                                    "[{\"number\":9,\"title\":\"Crash\"},{\"number\":7,\"title\":\"Fix the crash\"}]")
                                   ((member "commits" args)
                                    "[{\"sha\":\"ccc333\",\"commit\":{\"message\":\"Another crash\"}}]")
                                   (t "[]"))))
          (should (equal (funcall items) '(9 7 "ccc333" "aaa111")))
          (should (equal (cdr log) [indicator finished])))))))

(ert-deftest octocat-search-test-git-args ()
  "Commit messages are searched for every word; a SHA-like query names one."
  (should (equal (octocat--search-git-args "fix crash")
                 (list (list "log" "--remotes=origin" "-n" "30" "-i" "-F" "--all-match"
                             octocat--search-git-format "--grep=fix" "--grep=crash"))))
  (should (equal (cadr (octocat--search-git-args "a1b2c3"))
                 (list "log" "-n" "1" octocat--search-git-format "a1b2c3" "--")))
  (should (= (length (octocat--search-git-args "fix")) 1)))

(ert-deftest octocat-search-test-git ()
  "`git log' of a clone finds the commits on origin's branches only."
  (skip-unless (executable-find "git"))
  (let* ((dir (make-temp-file "octocat-git" t))
         (default-directory (file-name-as-directory dir))
         (git (lambda (&rest args) (apply #'process-file "git" nil nil nil args)))
         result)
    (unwind-protect
        (progn
          (funcall git "init" "-q")
          (funcall git "-c" "user.name=Ann" "-c" "user.email=a@b" "commit" "-q"
                   "--allow-empty" "-m" "Fix the crash")
          (funcall git "update-ref" "refs/remotes/origin/main" "HEAD")
          (funcall git "-c" "user.name=Ann" "-c" "user.email=a@b" "commit" "-q"
                   "--allow-empty" "-m" "Crash, not pushed")
          (octocat--search-git default-directory (octocat--search-git-args "crash")
                               (lambda (lines) (setq result (list lines))))
          (with-timeout (10 (error "Git timed out"))
            (while (null result) (accept-process-output nil 0.05)))
          (let ((commits (octocat--search-git-parse (car result))))
            (should (equal (mapcar (lambda (c) (gethash "message" (gethash "commit" c))) commits)
                           '("Fix the crash")))))
      (delete-directory dir t))))

(provide 'octocat-search-tests)
;;; octocat-search-tests.el ends here
