;;; octocat-diff-tests.el --- ERT tests for octocat-diff.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-diff-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-diff-test-line-count ()
  "A file takes its heading line plus its patch lines; no patch, just one."
  (should (= (octocat-diff--line-count
              (vector (json-parse-string "{\"patch\":\"@@ -1 +1 @@\\n-a\\n+b\"}")
                      (json-parse-string "{\"filename\":\"logo.png\"}")))
             5)))

(ert-deftest octocat-diff-test-comment-markdown ()
  "An inline comment's body is rendered markdown, unless raw."
  (let ((c (json-parse-string
            "{\"user\":{\"login\":\"me\"},\"body\":\"**hi**\",\"created_at\":\"\"}")))
    (should (equal (nth 1 (octocat-diff--comment-lines c nil 80)) "  │ hi"))
    (should (equal (nth 1 (octocat-diff--comment-lines c t 80)) "  │ **hi**"))))

(ert-deftest octocat-diff-test-comment-reactions ()
  "An inline comment's reactions follow the date in its heading."
  (let ((c (json-parse-string
            (concat "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\","
                    "\"reactions\":{\"total_count\":1,\"heart\":1}}"))))
    (should (string-search "  ❤️ 1 ─" (car (octocat-diff--comment-lines c nil 80))))))

(ert-deftest octocat-diff-test-timeline ()
  "General comments hang off one rail, a rail row between them."
  (let ((cs (mapcar #'json-parse-string
                    '("{\"user\":{\"login\":\"a\"},\"body\":\"q\"}"
                      "{\"user\":{\"login\":\"b\"},\"body\":\"r\"}"))))
    (should (equal (substring-no-properties (octocat-diff--timeline cs nil 80))
                   "  ● @a  \n  │ q\n  │\n  ● @b  \n  │ r"))))

(ert-deftest octocat-diff-test-copy-thread ()
  "Copying a thread leaves out its box's edges and rails."
  (let* ((cs (mapcar #'json-parse-string
                     '("{\"user\":{\"login\":\"a\"},\"body\":\"q\"}"
                       "{\"user\":{\"login\":\"b\"},\"body\":\"r\"}")))
         (copy (lambda (lines)
                 (octocat-markdown-copy-text (string-join lines "\n")))))
    (should (equal (octocat-markdown-copy-text (octocat-diff--timeline cs nil 80))
                   "@a  \nq\n\n@b  \nr"))
    (should (equal (split-string (funcall copy (octocat-diff--comment-lines
                                                (car cs) nil 80 (cdr cs)))
                                 "\n")
                   '("@a  " "q" "" "@b  " "r" "")))))

(ert-deftest octocat-diff-test-threads ()
  "A reply joins the box of the comment it answers, a bubble on its edge.
An edge row sets each comment apart from the one before.
A reply to a reply joins the same thread; one whose comment is missing
starts its own."
  (let* ((cs (mapcar #'json-parse-string
                     '("{\"id\":1,\"line\":3,\"user\":{\"login\":\"a\"},\"body\":\"q\"}"
                       "{\"id\":2,\"in_reply_to_id\":1,\"user\":{\"login\":\"b\"},\"body\":\"r\"}"
                       "{\"id\":3,\"in_reply_to_id\":2,\"user\":{\"login\":\"a\"},\"body\":\"s\"}"
                       "{\"id\":4,\"in_reply_to_id\":9,\"line\":5,\"body\":\"t\"}")))
         (threads (octocat-diff--threads cs)))
    (should (equal (mapcar (lambda (th) (mapcar (lambda (c) (gethash "id" c)) th)) threads)
                   '((1 2 3) (4))))
    (should (equal (mapcar #'substring-no-properties
                           (octocat-diff--comment-lines (caar threads) nil 12 (cdar threads)))
                   '("  ┌─ @a   ───" "  │ q" "  │" "  ○── @b  " "  │   r"
                     "  │" "  ○── @a  " "  │   s" "  └─")))
    (should (= (octocat-diff--placed-count "@@ -1,5 +1,5 @@\n a\n b\n c\n d\n e" cs) 4))))

(ert-deftest octocat-diff-test-comments-section ()
  "General comments are a timeline; inline ones only counted.
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
                                 "{\"path\":\"a.el\",\"body\":\"x\",\"created_at\":\"\"}")))))
      (should (string-search "Comments (2)" out))
      (should (string-search "(1 inline comment, in the diff above)" out))
      (should (string-search "  ● @me" out))
      (should (string-search "  │ hi" out))
      (should-not (string-search "┌" out)))))

(ert-deftest octocat-diff-test-files-hide-comments ()
  "Inline comments start hidden, their count on the button that shows them."
  (let* ((file (json-parse-string
                "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
         (c    (json-parse-string
                "{\"path\":\"a.el\",\"line\":1,\"body\":\"note\",\"created_at\":\"\"}"))
         (out  (with-temp-buffer
                 (vui-render (vui-component 'octocat-diff--files
                               :files (vector file)
                               :by-path (octocat-diff-by-path (vector c))
                               :hide t
                               :fits t :raw nil :width 80))
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (should (string-search "]  [Show comments (1)]" out))
    (should (string-search "+x" out))
    (should-not (string-search "note" out))))

(ert-deftest octocat-diff-test-outdated-comments-no-button ()
  "Comments the diff cannot place, as outdated ones, leave out the switch."
  (let* ((file (json-parse-string
                "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
         (c    (json-parse-string
                "{\"path\":\"a.el\",\"line\":40,\"body\":\"gone\",\"created_at\":\"\"}"))
         (out  (with-temp-buffer
                 (vui-render (vui-component 'octocat-diff--files
                               :files (vector file)
                               :by-path (octocat-diff-by-path (vector c))
                               :hide nil :fits t :raw nil :width 80))
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (should-not (string-search "comments (" out))
    (should (string-search "+x" out))))

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

(ert-deftest octocat-diff-test-walk-note ()
  "A `\\ No newline' note takes no line of the new file."
  (let (seen)
    (octocat-diff--walk "@@ -1 +1,2 @@\n-a\n\\ No newline at end of file\n+a\n+b"
                        (octocat-diff--index
                         (list (json-parse-string "{\"line\":2,\"body\":\"x\"}")))
                        (lambda (line placed _anchor) (when placed (push line seen))))
    (should (equal seen '("+b")))))

(ert-deftest octocat-diff-test-walk-anchors ()
  "A removed line is anchored on the old side, the others on the new one.
Each side counts from its `@@' header; a header or a note has none."
  (let (seen)
    (octocat-diff--walk "@@ -5,3 +7,3 @@\n a\n-b\n+c\n d\n@@ -20 +22 @@\n+e"
                        '(nil nil nil)
                        (lambda (_line _placed anchor) (push anchor seen)))
    (should (equal (nreverse seen)
                   '(nil ("RIGHT" 7 2 1) ("LEFT" 6 3 1) ("RIGHT" 8 4 1) ("RIGHT" 9 5 1)
                         nil ("RIGHT" 22 7 2))))))

(defun octocat-diff-tests--comment (json)
  "Return the comment of JSON, with its body and date."
  (let ((c (json-parse-string json)))
    (puthash "body" (or (gethash "body" c) "x") c)
    (puthash "created_at" "" c)
    c))

(ert-deftest octocat-diff-test-segments ()
  "Threads come between runs of diff lines, after the line they are on.
A comment on a removed line is on the old side, one on the whole file
before the diff; each line carries its anchor."
  (let* ((cs (mapcar #'octocat-diff-tests--comment
                     '("{\"id\":1,\"line\":2,\"side\":\"LEFT\"}"
                       "{\"id\":2,\"line\":2,\"side\":\"RIGHT\"}"
                       "{\"id\":3,\"subject_type\":\"file\"}")))
         (segs (octocat-diff--segments "@@ -1,2 +1,2 @@\n a\n-b\n+c"
                                       "notes" (octocat-diff--index cs))))
    (should (equal (mapcar (lambda (s) (if (stringp s)
                                           (substring-no-properties s)
                                         (gethash "id" (car s))))
                           segs)
                   '(3 "@@ -1,2 +1,2 @@\n a\n-b" 1 "+c" 2)))
    (should (equal (get-text-property 0 'octocat-diff-line (nth 3 segs))
                   '("notes" "RIGHT" 2 4 1)))
    (should-not (get-text-property 0 'octocat-diff-line (nth 1 segs)))
    (should (= (octocat-diff--placed-count "@@ -1,2 +1,2 @@\n a\n-b\n+c" cs) 3))))

(ert-deftest octocat-diff-test-range ()
  "A range runs from its first line to its last, in one hunk of one file."
  (should (equal (octocat-diff--range '(("a" "RIGHT" 4 5 1)))
                 '(:path "a" :side "RIGHT" :line 4)))
  (should (equal (octocat-diff--range '(("a" "LEFT" 3 4 1) ("a" "RIGHT" 4 5 1)))
                 '(:path "a" :side "RIGHT" :line 4 :start-side "LEFT" :start-line 3)))
  (should (equal (octocat-diff--range '(("a"))) '(:path "a" :file t)))
  (should-error (octocat-diff--range nil) :type 'user-error)
  (should-error (octocat-diff--range '(("a" "RIGHT" 4 5 1) ("a" "RIGHT" 9 8 2)))
                :type 'user-error)
  (should-error (octocat-diff--range '(("a" "RIGHT" 4 5 1) ("b" "RIGHT" 5 6 1)))
                :type 'user-error))

(ert-deftest octocat-diff-test-range-label ()
  "A range reads as its file and lines, an old-side line marked so."
  (should (equal (octocat-diff-range-label '(:path "a.el" :side "RIGHT" :line 4))
                 "a.el:L4"))
  (should (equal (octocat-diff-range-label
                  '(:path "a.el" :side "RIGHT" :line 9 :start-side "LEFT" :start-line 3))
                 "a.el:old L3–L9"))
  (should (equal (octocat-diff-range-label '(:path "a.el" :file t)) "a.el")))

(defun octocat-diff-tests--render (vnode)
  "Return the text VNODE renders to."
  (with-temp-buffer
    (vui-render vnode)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest octocat-diff-test-thread-resolved ()
  "A resolved thread folds to one line, saying who resolved it."
  (let ((root (octocat-diff-tests--comment
               (concat "{\"id\":1,\"path\":\"a.el\",\"line\":4,\"resolved\":true,"
                       "\"resolved_by\":\"b\",\"user\":{\"login\":\"a\"}}"))))
    (should (equal (octocat-diff-tests--render
                    (vui-component 'octocat-diff--thread
                      :thread (list root) :raw nil :width 80))
                   "  ▸ @a  a.el:L4  Resolved by @b"))))

(ert-deftest octocat-diff-test-thread-pending ()
  "A draft says Pending in its heading; each line names its comment.
A thread that can be resolved ends in a button doing it, a row apart."
  (let* ((root (octocat-diff-tests--comment
                (concat "{\"id\":1,\"line\":4,\"pending\":true,\"can_resolve\":true,"
                        "\"user\":{\"login\":\"me\"},\"body\":\"hm\"}")))
         (text (with-temp-buffer
                 (vui-render (vui-component 'octocat-diff--thread
                               :thread (list root) :raw nil :width 40))
                 (goto-char (point-min))
                 (search-forward "hm")
                 (should (eq (octocat-diff-comment-at-point) root))
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (should (string-prefix-p "  ┌─ @me  Pending ─" text))
    (should (string-search "  │ hm\n  │\n  │ [Resolve conversation]\n  └─" text))))

(ert-deftest octocat-diff-test-underline-last ()
  "Only the last line of a file's diff is underlined, across the width."
  (let ((text (octocat-diff--underline-last "+a\n+b" 10)))
    (should-not (memq 'underline (octocat-diff-tests--face-at text 1)))
    (should (memq 'underline (octocat-diff-tests--face-at text 4)))
    (should (equal (get-text-property 5 'display text) '(space :align-to 10)))))

(ert-deftest octocat-diff-test-no-diff-note ()
  "A file without a patch says why: binary or empty, or too large."
  (should (equal (octocat-diff--no-diff-note "added" 0) "binary or empty"))
  (should (equal (octocat-diff--no-diff-note "modified" 36142) "diff too large to show"))
  (should-not (octocat-diff--no-diff-note "renamed" 0)))

(ert-deftest octocat-diff-test-image-stays-folded ()
  "An image is unfolded only by its own RET, not with the rest of the diff."
  (let ((out (with-temp-buffer
               (vui-render (vui-component 'octocat-diff--files
                             :repo "o/r"
                             :files (vector (json-parse-string
                                             "{\"filename\":\"a.png\",\"status\":\"added\",\"sha\":\"abc\",\"changes\":0}")
                                            (json-parse-string
                                             "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
                             :fits t :raw nil :width 80))
               (buffer-substring-no-properties (point-min) (point-max)))))
    (should (string-search "▸ A a.png" out))
    (should (string-search "+x" out))))

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

(ert-deftest octocat-diff-test-segments-span ()
  "The lines of a span are highlighted, over the diff's faces; the first is the target."
  (let* ((seg   (car (octocat-diff--segments octocat-diff-tests--patch "a.el"
                                             (octocat-diff--index nil) '(3 . 4))))
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

(defun octocat-diff-tests--files-with (at)
  "Mount the Files section of a.el and b.el, folded, AT the lines a link named.
Return the buffer, current, once point has moved there."
  (let ((buf (generate-new-buffer " *files*")))
    (set-buffer buf)
    (vui-mount (vui-component 'octocat-diff--files
                 :repo "o/r"
                 :files (vector (json-parse-string
                                 "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}")
                                (let ((f (make-hash-table :test #'equal)))
                                  (puthash "filename" "b.el" f)
                                  (puthash "patch" octocat-diff-tests--patch f)
                                  f))
                 :fits nil :raw nil :width 80 :at at)
               (buffer-name))
    buf))

(ert-deftest octocat-diff-test-files-total ()
  "Files GitHub left out are counted at the end of the list."
  (with-temp-buffer
    (vui-mount (vui-component 'octocat-diff--files
                 :repo "o/r"
                 :files (vector (json-parse-string
                                 "{\"filename\":\"a.el\",\"patch\":\"@@ -1 +1 @@\\n+x\"}"))
                 :fits nil :raw nil :width 80 :total 31)
               (buffer-name))
    (should (string-search "30 more files changed than GitHub's API lists"
                           (buffer-string)))))

(ert-deftest octocat-diff-test-file-too-large ()
  "RET on a file too large to diff diffs it in a buffer, given the commits."
  (let ((file (json-parse-string
               "{\"filename\":\"big.txt\",\"status\":\"modified\",\"changes\":9000}"))
        opened)
    (cl-letf (((symbol-function 'octocat-diff-open-large)
               (lambda (&rest args) (setq opened args))))
      (with-temp-buffer
        (vui-render (octocat-diff--file "o/r" file nil nil nil 80 t nil '("a" . "b"))
                    (current-buffer))
        (goto-char (point-min))
        (search-forward "big.txt")
        (should (equal (get-text-property (point) 'help-echo) "RET: diff it in a buffer"))
        (call-interactively (key-binding (kbd "RET")))
        (should (equal opened (list "o/r" file '("a" . "b"))))))
    ;; Without the commits, it is just a heading.
    (with-temp-buffer
      (vui-render (octocat-diff--file "o/r" file nil nil nil 80 t) (current-buffer))
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

(ert-deftest octocat-diff-test-files-at ()
  "The file a link names is unfolded, its lines highlighted and scrolled to.
Only that file; a hash naming none changes nothing."
  (let ((h (secure-hash 'sha256 "b.el")))
    (with-current-buffer (octocat-diff-tests--files-with
                          (list 'diff h '("LEFT" . 2) '("RIGHT" . 2)))
      (unwind-protect
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-search "▾ M b.el" text))
            (should (string-search "▸ M a.el" text))
            (should-not (string-search "+x" text))
            (should (looking-at-p "-b"))
            (should (memq 'octocat-line-highlight (ensure-list (get-text-property (point) 'face))))
            (should (equal (octocat-diff--url-fragment) (concat "#diff-" h "L2"))))
        (kill-buffer)))
    ;; The file alone: its heading.
    (with-current-buffer (octocat-diff-tests--files-with (list 'diff h))
      (unwind-protect
          (progn
            (should (string-search "▾ M b.el" (buffer-string)))
            (should (looking-at-p "M b\\.el"))
            (should-not (text-property-any (point-min) (point-max)
                                           'octocat-line-highlight t)))
        (kill-buffer)))
    (with-current-buffer (octocat-diff-tests--files-with
                          (list 'diff (secure-hash 'sha256 "c.el") '("RIGHT" . 1) '("RIGHT" . 1)))
      (unwind-protect
          (progn
            (should (string-search "▸ M b.el" (buffer-string)))
            (should (= (point) (point-min))))
        (kill-buffer)))))

(ert-deftest octocat-diff-test-url-fragment ()
  "The diff line of point, or the region's, makes the link's fragment."
  (let ((h (secure-hash 'sha256 "b.el")))
    (with-current-buffer (octocat-diff-tests--files-with (list 'diff h))
      (unwind-protect
          (cl-flet ((at (s) (goto-char (point-min)) (search-forward s) (goto-char (match-beginning 0))))
            (at "+c")
            (should (equal (octocat-diff--url-fragment) (concat "#diff-" h "R2")))
            (at " d")
            (should (equal (octocat-diff--url-fragment) (concat "#diff-" h "R3")))
            (at "b.el")
            (should (equal (octocat-diff--url-fragment) (concat "#diff-" h)))
            (let ((transient-mark-mode t))
              (at "-b")
              (push-mark (point) t t)
              (at "+c")
              (end-of-line)
              (should (equal (octocat-diff--url-fragment) (concat "#diff-" h "L2-R2")))
              ;; From a.el's heading on: the first file's.
              (at "a.el")
              (should (equal (octocat-diff--url-fragment)
                             (concat "#diff-" (secure-hash 'sha256 "a.el"))))
              (deactivate-mark))
            (goto-char (point-min))
            (should (equal (octocat-diff--url-fragment) "")))
        (kill-buffer)))))

(ert-deftest octocat-commit-test-skeleton ()
  "The commit skeleton keeps its grey bars within WIDTH."
  (let ((text (octocat-commit--skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(ert-deftest octocat-commit-test-date-committed ()
  "Rows show when a commit was committed; its author date when it has no other."
  (let ((both (octocat-model--repo-history-commit
               (json-parse-string
                "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"committedDate\":\"2026-10-02T10:00:00Z\",\"author\":null}")))
        (old  (octocat-model--repo-history-commit
               (json-parse-string
                "{\"oid\":\"a\",\"messageHeadline\":\"s\",\"authoredDate\":\"2026-10-01T10:00:00Z\",\"author\":null}"))))
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

(ert-deftest octocat-commit-test-tree-changes ()
  "A commit's files mark its tree as its diff does, RET on one showing its diff."
  (let* ((files   (json-parse-string
                   (concat "[{\"filename\":\"src/a.el\",\"status\":\"added\","
                           "\"additions\":3,\"deletions\":0,\"changes\":3,\"patch\":\"@@\"},"
                           "{\"filename\":\"old/b.el\",\"status\":\"removed\","
                           "\"additions\":0,\"deletions\":2,\"changes\":2,\"patch\":\"@@\"},"
                           "{\"filename\":\"logo.png\",\"status\":\"modified\","
                           "\"changes\":0}]")))
         (changes (octocat-diff--tree-changes files))
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
  "The commit's views are Diff, Tree and Patch, in that order, VIEW current."
  (let ((segments (octocat-diff--view-segments 'tree)))
    (should (equal (mapcar #'car segments) '("Diff" "Tree" "Patch")))
    (should (equal (mapcar #'cadr segments) '(nil t nil)))))

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
  "A loaded comparison shows its commits and its files."
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
                         :repo "o/r" :base "main" :dots "..." :head "topic"
                         :raw nil :tick 0)
                       "*octocat-compare-test*")
            (with-current-buffer "*octocat-compare-test*"
              (should (string-search "Files (1)" (buffer-string)))))
        (kill-buffer "*octocat-compare-test*")))))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
