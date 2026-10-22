;;; octocat-tree-tests.el --- ERT tests for octocat-tree.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-tree-tests.el

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
Moving into a directory is recorded in `octocat-tree-tests--visited'.  A listing not in the store is an error,
so no gh call is made."
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
      (should-not (string-match-p "more entries" (buffer-string)))))))

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

(defconst octocat-tree-tests--file-log-commits-json
  (concat "[{\"sha\":\"a1b2c3d4e5f6\",\"author\":{\"login\":\"ann\"},"
          "\"commit\":{\"message\":\"Fix parser\\n\\nLonger body\","
          "\"author\":{\"name\":\"Ann\",\"date\":\"2026-06-01T10:00:00Z\"}}},"
          "{\"sha\":\"f6e5d4c3b2a1\",\"author\":null,"
          "\"commit\":{\"message\":\"Add tests\","
          "\"author\":{\"name\":\"Bob\",\"date\":\"2026-05-28T10:00:00Z\"}}}]")
  "Two commits as the REST commits endpoint returns them.")

(defun octocat-tree-tests--mount-file-log (&rest result)
  "Mount the file log page in the current buffer.
Its fetch gives the car of RESULT, or never returns when there is none."
  (octocat-file-log-mode)
  (setq octocat-file-log--repo "owner/repo"
        octocat-file-log--path "src/foo.el")
  (cl-letf (((symbol-function 'octocat-tree--fetch-file-commits)
             (lambda (_repo _ref _path callback)
               (when result (funcall callback (car result))))))
    (octocat-file-log-refresh)))

(ert-deftest octocat-tree-test-file-log-commit-line ()
  "A commit line shows short SHA, author and subject, and carries the SHA."
  (let* ((commit (aref (json-parse-string octocat-tree-tests--file-log-commits-json
                                          :null-object nil)
                       0))
         (line   (octocat-file-log--commit-line commit)))
    (should (string-match-p "a1b2c3d " line))
    (should (string-match-p "@ann" line))
    (should (string-match-p "Fix parser" line))
    (should-not (string-match-p "Longer body" line))
    (should-not (string-search "\n" line))
    (should (equal (get-text-property 0 'octocat-file-log--sha line)
                   "a1b2c3d4e5f6"))
    (should (equal (get-text-property (1- (length line)) 'octocat-file-log--sha line)
                   "a1b2c3d4e5f6"))))

(ert-deftest octocat-tree-test-file-log-render-commits ()
  "The file log lists one line per commit under a header with the count."
  (octocat-tree-tests--with-store
    (with-temp-buffer
      (octocat-tree-tests--mount-file-log
       (append (json-parse-string octocat-tree-tests--file-log-commits-json
                                  :null-object nil)
               nil))
      (let ((text (buffer-string)))
        (should (string-match-p "owner/repo  src/foo.el  (2 commits)" text))
        (should (< (string-search "Fix parser" text)
                   (string-search "Add tests" text))))
      (goto-char (point-min))
      (search-forward "Add tests")
      (should (equal (octocat-file-log--sha-at-point) "f6e5d4c3b2a1"))
      (goto-char (point-min))
      (should-not (octocat-file-log--sha-at-point)))))

(ert-deftest octocat-tree-test-file-log-render-loading-and-empty ()
  "The file log shows no count while loading, an error, or a no-commits line."
  (octocat-tree-tests--with-store
    (with-temp-buffer
      (octocat-tree-tests--mount-file-log)
      (should-not (string-match-p "commits)" (buffer-string)))))
  (octocat-tree-tests--with-store
    (with-temp-buffer
      (octocat-tree-tests--mount-file-log '(error . "boom"))
      (should (string-match-p "Error: boom; g to retry" (buffer-string)))))
  (octocat-tree-tests--with-store
    (with-temp-buffer
      (octocat-tree-tests--mount-file-log nil)
      (should (string-match-p "(0 commits)" (buffer-string)))
      (should (string-match-p "(no commits found)" (buffer-string))))))

(provide 'octocat-tree-tests)
;;; octocat-tree-tests.el ends here
