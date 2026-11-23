;;; octocat-diff-tests.el --- ERT tests for octocat-diff.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-diff-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-diff-test-comment-markdown ()
  "A comment's body is rendered markdown, unless raw."
  (let ((c (json-parse-string
            "{\"user\":{\"login\":\"me\"},\"body\":\"**hi**\",\"created_at\":\"\"}")))
    (should (equal (octocat-diff--comment-body c "  │ " nil 80) "  │ hi"))
    (should (equal (octocat-diff--comment-body c "  │ " t 80) "  │ **hi**"))))

(ert-deftest octocat-diff-test-comment-head ()
  "A comment's heading names its file and line, if any, then its reactions."
  (let ((c (json-parse-string
            (concat "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\","
                    "\"path\":\"a.el\",\"line\":4,"
                    "\"reactions\":{\"total_count\":1,\"heart\":1}}"))))
    (should (equal (substring-no-properties (octocat-diff--comment-head c))
                   "@me  a.el:L4    ❤️ 1"))))

(ert-deftest octocat-diff-test-timeline ()
  "Comments hang off one rail, a rail row between them."
  (let ((cs (mapcar #'json-parse-string
                    '("{\"user\":{\"login\":\"a\"},\"body\":\"q\"}"
                      "{\"user\":{\"login\":\"b\"},\"body\":\"r\"}"))))
    (should (equal (substring-no-properties (octocat-diff--timeline cs nil 80))
                   "  ◆ @a  \n  │ q\n  │\n  ◆ @b  \n  │ r"))))

(ert-deftest octocat-diff-test-copy-timeline ()
  "Copying a timeline leaves out its bullets and rails."
  (let ((cs (mapcar #'json-parse-string
                    '("{\"user\":{\"login\":\"a\"},\"body\":\"q\"}"
                      "{\"user\":{\"login\":\"b\"},\"body\":\"r\"}"))))
    (should (equal (octocat-markdown-copy-text (octocat-diff--timeline cs nil 80))
                   "@a  \nq\n\n@b  \nr"))))

(ert-deftest octocat-diff-test-comments-section ()
  "Comments are a timeline, an inline one naming its place.
The comments come as a sync snapshot."
  (let ((text (lambda (data)
                (with-temp-buffer
                  (vui-render (octocat-diff-comments-section
                               "Comments" (list :data data) nil 80))
                  (buffer-substring-no-properties (point-min) (point-max))))))
    (should (string-search "(no comments)" (funcall text [])))
    (let ((out (funcall text
                        (vector (json-parse-string
                                 "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\"}")
                                (json-parse-string
                                 "{\"path\":\"a.el\",\"line\":3,\"body\":\"x\",\"created_at\":\"\"}")))))
      (should (string-search "Comments (2)" out))
      (should (string-search "  ◆ @me" out))
      (should (string-search "  │ hi" out))
      (should (string-search "a.el:L3" out))
      (should (string-search "  │ x" out)))))

(defun octocat-diff-tests--face-at (line col)
  "Return the faces at COL of LINE, as a list."
  (ensure-list (get-text-property col 'face line)))

(ert-deftest octocat-diff-test-highlight-sides ()
  "Each side of a hunk is highlighted apart, under the diff faces.
The old side's comment, left open, does not reach the added line."
  (pcase-let ((`(,_ ,removed ,added ,context)
               (octocat-diff--lines
                "@@ -1,2 +1,2 @@\n-/* int x;\n+int x;\n return;\n" "a.c")))
    (should (memq 'font-lock-comment-face (octocat-diff-tests--face-at removed 4)))
    (should (memq 'diff-removed (octocat-diff-tests--face-at removed 4)))
    (should (equal (octocat-diff-tests--face-at added 0) '(diff-indicator-added)))
    (should (equal (octocat-diff-tests--face-at added 1)
                   '(font-lock-type-face diff-added)))
    (should (memq 'font-lock-keyword-face (octocat-diff-tests--face-at context 1)))
    (should (equal (substring-no-properties context) " return;"))))

(ert-deftest octocat-diff-test-highlight-hunks ()
  "Every hunk is highlighted, each on its own."
  (should (memq 'font-lock-keyword-face
                (octocat-diff-tests--face-at
                 (car (last (octocat-diff--lines
                             "@@ -1 +1 @@\n-int a;\n+int b;\n@@ -9 +9 @@\n return;" "a.c")))
                 1))))

(ert-deftest octocat-diff-test-highlight-added-file ()
  "An added file is highlighted whole: a comment spans its lines."
  (let ((lines (octocat-diff--lines
                "@@ -0,0 +1,4 @@\n+/* A note\n+   over lines\n+ */\n+int x;" "a.c")))
    (should (memq 'font-lock-comment-face (octocat-diff-tests--face-at (nth 2 lines) 4)))
    (should (memq 'font-lock-type-face (octocat-diff-tests--face-at (nth 4 lines) 1)))))

(defun octocat-diff-tests--refined (line face)
  "Return the text of LINE in FACE, the parts joined by `|'."
  (let ((pos 0) out)
    (while (< pos (length line))
      (let ((next (next-single-property-change pos 'face line (length line))))
        (when (memq face (octocat-diff-tests--face-at line pos))
          (push (substring-no-properties line pos next) out))
        (setq pos next)))
    (string-join (nreverse out) "|")))

(ert-deftest octocat-diff-test-refine ()
  "The words changed in a line are marked, on both sides.
A line added whole, and a change of spaces alone, are not."
  (pcase-let ((`(,_ ,old ,whole ,new ,_ ,spaced)
               (octocat-diff--lines
                (concat "@@ -1,3 +1,4 @@\n-f(a, b);\n+int x;\n+f(a, c, d);\n"
                        "-g(1);\n+g( 1 );")
                "notes")))
    (should (equal (octocat-diff-tests--refined old 'diff-refine-removed) "b"))
    (should (equal (octocat-diff-tests--refined new 'diff-refine-added) "c, d"))
    (should (equal (octocat-diff-tests--refined whole 'diff-refine-added) ""))
    (should (equal (octocat-diff-tests--refined spaced 'diff-refine-added) ""))))

(ert-deftest octocat-diff-test-refine-limit ()
  "A run of more words than `octocat-diff--refine-limit' is not refined."
  (let ((octocat-diff--refine-limit 4))
    (should (equal (octocat-diff-tests--refined
                    (nth 2 (octocat-diff--lines "@@ -1 +1 @@\n-f(a);\n+f(b);" "notes"))
                    'diff-refine-added)
                   ""))))

(ert-deftest octocat-diff-test-highlight-limit ()
  "A patch past `octocat-diff--highlight-limit' is only in the diff faces."
  (let ((octocat-diff--highlight-limit 10))
    (should (equal (octocat-diff-tests--face-at
                    (nth 1 (octocat-diff--lines "@@ -1 +1 @@\n+return 1;" "a.c"))
                    1)
                   '(diff-added)))))

(ert-deftest octocat-diff-test-highlight-no-mode ()
  "A file with no mode of its own is only in the diff faces."
  (should (equal (octocat-diff-tests--face-at
                  (nth 1 (octocat-diff--lines "@@ -1 +1 @@\n-int x;\n+int y;" "notes"))
                  1)
                 '(diff-removed))))

(defun octocat-diff-tests--render (vnode)
  "Return the text VNODE renders to."
  (with-temp-buffer
    (vui-render vnode)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest octocat-diff-test-no-diff-note ()
  "A file without a patch says why: binary or empty, or too large."
  (should (equal (octocat-diff--no-diff-note "added" 0) "binary or empty"))
  (should (equal (octocat-diff--no-diff-note "modified" 36142) "diff too large to show"))
  (should-not (octocat-diff--no-diff-note "renamed" 0)))

(ert-deftest octocat-diff-test-image-stays-folded ()
  "An image is unfolded only by its own RET; a diff shows unfolded."
  (should (string-search
           "▸ A a.png"
           (octocat-diff-tests--render
            (octocat-diff--file "o/r" (json-parse-string
                                       "{\"filename\":\"a.png\",\"status\":\"added\",\"sha\":\"abc\",\"changes\":0}")
                                80))))
  (should (string-search
           "+x"
           (octocat-diff-tests--render
            (octocat-diff--file "o/r" (json-parse-string
                                       "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}")
                                80)))))

(defconst octocat-diff-tests--patch "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d"
  "A patch whose positions are: 1 the hunk, 2 a, 3 -b, 4 +c, 5 d.")

(ert-deftest octocat-diff-test-span ()
  "A link's lines map to positions in the patch, a context line on both sides."
  (let ((p octocat-diff-tests--patch))
    (should (equal (octocat-diff--span p '("LEFT" . 2) '("RIGHT" . 2)) '(3 . 4)))
    (should (equal (octocat-diff--span p '("RIGHT" . 3) '("LEFT" . 1)) '(2 . 5)))
    (should (equal (octocat-diff--span p '("LEFT" . 3) '("LEFT" . 3)) '(5 . 5)))
    (should (equal (octocat-diff--span p '("RIGHT" . 9) '("RIGHT" . 2)) '(4 . 4)))
    (should-not (octocat-diff--span p '("RIGHT" . 9) '("LEFT" . 9)))))

(ert-deftest octocat-diff-test-text-span ()
  "The lines of a span are highlighted, over the diff's faces; the first is the target."
  (let* ((seg   (octocat-diff--text octocat-diff-tests--patch "a.el" '(3 . 4)))
         (lit   (lambda (i) (and (memq 'octocat-line-highlight
                                       (ensure-list (get-text-property i 'face seg)))
                                 t)))
         (start (lambda (s) (string-search s seg))))
    (should (equal (substring-no-properties seg) octocat-diff-tests--patch))
    (should-not (funcall lit (funcall start " a")))
    (should (funcall lit (funcall start "-b")))
    ;; The newline between them too, so the band reaches the edge.
    (should (funcall lit (+ 2 (funcall start "-b"))))
    (should (funcall lit (funcall start "+c")))
    (should (funcall lit (+ 2 (funcall start "+c"))))
    (should-not (funcall lit (funcall start " d")))
    ;; Over, not under, the diff's own background.
    (should (eq (car (ensure-list (get-text-property (funcall start "-b") 'face seg)))
                'octocat-line-highlight))
    (should (equal (text-property-any 0 (length seg) 'octocat-line-target t seg)
                   (funcall start "-b")))))

(ert-deftest octocat-diff-test-file-at ()
  "A link's lines are highlighted in the file's diff, the first the target.
Without lines, or with none in the patch, the heading is."
  (let* ((file   (octocat--table "filename" "b.el" "patch" octocat-diff-tests--patch))
         (target (lambda (at)
                   (with-temp-buffer
                     (vui-render (octocat-diff--file "o/r" file 80 at))
                     (when-let* ((pos (text-property-any (point-min) (point-max)
                                                         'octocat-line-target t)))
                       (goto-char pos)
                       (buffer-substring-no-properties pos (line-end-position)))))))
    (should (equal (funcall target '(diff "h" ("LEFT" . 2) ("RIGHT" . 2))) "-b"))
    (should (string-search "M b.el" (funcall target '(diff "h"))))
    (should (string-search "M b.el" (funcall target '(diff "h" ("RIGHT" . 9) ("RIGHT" . 9)))))
    (should-not (funcall target nil))))

(ert-deftest octocat-diff-test-file-too-large ()
  "RET on a file too large to diff diffs it in a buffer, given the commits."
  (let ((file (json-parse-string
               "{\"filename\":\"big.txt\",\"status\":\"modified\",\"changes\":9000}"))
        opened)
    (cl-letf (((symbol-function 'octocat-diff-open-large)
               (lambda (&rest args) (setq opened args))))
      (with-temp-buffer
        (vui-render (octocat-diff--file "o/r" file 80 nil '("a" . "b"))
                    (current-buffer))
        (goto-char (point-min))
        (search-forward "big.txt")
        (should (equal (get-text-property (point) 'help-echo) "RET: diff it in a buffer"))
        (call-interactively (key-binding (kbd "RET")))
        (should (equal opened (list "o/r" file '("a" . "b"))))))
    ;; Without the commits, it is just a heading.
    (with-temp-buffer
      (vui-render (octocat-diff--file "o/r" file 80) (current-buffer))
      (goto-char (point-min))
      (search-forward "big.txt")
      (should-not (get-text-property (point) 'help-echo)))))

(defun octocat-diff-tests--open-large (old-rev body)
  "Open the large diff of big.txt from OLD-REV to \"head\", fetching nothing.
Call BODY with its buffer and a function returning the callback of the
fetch of REF; the buffer is killed after."
  (let ((file    (json-parse-string "{\"filename\":\"big.txt\",\"status\":\"modified\"}"))
        fetches)
    (cl-letf (((symbol-function 'y-or-n-p) #'always)
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'octocat-diff--fetch-text)
               (lambda (_repo ref _path k) (push (cons ref k) fetches))))
      (octocat-diff-open-large "o/r" file (cons old-rev "head"))
      (let ((buf (get-buffer "*octocat diff big.txt*")))
        (unwind-protect
            (funcall body buf (lambda (ref) (cdr (assoc ref fetches))))
          (kill-buffer buf))))))

(ert-deftest octocat-diff-test-open-large ()
  "The buffer shows at once; the new side is fetched before the merge base lands."
  (let (base-k)
    (octocat-diff-tests--open-large
     (lambda (k) (setq base-k k))
     (lambda (buf fetched)
       (should (string-search "Fetching both versions"
                              (with-current-buffer buf (buffer-string))))
       (should (funcall fetched "head"))
       (should-not (funcall fetched "base"))
       (funcall base-k "base")
       (funcall (funcall fetched "head") "a\nnew\n")
       (funcall (funcall fetched "base") "a\nold\n")
       (with-current-buffer buf
         (should (derived-mode-p 'diff-mode))
         (should (string-search "-old\n+new" (buffer-string))))))))

(ert-deftest octocat-diff-test-open-large-error ()
  "A failed fetch shows its error in the buffer, and the other side is ignored."
  (octocat-diff-tests--open-large
   (lambda (k) (funcall k '(error . "No merge base")))
   (lambda (buf fetched)
     (funcall (funcall fetched "head") "new\n")
     (should (equal (with-current-buffer buf (buffer-string)) "No merge base\n")))))

(ert-deftest octocat-commit-test-skeleton ()
  "The commit skeleton keeps its grey bars within WIDTH."
  (let ((text (octocat-commit--skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(ert-deftest octocat-commit-test-date-committed ()
  "Rows show when a commit was committed; its author date when it has no other."
  (let ((both (json-parse-string
               "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"committedDate\":\"2026-10-02T10:00:00Z\",\"author\":null}"))
        (old  (json-parse-string
               "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":null}")))
    (should (equal (octocat--commit-date both) "2026-10-02T10:00:00Z"))
    (should (equal (octocat--commit-date old) "2026-10-01T10:00:00Z"))
    (should (equal (octocat-vui--date both)
                   (octocat--format-ts-relative "2026-10-02T10:00:00Z")))))

(ert-deftest octocat-commit-test-date-as-git ()
  "A date reads as `git show' prints it, its age after it."
  (let ((commit (json-parse-string
                 "{\"commit\":{\"author\":{\"date\":\"2026-10-01T10:00:00Z\"}}}"))
        (process-environment (cons "TZ=UTC" process-environment)))
    (set-time-zone-rule "UTC")
    (unwind-protect
        (should (string-prefix-p "Thu Oct 1 10:00:00 2026 +0000  ("
                                 (octocat-commit--date commit "author")))
      (set-time-zone-rule nil))
    (should-not (octocat-commit--date commit "committer"))))

(ert-deftest octocat-diff-test-tree-open-file ()
  "RET on a changed file of a Tree opens it in the file viewer, with its change."
  (let* ((files   (json-parse-string
                   "[{\"filename\":\"src/a.el\",\"status\":\"modified\",\"patch\":\"@@\"}]"))
         (changes (octocat-diff--tree-changes "owner/repo" "abc123" files
                                              '(:revs ("p" . "abc123") :label "Changes")))
         opened)
    (cl-letf (((symbol-function 'octocat-tree--open-file-by-path)
               (lambda (&rest args) (setq opened args))))
      (funcall (plist-get (gethash "src/a.el" changes) :open)))
    (should (equal (seq-take opened 4) '("owner/repo" "abc123" "src/a.el" nil)))
    (should (eq (plist-get (nth 4 opened) :file) (aref files 0)))
    (should (equal (plist-get (nth 4 opened) :revs) '("p" . "abc123")))
    (should (equal (plist-get (nth 4 opened) :label) "Changes"))))

(ert-deftest octocat-diff-test-patch-path ()
  "Each file of the Patch carries its path, for a switch of views to keep."
  (let* ((files (json-parse-string
                 (concat "[{\"filename\":\"a.el\",\"status\":\"modified\",\"patch\":\"@@ -1 +1 @@\"},"
                         "{\"filename\":\"src/b.el\",\"status\":\"modified\","
                         "\"patch\":\"@@ -1 +1 @@\"}]"))))
    (with-temp-buffer
      (insert (octocat-diff-patch-text files))
      (goto-char (point-min))
      (should (octocat-diff--goto-patch "src"))
      (should (looking-at "diff --git a/src/b.el"))
      (should-not (octocat-diff--goto-patch "lib")))))

(ert-deftest octocat-commit-test-tree-changes ()
  "A commit's files mark its tree as its diff does."
  (let* ((files   (json-parse-string
                   (concat "[{\"filename\":\"src/a.el\",\"status\":\"added\","
                           "\"additions\":3,\"deletions\":0,\"changes\":3,\"patch\":\"@@\"},"
                           "{\"filename\":\"old/b.el\",\"status\":\"removed\","
                           "\"additions\":0,\"deletions\":2,\"changes\":2,\"patch\":\"@@\"},"
                           "{\"filename\":\"logo.png\",\"status\":\"modified\","
                           "\"changes\":0}]")))
         (changes (octocat-diff--tree-changes "owner/repo" "abc123" files nil))
         (added   (gethash "src/a.el" changes))
         (removed (gethash "old/b.el" changes)))
    (should (equal (substring-no-properties (plist-get added :mark)) "A "))
    (should (equal (substring-no-properties (plist-get added :after)) "  +3 -0"))
    (should (equal (substring-no-properties (plist-get removed :mark)) "D "))
    (should (functionp (plist-get removed :open)))
    (should (plist-get removed :removed))
    ;; Nothing to count, as in the diff.
    (should (equal (plist-get (gethash "logo.png" changes) :after) ""))
    (should (equal (sort (octocat-diff--tree-dirs files) #'string<) '("old" "src")))))

(ert-deftest octocat-diff-test-patch-text ()
  "Changed files as a patch are every file's diff, as git writes them."
  (let ((files (json-parse-string
                (concat "[{\"filename\":\"a.el\",\"status\":\"modified\","
                        "\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"},"
                        "{\"filename\":\"b.el\",\"status\":\"removed\","
                        "\"patch\":\"@@ -1 +0,0 @@\\n-gone\"}]"))))
    (should (equal (substring-no-properties (octocat-diff-patch-text files))
                   (concat "diff --git a/a.el b/a.el\n"
                           "--- a/a.el\n+++ b/a.el\n"
                           "@@ -1 +1 @@\n-old\n+new\n"
                           "diff --git a/b.el b/b.el\n"
                           "deleted file mode 100644\n"
                           "--- a/b.el\n+++ /dev/null\n"
                           "@@ -1 +0,0 @@\n-gone")))))

(ert-deftest octocat-commit-test-view-segments ()
  "The views are Tree and Patch, in that order, VIEW current."
  (let ((segments (octocat-diff--view-segments 'patch)))
    (should (equal (mapcar #'car segments) '("Tree" "Patch")))
    (should (equal (mapcar #'cadr segments) '(nil t)))))

(ert-deftest octocat-diff-test-tree-notes ()
  "A file's conversations follow its line in a column past the longest file's."
  (let* ((file (lambda (name) (octocat--table "filename" name "status" "modified"
                                              "additions" 1 "deletions" 0 "changes" 1)))
         (changes (octocat-diff--tree-changes
                   "o/r" "main" (vector (funcall file "a.el") (funcall file "src/long-name.el"))
                   nil '(("a.el" 2 diff "h")))))
    ;; "src/long-name.el" is 4 + 2 + 12 + 7 wide, so the column is at 27.
    (should (equal (substring-no-properties (plist-get (gethash "a.el" changes) :after))
                   (concat "  +1 -0" (make-string (- 27 (+ 2 4 7)) ?\s))))
    (should (plist-get (gethash "a.el" changes) :button))
    (should-not (plist-get (gethash "src/long-name.el" changes) :button))
    (should (equal (substring-no-properties
                    (plist-get (gethash "src/long-name.el" changes) :after))
                   "  +1 -0"))))

(ert-deftest octocat-commit-test-patch-text ()
  "A commit as a patch is as `git format-patch' writes it, binary files included."
  (let* ((commit (json-parse-string
                  (concat "{\"sha\":\"abc123\",\"commit\":{\"message\":\"Fix it\\n\\nWhy.\","
                          "\"author\":{\"name\":\"Ann\",\"email\":\"a@x\","
                          "\"date\":\"2026-10-01T10:00:00Z\"}},\"files\":["
                          "{\"filename\":\"a.el\",\"status\":\"modified\","
                          "\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"},"
                          "{\"filename\":\"new.png\",\"status\":\"added\"}]}")))
         (text   (substring-no-properties (octocat-commit--patch-text commit))))
    (should (equal text (concat "From abc123 Mon Sep 17 00:00:00 2001\n"
                                "From: Ann <a@x>\n"
                                "Date: Thu, 01 Oct 2026 10:00:00 +0000\n"
                                "Subject: [PATCH] Fix it\n\n"
                                "Why.\n"
                                "---\n\n"
                                "diff --git a/a.el b/a.el\n"
                                "--- a/a.el\n+++ b/a.el\n"
                                "@@ -1 +1 @@\n-old\n+new\n"
                                "diff --git a/new.png b/new.png\n"
                                "new file mode 100644\n"
                                "Binary files /dev/null and b/new.png differ")))))

(defun octocat-compare-tests--json (s)
  "Parse the JSON string S as the API's response is."
  (json-parse-string s))

(ert-deftest octocat-compare-test-summary ()
  "The top row counts commits and files; notes say what differs from github.com."
  (let ((ahead (octocat-compare-tests--json
                "{\"status\":\"ahead\",\"total_commits\":1,\"behind_by\":0,
                  \"commits\":[{}],\"files\":[{},{}]}"))
        (diverged (octocat-compare-tests--json
                   "{\"status\":\"diverged\",\"total_commits\":3,\"behind_by\":2,
                     \"commits\":[{},{}],\"files\":[]}")))
    (should (equal (octocat-compare--counts ahead) "1 commit · 2 files changed"))
    (should-not (octocat-compare--summary ahead ".."))
    (should (equal (octocat-compare--counts diverged) "3 commits · 0 files changed · 2 behind"))
    (should (equal (octocat-compare--summary diverged "...")
                   '("2 of the 3 commits listed, as GitHub's API returns at most 2")))
    (should (string-search "two-dot" (car (octocat-compare--summary diverged ".."))))
    (should (equal (octocat-compare--counts
                    (octocat-compare-tests--json
                     "{\"status\":\"identical\",\"total_commits\":0,\"commits\":[],\"files\":[]}"))
                   "identical"))))

(ert-deftest octocat-compare-test-ref-label ()
  "A SHA shows its first 7 chars, whole on hover; a branch shows as is."
  (let ((sha (octocat-compare--ref-label "0123456789abcdef0123456789abcdef01234567")))
    (should (equal sha "0123456"))
    (should (equal (get-text-property 0 'help-echo sha)
                   "0123456789abcdef0123456789abcdef01234567")))
  (should (equal (octocat-compare--ref-label "template-cache") "template-cache"))
  (should-not (get-text-property 0 'help-echo (octocat-compare--ref-label "main"))))

(ert-deftest octocat-compare-test-max-age ()
  "Only a comparison of two commits is kept, as a commit is; refs move."
  (let ((max-age (lambda (base head)
                   (plist-get (octocat-sync--props (list 'compare "o/r" base head)) :max-age))))
    (should (funcall max-age "abc1234" (make-string 40 ?f)))
    (should-not (funcall max-age "abc1234" "main"))
    (should-not (funcall max-age "v1.0" "v1.1"))))

(ert-deftest octocat-compare-test-page-renders-files ()
  "A loaded comparison shows its commits, and its files as a Tree or a Patch."
  (let ((data (octocat-compare-tests--json
               "{\"status\":\"ahead\",\"total_commits\":0,\"behind_by\":0,\"commits\":[],
                 \"files\":[{\"filename\":\"a.el\",\"status\":\"modified\",
                             \"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"}]}"))
        (vui-render-delay nil))
    (cl-letf (((symbol-function 'octocat-vui-use-resource)
               (lambda (_spec _tick) (list :data data))))
      (unwind-protect
          (progn
            (vui-mount (vui-component 'octocat-compare--page
                         :repo "o/r" :base "main" :dots "..." :head "topic" :tick 0)
                       "*octocat-compare-test*")
            (with-current-buffer "*octocat-compare-test*"
              (should (string-search " Tree  Patch " (buffer-string)))
              (should-not (string-search "diff --git" (buffer-string)))))
        (kill-buffer "*octocat-compare-test*"))
      ;; The Patch view shows every file's diff as git writes it.
      (unwind-protect
          (progn
            (vui-mount (vui-component 'octocat-compare--page
                         :repo "o/r" :base "main" :dots "..." :head "topic"
                         :view 'patch :tick 0)
                       "*octocat-compare-test*")
            (with-current-buffer "*octocat-compare-test*"
              (should (string-search "diff --git a/a.el b/a.el" (buffer-string)))))
        (kill-buffer "*octocat-compare-test*")))))

(ert-deftest octocat-compare-test-link-opens-file ()
  "A link to lines of a comparison opens its file in the file viewer, at them.
The page stays on its Tree, the link dropped."
  (let ((data (octocat-compare-tests--json
               "{\"status\":\"ahead\",\"total_commits\":0,\"behind_by\":0,\"commits\":[],
                 \"files\":[{\"filename\":\"a.el\",\"status\":\"modified\",
                             \"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"}]}"))
        (at (list 'diff (secure-hash 'sha256 "a.el") '("RIGHT" . 1) '("RIGHT" . 1)))
        (vui-render-delay nil)
        opened)
    (cl-letf (((symbol-function 'octocat-vui-use-resource)
               (lambda (_spec _tick) (list :data data)))
              ((symbol-function 'octocat-tree--open-file-by-path)
               (lambda (&rest args) (setq opened args))))
      (unwind-protect
          (with-current-buffer (get-buffer-create "*octocat-compare-test*")
            (setq octocat-diff--at at)
            (vui-mount (vui-component 'octocat-compare--page
                         :repo "o/r" :base "main" :dots "..." :head "topic"
                         :at at :tick 0)
                       "*octocat-compare-test*")
            (should (equal (seq-take opened 4) (list "o/r" "topic" "a.el" at)))
            (should (equal (plist-get (nth 4 opened) :label) "Changes in main...topic"))
            (should-not octocat-diff--at))
        (kill-buffer "*octocat-compare-test*")))))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
