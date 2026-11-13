;;; octocat-clone-tests.el --- ERT tests for octocat-clone.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-clone-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(defmacro octocat-clone-tests--with-remote (url &rest body)
  "Evaluate BODY with `vc-git-repository-url' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'vc-git-repository-url) (lambda (&rest _) ,url)))
     ,@body))

(ert-deftest octocat-clone-test-ssh ()
  "Parse SSH remote URL."
  (octocat-clone-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat-clone-current-repo) "owner/repo"))))

(ert-deftest octocat-clone-test-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-clone-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat-clone-current-repo) "owner/repo"))))

(ert-deftest octocat-clone-test-https ()
  "Parse HTTPS remote URL."
  (octocat-clone-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat-clone-current-repo) "owner/repo"))))

(ert-deftest octocat-clone-test-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-clone-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat-clone-current-repo) "owner/repo"))))

(ert-deftest octocat-clone-test-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-clone-tests--with-remote ""
    (should-error (octocat-clone-current-repo) :type 'user-error)))

(ert-deftest octocat-clone-test-parse-unpushed-merge ()
  "A commit of two parents is a merge, of one or none not."
  (should (equal (octocat-clone--parse-unpushed
                  '("aaa\0p1 p2\0Merge x" "bbb\0p1\0One" "ccc\0\0Root"))
                 '((:sha "aaa" :merge t :subject "Merge x")
                   (:sha "bbb" :merge nil :subject "One")
                   (:sha "ccc" :merge nil :subject "Root")))))

(ert-deftest octocat-clone-test-unpushed ()
  "Count local commits against the upstream, and how far it is ahead."
  (skip-unless (executable-find "git"))
  (let* ((root   (make-temp-file "octocat-unpushed" t))
         (origin (expand-file-name "origin" root))
         (clone  (expand-file-name "clone" root))
         (git    (lambda (dir &rest args)
                   (let ((default-directory (file-name-as-directory dir)))
                     (apply #'call-process "git" nil nil nil
                            "-c" "user.name=T" "-c" "user.email=t@t" args)))))
    (unwind-protect
        (progn
          (make-directory origin)
          (funcall git origin "init" "-q" "-b" "main")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "base")
          (funcall git root "clone" "-q" origin clone)
          (should-not (octocat-clone-unpushed clone))
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "one")
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "two")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "theirs")
          (funcall git clone "fetch" "-q")
          (let ((u (octocat-clone-unpushed clone)))
            (should (equal (mapcar (lambda (c) (plist-get c :subject))
                                   (plist-get u :commits))
                           '("two" "one")))
            (should (equal (plist-get u :upstream) "origin/main"))
            (should (= (plist-get u :behind) 1))))
      (delete-directory root t))))

(ert-deftest octocat-clone-test-tracked-branch ()
  "The clone's branch is followed under its name on origin, once pushed."
  (skip-unless (executable-find "git"))
  (let* ((root   (make-temp-file "octocat-tracked" t))
         (origin (expand-file-name "origin" root))
         (clone  (expand-file-name "clone" root))
         (git    (lambda (dir &rest args)
                   (let ((default-directory (file-name-as-directory dir)))
                     (apply #'call-process "git" nil nil nil
                            "-c" "user.name=T" "-c" "user.email=t@t" args)))))
    (unwind-protect
        (progn
          (make-directory origin)
          (funcall git origin "init" "-q" "-b" "main")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "base")
          (funcall git origin "branch" "theirs")
          (funcall git root "clone" "-q" origin clone)
          (should-not (octocat-clone-tracked-branch nil))
          (should (equal (octocat-clone-tracked-branch clone) "main"))
          (funcall git clone "checkout" "-q" "-b" "local" "origin/theirs")
          (should (equal (octocat-clone-tracked-branch clone) "theirs"))
          (funcall git clone "checkout" "-q" "-b" "unpushed")
          (should-not (octocat-clone-tracked-branch clone))
          (funcall git clone "push" "-q" "origin" "unpushed")
          (should (equal (octocat-clone-tracked-branch clone) "unpushed"))
          (funcall git clone "checkout" "-q" "--detach")
          (should-not (octocat-clone-tracked-branch clone)))
      (delete-directory root t))))

(ert-deftest octocat-clone-test-here-ref ()
  "The ref is the pushed branch, a pushed detached HEAD, or the default."
  (skip-unless (executable-find "git"))
  (let* ((root   (make-temp-file "octocat-here" t))
         (origin (expand-file-name "origin" root))
         (clone  (expand-file-name "clone" root))
         (git    (lambda (dir &rest args)
                   (let ((default-directory (file-name-as-directory dir)))
                     (apply #'call-process "git" nil nil nil
                            "-c" "user.name=T" "-c" "user.email=t@t" args)))))
    (unwind-protect
        (progn
          (make-directory origin)
          (funcall git origin "init" "-q" "-b" "main")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "base")
          (funcall git root "clone" "-q" origin clone)
          (should (equal (octocat-clone-here-ref clone) '("main" . "origin/main")))
          (funcall git clone "checkout" "-q" "--detach")
          (let ((sha (car (octocat-clone--git-lines clone "rev-parse" "HEAD"))))
            (should (equal (octocat-clone-here-ref clone) (cons sha sha))))
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "local")
          (should (equal (octocat-clone-here-ref clone) '(nil . "origin/HEAD")))
          (funcall git clone "checkout" "-q" "-b" "unpushed")
          (should (equal (octocat-clone-here-ref clone) '(nil . "origin/HEAD"))))
      (delete-directory root t))))

(ert-deftest octocat-clone-test-parse-ls-tree ()
  "Entries read as GitHub's: a submodule, sizes, and names with spaces and newlines."
  (let ((entries (octocat-clone-parse-ls-tree
                  (encode-coding-string
                   (concat "100644 blob aaaa      12\ta file.txt\0"
                           "040000 tree bbbb       -\tsrc\0"
                           "160000 commit cccc       -\tvendor/lib\0"
                           "100644 blob dddd       3\tline\nbreak ü\0")
                   'utf-8))))
    (should (equal (mapcar (lambda (e) (gethash "path" e)) entries)
                   '("a file.txt" "src" "vendor/lib" "line\nbreak ü")))
    (should (equal (mapcar (lambda (e) (gethash "type" e)) entries) '("blob" "tree" "commit" "blob")))
    (should (equal (mapcar (lambda (e) (gethash "size" e)) entries) '(12 nil nil 3)))
    (should (equal (gethash "mode" (nth 1 entries)) "040000"))
    (should (equal (gethash "sha" (nth 2 entries)) "cccc")))
  ;; Without --long, as `ls-tree -r' prints.
  (should (equal (gethash "path" (car (octocat-clone-parse-ls-tree "100644 blob aaaa\tsrc/x.el\0")))
                 "src/x.el"))
  (should-error (octocat-clone-parse-ls-tree "garbage\0")))

(defun octocat-clone-tests--await (local)
  "Call LOCAL, a :local function, and return its one answer."
  (let (answers)
    (funcall local (lambda (r) (push r answers)))
    (with-timeout (5 (error "No answer from git"))
      (while (not answers) (accept-process-output nil 0.05)))
    ;; Say the timer and the sentinel both answered: it shows by now.
    (accept-process-output nil 0.3)
    (should (= (length answers) 1))
    (car answers)))

(ert-deftest octocat-clone-test-reads ()
  "A clone answers trees, blobs and files at a commit; a missing object errs."
  (let* ((dir (file-name-as-directory (make-temp-file "octocat-clone-" t)))
         (default-directory dir)
         (octocat-clone--roots (make-hash-table :test #'equal)))
    (unwind-protect
        (cl-flet ((git (&rest args)
                    (with-temp-buffer
                      (should (eql 0 (apply #'process-file "git" nil t nil args)))
                      (string-trim (buffer-string))))
                  (local (spec) (plist-get (octocat-sync--props spec) :local)))
          (git "init" "-q")
          (make-directory "src")
          (write-region "hello\n" nil "a file.txt")
          (let ((coding-system-for-write 'binary))
            (write-region (unibyte-string 0 1 2) nil "src/b.bin"))
          (git "add" ".")
          (git "-c" "user.name=T" "-c" "user.email=t@example.com" "commit" "-q" "-m" "x")
          (octocat-clone-add "o/r" dir)
          (let ((commit (git "rev-parse" "HEAD"))
                (tree   (git "rev-parse" "HEAD^{tree}"))
                (blob   (git "rev-parse" "HEAD:src/b.bin")))
            (let ((entries (octocat-clone-tests--await (local (list 'tree-dir "o/r" tree)))))
              (should (vectorp entries))
              (should (equal (mapcar (lambda (e) (gethash "path" e)) entries) '("a file.txt" "src"))))
            (should (equal (octocat-model-blob-content
                            (octocat-clone-tests--await (local (list 'blob "o/r" blob))))
                           (unibyte-string 0 1 2)))
            (should (equal (gethash "src/b.bin" (octocat-clone-tests--await
                                                 (local (list 'tree-files "o/r" tree))))
                           blob))
            (should (equal (gethash "text" (octocat-clone-tests--await
                                            (local (list 'file-text "o/r" commit "a file.txt"))))
                           "hello\n"))
            (should (equal (octocat-model-tree-shas
                            (octocat-clone-tests--await
                             (local (list 'tree-path "o/r" commit "src/b.bin/c"))))
                           (vector tree (git "rev-parse" "HEAD:src") nil nil)))
            ;; Only at a SHA: a branch can be behind GitHub.
            (should-not (local (list 'file-text "o/r" "main" "a file.txt")))
            (should-not (local (list 'tree-path "o/r" "main" "src")))
            ;; A directory is no file, nor a missing object: GitHub is asked,
            ;; and the clone kept.
            (should (eq 'error (car (octocat-clone-tests--await
                                     (local (list 'file-blob "o/r" commit "src"))))))
            (should (eq 'error (car (octocat-clone-tests--await
                                     (local (list 'blob "o/r" (make-string 40 ?0)))))))
            (should (eq 'error (car (octocat-clone-tests--await
                                     (local (list 'tree-path "o/r" (make-string 40 ?0) "src")))))))
          (should (octocat-clone-root "o/r")))
      (delete-directory dir t))))

(ert-deftest octocat-clone-test-git-fails ()
  "A git that hangs, fails or is missing answers an error once, and the clone is dropped."
  (let* ((dir (file-name-as-directory (make-temp-file "octocat-git-" t)))
         (octocat-clone--roots (make-hash-table :test #'equal))
         (octocat-clone-timeout 0.3))
    (make-directory (expand-file-name ".git" dir))
    (unwind-protect
        (dolist (script '("sleep 10" "exit 1" nil))
          (let ((vc-git-program (expand-file-name "git" dir)))
            (if script
                (progn (write-region (concat "#!/bin/sh\n" script "\n") nil vc-git-program)
                       (set-file-modes vc-git-program #o755))
              (delete-file vc-git-program))
            (puthash "o/r" dir octocat-clone--roots)
            (should (eq 'error (car (octocat-clone-tests--await
                                     (octocat-clone-read "o/r" "abc" "tree" #'list #'ignore)))))
            (should-not (octocat-clone-root "o/r"))))
      (delete-directory dir t))))

(ert-deftest octocat-clone-test-log-commit ()
  "A `git log' header reads as GitHub's commit: its headline, dates and parents."
  (let ((c (octocat-clone--log-commit
            (encode-coding-string
             (mapconcat #'identity
                        '("abc" "p1 p2 p3" "Jü" "j@example.com" "2026-01-02T03:04:05+02:00"
                          "2026-01-03T00:00:00Z" "Fix it\n\nBody\n")
                        "\x1f")
             'utf-8))))
    (should (equal (gethash "oid" c) "abc"))
    (should (equal (gethash "messageHeadline" c) "Fix it"))
    (should (equal (gethash "authoredDate" c) "2026-01-02T01:04:05Z"))
    (should (equal (gethash "committedDate" c) "2026-01-03T00:00:00Z"))
    (should (equal (octocat--get c "author" "name") "Jü"))
    (should-not (octocat--get c "author" "user"))
    (should (equal (mapcar (lambda (p) (gethash "oid" p)) (octocat--get c "parents" "nodes"))
                   '("p1" "p2")))))

(ert-deftest octocat-clone-test-headline ()
  "A headline is the first line, cut past 72 characters as GitHub cuts it."
  (should (equal (octocat-clone--headline "One\nTwo") "One"))
  (should (equal (octocat-clone--headline (make-string 72 ?a)) (make-string 72 ?a)))
  (should (equal (octocat-clone--headline (make-string 73 ?a))
                 (concat (make-string 69 ?a) "…"))))

(ert-deftest octocat-clone-test-last-commits ()
  "Each entry's last commit comes from one walk, its author's user from the store."
  (let* ((dir (file-name-as-directory (make-temp-file "octocat-clone-" t)))
         (default-directory dir)
         (octocat-clone--roots (make-hash-table :test #'equal))
         (octocat-sync--db (octocat-sync--create (sqlite-open nil))))
    (unwind-protect
        (cl-flet ((git (&rest args)
                    (with-temp-buffer
                      (should (eql 0 (apply #'process-file "git" nil t nil
                                            "-c" "user.name=T" "-c" "user.email=t@example.com"
                                            args)))
                      (string-trim (buffer-string))))
                  (local (spec) (plist-get (octocat-sync--props spec) :local)))
          (git "init" "-q")
          (make-directory "src")
          (write-region "a" nil "a.txt")
          (write-region "x" nil "src/x.el")
          (git "add" ".")
          (git "commit" "-q" "-m" "One\n\nmore")
          (write-region "y" nil "src/x.el")
          (git "commit" "-q" "-am" "Two")
          (write-region "b" nil "b.txt")
          (git "add" ".")
          (git "commit" "-q" "-m" "Three")
          ;; GitHub gave a commit of that email before.
          (octocat-sync--write octocat-sync--db "(other)"
                               (octocat--table "author" (octocat--table
                                                         "email" "t@example.com"
                                                         "user" (octocat--table "login" "tee")))
                               1.0)
          (octocat-clone-add "o/r" dir)
          (let* ((commit (git "rev-parse" "HEAD"))
                 (root   (octocat-clone-tests--await
                          (local (list 'tree-commits "o/r" commit "" (git "rev-parse" "HEAD^{tree}")))))
                 (src    (octocat-clone-tests--await
                          (local (list 'tree-commits "o/r" commit "src"
                                       (git "rev-parse" "HEAD:src"))))))
            (should (equal (mapcar (lambda (p) (gethash "messageHeadline" (gethash p root)))
                                   '("a.txt" "b.txt" "src"))
                           '("One" "Three" "Two")))
            (should (equal (gethash "oid" (gethash "b.txt" root)) commit))
            (should (equal (octocat--get (gethash "a.txt" root) "author" "user" "login") "tee"))
            (should (equal (hash-table-keys src) '("src/x.el")))
            (should (equal (gethash "messageHeadline" (gethash "src/x.el" src)) "Two"))
            ;; No commit yet: the page asks before it knows it.
            (should-not (local (list 'tree-commits "o/r" nil "" "x")))))
      (delete-directory dir t))))

(provide 'octocat-clone-tests)
;;; octocat-clone-tests.el ends here
