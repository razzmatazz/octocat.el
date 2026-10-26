;;; octocat-repo-tests.el --- ERT tests for octocat-repo.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-repo-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defmacro octocat-repo-tests--with-remote (url &rest body)
  "Evaluate BODY with `shell-command-to-string' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) ,url)))
     ,@body))

(ert-deftest octocat-repo-test-ssh ()
  "Parse SSH remote URL."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https ()
  "Parse HTTPS remote URL."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-repo-tests--with-remote ""
    (should-error (octocat-repo--current-repo) :type 'user-error)))

(ert-deftest octocat-repo-test-state-label ()
  "State labels are fixed-width words; only open PRs can be drafts."
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN")) "open  "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "CLOSED")) "closed"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "MERGED" t)) "merged"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" t)) "draft "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" :false)) "open  ")))

(defun octocat-repo-tests--commits (&rest shas)
  "Return commit hash-tables for SHAS."
  (mapcar (lambda (sha)
            (let ((c (make-hash-table :test #'equal)))
              (puthash "sha" sha c)
              c))
          shas))

(ert-deftest octocat-repo-test-commits-merge ()
  "The longest list from the same head wins; another head is dropped."
  (let ((fresh  (octocat-repo-tests--commits "c" "b"))
        (longer (octocat-repo-tests--commits "c" "b" "a"))
        (stale  (octocat-repo-tests--commits "b" "a" "z")))
    (should (eq (octocat-repo--commits-merge fresh longer) longer))
    (should (eq (octocat-repo--commits-merge fresh stale) fresh))
    (should (eq (octocat-repo--commits-merge longer fresh nil) longer))
    (should-not (octocat-repo--commits-merge nil fresh))))

(ert-deftest octocat-repo-test-branch-candidates ()
  "The default branch comes first, then the pushed local one, each noted."
  (should (equal (octocat--branch-candidates '("a" "main" "feat") "main" "feat")
                 '("main" "feat" "a")))
  (should (equal (octocat--branch-candidates '("a" "main") "main" "unpushed")
                 '("main" "a")))
  (should (equal (octocat--branch-candidates '("a" "main") "main" "main")
                 '("main" "a")))
  (should (equal (octocat--branch-note "main" "main" "feat") "  default"))
  (should (equal (octocat--branch-note "feat" "main" "feat") "  checked out"))
  (should-not (octocat--branch-note "a" "main" "feat")))

(ert-deftest octocat-repo-test-async-branches ()
  "The stored branches show first; the fetched ones replace them in the store."
  (let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
        (octocat-sync--loading (make-hash-table :test #'equal))
        (octocat-sync--queue nil)
        (octocat-sync--prefetches nil)
        (octocat-sync--prefetching nil)
        (octocat-sync--running 0)
        (octocat-sync--waiters nil)
        got deliver)
    (cl-letf (((symbol-function 'octocat--list-branches)
               (lambda (_repo callback) (setq deliver callback))))
      ;; Stored long ago, so it is refetched.
      (octocat-sync--write octocat-sync--db (octocat-sync-spec-key '(branches "o/r"))
                           ["old" "main"] 0.0)
      (let ((stage (funcall (octocat--async-branches "o/r" "main" nil)
                            (lambda (action)
                              (pcase action
                                ('flush (setq got nil))
                                ((pred consp) (setq got (append got action))))))))
        (funcall stage 'setup)
        (should (equal got '("main" "old")))
        (funcall deliver '("new" "main"))
        (should (equal got '("main" "new")))
        (should (equal (plist-get (octocat-sync-read '(branches "o/r")) :data)
                       ["new" "main"]))))))

(ert-deftest octocat-repo-test-run-title-width ()
  "The run title column fits the longest title, within the width left."
  (let ((runs (mapcar (lambda (title)
                        (let ((r (make-hash-table :test #'equal)))
                          (puthash "displayTitle" title r)
                          r))
                      (list (make-string 30 ?t) "short"))))
    (should (= (octocat-run-list--title-width runs 200 4) 30))
    (should (= (octocat-run-list--title-width runs 60 4)
               octocat-run-list--title-min-width))
    ;; The other columns: branch 10, id 11, workflow 4, icon, date and gaps.
    (let ((octocat-branch-max-width 10)
          (date-w (string-width (octocat--format-ts-relative ""))))
      (should (= (octocat-run-list--title-width runs (+ 37 date-w 27) 4) 27)))))

(ert-deftest octocat-repo-test-workflow-columns ()
  "Workflow rows give the name the room the state and file name leave."
  (let ((wfs (mapcar (pcase-lambda (`(,name ,path))
                       (let ((wf (make-hash-table :test #'equal)))
                         (puthash "name" name wf)
                         (puthash "path" path wf)
                         (puthash "state" "active" wf)
                         wf))
                     '(("Test" ".github/workflows/test.yml")
                       ("Release builds" ".github/workflows/release.yml")))))
    (should (equal (octocat-workflow--file (car wfs)) "test.yml"))
    (should (= (octocat-workflow-list--name-width wfs 200 6) 14))
    ;; 30 columns leave 8 beside the state and release.yml: the floor wins.
    (should (= (octocat-workflow-list--name-width wfs 30 6) 10))
    (should (= (octocat-workflow-list--name-width (list (car wfs)) 200 6) 4))))

(ert-deftest octocat-repo-test-item-lines ()
  "Item lines put the labels on the title line and cut only given a width."
  (let ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                     :chips "bug" :branch "b" :number "#1")))
    (pcase-let ((`(,top ,bottom) (octocat-repo-vui--item-lines "open" cells '(:review :branch))))
      (should (string-suffix-p "  bug" top))
      (should (string-match-p (make-string 60 ?t) top))
      (should (string-suffix-p "#1 by @a · 1d · b" bottom)))
    (dolist (line (octocat-repo-vui--item-lines "open" cells '(:branch) 40))
      (should (<= (string-width line) 39)))))

(ert-deftest octocat-repo-test-compact-line ()
  "A compact line has the number, title, labels and author, without the age."
  (let* ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                      :chips "bug" :number "o/r#1"))
         (line  (octocat-repo-vui--compact-line "open" "#1" cells)))
    (should (string-prefix-p "open  #1  t" line))
    (should (string-suffix-p "  bug · @a" line))
    (should-not (string-search "o/r" line))
    (should-not (string-search "1d" line))
    (let ((cut (octocat-repo-vui--compact-line "open" "#1" cells 40)))
      (should (<= (string-width cut) 39))
      (should (string-suffix-p "  bug · @a" cut)))
    ;; A short title leaves the author at the right edge all the same.
    (let ((short (octocat-repo-vui--compact-line
                  "open" "#1" (plist-put (copy-sequence cells) :title "t") 40)))
      (should (= (string-width short) 39))
      (should (string-suffix-p " · @a" short)))
    (should (string-prefix-p "#1  t" (octocat-repo-vui--compact-line nil "#1" cells)))))

(ert-deftest octocat-repo-test-compact-width ()
  "The widest line sets the width, up to the window's."
  (should (= (octocat-repo-vui--compact-width '("abc" "abcdef") 80) 7))
  (should (= (octocat-repo-vui--compact-width '("abc" "abcdef") 5) 5)))

(ert-deftest octocat-repo-test-unpushed ()
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
          (should-not (octocat-repo--unpushed clone))
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "one")
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "two")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "theirs")
          (funcall git clone "fetch" "-q")
          (let ((u (octocat-repo--unpushed clone)))
            (should (equal (mapcar (lambda (c) (plist-get c :subject))
                                   (plist-get u :commits))
                           '("two" "one")))
            (should (equal (plist-get u :upstream) "origin/main"))
            (should (= (plist-get u :behind) 1))))
      (delete-directory root t))))

(ert-deftest octocat-repo-test-tracked-branch ()
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
          (should-not (octocat-repo--tracked-branch nil))
          (should (equal (octocat-repo--tracked-branch clone) "main"))
          (funcall git clone "checkout" "-q" "-b" "local" "origin/theirs")
          (should (equal (octocat-repo--tracked-branch clone) "theirs"))
          (funcall git clone "checkout" "-q" "-b" "unpushed")
          (should-not (octocat-repo--tracked-branch clone))
          (funcall git clone "push" "-q" "origin" "unpushed")
          (should (equal (octocat-repo--tracked-branch clone) "unpushed"))
          (funcall git clone "checkout" "-q" "--detach")
          (should-not (octocat-repo--tracked-branch clone)))
      (delete-directory root t))))

(ert-deftest octocat-repo-test-parse-history ()
  "History edges become REST-shaped commits that keep their cursor."
  (let* ((json "{\"data\":{\"repository\":{\"object\":{\"history\":{\"edges\":[{\"cursor\":\"abc 0\",\"node\":{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}},{\"cursor\":\"abc 1\",\"node\":{\"oid\":\"def\",\"messageHeadline\":\"Old\",\"authoredDate\":\"2026-10-13T00:00:00Z\",\"author\":{\"name\":\"Bo\",\"email\":\"b@x\",\"user\":null}}}]}}}}}")
         (commits (octocat-repo--parse-history json))
         (first   (car commits)))
    (should (equal (gethash "sha" first) "abc"))
    (should (equal (gethash "message" (gethash "commit" first)) "Fix it"))
    (should (equal (octocat--commit-author first) "@ann"))
    (should (equal (octocat--commit-author (cadr commits)) "Bo"))
    (should (equal (gethash "cursor" (cadr commits)) "abc 1"))
    (should-not (gethash "total" first)))
  (should (equal (gethash "total" (car (octocat-repo--parse-history
                                        "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":7,\"edges\":[{\"cursor\":\"c\",\"node\":{\"oid\":\"abc\"}}]}}}}}")))
                 7))
  (should-error (octocat-repo--parse-history
                 "{\"data\":{\"repository\":{\"object\":null}}}")))

(ert-deftest octocat-repo-test-numbers-link ()
  "Each number opens its own issue, in its repository when another."
  (let* ((refs (json-parse-string
                "[{\"number\":3},{\"number\":4,\"repository\":{\"name\":\"x\",\"owner\":{\"login\":\"o\"}}}]"))
         (links (seq-filter #'vui-vnode-button-p
                            (octocat-repo-vui--numbers "a/b" refs (lambda (r n) (list r n))))))
    (should (equal (mapcar #'vui-vnode-button-label links) '("#3" "o/x#4")))
    (should (equal (funcall (vui-vnode-button-on-click (cadr links))) '("o/x" 4)))))

(ert-deftest octocat-repo-test-docs ()
  "The documents are found by name, a markdown README winning, in GitHub's order."
  (let* ((entry (lambda (name &optional type)
                  (let ((h (make-hash-table :test #'equal)))
                    (puthash "path" name h)
                    (puthash "type" (or type "blob") h)
                    h)))
         (docs (octocat-repo--docs
                (cons (funcall entry "SECURITY" "tree")
                      (mapcar entry '("LICENSE" "Makefile" "README" "readme.md"
                                      "README.txt" "CONTRIBUTING.md" "licenses.txt"))))))
    (should (equal (mapcar #'car docs) '(readme contrib license)))
    (should (equal (gethash "path" (nth 2 (assq 'readme docs))) "readme.md"))
    (should (equal (gethash "path" (nth 2 (assq 'license docs))) "LICENSE"))))

(ert-deftest octocat-repo-test-doc-relative-links ()
  "A document's relative links open its repository's files at the ref shown."
  (let ((text (octocat-repo--doc-text "o/r" "dev" "docs/GUIDE.md"
                                      "[shots](shots/README.md)" nil 80)))
    (should (equal (get-text-property (string-search "shots" text)
                                      'octocat-markdown-url text)
                   "https://github.com/o/r/blob/dev/docs/shots/README.md"))))

(ert-deftest octocat-repo-test-parse-head ()
  "A directory at a ref has its last commit, its tree and its history count."
  (let ((head (octocat-repo--parse-head
               "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":42,\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}]}},\"dir\":{\"__typename\":\"Tree\",\"oid\":\"t1\"}}}}"
               "main" "src")))
    (should (equal (gethash "sha" head) "abc"))
    (should (equal (octocat--commit-author head) "@ann"))
    (should (equal (gethash "tree" head) "t1"))
    (should (equal (gethash "kind" head) "tree"))
    (should (equal (gethash "total" head) 42)))
  (should-error (octocat-repo--parse-head
                 "{\"data\":{\"repository\":{\"object\":null,\"dir\":null}}}" "nope" nil))
  (should-error (octocat-repo--parse-head
                 "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":0,\"nodes\":[]}},\"dir\":null}}}"
                 "main" "missing")))

(ert-deftest octocat-repo-test-file-notice ()
  "A binary or large file is not shown unasked; an image or small file is."
  (let ((head (octocat-repo--parse-head
               "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":1,\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Add\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}]}},\"dir\":{\"__typename\":\"Blob\",\"oid\":\"b1\",\"byteSize\":2000000,\"isBinary\":false}}}}"
               "main" "dist/app.min.js")))
    (should (equal (gethash "size" head) 2000000))
    (should (string-match-p "too large" (octocat-repo--file-notice "dist/app.min.js" head)))
    (should-not (octocat-repo--file-notice "docs/a.png" head))
    (puthash "binary" t head)
    (should (string-match-p "binary" (octocat-repo--file-notice "a.bin" head)))
    (puthash "binary" nil head)
    (puthash "size" 100 head)
    (should-not (octocat-repo--file-notice "src/a.el" head))))

(ert-deftest octocat-repo-test-compact-pr-row-marks-draft ()
  "Without the state column, a compact draft PR row says (draft) before its title."
  (let ((pr (make-hash-table :test #'equal)))
    (puthash "number" 7 pr)
    (puthash "title" "Wip" pr)
    (puthash "state" "OPEN" pr)
    (puthash "isDraft" t pr)
    (should (string-prefix-p "#7  (draft) Wip"
                             (octocat-repo-vui--pr-compact-line "o/r" pr nil t)))
    (should-not (string-search "(draft)" (octocat-repo-vui--pr-compact-line "o/r" pr nil nil)))
    (puthash "isDraft" :false pr)
    (should (string-prefix-p "#7  Wip" (octocat-repo-vui--pr-compact-line "o/r" pr nil t)))))

(ert-deftest octocat-repo-browse-default-branch-opens-repo ()
  "Off an entry, C-c C-o opens the bare repo URL on the default branch."
  (with-temp-buffer
    (octocat-repo-mode)
    (setq octocat-repo--repo "o/r"
          octocat-repo--default-branch "main")
    (let (browsed)
      (cl-letf (((symbol-function 'octocat-browse-external)
                 (lambda (url) (push url browsed)))
                ((symbol-function 'message) #'ignore))
        (dolist (tracked '("main" "dev"))
          (setq octocat-repo--tracked tracked)
          (octocat-repo-browse)))
      (should (equal (nreverse browsed)
                     '("https://github.com/o/r"
                       "https://github.com/o/r/tree/dev"))))))

(provide 'octocat-repo-tests)
;;; octocat-repo-tests.el ends here
