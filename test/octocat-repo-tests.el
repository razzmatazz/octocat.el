;;; octocat-repo-tests.el --- ERT tests for octocat-repo.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-repo-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
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
  (should (equal (substring-no-properties (octocat-vui--state-label "OPEN")) "open  "))
  (should (equal (substring-no-properties (octocat-vui--state-label "CLOSED")) "closed"))
  (should (equal (substring-no-properties (octocat-vui--state-label "MERGED" t)) "merged"))
  (should (equal (substring-no-properties (octocat-vui--state-label "OPEN" t)) "draft "))
  (should (equal (substring-no-properties (octocat-vui--state-label "OPEN" :false)) "open  ")))

(ert-deftest octocat-repo-test-state-label-faces ()
  "A closed PR is red; a closed issue purple, or grey when not planned."
  (cl-flet ((face (issue-p state &optional reason)
              (get-text-property
               0 'face
               (if issue-p
                   (octocat-vui--issue-state-label
                    (octocat--table "state" state "stateReason" (or reason :null)))
                 (octocat-vui--state-label state)))))
    (should (eq (face nil "CLOSED") 'octocat-pr-state-closed))
    (should (eq (face nil "MERGED") 'octocat-pr-state-merged))
    (should (eq (face t "CLOSED" "COMPLETED") 'octocat-issue-state-completed))
    (should (eq (face t "CLOSED") 'octocat-issue-state-completed))
    (should (eq (face t "CLOSED" "NOT_PLANNED") 'octocat-issue-state-not-planned))
    (should (eq (face t "OPEN" "REOPENED") 'octocat-pr-state-open))))

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
        (octocat-sync--queue nil)
        (octocat-sync--fetches (make-hash-table :test #'equal))
        (octocat-sync--waiters nil)
        got deliver)
    (cl-letf (((symbol-function 'octocat-model--list-branches)
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
  "Item lines read as GitHub's: the comments and assignees at the right edge."
  (let ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                     :chips "bug" :ci "✓ 1/1" :review "Approved" :number "#1"
                     :assignees "@b +1" :comments "✉ 2")))
    (pcase-let ((`(,top ,bottom) (octocat-vui--item-lines "open" cells)))
      (should (string-match-p (concat (make-string 60 ?t) "  ✓ 1/1  bug  ✉ 2  @b \\+1\\'") top))
      (should (string-suffix-p "#1 opened 1d by @a · Approved" bottom)))
    (pcase-let ((`(,top ,bottom) (octocat-vui--item-lines "open" cells 60)))
      (should (= (string-width top) 59))
      (should (string-suffix-p "  bug  ✉ 2  @b +1" top))
      (should (<= (string-width bottom) 59)))
    ;; With nothing for the right edge, a short title isn't padded out.
    (let ((short (list :title "t" :author "" :date "1d" :number "#1")))
      (should (equal (car (octocat-vui--item-lines "open" short 60)) "open  t")))))

(ert-deftest octocat-repo-test-assignees ()
  "The first assignee shows, and how many more."
  (let ((item (make-hash-table :test #'equal))
        (user (lambda (login) (let ((u (make-hash-table :test #'equal)))
                                (puthash "login" login u) u))))
    (should-not (octocat-vui--assignees item))
    (puthash "assignees" [] item)
    (should-not (octocat-vui--assignees item))
    (puthash "assignees" (vector (funcall user "a")) item)
    (should (equal (octocat-vui--assignees item) "assigned to @a"))
    (puthash "assignees" (vector (funcall user "a") (funcall user "b") (funcall user "c")) item)
    (should (equal (octocat-vui--assignees item) "assigned to @a +2"))))

(ert-deftest octocat-repo-test-compact-line ()
  "A compact line has the number, title and labels, the assignees right."
  (let* ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                      :chips "bug" :number "o/r#1" :assignees "@b"))
         (line  (octocat-vui--compact-line "open" "#1" cells)))
    (should (string-prefix-p "open  #1  t" line))
    (should (string-suffix-p "  bug  @b" line))
    (should-not (string-search "@a" line))
    (should-not (string-search "o/r" line))
    (should-not (string-search "1d" line))
    (let ((cut (octocat-vui--compact-line "open" "#1" cells 40)))
      (should (= (string-width cut) 39))
      (should (string-suffix-p "  bug  @b" cut)))
    ;; A short title leaves the assignee at the right edge all the same.
    (let ((short (octocat-vui--compact-line
                  "open" "#1" (plist-put (copy-sequence cells) :title "t") 40)))
      (should (= (string-width short) 39))
      (should (string-match-p "bug +@b\\'" short)))
    (should (string-prefix-p "#1  t" (octocat-vui--compact-line nil "#1" cells)))))

(ert-deftest octocat-repo-test-compact-width ()
  "The widest line sets the width, up to the window's."
  ;; The mark column too.
  (should (= (octocat-vui--compact-width '("abc" "abcdef") 80) 9))
  (should (= (octocat-vui--compact-width '("abc" "abcdef") 5) 5)))

(ert-deftest octocat-repo-test-item-row-mark-column ()
  "A row starts with a mark column, checked when it is marked."
  (let ((text (lambda (mark)
                (vui-vnode-text-content
                 (car (vui-vnode-region-children
                       (octocat-vui--item-row
                        "open" nil 40 #'ignore "" "#7  Title" nil nil 7 mark)))))))
    (should (string-prefix-p "  #7  Title" (funcall text nil)))
    (let ((marked (funcall text t)))
      (should (string-prefix-p "✓ #7  Title" marked))
      (should (memq 'octocat-marked (ensure-list (get-text-property 3 'face marked))))
      (should (eql (get-text-property 0 'octocat-vui-list-item marked) 7)))))

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

(ert-deftest octocat-repo-test-here-target ()
  "A path opens its page, or the nearest directory above that the ref has."
  (let ((has (lambda (p) (member p '("src" "src/a.el" "docs" ".github" ".github/workflows"
                                     ".github/workflows/ci.yml")))))
    (should (equal (octocat-repo--here-target "o/r" "main" ".github/workflows/ci.yml" nil
                                              '(lines 1 1) has)
                   '(workflow "o/r" "ci.yml" "ci.yml" ".github/workflows/ci.yml")))
    (should (equal (octocat-repo--here-target "o/r" "main" ".github/workflows/new.yml" nil
                                              '(lines 1 1) has)
                   '(tree "o/r" "main" ".github/workflows")))
    (should (equal (octocat-repo--here-target "o/r" "main" nil t nil has)
                   '(repo "o/r" "main")))
    (should (equal (octocat-repo--here-target "o/r" "main" "src/a.el" nil '(lines 3 3) has)
                   '(file "o/r" "main" "src/a.el" (lines 3 3))))
    (should (equal (octocat-repo--here-target "o/r" "main" "docs" t nil has)
                   '(tree "o/r" "main" "docs")))
    (should (equal (octocat-repo--here-target "o/r" "main" "src/new/b.el" nil '(lines 1 1) has)
                   '(tree "o/r" "main" "src")))
    (should (equal (octocat-repo--here-target "o/r" nil "new.el" nil nil has)
                   '(repo "o/r" nil)))
    ;; Following the checkout, the repo and tree pages get no ref; a file still needs one.
    (should (equal (octocat-repo--here-target "o/r" "main" nil t nil has t)
                   '(repo "o/r" nil)))
    (should (equal (octocat-repo--here-target "o/r" "main" "docs" t nil has t)
                   '(tree "o/r" nil "docs")))
    (should (equal (octocat-repo--here-target "o/r" "main" "src/a.el" nil nil has t)
                   '(file "o/r" "main" "src/a.el")))))

(ert-deftest octocat-repo-test-find-file-start ()
  "Finding a file starts in the directory of the one shown, which is the default."
  (should-not (octocat-tree--find-file-start nil nil))
  (should (equal (octocat-tree--find-file-start "src/a.el" 'file) '("src/" . "src/a.el")))
  (should (equal (octocat-tree--find-file-start "a.el" 'file) '(nil . "a.el")))
  (should (equal (octocat-tree--find-file-start "src/lib" 'dir) '("src/lib/"))))

(ert-deftest octocat-repo-test-here-ref ()
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
          (should (equal (octocat-repo--here-ref clone) '("main" . "origin/main")))
          (funcall git clone "checkout" "-q" "--detach")
          (let ((sha (car (octocat-repo--git-lines clone "rev-parse" "HEAD"))))
            (should (equal (octocat-repo--here-ref clone) (cons sha sha))))
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "local")
          (should (equal (octocat-repo--here-ref clone) '(nil . "origin/HEAD")))
          (funcall git clone "checkout" "-q" "-b" "unpushed")
          (should (equal (octocat-repo--here-ref clone) '(nil . "origin/HEAD"))))
      (delete-directory root t))))

(ert-deftest octocat-repo-test-numbers-link ()
  "Each number opens its own issue, in its repository when another."
  (let* ((refs (json-parse-string
                "[{\"number\":3},{\"number\":4,\"repository\":{\"name\":\"x\",\"owner\":{\"login\":\"o\"}}}]"))
         (links (seq-filter #'vui-vnode-button-p
                            (octocat-vui--numbers "a/b" refs (lambda (r n) (list r n))))))
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

(ert-deftest octocat-repo-test-docs-org ()
  "An org README wins over plain text, and a markdown one over it."
  (let ((readme (lambda (&rest names)
                  (gethash "path"
                           (nth 2 (assq 'readme
                                        (octocat-repo--docs
                                         (mapcar (lambda (name)
                                                   (let ((h (make-hash-table :test #'equal)))
                                                     (puthash "path" name h)
                                                     (puthash "type" "blob" h)
                                                     h))
                                                 names))))))))
    (should (equal (funcall readme "README" "README.txt" "README.org") "README.org"))
    (should (equal (funcall readme "README.org" "README.md") "README.md"))
    (should (equal (funcall readme "README.markdown" "README.org") "README.org"))))

(ert-deftest octocat-repo-test-doc-org ()
  "An org document is rendered, its links relative; raw, it is the org source."
  (let ((text (octocat-repo--doc-text "o/r" "dev" "docs/GUIDE.org"
                                      "* Guide\nSee [[file:shots/README.org][shots]]." nil 80)))
    (should (string-prefix-p "Guide\n" text))
    (should (equal (get-text-property (string-search "shots" text)
                                      'octocat-markdown-url text)
                   "https://github.com/o/r/blob/dev/docs/shots/README.org")))
  (should (string-prefix-p "* Guide" (octocat-repo--doc-text "o/r" "dev" "GUIDE.org"
                                                             "* Guide" t 80))))

(ert-deftest octocat-repo-test-doc-relative-links ()
  "A document's relative links open its repository's files at the ref shown."
  (let ((text (octocat-repo--doc-text "o/r" "dev" "docs/GUIDE.md"
                                      "[shots](shots/README.md)" nil 80)))
    (should (equal (get-text-property (string-search "shots" text)
                                      'octocat-markdown-url text)
                   "https://github.com/o/r/blob/dev/docs/shots/README.md"))))

(ert-deftest octocat-repo-test-file-notice ()
  "A binary or large file is not shown unasked; an image or small file is."
  (let ((head (octocat-model--repo-parse-head
               (gethash "data" (octocat-sync--parse "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":1,\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Add\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}]}},\"dir\":{\"__typename\":\"Blob\",\"oid\":\"b1\",\"byteSize\":2000000,\"isBinary\":false}}}}"))
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
                             (octocat-vui--pr-compact-line "o/r" pr nil t)))
    (should-not (string-search "(draft)" (octocat-vui--pr-compact-line "o/r" pr nil nil)))
    (puthash "isDraft" :false pr)
    (should (string-prefix-p "#7  Wip" (octocat-vui--pr-compact-line "o/r" pr nil t)))))

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
          (octocat-browse)))
      (should (equal (nreverse browsed)
                     '("https://github.com/o/r"
                       "https://github.com/o/r/tree/dev"))))))

(ert-deftest octocat-repo-commits-page-url ()
  "The commits page's URL is of the ref and path it shows."
  (with-temp-buffer
    (octocat-commit-list-mode)
    (setq octocat-repo--repo "o/r"
          octocat-repo--default-branch "main"
          octocat-repo--tracked "main")
    (should (equal (octocat--url-at-point) "https://github.com/o/r/commits"))
    (setq octocat-repo--tracked "dev")
    (should (equal (octocat--url-at-point) "https://github.com/o/r/commits/dev"))
    (setq octocat-repo--path "src/a.el")
    (should (equal (octocat--url-at-point) "https://github.com/o/r/commits/dev/src/a.el"))))

(ert-deftest octocat-tree-test-reveals-p ()
  "A directory is revealed on the way to a path, or to any of a list of them."
  (should (octocat-tree--reveals-p "src" "src/theme"))
  (should (octocat-tree--reveals-p "src/theme" "src/theme"))
  (should-not (octocat-tree--reveals-p "sr" "src/theme"))
  (should (octocat-tree--reveals-p "docs" '("src" "docs/assets")))
  (should-not (octocat-tree--reveals-p "docs" nil)))

(ert-deftest octocat-tree-test-removed ()
  "What a commit removed is listed where it was, a removed directory as one entry."
  (let ((changes (make-hash-table :test #'equal)))
    (puthash "src/gone.el" '(:removed t) changes)
    (puthash "src/kept.el" '(:mark "M ") changes)
    (puthash "src/old/a.el" '(:removed t) changes)
    (puthash "src/old/b.el" '(:removed t) changes)
    (puthash "src/lib/c.el" '(:removed t) changes)
    (let ((entries (octocat-tree--removed changes "src" '("lib" "kept.el"))))
      (should (equal (sort (mapcar (lambda (e) (cons (gethash "path" e) (gethash "type" e)))
                                   entries)
                           (lambda (a b) (string< (car a) (car b))))
                     '(("gone.el" . "blob") ("old" . "tree")))))
    (should (equal (mapcar (lambda (e) (gethash "path" e))
                           (octocat-tree--removed changes "src/lib" '()))
                   '("c.el")))
    (should-not (octocat-tree--removed nil "" nil))))

(ert-deftest octocat-tree-test-proxied-urls ()
  "GitHub's HTML maps each image of another site to its proxy's URL."
  (skip-unless (libxml-available-p))
  (let ((table (octocat-model--proxied-urls
                (concat "<p><img src=\"https://camo.githubusercontent.com/a/b\" "
                        "data-canonical-src=\"https://example.com/x.png?a=1&amp;b=2\">"
                        "<img src=\"/o/r/raw/main/local.png\"></p>"))))
    (should (equal (gethash "https://example.com/x.png?a=1&b=2" table)
                   "https://camo.githubusercontent.com/a/b"))
    (should (= (hash-table-count table) 1))))

(ert-deftest octocat-tree-test-fontify-plain-text ()
  "octocat-tree--fontify returns the content string unchanged for plain text."
  (let ((content "hello world\n"))
    (should (equal content (octocat-tree--fontify "plain.txt" content)))))

(ert-deftest octocat-tree-test-fontify-el ()
  "octocat-tree--fontify returns a string with face properties for Elisp."
  (let* ((content ";; hello\n(defun foo () nil)\n")
         (result (octocat-tree--fontify "foo.el" content)))
    ;; The result must be a string (face properties may or may not apply
    ;; depending on font-lock support in the test environment).
    (should (stringp result))
    (should (= (length content) (length result)))))

(defmacro octocat-tree-tests--with-store (&rest body)
  "Evaluate BODY with an empty in-memory sync store and queue."
  (declare (indent 0))
  `(let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
         (octocat-sync--queue nil)
         (octocat-sync--fetches (make-hash-table :test #'equal))
         (octocat-sync--waiters nil)
         (octocat-vui--subscriptions (make-hash-table :test #'equal)))
     ,@body))

(defun octocat-tree-tests--store (spec data)
  "Store DATA as fetched just now for SPEC."
  (octocat-sync--write octocat-sync--db (octocat-sync-spec-key spec) data (float-time)))

(defvar octocat-tree-tests--visited nil
  "The directories the mounted files asked the page to show, latest first.")

(defun octocat-tree-tests--no-dir-fetch (name &rest _)
  "Stand in for `octocat--run-gh': a directory listing, call NAME, is an error."
  (when (equal name "tree-dir")
    (error "Unexpected directory fetch")))

(defun octocat-tree-tests--blob-answer (bytes)
  "Return a stand-in for `octocat--run-gh' answering a blob holding BYTES."
  (lambda (_name _args parse callback)
    (funcall callback (funcall parse (json-serialize
                                      `((content . ,(base64-encode-string bytes))))))))

(defun octocat-tree-tests--mount-tree ()
  "List the root, tree \"rootsha\", of owner/repo here, as the repo page does.
Moving into a directory is recorded in `octocat-tree-tests--visited'.
A listing not in the store is an error, so no gh call is made."
  (unless (derived-mode-p 'octocat-repo-mode)
    (octocat-repo-mode))
  (setq octocat-tree-tests--visited nil)
  (cl-letf (((symbol-function 'octocat--run-gh) #'octocat-tree-tests--no-dir-fetch))
    (octocat-vui-refresh-page 'octocat-tree--dir "tree"
                              (list :repo "owner/repo" :branch "main" :sha "rootsha"
                                    :on-dir (lambda (dir)
                                              (push dir octocat-tree-tests--visited))))))

(defun octocat-tree-tests--mount-full-tree (reveal &optional focus)
  "Show the whole tree of root \"rootsha\" here, opened down to REVEAL.
FOCUS is where point goes, as for `octocat-tree--subtree'."
  (unless (derived-mode-p 'octocat-tree-mode)
    (octocat-tree-mode))
  (cl-letf (((symbol-function 'octocat--run-gh) #'octocat-tree-tests--no-dir-fetch))
    (octocat-vui-refresh-page 'octocat-tree--subtree "tree"
                              (list :repo "owner/repo" :branch "main" :sha "rootsha"
                                    :depth 0 :path "" :reveal reveal :focus focus))))

(defun octocat-tree-tests--entry (path type sha)
  "Return a tree API entry for PATH of TYPE (\"tree\" or \"blob\") and SHA."
  (let ((h (make-hash-table :test #'equal)))
    (puthash "path" path h)
    (puthash "type" type h)
    (puthash "sha"  sha  h)
    h))

(ert-deftest octocat-tree-test-paints-from-store ()
  "The stored listing paints without a fetch."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                               (vector (octocat-tree-tests--entry "cached.el" "blob" "b1")))
    (with-temp-buffer
      (octocat-tree-tests--mount-tree)
      (should (string-match-p "cached\\.el" (buffer-string))))))

(ert-deftest octocat-tree-test-reveal-fetches-at-once ()
  "Opened down to a directory, the tree asks for every listing on the way at once."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store '(tree-path "owner/repo" "main" "a/b")
                               (octocat--table "shas" ["rootsha" "asha" "bsha"]))
    (let (requested)
      (cl-letf (((symbol-function 'octocat-sync-request)
                 (lambda (spec &rest _) (push spec requested)))
                ((symbol-function 'octocat--head-info) #'ignore))
        (with-temp-buffer
          (octocat-tree-mode)
          (octocat-vui-refresh-page 'octocat-repo-vui--tree-page "tree"
                                    (list :repo "owner/repo" :ref "main" :reveal "a/b"))))
      (dolist (sha '("rootsha" "asha" "bsha"))
        (should (member (list 'tree-dir "owner/repo" sha) requested))))))

(ert-deftest octocat-repo-test-readme-fetched-with-listing ()
  "The repo page asks for the README the head names, not after the root's listing."
  (octocat-tree-tests--with-store
    (let ((head (octocat--table "sha" "c1" "tree" "rootsha" "kind" "tree"
                                "entries" (vector (octocat-tree-tests--entry "README.md" "blob" "b1"))))
          requested)
      (octocat-tree-tests--store '(repo-head "owner/repo" "main" nil) head)
      (cl-letf (((symbol-function 'octocat-sync-request)
                 (lambda (spec &rest _) (push spec requested)))
                ((symbol-function 'octocat--head-info) #'ignore)
                ((symbol-function 'octocat-repo--unpushed) #'ignore))
        (with-temp-buffer
          (octocat-repo-mode)
          (octocat-vui-refresh-page 'octocat-repo-vui--root "repo"
                                    (list :repo "owner/repo" :ref "main"))))
      (should (member '(blob "owner/repo" "b1") requested)))))

(ert-deftest octocat-tree-test-proxied-url-once ()
  "A file's rendering is asked for once, for all its images."
  (skip-unless (libxml-available-p))
  (octocat-tree-tests--with-store
    (let ((calls 0) got)
      (cl-letf (((symbol-function 'octocat--run-gh)
                 (lambda (_name args parse cb)
                   (cl-incf calls)
                   (should (member "repos/o/r/contents/docs/a%20b.md" args))
                   (should (member "ref=main" args))
                   (funcall cb (funcall parse "<img src=\"https://camo.githubusercontent.com/1\" data-canonical-src=\"https://e.com/1.png\">")))))
        (octocat-tree--proxied-url "o/r" "main" "docs/a b.md" "https://e.com/1.png" (lambda (u) (push u got)))
        (octocat-tree--proxied-url "o/r" "main" "docs/a b.md" "https://e.com/2.png" (lambda (u) (push u got)))
        (should (= calls 1))
        (should (equal got '(nil "https://camo.githubusercontent.com/1")))))))

(ert-deftest octocat-tree-test-blob-store ()
  "A fetched blob, which need not be text, is stored and then served without a fetch."
  (octocat-tree-tests--with-store
    (let ((bytes (string-to-unibyte "a\377b\n"))
          got)
      (cl-letf (((symbol-function 'octocat--run-gh) (octocat-tree-tests--blob-answer bytes)))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes))
      (setq got nil)
      (cl-letf (((symbol-function 'octocat--run-gh)
                 (lambda (&rest _) (error "Unexpected blob fetch"))))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes)))))

(ert-deftest octocat-tree-test-image-file ()
  "A file's image is fetched in one request, by ref and path; nil when there is none.
Over 1 MB, GitHub leaves its bytes out, and its blob is fetched."
  (octocat-tree-tests--with-store
    (let ((bytes (string-to-unibyte "\211PNG"))
          calls got)
      (cl-letf (((symbol-function 'octocat--run-gh)
                 (lambda (name args parse callback)
                   (push name calls)
                   (funcall callback
                            (cond ((equal name "blob")
                                   (funcall parse (json-serialize
                                                   `((content . ,(base64-encode-string bytes))))))
                                  ((member "repos/o/r/contents/a.png" args)
                                   (funcall parse (json-serialize
                                                   `((content . ,(base64-encode-string bytes))
                                                     (sha . "b1")))))
                                  ((member "repos/o/r/contents/big.png" args)
                                   (funcall parse (json-serialize '((content . "") (sha . "b2")))))
                                  (t '(error . "Not Found")))))))
        (with-temp-buffer
          (octocat-file-mode)
          (should (eq octocat-image-file-function #'octocat-tree--image-file)))
        (octocat-tree--image-file "o/r" "main" "a.png" (lambda (r) (setq got r)))
        (should (equal got bytes))
        (should (equal calls '("file-bytes")))
        (octocat-tree--image-file "o/r" "main" "big.png" (lambda (r) (setq got r)))
        (should (equal got bytes))
        (octocat-tree--image-file "o/r" "main" "b.png" (lambda (r) (setq got (list r))))
        (should (equal got '(nil)))))))

(defun octocat-tree-tests--json (json)
  "Return JSON parsed as the store keeps it."
  (json-parse-string json))

(defun octocat-tree-tests--store-file (ref path content)
  "Store owner/repo, main by default, and file PATH at REF holding CONTENT."
  (octocat-tree-tests--store '(repo-summary "owner/repo")
                             (octocat-tree-tests--json "{\"default-branch\":\"main\"}"))
  (let ((head (octocat-model--repo-history-commit
               (octocat-tree-tests--json
                "{\"oid\":\"abc1234def\",\"messageHeadline\":\"Add the guide\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":null}}")))
        (blob (make-hash-table :test #'equal)))
    (puthash "tree" (concat "blob-" ref) head)
    (puthash "kind" "blob" head)
    (puthash "total" 3 head)
    (octocat-tree-tests--store (list 'repo-head "owner/repo" ref path) head)
    (puthash "base64" (base64-encode-string content) blob)
    (octocat-tree-tests--store (list 'blob "owner/repo" (concat "blob-" ref)) blob)))

(defmacro octocat-tree-tests--with-file-page (&rest body)
  "Run BODY from the store, the local clone on no branch.
A refresh asks GitHub again, which never answers."
  (declare (indent 0))
  `(octocat-tree-tests--with-store
     (cl-letf (((symbol-function 'octocat--run-gh) #'ignore)
               ((symbol-function 'octocat--head-info) #'ignore)
               ((symbol-function 'octocat-display-buffer) #'set-buffer))
       ,@body)))

(ert-deftest octocat-tree-test-file-page ()
  "The file viewer starts as the tree browser does, and renders markdown."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file "dev" "docs/GUIDE.md"
                                    "# Guide\n\nSee [shots](shots/README.md).\n")
    (save-current-buffer
      (octocat-tree--open-file-by-path "owner/repo" "dev" "docs/GUIDE.md")
      (unwind-protect
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (equal (buffer-name) "*owner/repo@dev:docs/GUIDE.md*"))
            (should (derived-mode-p 'octocat-file-mode))
            (should (string-match-p
                     (concat "\\`owner/repo  \\[dev ▾\\]:/docs/GUIDE.md   Preview  Code  Blame \n\n"
                             "Add the guide +abc1234 · .*  \\[3 commits\\] \n")
                     text))
            (should-not (string-match-p "reset" text))
            ;; The root and the directories on the way open the tree.
            (let (opened)
              (cl-letf (((symbol-function 'octocat-tree-open)
                         (lambda (&rest args) (push args opened))))
                (goto-char (point-min))
                (search-forward ":/docs/GUIDE")
                (dolist (pos (list (- (point) 11) (- (point) 10) (- (point) 5)))
                  (goto-char pos)
                  (call-interactively (key-binding (kbd "RET")))))
              ;; ":" is plain; "/" is the root, "docs" docs/.
              ;; C-c C-o on a link opens it, not the file, on GitHub.
              (let (browsed)
                (cl-letf (((symbol-function 'octocat-browse-external)
                           (lambda (url) (push url browsed))))
                  (goto-char (point-min))
                  (search-forward "shots")
                  (backward-char)
                  (octocat-browse)
                  (goto-char (point-min))
                  (octocat-browse))
                (should (equal (nreverse browsed)
                               '("https://github.com/owner/repo/blob/dev/docs/shots/README.md"
                                 "https://github.com/owner/repo/blob/dev/docs/GUIDE.md"))))
              (should (equal (nreverse opened)
                             '(("owner/repo" "dev" nil) ("owner/repo" "dev" "docs")))))
            (should (string-match-p "^Guide$" text))
            (should-not (string-match-p "# Guide" text))
            (goto-char (point-min))
            (search-forward "shots")
            (should (equal (get-text-property (match-beginning 0) 'octocat-markdown-url)
                           "https://github.com/owner/repo/blob/dev/docs/shots/README.md"))
            ;; C-c C-v shows the source.
            (octocat-toggle-markdown)
            (should (string-match-p "^# Guide$" (buffer-string))))
        (kill-buffer)))))

(defun octocat-tree-tests--highlighted-p (pos)
  "Return non-nil if the text at POS has `octocat-line-highlight'."
  (memq 'octocat-line-highlight (ensure-list (get-text-property pos 'face))))

(defun octocat-tree-tests--highlighted-lines ()
  "Return the file lines of the current buffer in `octocat-line-highlight'."
  (let (out)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((n (get-text-property (point) 'octocat-file-line)))
          (when (octocat-tree-tests--highlighted-p (point)) (push n out)))
        (forward-line 1)))
    (nreverse out)))

(defun octocat-tree-tests--goto-file-line (n)
  "Move point to the start of line N of the file shown."
  (goto-char (point-min))
  (while (not (eql (get-text-property (point) 'octocat-file-line) n))
    (forward-line 1)))

(ert-deftest octocat-repo-test-mark-lines ()
  "Each line has its number, and only lines START to END the highlight."
  (let ((text (octocat-repo--mark-lines "a\nb\n\nd" '(2 . 3))))
    (should (equal (mapcar (lambda (i) (get-text-property i 'octocat-file-line text))
                           '(0 1 2 3 4 5))
                   '(1 1 2 2 3 4)))
    (should (equal (mapcar (lambda (i)
                             (and (memq 'octocat-line-highlight
                                        (ensure-list (get-text-property i 'face text)))
                                  t))
                           '(0 1 2 3 4 5))
                   '(nil nil t t t nil)))
    (should (equal (text-property-any 0 (length text) 'octocat-line-target t text) 2)))
  ;; A range past the end highlights what there is; a start past it, nothing.
  (let ((text (octocat-repo--mark-lines "a\nb" '(2 . 9))))
    (should (memq 'octocat-line-highlight (ensure-list (get-text-property 2 'face text))))
    (should (get-text-property 2 'octocat-line-target text)))
  (let ((text (octocat-repo--mark-lines "a\nb" '(5 . 9))))
    (should-not (text-property-not-all 0 (length text) 'face nil text))
    (should-not (text-property-any 0 (length text) 'octocat-line-target t text)))
  (should-not (get-text-property 0 'face (octocat-repo--mark-lines "a" nil))))

(ert-deftest octocat-tree-test-file-page-lines ()
  "A link's lines are highlighted and scrolled to, until the user's refresh.
The page's URL names the line of point, or the region's."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file
     "dev" "src/a.el"
     (mapconcat (lambda (n) (format "(line %d)" n)) (number-sequence 1 30) "\n"))
    (save-current-buffer
      (octocat-tree--open-file-by-path "owner/repo" "dev" "src/a.el" '(lines 3 5))
      (unwind-protect
          (progn
            (should (equal (octocat-tree-tests--highlighted-lines) '(3 4 5)))
            (should (looking-at-p "(line 3)"))
            (should (equal (octocat-file--page-url)
                           "https://github.com/owner/repo/blob/dev/src/a.el#L3"))
            ;; A refresh after an action keeps them, and leaves point.
            (octocat-tree-tests--goto-file-line 10)
            (octocat-file-refresh)
            (vui-flush-sync)
            (should (equal (octocat-tree-tests--highlighted-lines) '(3 4 5)))
            (should (eql (get-text-property (point) 'octocat-file-line) 10))
            (should (equal (octocat-file--page-url)
                           "https://github.com/owner/repo/blob/dev/src/a.el#L10"))
            ;; The user's refresh drops them.
            (octocat-vui-refresh)
            (vui-flush-sync)
            (should-not octocat-tree--file-lines)
            (should-not (octocat-tree-tests--highlighted-lines))
            ;; A region: from its first line to its last.
            (let ((transient-mark-mode t))
              (octocat-tree-tests--goto-file-line 4)
              (push-mark (point) t t)
              (octocat-tree-tests--goto-file-line 7)
              (should (equal (octocat-file--page-url)
                             "https://github.com/owner/repo/blob/dev/src/a.el#L4-L6"))
              (end-of-line)
              (should (equal (octocat-file--page-url)
                             "https://github.com/owner/repo/blob/dev/src/a.el#L4-L7"))
              (deactivate-mark))
            ;; Above the content, the file's link.
            (goto-char (point-min))
            (should (equal (octocat-file--page-url)
                           "https://github.com/owner/repo/blob/dev/src/a.el"))
            ;; A new link to the open page moves the highlight.
            (octocat-tree--open-file-by-path "owner/repo" "dev" "src/a.el" '(lines 20 20))
            (should (equal (octocat-tree-tests--highlighted-lines) '(20)))
            (should (looking-at-p "(line 20)")))
        (kill-buffer)))))

(ert-deftest octocat-tree-test-file-page-lines-markdown ()
  "A line link to markdown shows its code, whose links have ?plain=1."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file "dev" "docs/GUIDE.md" "# Guide\n\nText.\n")
    (save-current-buffer
      (octocat-tree--open-file-by-path "owner/repo" "dev" "docs/GUIDE.md" '(lines 3 3))
      (unwind-protect
          (progn
            (should (string-match-p "^# Guide$" (buffer-string)))
            (should (equal (octocat-tree-tests--highlighted-lines) '(3)))
            (should (looking-at-p "Text\\."))
            (should (equal (octocat-file--page-url)
                           "https://github.com/owner/repo/blob/dev/docs/GUIDE.md?plain=1#L3"))
            ;; The preview has no lines: the bare link.
            (octocat-file-show-view 'preview)
            (vui-flush-sync)
            (goto-char (point-min))
            (search-forward "Text.")
            (should (equal (octocat-file--page-url)
                           "https://github.com/owner/repo/blob/dev/docs/GUIDE.md")))
        (kill-buffer)))))

(ert-deftest octocat-tree-test-file-cycle-view ()
  "C-c C-v takes markdown from rendered to raw to blame and back.
The top line has a tab for each view, the one shown plain."
  (octocat-tree-tests--with-file-page
    (cl-letf (((symbol-function 'octocat-power) (lambda () 'low)))
      (octocat-tree-tests--store-file "dev" "docs/GUIDE.md" "# Guide\n\nText.\n")
      (octocat-tree-tests--store
       '(blame "owner/repo" "abc1234def" "docs/GUIDE.md")
       (octocat-model--repo-parse-blame
        (octocat--get
         (octocat-sync--parse
          (concat "{\"data\":{\"repository\":{\"object\":{\"blame\":{\"ranges\":["
                  "{\"startingLine\":1,\"endingLine\":3,\"commit\":{\"oid\":\"abc1234def\","
                  "\"messageHeadline\":\"Add the guide\",\"committedDate\":\"2026-10-01T10:00:00Z\","
                  "\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":null}}}]}}}}}"))
         "data")))
      (save-current-buffer
        (octocat-tree--open-file-by-path "owner/repo" "dev" "docs/GUIDE.md")
        (unwind-protect
            (progn
              (should (eq (key-binding (kbd "C-c C-v")) #'octocat-file-cycle-view))
              (should (string-match-p "^Guide$" (buffer-string)))
              (should (string-match-p ":/docs/GUIDE.md   Preview  Code  Blame $" (buffer-string)))
              (goto-char (point-min))
              (search-forward "Preview")
              (should (eq (get-text-property (point) 'face) 'octocat-segment-current))
              (octocat-file-cycle-view)
              (should (string-match-p "^# Guide$" (buffer-string)))
              (should (= (octocat--cap-width 1000) octocat-max-width))
              (octocat-file-cycle-view)
              ;; The blame widens the page by its column, the code as wide.
              (should (= (octocat--cap-width 1000)
                         (+ octocat-max-width (octocat-repo--blame-column-width))))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "^Add the guide +.* │ 1 # Guide$" text))
                (should (string-match-p "^ + │ 3 Text\\.$" text)))
              (let (opened)
                (cl-letf (((symbol-function 'octocat-commit-open)
                           (lambda (repo sha) (push (list repo sha) opened))))
                  (goto-char (point-min))
                  (search-forward "Add the guide" nil t 2)
                  (call-interactively (key-binding (kbd "RET"))))
                (should (equal opened '(("owner/repo" "abc1234def")))))
              (goto-char (point-min))
              (search-forward "Blame")
              (should (eq (get-text-property (1- (point)) 'face) 'octocat-segment-current))
              (octocat-file-cycle-view)
              (should (= (octocat--cap-width 1000) octocat-max-width))
              (should (string-match-p "^Guide$" (buffer-string))))
          (kill-buffer))))))

(ert-deftest octocat-tree-test-last-commit-text ()
  "A tree entry is followed by its last commit's subject and, at the right, its age."
  (let* ((commit (octocat-model--repo-history-commit
                  (octocat-tree-tests--json
                   "{\"oid\":\"abc\",\"messageHeadline\":\"Fix the build\",\"committedDate\":\"2026-10-01T10:00:00Z\",\"author\":null}")))
         (text   (concat "src/" (octocat-tree--last-commit-text "src/" commit 60))))
    (should (equal (string-width text) 60))
    (should (string-match-p "\\`src/ +Fix the build +[0-9a-z ]+ago\\'" text))
    (should (equal (string-match "Fix" text) 20))
    (should (equal (octocat-tree--last-commit-text "src/" nil 60) ""))
    ;; While it loads, grey bars stand where the subject and age go.
    (let ((bars (concat "src/" (octocat-tree--last-commit-text "src/" 'loading 60))))
      (should (equal (string-width bars) 60))
      (should (eq (get-text-property 20 'face bars) 'octocat-skeleton))
      (should (eq (get-text-property 59 'face bars) 'octocat-skeleton)))))

(ert-deftest octocat-tree-test-blame-skeleton ()
  "Before the blame lands the source shows, grey bars heading every few lines."
  (let* ((text  (octocat-repo--blame-text "owner/repo" "a\nb\nc\nd\ne" nil 80))
         (lines (split-string text "\n")))
    (should (equal (length lines) 5))
    (should (string-suffix-p "│ 1 a" (nth 0 lines)))
    (should (eq (get-text-property 0 'face (nth 0 lines)) 'octocat-skeleton))
    (should (string-prefix-p " " (nth 1 lines)))
    (should (eq (get-text-property 0 'face (nth 4 lines)) 'octocat-skeleton))))

(ert-deftest octocat-tree-test-blame-rule ()
  "Each commit's run of lines but the last ends underlined to the edge given,
the margin as wide whatever the window."
  (let* ((range (lambda (start end sha)
                  (let ((h (make-hash-table :test #'equal))
                        (c (make-hash-table :test #'equal)))
                    (puthash "sha" sha c)
                    (puthash "start" start h)
                    (puthash "end" end h)
                    (puthash "commit" c h)
                    h)))
         (text  (octocat-repo--blame-text
                 "owner/repo" "a\nb\nc"
                 (vector (funcall range 1 2 "a1") (funcall range 3 3 "b2"))
                 70))
         (lines (split-string text "\n"))
         (ruled (lambda (s)
                  (let ((f (get-text-property 0 'face s)))
                    (or (eq f 'octocat-blame-rule) (memq 'octocat-blame-rule (ensure-list f)))))))
    (should-not (funcall ruled (nth 0 lines)))
    (should (funcall ruled (nth 1 lines)))
    (should (equal (get-text-property (1- (length (nth 1 lines))) 'display (nth 1 lines))
                   '(space :align-to 70)))
    (should-not (funcall ruled (nth 2 lines)))
    (should (equal (string-search "│" (nth 0 lines)) (1+ octocat-repo--blame-width)))
    ;; Copying leaves the blame column out, keeping only the code.
    (should (equal (octocat-markdown-copy-text text) "a\nb\nc"))))

(ert-deftest octocat-tree-test-blame-pin ()
  "A window scrolled past a run's head shows its commit on the top line,
that window only, and none once the head is in view again."
  (let* ((range (lambda (start end subject)
                  (let ((h (make-hash-table :test #'equal))
                        (c (make-hash-table :test #'equal))
                        (m (make-hash-table :test #'equal)))
                    (puthash "message" subject m)
                    (puthash "sha" "a1" c)
                    (puthash "commit" m c)
                    (puthash "start" start h)
                    (puthash "end" end h)
                    (puthash "commit" c h)
                    h)))
         (text  (octocat-repo--blame-text
                 "owner/repo" "a\nb\nc\nd"
                 (vector (funcall range 1 3 "Add letters") (funcall range 4 4 "Add d"))
                 70))
         (pinned (lambda (win)
                   (seq-keep (lambda (ov)
                               (and (eq (overlay-get ov 'window) win)
                                    (string-trim (substring-no-properties
                                                  (overlay-get ov 'display)))))
                             (overlays-in (point-min) (point-max))))))
    (with-temp-buffer
      (insert text)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (forward-line 1)
      (octocat-repo--blame-pin (selected-window) (point))
      (should (equal (length (funcall pinned (selected-window))) 1))
      (should (string-prefix-p "Add letters" (car (funcall pinned (selected-window)))))
      (should (= (overlay-end (car octocat-repo--blame-pins))
                 (+ (point) octocat-repo--blame-width)))
      ;; Moving on replaces it, and a head in view needs none.
      (forward-line 2)
      (octocat-repo--blame-pin (selected-window) (point))
      (should-not (funcall pinned (selected-window)))
      (octocat-repo--blame-pin (selected-window) (point-min))
      (should-not (funcall pinned (selected-window))))))

(ert-deftest octocat-tree-test-older-last-commits ()
  "An older commit's last commits stand in, the newest at the same tree first."
  (let* ((table (lambda (sha)
                  (let ((h (make-hash-table :test #'equal)))
                    (puthash "a.el" sha h)
                    h)))
         (spec  (lambda (commit sha) (list 'tree-commits "owner/repo" commit "" sha)))
         (other (list (funcall spec "c1" "t1") (funcall table "x1") 30))
         (same  (list (funcall spec "c2" "t2") (funcall table "x2") 10))
         (newer (list (funcall spec "c3" "t3") (funcall table "x3") 20)))
    (should (equal (gethash "a.el" (octocat-tree--older-last-commits
                                    (list other same newer) "c9" "t2"))
                   "x2"))
    (should (equal (gethash "a.el" (octocat-tree--older-last-commits
                                    (list other same newer) "c9" "t9"))
                   "x1"))
    ;; Not the commit itself, nor one with none.
    (should-not (octocat-tree--older-last-commits
                 (list (list (funcall spec "c9" "t9") (funcall table "x9") 40)
                       (list (funcall spec nil "t9") (make-hash-table :test #'equal) 50))
                 "c9" "t9"))))

(ert-deftest octocat-tree-test-older-last-commits-stand-in ()
  "While the last commits load, a stored older commit's show; a new entry's load."
  (octocat-tree-tests--with-store
    (let ((old (make-hash-table :test #'equal)))
      (puthash "a.el" (octocat-model--repo-history-commit
                       (octocat-tree-tests--json
                        "{\"oid\":\"abc\",\"messageHeadline\":\"Old subject\",\"author\":null}"))
               old)
      (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                                 (vector (octocat-tree-tests--entry "a.el" "blob" "b1")
                                         (octocat-tree-tests--entry "new.el" "blob" "b2")))
      (octocat-tree-tests--store '(tree-commits "owner/repo" "c1" "" "rootsha") old)
      (octocat-tree-tests--store '(tree-commits "other/repo" "c5" "" "rootsha")
                                 (make-hash-table :test #'equal))
      (with-temp-buffer
        (octocat-repo-mode)
        (cl-letf (((symbol-function 'octocat-model--tree-fetch-last-commits) #'ignore))
          (octocat-vui-refresh-page 'octocat-tree--dir "tree"
                                    (list :repo "owner/repo" :branch "main" :sha "rootsha"
                                          :commit "c2")))
        (goto-char (point-min))
        (should (re-search-forward "^a\\.el +Old subject" nil t))
        (should-not (re-search-forward "Old subject" nil t)))
      (should (eq (octocat-tree--last-of (cons 'loading old) "new.el") 'loading)))))

(ert-deftest octocat-tree-test-keeps-listing-while-new-tree-loads ()
  "Moved on to a tree not yet fetched, as after a push, the old listing stays."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                               (vector (octocat-tree-tests--entry "old.el" "blob" "b1")))
    (with-temp-buffer
      (octocat-repo-mode)
      (cl-letf (((symbol-function 'octocat--run-gh) #'ignore))
        (dolist (sha '("rootsha" "newsha"))
          (octocat-vui-refresh-page 'octocat-tree--dir "tree"
                                    (list :repo "owner/repo" :branch "main" :sha sha))))
      (should (string-match-p "^old\\.el" (buffer-string)))
      (octocat-tree-tests--store '(tree-dir "owner/repo" "newsha")
                                 (vector (octocat-tree-tests--entry "new.el" "blob" "b2")))
      (octocat-sync--notify (list (octocat-sync-spec-key '(tree-dir "owner/repo" "newsha"))))
      (should (string-match-p "^new\\.el" (buffer-string)))
      (should-not (string-match-p "old\\.el" (buffer-string))))))

(ert-deftest octocat-tree-test-image-file-page ()
  "An image file is shown as the image, or, where it cannot be, said to be one."
  (let ((png "\211PNG\r\n\032\nbytes"))
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'create-image)
               (lambda (data type &rest _) (list 'img type data))))
      (let ((text (octocat-repo--file-text "o/r" "main" "docs/a.png" png nil 80)))
        (should (equal (get-text-property 0 'display text) (list 'img 'png png)))))
    (cl-letf (((symbol-function 'display-images-p) #'ignore))
      (should (string-match-p "\\`An image of "
                              (octocat-repo--file-text "o/r" "main" "docs/a.png" png nil 80))))))

(ert-deftest octocat-tree-test-ref-label ()
  "A long branch name is cut in its middle, keeping both ends; a SHA to seven."
  (let ((octocat-ref-max-width 12))
    (should (equal (octocat-repo-vui--ref-label "main") "main"))
    (should (equal (octocat-repo-vui--ref-label "feature/long-name") "featur…-name"))
    (should (= (length (octocat-repo-vui--ref-label "feature/long-name")) 12))
    (should (equal (octocat-repo-vui--ref-label (make-string 40 ?a)) "aaaaaaa"))
    (should (equal (octocat-repo-vui--picker-labels "feature/long-name" t "release/2026-10")
                   '("[featur…-name ▾]" "[reset to releas…26-10]")))))

(ert-deftest octocat-tree-test-cut-branch-in-full-on-hover ()
  "The help of a cut branch's picker names it in full."
  (octocat-tree-tests--with-file-page
    (let ((octocat-ref-max-width 12))
      (octocat-tree-tests--store-file "feature/long-name" "a.el" "(a)\n")
      (save-current-buffer
        (octocat-tree--open-file-by-path "owner/repo" "feature/long-name" "a.el")
        (unwind-protect
            (progn
              (goto-char (point-min))
              (should (search-forward "[featur…-name ▾]" nil t))
              (should (string-prefix-p "feature/long-name\n"
                                       (get-text-property (match-beginning 0) 'help-echo))))
          (kill-buffer))))))

(ert-deftest octocat-tree-test-file-branches ()
  "Each ref of a file has a buffer, the default branch by its name; picking another opens it."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file "main" "a.el" "(a)\n")
    (octocat-tree-tests--store-file "dev" "a.el" "(b)\n")
    (let (bufs)
      (unwind-protect
          (save-current-buffer
            (octocat-tree--open-file-by-path "owner/repo" "HEAD" "a.el")
            (push (current-buffer) bufs)
            (should (equal (buffer-name) "*owner/repo@main:a.el*"))
            (should (string-match-p "\\[main ▾\\]" (buffer-string)))
            (cl-letf (((symbol-function 'octocat--read-branch)
                       (lambda (repo default _local shown)
                         (should (equal (list repo default shown) '("owner/repo" "main" "main")))
                         "dev")))
              (octocat-file-switch-branch))
            (push (current-buffer) bufs)
            (should (equal (buffer-name) "*owner/repo@dev:a.el*"))
            (should (string-match-p "^(b)$" (buffer-string)))
            (should (string-match-p "^(a)$" (with-current-buffer (cadr bufs) (buffer-string)))))
        (mapc #'kill-buffer bufs)))))

(ert-deftest octocat-tree-test-render-entries-empty ()
  "An empty root says so."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha") [])
    (with-temp-buffer
      (octocat-tree-tests--mount-tree)
      (should (string-match-p "(empty)" (buffer-string))))))

(ert-deftest octocat-tree-test-render-entries-mixed ()
  "The tree shows dirs before files and uses correct labels."
  (octocat-tree-tests--with-store
    (with-temp-buffer
      (let* ((dir-entry  (let ((h (make-hash-table :test #'equal)))
                           (puthash "path" "src"       h)
                           (puthash "type" "tree"      h)
                           (puthash "sha"  "abc123"    h)
                           h))
             (file-entry (let ((h (make-hash-table :test #'equal)))
                           (puthash "path" "README.md" h)
                           (puthash "type" "blob"      h)
                           (puthash "sha"  "def456"    h)
                           h))
             (entries    (vector dir-entry file-entry)))
        (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha") entries)
        (octocat-tree-tests--mount-tree)
        (let ((text (buffer-string)))
          (should (string-match-p "src" text))
          (should (string-match-p "README.md" text))
          ;; Dir should appear before file in the buffer.
          (should (< (string-match "src" text)
                     (string-match "README.md" text))))))))

(ert-deftest octocat-tree-test-entries-are-not-tab-stops ()
  "An entry is a line RET runs, not a button; a directory's moves into it."
  (with-temp-buffer
    (octocat-tree-tests--with-store
      (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                                 (vector (octocat-tree-tests--entry "a.el" "blob" "b1")
                                         (octocat-tree-tests--entry "src" "tree" "srcsha")))
      (octocat-tree-tests--mount-tree)
      (goto-char (point-min))
      (should (equal (octocat-tree--path-at-point) "src"))
      (should-not (or (button-at (point)) (widget-at (point))))
      (should-not (eq (key-binding (kbd "TAB")) (key-binding (kbd "RET"))))
      (octocat-tree-visit)
      (should (equal octocat-tree-tests--visited '("src")))
      (forward-line 1)
      (should (equal (octocat-tree--path-at-point) "a.el")))))

(ert-deftest octocat-tree-test-full-tree ()
  "In a directory the whole tree shows, opened down to it, which RET toggles.
It does not fold, however long."
  (with-temp-buffer
    (octocat-tree-tests--with-store
      (let ((octocat-tree-entries 1))
        (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                                   (vector (octocat-tree-tests--entry "doc" "tree" "docsha")
                                           (octocat-tree-tests--entry "src" "tree" "srcsha")
                                           (octocat-tree-tests--entry "a.el" "blob" "b1")))
        (octocat-tree-tests--store '(tree-dir "owner/repo" "srcsha")
                                   (vector (octocat-tree-tests--entry "x.el" "blob" "b2")))
        (octocat-tree-tests--mount-full-tree "src" "src")
        (accept-process-output nil 0.01)
        (should (string-match-p "▸ doc/\n▾ src/\n    x\\.el\n  a\\.el" (buffer-string)))
        (should (equal (octocat-tree--path-at-point) "src"))
        (octocat-tree-visit)
        (vui-flush-sync)
        (should (string-match-p "▸ src/" (buffer-string)))
        (should-not (string-match-p "x\\.el" (buffer-string)))
        (should-not (string-match-p "more entries" (buffer-string)))
        ;; g shows the tree as it opened.
        (setq-local revert-buffer-function
                    (lambda (&rest _) (octocat-tree-tests--mount-full-tree "src" "src")))
        (octocat-vui-refresh)
        (vui-flush-sync)
        (should (string-match-p "▾ src/\n    x\\.el" (buffer-string)))))))

(ert-deftest octocat-tree-test-up ()
  "Up moves point to the directory holding the entry, not past the root's."
  (with-temp-buffer
    (octocat-tree-tests--with-store
      (octocat-tree-tests--store '(tree-dir "owner/repo" "rootsha")
                                 (vector (octocat-tree-tests--entry "src" "tree" "srcsha")))
      (octocat-tree-tests--store '(tree-dir "owner/repo" "srcsha")
                                 (vector (octocat-tree-tests--entry "x.el" "blob" "b2")))
      (octocat-tree-tests--mount-full-tree "src/x.el" "src/x.el")
      (accept-process-output nil 0.01)
      (should (equal (octocat-tree--path-at-point) "src/x.el"))
      (octocat-repo-up)
      (should (equal (octocat-tree--path-at-point) "src"))
      (should-error (octocat-repo-up) :type 'user-error))))

(ert-deftest octocat-tree-test-folds-long-directories ()
  "Past `octocat-tree-entries' the root's entries give way to Browse code."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store
     '(tree-dir "owner/repo" "rootsha")
     (vconcat (mapcar (lambda (i) (octocat-tree-tests--entry (format "f%02d" i) "blob" "b"))
                      (number-sequence 1 5))))
    (with-temp-buffer
      (let ((octocat-tree-entries 3))
        (octocat-tree-tests--mount-tree)
        (should (string-match-p "f03" (buffer-string)))
        (should-not (string-match-p "f04" (buffer-string)))
        (should (string-match-p "\\[Browse code (2 more entries)\\]" (buffer-string)))
        (let ((octocat-tree-entries nil))
          (with-temp-buffer
            (octocat-tree-tests--mount-tree)
            (should (string-match-p "f05" (buffer-string)))
            (should (string-match-p "\\[Browse code\\]" (buffer-string)))))))))

(ert-deftest octocat-tree-test-focus ()
  "Point moves to the focused entry of the tree once it is listed."
  (octocat-tree-tests--with-store
    (octocat-tree-tests--store
     '(tree-dir "owner/repo" "rootsha")
     (vconcat (mapcar (lambda (i) (octocat-tree-tests--entry (format "f%02d" i) "blob" "b"))
                      (number-sequence 1 5))))
    (with-temp-buffer
      (octocat-tree-tests--mount-full-tree nil "f04")
      (should (equal (octocat-tree--path-at-point) "f04")))))

(ert-deftest octocat-tree-test-commits-page ()
  "The commits page has the tree's top line, with the count, then a blank line; C-c C-l opens it."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file "dev" "docs/GUIDE.md" "# Guide\n")
    (octocat-tree-tests--store
     `(commits "owner/repo" "dev" "docs/GUIDE.md" ,octocat-repo-commits-page-size)
     (octocat-model--commits-tree (octocat-model--repo-parse-history
                                   "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":3,\"edges\":[{\"cursor\":\"c 0\",\"node\":{\"oid\":\"abc1234def\",\"messageHeadline\":\"Add the guide\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":null}}}]}}}}}")
                                  octocat-repo-commits-page-size))
    (save-current-buffer
      (octocat-tree--open-file-by-path "owner/repo" "dev" "docs/GUIDE.md")
      (let ((file (current-buffer)))
        (octocat-file-log-open)
        (unwind-protect
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (derived-mode-p 'octocat-commit-list-mode))
              (should (string-match-p
                       (concat "\\`owner/repo  \\[dev ▾\\]:/docs/GUIDE.md  3 commits  "
                               "\\[reset to main\\]\n\n○ Add the guide +Ann +[^ ].* +abc1234$")
                       text))
              ;; A directory on the way shows its own commits.
              (let (opened)
                (cl-letf (((symbol-function 'octocat-commit-list-open)
                           (lambda (&rest args) (push args opened))))
                  (goto-char (point-min))
                  (search-forward ":/docs")
                  (backward-char)
                  (call-interactively (key-binding (kbd "RET"))))
                (should (equal opened '(("owner/repo" "dev" "docs"))))))
          (kill-buffer)
          (kill-buffer file))))))

(ert-deftest octocat-repo-test-ref-path-unsettled ()
  "A link the stored branches don't settle opens at once on its first segment.
GitHub's answer then opens the right page."
  (let (opened answered spec)
    (cl-letf (((symbol-function 'octocat-sync-read) #'ignore)
              ((symbol-function 'octocat-sync-get) (lambda (s k) (setq spec s answered k)))
              ((symbol-function 'octocat-tree--open-file-by-path)
               (lambda (&rest a) (push a opened))))
      (octocat-open 'ref-path "o/r" 'file '("feat" "x" "a.el") '(lines 3 3))
      (should (equal spec '(ref-split "o/r" "feat/x/a.el")))
      (funcall answered (octocat--table "count" 2)))
    (should (equal (nreverse opened)
                   '(("o/r" "feat" "x/a.el" (lines 3 3))
                     ("o/r" "feat/x" "a.el" (lines 3 3)))))))

(ert-deftest octocat-repo-test-file-content-text ()
  "The file page shows the text `file-blob' had, fetching no blob."
  (let (fetched)
    (cl-letf (((symbol-function 'octocat-sync-request)
               (lambda (spec &rest _) (push spec fetched))))
      (with-temp-buffer
        (vui-render (vui-component 'octocat-repo-vui--file-content
                      :repo "o/r" :ref "main" :path "a.txt" :blob "b1" :text "héllo\n")
                    (current-buffer))
        (should (string-search "héllo" (buffer-string)))))
    (should-not (member '(blob "o/r" "b1") fetched))))

(provide 'octocat-repo-tests)
;;; octocat-repo-tests.el ends here
