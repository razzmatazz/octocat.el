;;; octocat-diff.el --- Diffs, commits and comparisons for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-4-6

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The changed files of a diff, and the pages that show them:
;;
;;   `octocat-commit-mode'  — a commit, as `git show', or as a patch
;;   `octocat-compare-mode' — the commits and files between two refs
;;
;; The changed files are shared with the PR's Files changed page
;; (octocat-pr.el): their Tree, which opens each file's change in the
;; file viewer, and their Patch.  Commit comments and PR review comments
;; have the same shape, so both pages pass theirs in, drawn as a
;; timeline.  Must not depend on octocat.el or octocat-pr.el, to avoid
;; circular requires.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff) ; `diff-command', for a diff GitHub won't send.
(require 'diff-mode) ; The diff faces.
(require 'octocat-core)
(require 'octocat-actions)
(require 'octocat-model)
(require 'octocat-vui)
(require 'vui)

(defvar octocat-timeline-body-lines) ; defcustom in octocat-timeline.el


;;;;; Faces

(defface octocat-diff-file-modified
  '((t :inherit default))
  "Face for the letter of a modified file in a diff."
  :group 'octocat)

(defface octocat-diff-file-added
  '((t :inherit success))
  "Face for the letter of an added file in a diff."
  :group 'octocat)

(defface octocat-diff-file-removed
  '((t :inherit error))
  "Face for the letter of a removed file in a diff."
  :group 'octocat)

(defface octocat-diff-file-renamed
  '((t :inherit octocat-branch))
  "Face for the letter of a renamed file in a diff."
  :group 'octocat)

(defface octocat-diff-file-name
  '((t :inherit bold))
  "Face for a file's name in a diff, set apart from the code below it."
  :group 'octocat)

(defface octocat-diff-hunk-heading
  '((t :inherit diff-header))
  "Face for a diff hunk header line."
  :group 'octocat)

(defface octocat-review-pending
  '((t :inherit warning))
  "Face for a draft review comment's edge and its Pending label."
  :group 'octocat)


;;;;; File status

(defun octocat-diff--file-icon (status)
  "Return a one-char icon string for STATUS."
  (cond ((equal status "added")    (propertize "A" 'face 'octocat-diff-file-added))
        ((equal status "removed")  (propertize "D" 'face 'octocat-diff-file-removed))
        ((equal status "renamed")  (propertize "R" 'face 'octocat-diff-file-renamed))
        (t                         (propertize "M" 'face 'octocat-diff-file-modified))))

;;;;; Comments
;;
;; A commit's comments and a PR's review comments have the same shape;
;; the pages draw them as a timeline under the changed files.

(defun octocat-diff--comment-head (comment)
  "Return the author, place, date and reactions of COMMENT, propertized.
The place is the file and line it is on, if any.  A draft, with
\"pending\" set, says so."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user)
                          (octocat--nonempty (gethash "login" user)))
                     ""))
         (path   (octocat--nonempty (gethash "path" comment)))
         (line   (gethash "line" comment))
         (date   (octocat--format-ts-relative
                  (or (octocat--nonempty (gethash "created_at" comment)) "")))
         (reactions (octocat--reactions-string comment)))
    (concat (propertize (if (string-empty-p login) "(unknown)" (concat "@" login))
                        'face 'octocat-pr-author)
            (if path
                (propertize (concat "  " path (if (integerp line) (format ":L%d" line) ""))
                            'face 'octocat-dimmed)
              "")
            (if (eq (gethash "pending" comment) t)
                (propertize "  Pending" 'face 'octocat-review-pending)
              (propertize (concat "  " date) 'face 'octocat-dimmed))
            (if reactions (concat "  " reactions) ""))))

(defun octocat-diff--comment-body (comment prefix raw width)
  "Return the body of COMMENT, each line after PREFIX, without final newline.
The body is markdown, rendered unless RAW, to fit WIDTH columns."
  (let ((body (string-trim (or (gethash "body" comment) ""))))
    (if (string-empty-p body)
        (concat prefix (propertize "(empty)" 'face 'octocat-dimmed))
      (string-remove-suffix "\n" (octocat--markdown-string body prefix raw width)))))

(defun octocat-diff--timeline (comments raw width)
  "Return COMMENTS as a timeline, without final newline.
They are drawn as the PR timeline's comments, a bullet then the body on
a rail.  RAW and WIDTH are as for `octocat-diff--comment-body'."
  (let ((rail (propertize "  │ " 'face 'octocat-dimmed 'octocat-markdown-copy 'drop)))
    (mapconcat (lambda (c)
                 (concat (propertize "  ◆ " 'face 'octocat-dimmed 'octocat-markdown-copy 'drop)
                         (octocat-diff--comment-head c) "\n"
                         (octocat-diff--comment-body c rail raw width)))
               comments
               (concat "\n" (string-trim-right rail) "\n"))))

(defun octocat-diff--span (patch from to)
  "Return (START . END), the positions in PATCH of its lines FROM and TO, or nil.
FROM and TO are (SIDE . LINE), as `octocat--url-lines' reads them; a
context line is on both sides.  When one is not in PATCH, the other is
both ends."
  (let ((left 0) (right 0) (pos 0) start end)
    (dolist (raw (octocat-diff--split patch))
      (cl-incf pos)
      (let ((on (pcase (octocat-diff--line-kind raw)
                  ('hunk
                   (when (string-match "@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw)
                     (setq left  (string-to-number (match-string 1 raw))
                           right (string-to-number (match-string 2 raw))))
                   nil)
                  ('note nil)
                  ('removed (prog1 (list (cons "LEFT" left)) (cl-incf left)))
                  ('added   (prog1 (list (cons "RIGHT" right)) (cl-incf right)))
                  (_ (prog1 (list (cons "LEFT" left) (cons "RIGHT" right))
                       (cl-incf left)
                       (cl-incf right))))))
        (when (and (not start) (member from on)) (setq start pos))
        (when (member to on) (setq end pos))))
    (let ((start (or start end))
          (end   (or end start)))
      (and start (cons (min start end) (max start end))))))

(defun octocat-diff--light (line target)
  "Return LINE in `octocat-line-highlight', over its diff faces, as GitHub's band.
TARGET marks it `octocat-line-target' too, the line scrolled to."
  (add-face-text-property 0 (length line) 'octocat-line-highlight nil line)
  (when target (put-text-property 0 (length line) 'octocat-line-target t line))
  line)

(defun octocat-diff--text (patch path &optional span)
  "Return the unified diff PATCH in the diff faces, without final newline.
PATH is the file's, whose major mode highlights the code, see
`octocat-diff--lines'.  A line is cut at `octocat--max-line-length',
see `octocat--clip-line'.  The lines at the positions SPAN, (START .
END) as `octocat-diff--span' gives them, are highlighted, and the first
is the target, see `octocat-diff--light'.  Diff lines are not indented,
so they copy out as a valid patch."
  ;; The newline after a highlighted line takes its face, so the band
  ;; reaches the window's edge.  One `concat': `cl-loop''s copies what
  ;; it has joined at every line.
  (apply #'concat
         (cl-loop for (line . more) on (octocat-diff--lines patch path)
                  for raw in (octocat-diff--split patch)
                  for pos from 1
                  for lit = (and span (<= (car span) pos (cdr span))
                                 (not (memq (octocat-diff--line-kind raw) '(hunk note))))
                  for text = (octocat--clip-line line octocat--max-line-length)
                  collect (if lit (octocat-diff--light text (= pos (car span))) text)
                  when more
                  collect (propertize "\n" 'face (and lit 'octocat-line-highlight)))))


;;;;; Highlighting
;;
;; A hunk holds part of two files: its old side, the context and removed
;; lines, and its new side, the context and added lines.  Each side is
;; highlighted by the file's major mode on its own, and the diff faces
;; are laid under the code's.  An added file is one hunk, its new side
;; the whole file, so it is highlighted as the file itself would be.

(defconst octocat-diff--highlight-limit 50000
  "Longest patch, in characters, whose code is highlighted.
About a thousand lines; a mode takes up to a second for twice that.")

(defun octocat-diff--split (patch)
  "Return the lines of PATCH, without the empty one after a final newline."
  (let ((lines (split-string patch "\n")))
    (if (equal (car (last lines)) "") (butlast lines) lines)))

(defun octocat-diff--line-kind (line)
  "Return what diff LINE is: `hunk', `added', `removed', `note' or `context'.
A note is a `\\ No newline at end of file'."
  (cond ((string-prefix-p "@@" line) 'hunk)
        ((string-prefix-p "+" line)  'added)
        ((string-prefix-p "-" line)  'removed)
        ((string-prefix-p "\\" line) 'note)
        (t                           'context)))

(defun octocat-diff--fontify (path texts)
  "Return the lines of each of TEXTS, highlighted as PATH's major mode would.
Return nil when PATH's mode, if any, does not highlight.  The mode is
set up once, with its hooks delayed, as for a file being visited."
  (with-temp-buffer
    (octocat-fontify-set-mode path)
    (when (font-lock-specified-p major-mode)
      (mapcar (lambda (text)
                (erase-buffer)
                (insert text)
                ;; A mode's broken font-lock rules should not lose the text.
                (with-demoted-errors "Octocat: cannot highlight: %S"
                  (font-lock-ensure))
                (split-string (octocat-fontify-faces-only (buffer-string)) "\n"))
              texts))))

(defun octocat-diff--bodies (lines kinds path)
  "Return the code of each diff line of LINES, highlighted for PATH.
KINDS are the lines' kinds, see `octocat-diff--line-kind'.  The code is
the line without its first column, nil for a hunk heading or a note.
Each hunk's sides are highlighted apart, see `octocat-diff--fontify';
the code is left plain when PATH has no mode."
  (let* ((bodies (vconcat (cl-mapcar (lambda (l k)
                                       (and (memq k '(added removed context))
                                            (substring l 1)))
                                     lines kinds)))
         (kinds (vconcat kinds))
         hunks old new)
    ;; Each hunk as (OLD . NEW), the indexes of the lines of each side.
    (cl-loop for k across kinds for i from 0
             do (pcase k
                  ('hunk (when (or old new) (push (cons (nreverse old) (nreverse new)) hunks))
                         (setq old nil new nil))
                  ('removed (push i old))
                  ('added (push i new))
                  ('context (push i old) (push i new))))
    (when (or old new) (push (cons (nreverse old) (nreverse new)) hunks))
    (setq hunks (nreverse hunks))
    (let ((sides (mapcan (lambda (h) (list (car h) (cdr h))) hunks)))
      (when-let* ((done (octocat-diff--fontify
                         path (mapcar (lambda (side)
                                        (mapconcat (lambda (i) (aref bodies i)) side "\n"))
                                      sides))))
        (cl-loop for side in sides for fontified in done
                 for removed = t then (not removed) ; Sides alternate, old first.
                 do (cl-loop for i in side for line in fontified
                             ;; A context line is the same on both sides:
                             ;; the new side's is kept.
                             unless (and removed (eq (aref kinds i) 'context))
                             do (aset bodies i line)))))
    (append bodies nil)))

(defconst octocat-diff--refine-limit 40000
  "Most word pairs compared to find what changed in a run of lines.
The comparison takes time and memory in their number.")

(defun octocat-diff--words (strings)
  "Return the words of STRINGS, a vector of (INDEX START END).
A word is a run of letters, digits and `_', or any other character
but a space.  INDEX is the string's, START and END the word's bounds."
  (let (out)
    (cl-loop for s in strings for i from 0
             do (let ((pos 0))
                  (while (string-match "[[:alnum:]_]+\\|[^[:space:]]" s pos)
                    (push (list i (match-beginning 0) (match-end 0)) out)
                    (setq pos (match-end 0)))))
    (vconcat (nreverse out))))

(defun octocat-diff--common (a b)
  "Return the strings of A and B, vectors of strings, in a longest common run.
That is (IN-A . IN-B), two vectors of booleans, as `diff' finds them."
  (let* ((n (length a)) (m (length b))
         ;; Row I, column J: the longest common run of A from I, B from J.
         (table (vconcat (cl-loop repeat (1+ n) collect (make-vector (1+ m) 0))))
         (in-a (make-bool-vector n nil))
         (in-b (make-bool-vector m nil))
         (i 0) (j 0))
    (cl-flet ((at (i j) (aref (aref table i) j)))
      (cl-loop for i from (1- n) downto 0
               do (cl-loop for j from (1- m) downto 0
                           do (aset (aref table i) j
                                    (if (equal (aref a i) (aref b j))
                                        (1+ (at (1+ i) (1+ j)))
                                      (max (at (1+ i) j) (at i (1+ j)))))))
      (while (and (< i n) (< j m))
        (cond ((equal (aref a i) (aref b j))
               (aset in-a i t) (aset in-b j t) (cl-incf i) (cl-incf j))
              ((>= (at (1+ i) j) (at i (1+ j))) (cl-incf i))
              (t (cl-incf j)))))
    (cons in-a in-b)))

(defun octocat-diff--mark (strings words kept face)
  "Add FACE to the WORDS of STRINGS not KEPT, a vector of booleans.
Changed words next to each other on a line are marked as one, with the
spaces between them.  A line none of whose words is kept is added or
removed whole, and left unmarked, as `diff-refine-nonmodified' leaves
it.  See `octocat-diff--words' for WORDS."
  (let ((kept-lines (cl-loop for w across words for k from 0
                             when (aref kept k) collect (car w)))
        range)                          ; (INDEX START END) being marked.
    (cl-flet ((flush ()
                (when (and range (memq (car range) kept-lines))
                  (pcase-let ((`(,i ,beg ,end) range))
                    (add-face-text-property beg end face nil (nth i strings)))
                  (setq range nil))))
      (cl-loop for w across words for k from 0
               do (cond ((aref kept k) (flush))
                        ((and range (= (car range) (car w)))
                         (setf (nth 2 range) (nth 2 w)))
                        (t (flush) (setq range (copy-sequence w)))))
      (flush))))

(defun octocat-diff--refine (kinds bodies)
  "Mark the words changed in each run of removed lines and added ones after.
KINDS are the lines' kinds and BODIES their code, see
`octocat-diff--bodies': the changed words get `diff-refine-removed' or
`diff-refine-added', in place.  A run of too many words, see
`octocat-diff--refine-limit', is left as it is."
  (let ((kinds (vconcat kinds)) (bodies (vconcat bodies)) (i 0))
    (while (< i (length kinds))
      (let* ((j (or (cl-position-if-not (lambda (k) (eq k 'removed)) kinds :start i)
                    (length kinds)))
             (k (or (cl-position-if-not (lambda (k) (eq k 'added)) kinds :start j)
                    (length kinds))))
        (if (and (> j i) (> k j))
            (let* ((old (append (substring bodies i j) nil))
                   (new (append (substring bodies j k) nil))
                   (wa (octocat-diff--words old))
                   (wb (octocat-diff--words new)))
              (when (<= (* (length wa) (length wb)) octocat-diff--refine-limit)
                (cl-flet ((text (strings words)
                            (vconcat (mapcar (pcase-lambda (`(,n ,beg ,end))
                                               (substring-no-properties (nth n strings) beg end))
                                             words))))
                  (let ((kept (octocat-diff--common (text old wa) (text new wb))))
                    (octocat-diff--mark old wa (car kept) 'diff-refine-removed)
                    (octocat-diff--mark new wb (cdr kept) 'diff-refine-added))))
              (setq i k))
          (setq i (max (1+ i) j)))))))

(defun octocat-diff--lines (patch path)
  "Return the lines of PATCH, a file's unified diff, propertized for display.
PATH is the file's: its major mode highlights the code, see
`octocat-diff--bodies', under `diff-added' or `diff-removed', and the
words changed within lines are marked, see `octocat-diff--refine'.  A
patch larger than `octocat-diff--highlight-limit' is only in the diff
faces."
  (let* ((lines  (octocat-diff--split patch))
         (kinds  (mapcar #'octocat-diff--line-kind lines))
         (large  (> (length patch) octocat-diff--highlight-limit))
         (bodies (mapcar (lambda (b) (and b (copy-sequence b)))
                         (if large
                             (cl-mapcar (lambda (l k)
                                          (and (memq k '(added removed context))
                                               (substring l 1)))
                                        lines kinds)
                           (octocat-diff--bodies lines kinds path)))))
    (unless large
      (octocat-diff--refine kinds bodies))
    (cl-mapcar
     (lambda (line kind body)
       (pcase kind
         ('hunk (propertize line 'face 'octocat-diff-hunk-heading))
         ('note line)
         (_ (let ((face (pcase kind ('added 'diff-added) ('removed 'diff-removed))))
              (when face
                (add-face-text-property 0 (length body) face t body))
              (concat (if face
                          (propertize (substring line 0 1) 'face
                                      (if (eq kind 'added)
                                          'diff-indicator-added
                                        'diff-indicator-removed))
                        (substring line 0 1))
                      body)))))
     lines kinds bodies)))


;;;;; Components

(defun octocat-diff--no-diff-note (status changes)
  "Return why a file of STATUS has no patch, or nil.
CHANGES is how many of its lines changed.  GitHub sends no patch for a
binary file, nor for a diff too large; an empty file, as a binary one,
has no lines changed.  A rename alone has no diff to explain."
  (cond ((and (equal status "renamed") (eql changes 0)) nil)
        ((eql changes 0) "binary or empty")
        (t "diff too large to show")))

(defun octocat-diff--merge-base (repo base head callback)
  "Call CALLBACK with the merge base of BASE and HEAD in REPO, or (error . MSG)."
  (octocat-sync-get (list 'merge-base repo base head)
                    (octocat--then (lambda (data) (gethash "sha" data)) callback)))

(defun octocat-diff--fetch-text (repo ref path callback)
  "Call CALLBACK with the content of PATH at REF in REPO, or (error . MSG).
Without REF, the file is not on that side, and its content is empty."
  (if (null ref)
      (funcall callback "")
    (octocat-sync-get (list 'file-text repo ref path)
                      (octocat--then (lambda (data) (gethash "text" data)) callback))))

(defun octocat-diff--large-set (buf thunk)
  "Empty BUF, a large file's diff buffer, and call THUNK in it to fill it.
Nothing is done once BUF is killed."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall thunk))
      (goto-char (point-min)))))

(defun octocat-diff--show-large (buf old-path path old new)
  "Show in BUF the diff of OLD, the text of OLD-PATH, and NEW, that of PATH."
  (let ((a (make-temp-file "octocat-a-" nil nil old))
        (b (make-temp-file "octocat-b-" nil nil new)))
    (unwind-protect
        (octocat-diff--large-set
         buf (lambda ()
               (call-process diff-command nil t nil "-u"
                             "--label" (concat "a/" old-path) "--label" (concat "b/" path)
                             a b)))
      (delete-file a)
      (delete-file b))))

(defun octocat-diff-open-large (repo file revs)
  "Diff FILE of REPO, whose diff GitHub won't send, in a buffer of its own.
Asks first, as both versions of the file are fetched whole.  The buffer
shows at once, and the diff once both are in.  REVS is \=(OLD . NEW),
the commits compared; OLD may instead be a function that calls its
callback with the commit, or with (error . MSG)."
  (let* ((path     (gethash "filename" file))
         (old-path (or (octocat--nonempty (gethash "previous_filename" file)) path))
         (status   (gethash "status" file))
         (buf      (get-buffer-create (format "*octocat diff %s*" path)))
         old new failed
         (fail     (lambda (r)
                     (unless failed
                       (setq failed t)
                       (octocat-diff--large-set
                        buf (lambda () (insert (propertize (cdr r) 'face 'error) "\n"))))))
         (done     (lambda ()
                     (when (and old new (not failed))
                       (octocat-diff--show-large buf old-path path old new)))))
    (when (y-or-n-p (format "Fetch both versions of %s and diff them? " path))
      (with-current-buffer buf
        (diff-mode)
        (setq buffer-read-only t))
      (octocat-diff--large-set
       buf (lambda () (insert (propertize (format "Fetching both versions of %s…\n" path)
                                          'face 'octocat-dimmed))))
      (pop-to-buffer buf)
      ;; The new side needs no merge base: fetched alongside it.
      (octocat-diff--fetch-text
       repo (and (not (equal status "removed")) (cdr revs)) path
       (lambda (b)
         (if (eq (car-safe b) 'error)
             (funcall fail b)
           (setq new b)
           (funcall done))))
      (funcall
       (if (functionp (car revs)) (car revs) (lambda (k) (funcall k (car revs))))
       (lambda (rev)
         (if (eq (car-safe rev) 'error)
             (funcall fail rev)
           (octocat-diff--fetch-text
            repo (and (not (equal status "added")) rev) old-path
            (lambda (a)
              (if (eq (car-safe a) 'error)
                  (funcall fail a)
                (setq old a)
                (funcall done))))))))))

(vui-defcomponent octocat-diff--image (repo sha width)
  "The image of blob SHA of REPO, no wider than WIDTH columns."
  :render
  (let* ((snap (octocat-vui-use-resource (list 'blob repo sha) nil))
         (data (plist-get snap :data))
         (text (vui-use-memo (data width)
                 (and data (octocat--image-text (octocat-model-blob-content data) width)))))
    (pcase (octocat-vui-snapshot-status snap)
      ('pending (vui-text (octocat-vui-skeleton '(("" 24)))))
      ('error   (vui-text (octocat-vui-error-text snap) :face 'error))
      (_        (vui-text text)))))

(defun octocat-diff--counts (file)
  "Return the lines FILE added and removed, to follow its name, or nil.
Nil for a file with no patch and no lines changed, nothing to count."
  (let ((patch (gethash "patch" file)))
    (unless (and (not (and (stringp patch) (not (string-empty-p patch))))
                 (eql (gethash "changes" file) 0))
      (propertize (format "  +%d -%d"
                          (or (gethash "additions" file) 0)
                          (or (gethash "deletions" file) 0))
                  'face 'octocat-dimmed))))

(defun octocat-diff--file (repo file width &optional at revs)
  "Return one changed FILE (a files-endpoint hash-table) of REPO, unfolded.
An image added or modified unfolds to the image, no wider than WIDTH
columns, see `octocat-diff--image', but only by its own RET, so no
image is fetched unasked.  Another file without a patch is just its
heading, which says why, see `octocat-diff--no-diff-note'; given REVS,
as for `octocat-diff-open-large', RET on one too large diffs it in a
buffer.  AT, (diff HASH FROM TO) as `octocat--url-lines' reads a link to
this file, highlights lines FROM to TO; without them, or with neither
in the patch, the heading is the place scrolled to."
  (let* ((filename (or (gethash "filename" file) ""))
         (status   (or (gethash "status" file) "modified"))
         (patch    (let ((p (gethash "patch" file)))
                     (and (stringp p) (not (string-empty-p p)) p)))
         (changes  (or (gethash "changes" file) 0))
         (span     (and at (nth 2 at) patch (octocat-diff--span patch (nth 2 at) (nth 3 at))))
         (sha      (gethash "sha" file))
         (image    (and (null patch) (stringp sha)
                        (member status '("added" "modified"))
                        (octocat--image-file-p filename)))
         (title    (concat (octocat-diff--file-icon status)
                           " "
                           (propertize filename 'face 'octocat-diff-file-name)
                           (octocat-diff--counts file)))
         (title    (if (and at (not span)) (propertize title 'octocat-line-target t) title)))
    (cond
     (image
      (vui-component 'octocat-vui-fold
        :key (intern filename)
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show image" . "RET: hide image")))
        :deps (list repo sha width)
        :prepare (lambda ()
                   (cons 1 (lambda (_n)
                             (list (vui-component 'octocat-diff--image
                                     :repo repo :sha sha :width width)))))))
     ((null patch)
      (let ((line (concat "  " title
                          (when-let* ((note (octocat-diff--no-diff-note status changes)))
                            (propertize (concat "  " note) 'face 'octocat-dimmed)))))
        (if (and revs (not (eql changes 0)))
            (octocat-vui-row line (lambda () (octocat-diff-open-large repo file revs))
                             "RET: diff it in a buffer")
          (vui-text line))))
     (t
      (vui-component 'octocat-vui-fold
        :key (intern filename)
        :bulk '(0 . t)
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show diff" . "RET: hide diff")))
        :compute-deps (list patch span)
        :compute (lambda () (octocat-diff--text patch filename span))
        :prepare (lambda (text)
                   (let ((ends (octocat-vui-line-ends text)))
                     (cons (1+ (length ends))
                           (lambda (n)
                             (list (vui-text (octocat-vui-take-lines text ends n))))))))))))

(defvar-local octocat-diff--at nil
  "Where the page is to start, or nil.
The lines a link to this page named, (diff HASH FROM TO), see
`octocat--url-lines', or (path PATH DIR-P), the file or directory a
switch of views kept, see `octocat-diff-show-view'.  The user's refresh
drops them, see `octocat-diff-use-at-reset'.")

(defun octocat-diff-use-at-reset ()
  "Drop `octocat-diff--at' once the user refreshes the page.
Called by the page, not a view, so it drops in every view.  Must be
called during render, like any hook."
  (let ((buf (current-buffer)))
    (octocat-vui-use-view-reset
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when octocat-diff--at
             (setq octocat-diff--at nil)
             (octocat-vui-update-page :at nil))))))))

(defun octocat-diff-comments-section (label comments raw width)
  "Return the vnode of the comments section headed LABEL, e.g. \"Comments\".
COMMENTS is the sync snapshot of the comments, drawn as a timeline, see
`octocat-diff--timeline'.  RAW and WIDTH are as for
`octocat-diff--comment-body'; the heading is underlined across WIDTH."
  (let* ((status (octocat-vui-snapshot-status comments))
         (all    (plist-get comments :data))
         (noun   (downcase (string-remove-suffix "s" label))))
    (apply #'vui-vstack
           (octocat-vui-section-heading (if (eq status 'ready)
                                            (format "%s (%d)" label (length all))
                                          label)
                                        width)
           (pcase status
             ('pending (list (vui-text (octocat-vui-skeleton '(("  " 36))))))
             ('error   (list (vui-text (concat "  " (octocat-vui-error-text comments))
                               :face 'octocat-dimmed)))
             (_ (list (if (seq-empty-p all)
                          (vui-text (format "  (no %ss)" noun) :face 'octocat-dimmed)
                        (vui-text (octocat-diff--timeline all raw width)))))))))


;;;; Views
;;
;; A page of changed files shows them two ways, as `octocat-diff--views':
;; the Tree, the repository's files at the new side, opened down to the
;; changes and marked as in the diff, which is the tree browser's; and
;; the Patch, every file's diff as git writes it.  A file's change is
;; read in the file viewer, opened from the Tree.

(defconst octocat-diff--views '(tree patch)
  "The views of changed files, in the order `octocat-diff-cycle-view' goes.")

(defvar-local octocat-diff--view nil
  "The view this page shows, one of `octocat-diff--views'.
A page with views sets it, buffer-locally.")

(defun octocat-diff--view-segments (view)
  "Return the segments of the views of a page of changed files, VIEW current.
The hints name the key that cycles them.  See `octocat-vui-segmented'."
  (let ((key (substitute-command-keys "\\[octocat-diff-cycle-view]")))
    (mapcar (lambda (v)
              (let ((label (capitalize (symbol-name v))))
                (list label (eq v view)
                      (propertize (format "RET: show the %s  %s: next view"
                                          (downcase label) key)
                                  'octocat-key-help t)
                      (lambda () (octocat-diff-show-view v)))))
            octocat-diff--views)))

(defun octocat-diff--path-at-point ()
  "Return the path of the changed file or the directory at point, or nil.
That is in the view shown, see `octocat-diff--view'."
  (pcase octocat-diff--view
    ('tree  (octocat-tree--path-at-point))
    ('patch (get-text-property (point) 'octocat-diff-path))))

(defun octocat-diff--under-p (file path)
  "Return non-nil if FILE, a path, is PATH or in directory PATH."
  (or (equal file path) (string-prefix-p (concat path "/") file)))

(defun octocat-diff--goto-patch (path)
  "Move point to the diff of the first file of the Patch at or under PATH.
A window scrolls it to the top only if it is hidden.  Return non-nil if
one is there."
  (let ((pos (point-min)) found)
    (while (and (not found) pos (< pos (point-max)))
      (let ((file (get-text-property pos 'octocat-diff-path)))
        (if (and file (octocat-diff--under-p file path))
            (setq found pos)
          (setq pos (next-single-property-change pos 'octocat-diff-path)))))
    (when found
      (goto-char found)
      (dolist (win (get-buffer-window-list (current-buffer) nil t))
        (set-window-point win found)
        (unless (pos-visible-in-window-p found win)
          (set-window-start win found)))
      t)))

(defun octocat-diff-show-view (view)
  "Show this page's changed files as VIEW, one of `octocat-diff--views'.
The file or directory at point is kept: the new view starts at it, or
at the first file changed in it."
  (unless (local-variable-p 'octocat-diff--view)
    (user-error "Octocat: This page has no views"))
  (let ((path  (octocat-diff--path-at-point))
        (dir-p (and (eq octocat-diff--view 'tree) (eq (octocat-tree--type-at-point) 'dir))))
    (setq octocat-diff--view view
          ;; Off any file, the view starts afresh, not at one kept before.
          octocat-diff--at (and path (list 'path path dir-p)))
    (octocat-vui-update-page :view view :at octocat-diff--at)
    (when (and path (eq view 'patch))
      (octocat-diff--goto-patch path))))

(defun octocat-diff-cycle-view ()
  "Show the changed files the other way: as their tree, or their patch.
The tree is the repository's files, opened down to those changed,
marked as in the diff; the patch is every file's diff as git writes it."
  (interactive)
  (unless (local-variable-p 'octocat-diff--view)
    (user-error "Octocat: This page has no views"))
  (let ((next (or (cadr (memq octocat-diff--view octocat-diff--views))
                  (car octocat-diff--views))))
    (message "View: %s" (capitalize (symbol-name next)))
    (octocat-diff-show-view next)))

(defun octocat-diff--patch-file (file)
  "Return the diff of changed FILE, as git writes it, propertized.
FILE is an entry of the \"files\" of a commit or a pull request.
Without a patch, as of a binary or very large file, git's line saying
it differs stands in."
  (let* ((new    (or (gethash "filename" file) ""))
         (old    (or (octocat--nonempty (gethash "previous_filename" file)) new))
         (status (gethash "status" file))
         (patch  (gethash "patch" file))
         (a      (if (equal status "added") "/dev/null" (concat "a/" old)))
         (b      (if (equal status "removed") "/dev/null" (concat "b/" new))))
    (propertize
     (concat
      (propertize (string-join
                   (delq nil
                         (list (format "diff --git a/%s b/%s" old new)
                               (pcase status
                                 ("added" "new file mode 100644")
                                 ("removed" "deleted file mode 100644"))
                               (and (equal status "renamed")
                                    (format "rename from %s\nrename to %s" old new))))
                   "\n")
                  'face 'octocat-diff-file-name)
      "\n"
      (if (stringp patch)
          (concat (propertize (format "--- %s\n+++ %s" a b) 'face 'octocat-diff-file-name)
                  "\n"
                  (mapconcat (lambda (l) (octocat--clip-line l octocat--max-line-length))
                             (octocat-diff--lines patch new) "\n"))
        (format "Binary files %s and %s differ" a b)))
     ;; Which file it is, for a switch of views to keep.
     'octocat-diff-path new)))

(defun octocat-diff-patch-text (files)
  "Return the diff of FILES as git writes it, as GitHub's .diff.
Each file's diff in full, see `octocat-diff--patch-file'.  Not
indented, so it copies out as a patch `git apply' applies."
  (mapconcat #'octocat-diff--patch-file files "\n"))

(defun octocat-diff--open-change (repo ref file context &optional at)
  "Open changed FILE of REPO in the file viewer at REF, on its Diff view.
Its change is FILE's entry with CONTEXT, see `octocat-diff--tree-changes'.
AT, (diff HASH FROM TO) as `octocat--url-lines' reads a link, scrolls
to lines FROM to TO, highlighted."
  (octocat-tree--open-file-by-path repo ref (or (gethash "filename" file) "") at
                                   (cons :file (cons file context))))

(defun octocat-diff--tree-changes (repo ref files context &optional notes)
  "Return how the tree of REPO at REF is to show FILES, the \"files\" changed.
See `octocat-tree--subtree'.  They are as in its diff, see
`octocat-diff--file-icon' and `octocat-diff--counts'; RET on one opens
it in the file viewer, see `octocat-diff--open-change', its change
being the file's entry with CONTEXT, a plist of :revs and :label, see
`octocat-tree--file-change'.  NOTES, an alist of (PATH COUNT . AT),
ends a file's line with its COUNT of conversations, in a column past
the longest changed file's, RET on it opening the file at AT."
  (let* ((changes (make-hash-table :test #'equal))
         ;; As the tree draws them: 4 columns a level, then the mark.
         (width   (lambda (file)
                    (let ((path (or (gethash "filename" file) "")))
                      (+ (* 4 (cl-count ?/ path)) 2
                         (string-width (file-name-nondirectory path))
                         (string-width (or (octocat-diff--counts file) ""))))))
         (column  (and notes (+ 2 (seq-reduce #'max (seq-map width files) 0)))))
    (seq-doseq (file files)
      (let* ((status (or (gethash "status" file) "modified"))
             (path   (or (gethash "filename" file) ""))
             (counts (or (octocat-diff--counts file) ""))
             (note   (cdr (assoc path notes))))
        (puthash path
                 (list :mark    (concat (octocat-diff--file-icon status) " ")
                       :face    'octocat-diff-file-name
                       :after   (if note
                                    (concat counts
                                            (make-string (- column (funcall width file)) ?\s))
                                  counts)
                       :button  (and note
                                     (octocat-diff--note-button
                                      (car note)
                                      (lambda ()
                                        (octocat-diff--open-change repo ref file context
                                                                   (cdr note)))))
                       :open    (lambda () (octocat-diff--open-change repo ref file context))
                       :removed (equal status "removed"))
                 changes)))
    changes))

(defun octocat-diff--note-button (count open)
  "Return the button of a file's COUNT conversations, calling OPEN."
  (octocat-vui--link (format "✉ %d" count) 'default open
                     (format "RET: show the first of %d unresolved conversation%s"
                             count (if (= count 1) "" "s"))))

(defun octocat-diff-use-link (repo ref files context at)
  "Open the file of FILES a link's AT names in the file viewer, at its lines.
FILES are those changed in REPO, nil while they load.  AT is as
`octocat-diff--at'; a link's, (diff HASH FROM TO), is opened once FILES
and REF, the new side, are in, see `octocat-diff--open-change' for
CONTEXT, then dropped, the page staying on its Tree.  Must be called
during render, like any hook."
  (let ((buf (current-buffer)))
    (vui-use-effect (at files ref)
      (when (and (eq (car-safe at) 'diff) files ref)
        (let ((file (seq-find (lambda (f) (octocat--diff-path-hash-p
                                           (nth 1 at) (or (gethash "filename" f) "")))
                              files)))
          (with-current-buffer buf
            (setq octocat-diff--at nil)
            (octocat-vui-update-page :at nil))
          (when file
            (octocat-diff--open-change repo ref file context at))))
      nil)))

(defun octocat-diff--tree-dirs (files)
  "Return the directories of FILES, the \"files\" changed, for the tree to open."
  (delete "" (delete-dups (mapcar (lambda (f) (octocat-tree--parent
                                               (or (gethash "filename" f) "")))
                                  files))))

(defun octocat-diff-views-heading (view width)
  "Return the pill of the views, VIEW filled in, at the right edge of WIDTH.
It ends a PR's tab row and the commit and comparison pages' top line."
  (octocat-vui-segmented-right (octocat-diff--view-segments view) width))

(defun octocat-diff--focus (at)
  "Return the path a switch of views kept, of AT, see `octocat-diff--at'."
  (pcase at (`(path ,path . ,_) path)))

(defun octocat-diff-tree (repo ref root files context at &optional notes)
  "Return the Tree view of FILES, the \"files\" changed in REPO.
That is the tree browser's tree at REF, the new side, its root tree
ROOT, opened down to FILES, marked as in the diff.  See
`octocat-diff--tree-changes' for CONTEXT and NOTES.  Point moves to the
path a switch of views kept, of AT, see `octocat-diff--at'."
  (vui-component 'octocat-diff--tree :repo repo :ref ref :root root :files files
                 :context context :notes notes :focus (octocat-diff--focus at)))

(vui-defcomponent octocat-diff--tree (repo ref root files context notes focus)
  "The Tree view, see `octocat-diff-tree'."
  :render
  (let ((changes (vui-use-memo (files context notes)
                   (octocat-diff--tree-changes repo ref files context notes)))
        (dirs    (vui-use-memo (files) (octocat-diff--tree-dirs files))))
    (if root
        (vui-component 'octocat-tree--subtree
          :key (list ref root)
          :repo repo :branch ref :sha root :commit nil
          :depth 0 :path "" :reveal dirs :focus focus :changes changes)
      (vui-text (octocat-tree--skeleton)))))

(vui-defcomponent octocat-diff-head-tree (repo head files context at notes)
  "The Tree view of FILES changed in REPO, at HEAD, a ref or commit.
For a page whose data lacks HEAD's root tree, which this looks up.
See `octocat-diff-tree' for CONTEXT, AT and NOTES."
  :render
  (let ((snap (octocat-vui-use-resource (list 'repo-head repo head nil) nil)))
    (octocat-diff-tree repo head
                       (octocat--get (octocat-model-head-dir (plist-get snap :data)) "oid")
                       files context at notes)))

(vui-defcomponent octocat-diff-file-view (repo path change commit lines)
  "The file viewer's Diff view of file PATH of REPO.
That is CHANGE, see `octocat-tree--file-change', or without it the
file's change in COMMIT, the last that touched it, nil while that is
looked up.  A line above says what changed it.  LINES, (FROM . TO) of
\(SIDE . LINE) as `octocat--url-lines' reads a link to a diff, are
highlighted in CHANGE and scrolled to."
  :render
  (let ((buf (current-buffer)))
    (vui-use-effect (lines)
      (when lines (octocat--goto-line-target buf))
      nil)
    (cond
     (change
      (vui-vstack
       (vui-text (plist-get change :label) :face 'octocat-dimmed)
       (octocat-diff--file repo (plist-get change :file) (octocat--markdown-width)
                           (and lines (list 'diff nil (car lines) (cdr lines)))
                           (plist-get change :revs))))
     (commit (vui-component 'octocat-diff--last-change :repo repo :path path :commit commit))
     (t (vui-text (octocat-tree--skeleton))))))

(vui-defcomponent octocat-diff--last-change (repo path commit)
  "The change to file PATH of REPO in COMMIT, its last, see `octocat-diff-file-view'."
  :render
  (let* ((snap   (octocat-vui-use-resource (list 'commit repo commit) nil))
         (data   (plist-get snap :data))
         (short  (substring commit 0 (min 7 (length commit))))
         (file   (and data (seq-find (lambda (f) (equal (gethash "filename" f) path))
                                     (gethash "files" data))))
         (parent (let ((parents (and data (gethash "parents" data))))
                   (and (> (length parents) 0) (gethash "sha" (aref parents 0))))))
    (octocat-vui-resource-view
     snap
     :skeleton (lambda (_) (vui-text (octocat-tree--skeleton)))
     :render
     (lambda (_)
       (if file
           (vui-vstack
            (vui-text (format "Changes in its last commit, %s" short) :face 'octocat-dimmed)
            (octocat-diff--file repo file (octocat--markdown-width) nil (cons parent commit)))
         ;; A merge's files are those of its first parent's side.
         (vui-text (format "Not among the files GitHub lists for its last commit, %s" short)
           :face 'octocat-dimmed))))))


;;;; Commit page
;;
;; Commit data fetching and the `octocat-commit-mode' page, rendered with
;; vui.el like the issue and PR pages.  The commit, its check-runs and its
;; comments are three sync resources, each painted from the store and
;; refetched behind it; the commit itself never changes, so it is kept.

;;;;; Buffer-local declarations

(defvar-local octocat--commit-repo nil
  "The \"owner/repo\" this commit buffer belongs to.")

(defvar-local octocat--commit-sha nil
  "The full commit SHA this buffer is displaying.")



;;;;; Sections
;;
;; Each returns the vnodes of one part of the page.  The files reuse the
;; PR diff's file component: commit comments have the same shape as PR
;; review comments.

(defun octocat-commit--top-line (repo sha view width)
  "Return the top line of commit SHA of REPO, as the tree browser's.
That is owner/repo@SHA, then the tabs of the views, VIEW the one
shown, see `octocat-diff-views-heading'; the Tree view browses the
files at it.  SHA is cut to keep the line within WIDTH columns, ElDoc
showing it whole."
  (let ((tabs (mapconcat (lambda (v) (format " %s " (capitalize (symbol-name v))))
                         octocat-diff--views "")))
    (vui-hstack :spacing 0
                (octocat-vui-repo-heading repo)
                (vui-text (concat "@" (octocat-vui--fit
                                       sha (- width (string-width repo) 1 2
                                              (string-width tabs))))
                  :face 'octocat-commit-sha)
                (octocat-diff-views-heading view width))))

(defun octocat-commit--person (commit role)
  "Return who COMMIT's ROLE is, as `git show' prints it, as nodes.
ROLE is \"author\" or \"committer\".  That is Name <email>, then the
GitHub account linked to it, @login, opening its page."
  (let* ((c     (gethash "commit" commit))
         (who   (and c (gethash role c)))
         (name  (and (hash-table-p who) (octocat--nonempty (gethash "name" who))))
         (email (and (hash-table-p who) (octocat--nonempty (gethash "email" who))))
         (user  (gethash role commit))
         (login (and (hash-table-p user) (octocat--nonempty (gethash "login" user)))))
    (delq nil
          (list (vui-text (string-join (delq nil (list name (and email (format "<%s>" email))))
                                       " ")
                  :face 'octocat-pr-author)
                (and login (vui-text " "))
                (and login (octocat-vui--login-link login))))))

(defun octocat-commit--date (commit role)
  "Return the date of COMMIT's ROLE as `git show' prints it, then its age.
ROLE is as for `octocat-commit--person'.  Nil when it has none."
  (let* ((c   (gethash "commit" commit))
         (who (and c (gethash role c)))
         (ts  (and (hash-table-p who) (octocat--nonempty (gethash "date" who)))))
    (and ts
         (concat (format-time-string "%a %b %-d %H:%M:%S %Y %z" (date-to-time ts))
                 "  "
                 (propertize (concat "(" (octocat--format-ts-relative ts) ")")
                             'face 'octocat-dimmed)))))

(defun octocat-commit--field (label nodes)
  "Return a field row of the commit header: LABEL, dimmed, then NODES.
LABEL is padded as `git show --format=fuller' pads them.  NODES are
strings or vnodes; nil when there are none."
  (when nodes
    (apply #'vui-hstack :spacing 0
           (vui-text (format "%-12s" (concat label ":")) :face 'octocat-dimmed)
           (mapcar (lambda (n) (if (stringp n) (vui-text n) n)) nodes))))

(defun octocat-commit--fields (repo commit branch)
  "Return the rows naming COMMIT of REPO, as `git show --format=fuller'.
Its author and committer, with their dates, then its parents and, from
BRANCH, the `commit-branch' snapshot, the default branch when it holds
the commit.  Each parent and the branch open their page."
  (let ((parents (append (gethash "parents" commit) nil))
        (holder  (octocat--nonempty (octocat-model-commit-holder (plist-get branch :data)))))
    (delq nil
          (list
           (octocat-commit--field "Author" (octocat-commit--person commit "author"))
           (octocat-commit--field "AuthorDate"
                                  (delq nil (list (octocat-commit--date commit "author"))))
           (octocat-commit--field "Commit" (octocat-commit--person commit "committer"))
           (octocat-commit--field "CommitDate"
                                  (delq nil (list (octocat-commit--date commit "committer"))))
           (octocat-commit--field
            (if (cdr parents) "Parents" "Parent")
            (cdr (mapcan (lambda (p)
                           (let ((sha (or (gethash "sha" p) "")))
                             (list " "
                                   (octocat-vui--link
                                    (substring sha 0 (min 7 (length sha))) 'octocat-commit-sha
                                    (lambda () (octocat-commit-open repo sha))
                                    "RET: view parent commit"))))
                         parents)))
           ;; Grey bars while it loads, so the message below holds still.
           (pcase (octocat-vui-snapshot-status branch)
             ('pending (octocat-commit--field "Branch" (list (octocat-vui-skeleton '((8))))))
             ('ready
              (and holder
                   (octocat-commit--field
                    "Branch"
                    (list (octocat-vui--link
                           holder 'octocat-branch
                           (lambda () (octocat-open 'tree repo holder))
                           (format "RET: browse %s, which holds this commit" holder)))))))))))

(defun octocat-commit--skeleton (width)
  "Return grey bars shaped like a commit page below its top line, cut to WIDTH.
Shown when there is neither a cache nor a response yet: the author and
committer rows, the message, then a few changed files."
  (octocat-vui-skeleton '((12 40) (12 30) (12 40) (12 30) nil ("    " 44) nil ("  " 40) ("  " 28))
                        width))

(defun octocat-commit--message (commit)
  "Return COMMIT's message, its subject bold, unindented so it copies as is.
Shown verbatim, not as markdown: git messages are plain text, wrapped
by their author.  A long one is folded as an opening post is (see
`octocat-timeline-body-lines')."
  (let* ((c     (gethash "commit" commit))
         (lines (split-string (string-trim-right (or (and c (gethash "message" c)) "")) "\n"))
         (text  (string-join (cons (propertize (car lines) 'face 'bold) (cdr lines)) "\n")))
    (octocat-vui-fold-lines text (octocat-vui-line-ends text)
                            octocat-timeline-body-lines 'message-fold "")))

(defun octocat-commit--async-status (snap empty &optional items)
  "Return a dimmed vnode for the sync snapshot SNAP if failed or empty, else nil.
EMPTY is the text shown when it is ready but has no ITEMS, by default
its data.  Grey bars while it is pending."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28)))))
    ('error   (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'octocat-dimmed))
    (_ (and (seq-empty-p (or items (plist-get snap :data)))
            (vui-text (concat "  " empty) :face 'octocat-dimmed)))))

(defun octocat-commit--heading (label snap width &optional items)
  "Return the section heading LABEL, with the count of SNAP's data once known.
ITEMS, by default its data, are what is counted.  It is underlined
across WIDTH columns."
  (octocat-vui-section-heading (if (plist-get snap :data)
                                   (format "%s (%d)" label
                                           (length (or items (plist-get snap :data))))
                                 label)
                               width))

(defun octocat-commit--checks (repo sha checks width)
  "Return the CI section of commit SHA of REPO, or nil when it has none.
Its check-runs are in CHECKS, a sync snapshot.  Its heading is
underlined across WIDTH columns."
  (let ((runs (octocat-model-check-list (plist-get checks :data))))
    (unless (and (plist-get checks :data) (seq-empty-p runs))
      (or (and (eq (octocat-vui-snapshot-status checks) 'pending)
               (octocat-commit--heading "Checks" checks width runs))
          (when-let* ((status (octocat-commit--async-status checks "(no checks)" runs)))
            (vui-vstack (octocat-commit--heading "Checks" checks width runs) status))
          (apply #'vui-vstack
                 (octocat-checks-block runs (lambda () (octocat-checks-open repo sha nil))
                                       width))))))


;;;;; Patch

(defun octocat-commit--patch-text (commit)
  "Return COMMIT as `git format-patch' writes it, as GitHub's .patch.
Its header, message, then each file's diff, see
`octocat-diff--patch-file'.  Not indented, so it copies out as a patch
`git am' applies."
  (let* ((c       (gethash "commit" commit))
         (author  (and (hash-table-p c) (gethash "author" c)))
         (get     (lambda (k) (or (and (hash-table-p author)
                                       (octocat--nonempty (gethash k author)))
                                  "")))
         (date    (funcall get "date"))
         (lines   (split-string (string-trim-right (or (and c (gethash "message" c)) "")) "\n"))
         (body    (string-trim (string-join (cdr lines) "\n"))))
    (concat
     (propertize
      (concat (format "From %s Mon Sep 17 00:00:00 2001\n" (or (gethash "sha" commit) ""))
              (format "From: %s <%s>\n" (funcall get "name") (funcall get "email"))
              (format "Date: %s\n"
                      (if (string-empty-p date) ""
                        (format-time-string "%a, %d %b %Y %H:%M:%S %z" (date-to-time date) t))))
      'face 'octocat-dimmed)
     (propertize (concat "Subject: [PATCH] " (car lines)) 'face 'bold)
     "\n\n"
     (if (string-empty-p body) "" (concat body "\n"))
     "---\n\n"
     (mapconcat #'octocat-diff--patch-file (gethash "files" commit) "\n"))))



;;;;; Page

(vui-defcomponent octocat-commit--page (repo sha raw view at tick)
  "Commit SHA of REPO: top line, then as `git show': who and when, the
message, then checks, files and comments.  RAW shows markdown verbatim.
VIEW, of `octocat-diff--views', `tree' shows the repository's files at
the commit, those it changed marked, see `octocat-diff-tree'; `patch'
the commit as a patch, see `octocat-commit--patch-text'.  AT is as
`octocat-diff--at'; a link's lines open in the file viewer, see
`octocat-diff-use-link'.  The commit, its checks, its comments and the
branch holding it are fetched independently; each shows what the store
holds until then.  A new TICK fetches them again."
  :render
  (let* ((_        (octocat-diff-use-at-reset))
         (width    (octocat-vui-window-width))
         (commit   (octocat-vui-use-resource (list 'commit repo sha) tick))
         (checks   (octocat-vui-use-resource (list 'checks repo sha) tick))
         (comments (octocat-vui-use-resource (list 'commit-comments repo sha) tick))
         (branch   (octocat-vui-use-resource (list 'commit-branch repo sha) tick))
         (data     (plist-get commit :data))
         (md-width (progn width (octocat--markdown-width)))
         (message  (vui-use-memo (data)
                     (and data (octocat-commit--message data))))
         (text     (vui-use-memo (data view)
                     (and data (eq view 'patch) (octocat-commit--patch-text data))))
         (parent   (let ((parents (and data (gethash "parents" data))))
                     (and (> (length parents) 0) (gethash "sha" (aref parents 0)))))
         (revs     (cons parent (and data (gethash "sha" data))))
         (context  (and data
                        (list :revs revs
                              :label (format "Changes in commit %s"
                                             (substring (gethash "sha" data) 0 7))))))
    (octocat-diff-use-link repo (and data (gethash "sha" data))
                           (and data (or (gethash "files" data) [])) context at)
    (octocat-vui-page
     (octocat-vui-commit-pin repo (or (and data (gethash "sha" data)) sha)
                             (octocat-vui-segmented-pin (octocat-diff--view-segments view)))
     (vui-vstack
      (octocat-commit--top-line repo (or (and data (gethash "sha" data)) sha) view width)
      (octocat-vui-resource-view
       commit
       :skeleton (lambda (_) (vui-text (octocat-commit--skeleton width)))
       :render
       (lambda (_)
         (cond
          (text (vui-text text))
          (t
           (apply
            #'vui-vstack
            (append
             (octocat-commit--fields repo data branch)
             (delq nil
                   (list (vui-newline)
                         message
                         (vui-newline)
                         (when-let* ((section (octocat-commit--checks repo sha checks width)))
                           (vui-fragment section (vui-newline)))
                         (octocat-diff-tree
                          repo (gethash "sha" data)
                          (octocat--get data "commit" "tree" "sha")
                          (or (gethash "files" data) [])
                          context at)
                         ;; Most commits have none, so the section is left
                         ;; out unless there are any, or they failed to load.
                         (when (or (not (seq-empty-p (plist-get comments :data)))
                                   (eq (octocat-vui-snapshot-status comments) 'error))
                           (vui-fragment
                            (vui-newline)
                            (octocat-diff-comments-section
                             "Comments" comments raw md-width)))))))))))))))


;;;;; Major mode

(defun octocat-commit--page-url ()
  "Return the URL of this commit."
  (and octocat--commit-repo octocat--commit-sha
       (octocat--web-url "%s/commit/%s" octocat--commit-repo octocat--commit-sha)))

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-v") #'octocat-diff-cycle-view)
    map)
  "Keymap for `octocat-commit-mode'.")

(define-derived-mode octocat-commit-mode octocat-page-mode "Octocat-Commit"
  "Major mode for viewing a GitHub commit.

\\{octocat-commit-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-commit-refresh)
  (setq-local octocat--url-function #'octocat-commit--page-url)
  (setq-local octocat-diff--view 'tree)
  (setq-local octocat--repo-function (lambda () octocat--commit-repo)))


;;;;; Refresh

(defun octocat-commit-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commit buffer.
The page paints from the sync store at once and fetches the commit's
checks and comments in the background, in place; the commit itself
only on `g'."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (octocat-vui-refresh-page 'octocat-commit--page
                            (cons octocat--commit-repo octocat--commit-sha)
                            (list :repo octocat--commit-repo
                                  :sha octocat--commit-sha
                                  :raw octocat--markdown-raw
                                  :view octocat-diff--view
                                  :at octocat-diff--at)))

(defun octocat-commit-open (repo sha &optional at)
  "Show commit SHA of REPO in its own buffer, on its Tree.
AT, the lines a link named, opens them in the file viewer, see
`octocat-diff-use-link'."
  (let ((buf (get-buffer-create
              (format "*%s commit %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-commit-mode)
      (octocat-commit-mode))
    (setq octocat--commit-repo repo
          octocat--commit-sha  sha
          octocat-diff--at at
          octocat-diff--view 'tree)
    (octocat-commit-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'commit)) repo sha &optional at)
  "Open commit SHA of REPO, AT the lines a link named, as `octocat-commit-open'."
  (apply #'octocat-commit-open repo sha (and at (list at))))


;;;; Compare page
;;
;; What github.com/OWNER/REPO/compare/BASE...HEAD shows, the commits
;; between two refs, oldest first, then the changed files as on the
;; commit page.  One `gh api' call fetches it all.
;;
;; GitHub's API compares from the merge base only (BASE...HEAD); it has
;; no two-dot BASE..HEAD.  The two agree whenever BASE is an ancestor of
;; HEAD, the usual case, so a two-dot link is shown as three-dot, with a
;; note when they differ.

;;;;; Buffer-local declarations

(defvar-local octocat--compare-repo nil
  "The \"owner/repo\" this compare buffer belongs to.")

(defvar-local octocat--compare-refs nil
  "The (BASE DOTS HEAD) this buffer compares; DOTS is \"..\" or \"...\".")


;;;;; Sections

(defun octocat-compare--counts (data)
  "Return the count of commits and files of the comparison DATA, for its top row."
  (let ((total  (or (gethash "total_commits" data) 0))
        (files  (length (gethash "files" data)))
        (behind (or (gethash "behind_by" data) 0))
        (plural (lambda (n word) (format "%d %s%s" n word (if (= n 1) "" "s")))))
    (if (equal (gethash "status" data) "identical")
        "identical"
      (string-join
       (delq nil (list (funcall plural total "commit")
                       (concat (funcall plural files "file") " changed")
                       (and (> behind 0) (format "%d behind" behind))))
       " · "))))

(defun octocat-compare--summary (data dots)
  "Return the dimmed notes on the comparison DATA, under its top row.
DOTS is as in `octocat--compare-refs': a two-dot comparison of refs that
have diverged gets a note that the three-dot one is shown."
  (let ((total  (or (gethash "total_commits" data) 0))
        (shown  (length (gethash "commits" data)))
        (files  (length (gethash "files" data)))
        (behind (or (gethash "behind_by" data) 0)))
    (delq nil
          (list
           (and (equal dots "..") (> behind 0)
                "Compared from the merge base (...): GitHub's API has no two-dot compare")
           (and (< shown total)
                (format "%d of the %d commits listed, as GitHub's API returns at most %d"
                        shown total shown))
           ;; GitHub returns at most 300 files and doesn't say how many more.
           (and (>= files 300) "GitHub's API lists at most 300 changed files")))))

(defun octocat-compare--commits (repo commits width)
  "Return the vnodes of the Commits section, fitted to WIDTH.
COMMITS is a vector of commits of REPO, as the commit rows read them."
  (let* ((commits   (append commits nil))
         (author-w  (octocat-vui--author-width commits))
         (subject-w (octocat-vui--subject-width commits width author-w))
         (date-w    (octocat-vui--date-width commits)))
    (and commits
         (append (list (octocat-vui-section-heading
                        (format "Commits (%d)" (length commits)) width))
                 (mapcar (lambda (c)
                           (octocat-vui--commit-row repo c nil author-w subject-w date-w))
                         commits)
                 (list (vui-newline))))))

(defun octocat-compare--ref-label (ref)
  "Return REF for the top row: a SHA cut to 7 chars, whole on hover.
Two full SHAs would push the counts onto another line."
  (if (and (octocat--sha-p ref) (> (length ref) 7))
      (propertize (substring ref 0 7) 'face 'octocat-branch 'help-echo ref)
    (propertize ref 'face 'octocat-branch)))

(defun octocat-compare--top-row (repo base dots head data view width)
  "Return the top row of the comparison of BASE and HEAD of REPO.
That is `owner/repo BASE...HEAD', as the commit page's `owner/repo@sha',
then the counts of DATA, the comparison, once it is loaded, and the
tabs of the views, VIEW the one shown, at the right edge of WIDTH, see
`octocat-diff-views-heading'."
  (vui-hstack :spacing 0
              (octocat-vui-repo-heading repo)
              (vui-text (concat "  "
                                (octocat-compare--ref-label base)
                                (propertize dots 'face 'octocat-dimmed)
                                (octocat-compare--ref-label head)
                                (and data
                                     (propertize (concat " · " (octocat-compare--counts data))
                                                 'face 'octocat-dimmed))))
              (octocat-diff-views-heading view width)))


;;;;; Page

(vui-defcomponent octocat-compare--page (repo base dots head view at tick)
  "The comparison of BASE and HEAD of REPO: its commits, then its files.
DOTS is as in `octocat--compare-refs'.  VIEW, of `octocat-diff--views',
`tree' shows the repository's files at HEAD, those changed marked, see
`octocat-diff-head-tree'; `patch' every file's diff, see
`octocat-diff-patch-text'.  AT is as `octocat-diff--at'; a link's lines
open in the file viewer, see `octocat-diff-use-link'.  A new TICK
fetches it again."
  :render
  (let* ((_        (octocat-diff-use-at-reset))
         (width    (octocat--markdown-width))
         (snap     (octocat-vui-use-resource (list 'compare repo base head) tick))
         (data     (plist-get snap :data))
         (text     (vui-use-memo (data view)
                     (and data (eq view 'patch)
                          (octocat-diff-patch-text (or (gethash "files" data) [])))))
         (revs     (cons (octocat--get data "merge_base_commit" "sha") head))
         (context  (list :revs revs
                         :label (format "Changes in %s%s%s" base dots head))))
    (octocat-diff-use-link repo head (and data (or (gethash "files" data) [])) context at)
    (octocat-vui-page
     (octocat-vui-pin (propertize repo 'face 'octocat-repo)
                      (concat (octocat-compare--ref-label base)
                              (propertize dots 'face 'octocat-dimmed)
                              (octocat-compare--ref-label head))
                      (octocat-vui-segmented-pin (octocat-diff--view-segments view)))
     (vui-vstack
      (octocat-compare--top-row repo base dots head data view (octocat-vui-window-width))
      (octocat-vui-resource-view
       snap
       :skeleton (lambda (_)
                   (vui-text (octocat-vui-skeleton
                              '(nil (26) ("  " 7 "  " 40) ("  " 7 "  " 34) nil
                                    (12) ("  " 40) ("  " 28))
                              (octocat-vui-window-width))))
       :render
       (lambda (data)
         (let ((files (or (gethash "files" data) [])))
           (if text
               (vui-text text)
             (apply #'vui-vstack
                    (append
                     (mapcar (lambda (line) (vui-text line :face 'octocat-dimmed))
                             (octocat-compare--summary data dots))
                     (list (vui-newline))
                     (octocat-compare--commits repo (or (gethash "commits" data) []) width)
                     (list (vui-component 'octocat-diff-head-tree
                             :repo repo :head head :files files :context context
                             :at at))))))))))))


;;;;; Major mode

(defun octocat-compare--url (repo refs)
  "Return the web page comparing REFS, as `octocat--compare-refs', of REPO."
  (octocat--web-url "%s/compare/%s" repo (apply #'concat refs)))

(defun octocat-compare--page-url ()
  "Return the URL of this comparison."
  (and octocat--compare-repo octocat--compare-refs
       (octocat-compare--url octocat--compare-repo octocat--compare-refs)))

(defvar octocat-compare-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-v") #'octocat-diff-cycle-view)
    map)
  "Keymap for `octocat-compare-mode'.")

(define-derived-mode octocat-compare-mode octocat-page-mode "Octocat-Compare"
  "Major mode for viewing the comparison of two refs of a GitHub repository.

\\{octocat-compare-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-compare-refresh)
  (setq-local octocat--url-function #'octocat-compare--page-url)
  (setq-local octocat-diff--view 'tree)
  (setq-local octocat--repo-function (lambda () octocat--compare-repo)))


;;;;; Refresh

(defun octocat-compare-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current compare buffer."
  (interactive)
  (unless (and octocat--compare-repo octocat--compare-refs)
    (user-error "Octocat: Buffer is not associated with a comparison"))
  (pcase-let ((`(,base ,dots ,head) octocat--compare-refs))
    (octocat-vui-refresh-page 'octocat-compare--page
                              (list octocat--compare-repo base head)
                              (list :repo octocat--compare-repo
                                    :base base :dots dots :head head
                                    :view octocat-diff--view
                                    :at octocat-diff--at))))

(defun octocat-compare-open (repo base dots head &optional at)
  "Show the comparison of BASE and HEAD of REPO in its own buffer.
DOTS is \"...\", or \"..\" for a two-dot link (see the Commentary).
AT, the lines a link named, opens them in the file viewer, see
`octocat-diff-use-link'."
  (let ((buf (get-buffer-create (format "*%s compare %s%s%s*" repo base dots head))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-compare-mode)
      (octocat-compare-mode))
    (setq octocat--compare-repo repo
          octocat--compare-refs (list base dots head)
          octocat-diff--at at
          octocat-diff--view 'tree)
    (octocat-compare-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'compare)) repo base dots head &optional at)
  "Open the comparison of BASE DOTS HEAD in REPO, AT the lines a link named.
See `octocat-compare-open'."
  (apply #'octocat-compare-open repo base dots head (and at (list at))))

(provide 'octocat-diff)
;;; octocat-diff.el ends here
