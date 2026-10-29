;;; octocat-tree-tests.el --- ERT tests for octocat-tree.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-tree-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

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
         (octocat-sync--loading (make-hash-table :test #'equal))
         (octocat-sync--queue nil)
         (octocat-sync--prefetches nil)
         (octocat-sync--prefetching nil)
         (octocat-sync--running 0)
         (octocat-sync--waiters nil)
         (octocat-vui--subscriptions (make-hash-table :test #'equal)))
     ,@body))

(defun octocat-tree-tests--store (spec data)
  "Store DATA as fetched just now for SPEC."
  (octocat-sync--write octocat-sync--db (octocat-sync-spec-key spec) data (float-time)))

(defvar octocat-tree-tests--visited nil
  "The directories the mounted files asked the page to show, latest first.")

(defun octocat-tree-tests--mount-tree ()
  "List the root, tree \"rootsha\", of owner/repo here, as the repo page does.
Moving into a directory is recorded in `octocat-tree-tests--visited'.
A listing not in the store is an error, so no gh call is made."
  (unless (derived-mode-p 'octocat-repo-mode)
    (octocat-repo-mode))
  (setq octocat-tree-tests--visited nil)
  (cl-letf (((symbol-function 'octocat-tree--fetch-dir)
             (lambda (&rest _) (error "Unexpected directory fetch"))))
    (octocat-vui-refresh-page 'octocat-tree--dir "tree"
                              (list :repo "owner/repo" :branch "main" :sha "rootsha"
                                    :on-dir (lambda (dir)
                                              (push dir octocat-tree-tests--visited))))))

(defun octocat-tree-tests--mount-full-tree (reveal &optional focus)
  "Show the whole tree of root \"rootsha\" here, opened down to REVEAL.
FOCUS is where point goes, as for `octocat-tree--subtree'."
  (unless (derived-mode-p 'octocat-tree-mode)
    (octocat-tree-mode))
  (cl-letf (((symbol-function 'octocat-tree--fetch-dir)
             (lambda (&rest _) (error "Unexpected directory fetch"))))
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

(ert-deftest octocat-tree-test-blob-store ()
  "A fetched blob, which need not be text, is stored and then served without a fetch."
  (octocat-tree-tests--with-store
    (let ((bytes (string-to-unibyte "a\377b\n"))
          got)
      (cl-letf (((symbol-function 'octocat-tree--fetch-file)
                 (lambda (_repo _sha callback) (funcall callback (base64-encode-string bytes)))))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes))
      (setq got nil)
      (cl-letf (((symbol-function 'octocat-tree--fetch-file)
                 (lambda (&rest _) (error "Unexpected blob fetch"))))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes)))))

(ert-deftest octocat-tree-test-image-file ()
  "A README's image is its file's blob, looked up at the ref; nil when there is none."
  (octocat-tree-tests--with-store
    (let ((bytes (string-to-unibyte "\211PNG"))
          got)
      (cl-letf (((symbol-function 'octocat-tree--fetch-blob-sha)
                 (lambda (repo ref path cb)
                   (funcall cb (if (equal (list repo ref path) '("o/r" "main" "a.png"))
                                   "b1"
                                 '(error . "No file")))))
                ((symbol-function 'octocat-tree--fetch-file)
                 (lambda (_repo _sha cb) (funcall cb (base64-encode-string bytes)))))
        (should (eq octocat-image-file-function #'octocat-tree--image-file))
        (octocat-tree--image-file "o/r" "main" "a.png" (lambda (r) (setq got r)))
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
  (let ((head (octocat-repo--history-commit
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

(ert-deftest octocat-tree-test-file-cycle-view ()
  "C-c C-v takes markdown from rendered to raw to blame and back.
The top line has a tab for each view, the one shown plain."
  (octocat-tree-tests--with-file-page
   (cl-letf (((symbol-function 'octocat-power) (lambda () 'low)))
    (octocat-tree-tests--store-file "dev" "docs/GUIDE.md" "# Guide\n\nText.\n")
    (octocat-tree-tests--store
     '(blame "owner/repo" "abc1234def" "docs/GUIDE.md")
     (octocat-repo--parse-blame
      (concat "{\"data\":{\"repository\":{\"object\":{\"blame\":{\"ranges\":["
              "{\"startingLine\":1,\"endingLine\":3,\"commit\":{\"oid\":\"abc1234def\","
              "\"messageHeadline\":\"Add the guide\",\"committedDate\":\"2026-10-01T10:00:00Z\","
              "\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":null}}}]}}}}}")))
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
            (octocat-file-cycle-view)
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
            (should (string-match-p "^Guide$" (buffer-string))))
        (kill-buffer))))))

(ert-deftest octocat-tree-test-last-commit-text ()
  "A tree entry is followed by its last commit's subject and, at the right, its age."
  (let* ((commit (octocat-repo--history-commit
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
  (let* ((text  (octocat-repo--blame-text "owner/repo" "a\nb\nc\nd\ne" nil))
         (lines (split-string text "\n")))
    (should (equal (length lines) 5))
    (should (string-suffix-p "│ 1 a" (nth 0 lines)))
    (should (eq (get-text-property 0 'face (nth 0 lines)) 'octocat-skeleton))
    (should (string-prefix-p " " (nth 1 lines)))
    (should (eq (get-text-property 0 'face (nth 4 lines)) 'octocat-skeleton))))

(ert-deftest octocat-tree-test-blame-rule ()
  "Each commit's run of lines but the last ends underlined, the margin as wide
whatever the window."
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
                 (vector (funcall range 1 2 "a1") (funcall range 3 3 "b2"))))
         (lines (split-string text "\n"))
         (ruled (lambda (s)
                  (let ((f (get-text-property 0 'face s)))
                    (or (eq f 'octocat-blame-rule) (memq 'octocat-blame-rule (ensure-list f)))))))
    (should-not (funcall ruled (nth 0 lines)))
    (should (funcall ruled (nth 1 lines)))
    (should-not (funcall ruled (nth 2 lines)))
    (should (equal (string-search "│" (nth 0 lines)) (1+ octocat-repo--blame-width)))))

(ert-deftest octocat-tree-test-parse-last-commits ()
  "Each path gets the commit of its alias; one with no history is left out."
  (let ((got (octocat-tree--parse-last-commits
              (concat "{\"data\":{\"repository\":{\"object\":{"
                      "\"e0\":{\"nodes\":[{\"oid\":\"a1\",\"messageHeadline\":\"One\"}]},"
                      "\"e1\":{\"nodes\":[]}}}}}")
              '("README.md" "gone"))))
    (should (equal (gethash "sha" (gethash "README.md" got)) "a1"))
    (should-not (gethash "gone" got))))

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
      (accept-process-output nil 0.01)
      (should (equal (octocat-tree--path-at-point) "f04")))))

(ert-deftest octocat-tree-test-commits-page ()
  "The commits page has the tree's top line, with the count, then a blank line; C-c C-l opens it."
  (octocat-tree-tests--with-file-page
    (octocat-tree-tests--store-file "dev" "docs/GUIDE.md" "# Guide\n")
    (octocat-tree-tests--store
     '(commits "owner/repo" "dev" "docs/GUIDE.md")
     (vconcat (octocat-repo--parse-history
               "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":3,\"edges\":[{\"cursor\":\"c 0\",\"node\":{\"oid\":\"abc1234def\",\"messageHeadline\":\"Add the guide\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":null}}}]}}}}}")))
    (save-current-buffer
      (octocat-tree--open-file-by-path "owner/repo" "dev" "docs/GUIDE.md")
      (let ((file (current-buffer)))
        (octocat-file-log-open)
        (unwind-protect
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (derived-mode-p 'octocat-commit-list-mode))
              (should (string-match-p
                       (concat "\\`owner/repo  \\[dev ▾\\]:/docs/GUIDE.md  3 commits  "
                               "\\[reset to main\\]\n\nAdd the guide +Ann +[^ ].* +abc1234$")
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

(provide 'octocat-tree-tests)
;;; octocat-tree-tests.el ends here
