;;; octocat-diff.el --- Diff rendering for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5
;; Assisted-by: Claude:claude-opus-5-5

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

;; The changed files of a diff page, shared by the commit page
;; (octocat-commit.el) and the PR diff page (octocat-pr-diff.el): a fold
;; per file, its patch in the diff faces, with the inline comments boxed
;; after the lines they are on.  The files start folded unless the whole
;; diff fits in the window.  Commit comments and PR review comments have
;; the same shape, so both pass theirs in.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff-mode) ; The diff faces.
(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)


;;;; Faces

(defface octocat-commit-file-modified
  '((t :inherit default))
  "Face for the letter of a modified file in a diff."
  :group 'octocat)

(defface octocat-commit-file-added
  '((t :inherit success))
  "Face for the letter of an added file in a diff."
  :group 'octocat)

(defface octocat-commit-file-removed
  '((t :inherit error))
  "Face for the letter of a removed file in a diff."
  :group 'octocat)

(defface octocat-commit-file-renamed
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


;;;; File status

(defun octocat-diff--file-icon (status)
  "Return a one-char icon string for STATUS."
  (cond ((equal status "added")    (propertize "A" 'face 'octocat-commit-file-added))
        ((equal status "removed")  (propertize "D" 'face 'octocat-commit-file-removed))
        ((equal status "renamed")  (propertize "R" 'face 'octocat-commit-file-renamed))
        (t                         (propertize "M" 'face 'octocat-commit-file-modified))))

;;;; Patch text
;;
;; The patch of a file is built as one string: the diff lines in the diff
;; faces, each inline review comment boxed right after the line it is on.

(defun octocat-diff--comment-lines (comment raw width)
  "Return the lines of the boxed inline review COMMENT, without newlines.
Its body is markdown, rendered unless RAW, to fit WIDTH columns."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user)
                          (octocat--nonempty (gethash "login" user)))
                     ""))
         (author (if (string-empty-p login) "(unknown)" (concat "@" login)))
         (body   (string-trim (or (gethash "body" comment) "")))
         (date   (octocat--format-ts-relative
                  (or (octocat--nonempty (gethash "created_at" comment)) "")))
         (reactions (octocat--reactions-string comment))
         (bar    (propertize "  │ " 'face 'octocat-dimmed)))
    (append
     (list (concat (propertize "  ┌─ " 'face 'octocat-dimmed)
                   (propertize author 'face 'octocat-pr-author)
                   (propertize (concat "  " date) 'face 'octocat-dimmed)
                   (if reactions (concat "  " reactions) "")))
     (if (string-empty-p body)
         (list (concat bar (propertize "(empty)" 'face 'octocat-dimmed)))
       (list (string-remove-suffix
              "\n" (octocat--markdown-string body bar raw width))))
     (list (propertize "  └─" 'face 'octocat-dimmed)))))

(defun octocat-diff--index (comments)
  "Index the review COMMENTS of one file for `octocat-diff--patch-text'.
Returns (BY-LINE . BY-POS): alists mapping a right-side line number, and
for older comments that have no line a diff position, to the list of
comments there, in order."
  (let (by-line by-pos)
    (dolist (c comments)
      (let ((line (let ((v (gethash "line" c))) (and (integerp v) v)))
            (pos  (let ((v (gethash "position" c))) (and (integerp v) v))))
        (cond (line (push c (alist-get line by-line)))
              (pos  (push c (alist-get pos by-pos))))))
    (cons (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-line)
          (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-pos))))

(defun octocat-diff--walk (patch index fn)
  "Call FN with each line of the unified diff PATCH and the comments after it.
INDEX is the comment index of the file, see `octocat-diff--index'.  FN
gets the line and the list of comments placed right after it, found by
tracking the right-side line number, from the `@@' headers, and the
1-based position in the diff.  A comment on no line of PATCH, as an
outdated one, is placed nowhere."
  (let ((by-line (car index))
        (by-pos  (cdr index))
        (right 0)
        (pos   0))
    (cl-flet ((at (key table) (cdr (assq key table))))
      (dolist (raw (octocat-diff--split patch))
        (cl-incf pos)
        (pcase (octocat-diff--line-kind raw)
          ('hunk
           (when (string-match "@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw)
             (setq right (string-to-number (match-string 1 raw))))
           (funcall fn raw (at pos by-pos)))
          ;; Only in the old file, or in neither, so the right line stays.
          ((or 'removed 'note)
           (funcall fn raw (at pos by-pos)))
          (_
           (funcall fn raw (append (at right by-line) (at pos by-pos)))
           (cl-incf right)))))))

(defun octocat-diff--placed-count (patch comments)
  "Return how many of COMMENTS, on the file of PATCH, are placed in its diff."
  (let ((n 0))
    (octocat-diff--walk patch (octocat-diff--index comments)
                        (lambda (_line placed) (cl-incf n (length placed))))
    n))

(defun octocat-diff--patch-text (patch path index raw width)
  "Return the unified diff PATCH as a propertized string, without final newline.
PATH is the file's, whose major mode highlights the code, see
`octocat-diff--lines'.  INDEX is the comment index of the file, see
`octocat-diff--index'.  RAW and WIDTH are as for
`octocat-diff--comment-lines'.  Each comment is placed right after the
diff line it is on, see `octocat-diff--walk'.  A line is cut at
`octocat--max-line-length', see `octocat--clip-line'."
  (let ((lines (octocat-diff--lines patch path))
        out)
    ;; Diff lines are not indented, so they copy out as a valid patch.
    (octocat-diff--walk
     patch index
     (lambda (_line placed)
       (push (octocat--clip-line (pop lines) octocat--max-line-length) out)
       (dolist (c placed)
         (dolist (l (octocat-diff--comment-lines c raw width))
           (push l out)))))
    (mapconcat #'identity (nreverse out) "\n")))


;;;; Highlighting
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

(defun octocat-diff--faces-only (text)
  "Return TEXT with no property but its faces, `font-lock-face' as `face'."
  (let ((pos 0) (end (length text)) (face-next 0) (flf-next 0) out)
    (while (< pos end)
      ;; Each next change is looked for only once passed: looking from
      ;; every position for a property not there would scan to the end.
      (when (<= face-next pos)
        (setq face-next (next-single-property-change pos 'face text end)))
      (when (<= flf-next pos)
        (setq flf-next (next-single-property-change pos 'font-lock-face text end)))
      (let ((next (min face-next flf-next))
            (face (or (get-text-property pos 'face text)
                      (get-text-property pos 'font-lock-face text))))
        (push (if face
                  (propertize (substring-no-properties text pos next) 'face face)
                (substring-no-properties text pos next))
              out)
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun octocat-diff--fontify (path texts)
  "Return the lines of each of TEXTS, highlighted as PATH's major mode would.
Return nil when PATH's mode, if any, does not highlight.  The mode is
set up once, with its hooks delayed, as for a file being visited."
  (with-temp-buffer
    (with-demoted-errors "Octocat: cannot highlight: %S"
      (let ((buffer-file-name path))
        (delay-mode-hooks (set-auto-mode))))
    (when (font-lock-specified-p major-mode)
      (mapcar (lambda (text)
                (erase-buffer)
                (insert text)
                ;; A mode's broken font-lock rules should not lose the text.
                (with-demoted-errors "Octocat: cannot highlight: %S"
                  (font-lock-ensure))
                (split-string (octocat-diff--faces-only (buffer-string)) "\n"))
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


;;;; Components

(defun octocat-diff--file (file comments bulk raw width)
  "Return one changed FILE (a files-endpoint hash-table) with its inline COMMENTS.
It is folded unless BULK, as for `octocat-vui-fold', says otherwise; a
file without a patch is just its heading, which says why when the file
changed: it is binary, or too large for GitHub to show.  RAW and WIDTH
are as for `octocat-diff--comment-lines'."
  (let* ((filename (or (gethash "filename" file) ""))
         (status   (or (gethash "status" file) "modified"))
         (patch    (let ((p (gethash "patch" file)))
                     (and (stringp p) (not (string-empty-p p)) p)))
         (title    (concat (octocat-diff--file-icon status)
                           " "
                           (propertize filename 'face 'octocat-diff-file-name)
                           (propertize (format "  +%d -%d"
                                               (or (gethash "additions" file) 0)
                                               (or (gethash "deletions" file) 0))
                                       'face 'octocat-dimmed))))
    (if (null patch)
        (vui-text (concat "  " title
                          ;; Not a rename alone, which has no diff.
                          (unless (and (equal status "renamed")
                                       (eql (gethash "changes" file) 0))
                            (propertize "  binary, or too large to show"
                                        'face 'octocat-dimmed))))
      (vui-component 'octocat-vui-fold
        :key (intern filename)
        :bulk bulk
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show diff" . "RET: hide diff")))
        :deps (list patch comments raw width)
        :prepare (lambda ()
                   (octocat-vui-text-body
                    (octocat-diff--patch-text
                     patch filename (octocat-diff--index comments) raw width)))))))

(defun octocat-diff--line-count (files)
  "Return how many lines FILES take with every patch shown."
  (cl-loop for f across files
           sum (let ((p (gethash "patch" f)))
                 (1+ (if (stringp p) (1+ (cl-count ?\n p)) 0)))))

(defun octocat-diff-by-path (comments)
  "Return an alist mapping a file path to the review COMMENTS made on it."
  (let (table)
    (seq-doseq (c comments)
      (when-let* ((path (octocat--nonempty (gethash "path" c))))
        (push c (alist-get path table nil nil #'equal))))
    (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) table)))

(defvar-local octocat-diff--hide-comments nil
  "Non-nil leaves the inline comments out of this page's diff.
Opening the page shows them again.")

(defun octocat-diff-toggle-comments ()
  "Show or hide the inline comments in the diff of this page."
  (interactive)
  (setq octocat-diff--hide-comments (not octocat-diff--hide-comments))
  (octocat-vui-update-page :hide-comments octocat-diff--hide-comments))

(vui-defcomponent octocat-diff--files (files by-path hide fits raw width underline)
  "The Files section: FILES with the review comments BY-PATH, folded.
They start unfolded when FITS, the whole diff fitting in the window.
HIDE leaves the comments out.  RAW and WIDTH are as for
`octocat-diff--comment-lines'; UNDERLINE underlines the heading across
WIDTH, but for a page whose tab row heads the section.  The heading's \"Expand all\" button
unfolds or folds every file, and its \"Show comments (N)\" button, there
when the diff shows some comment, runs `octocat-diff-toggle-comments'."
  :state ((bulk (and fits (cons 0 t))))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback () (vui-set-state :bulk (and fits (cons 0 t))))))
         (heading (format "Files (%d)" (length files)))
         ;; Only those the diff places: an outdated comment's line is gone.
         (placed  (vui-use-memo (files by-path)
                    (cl-loop for f across files
                             for patch = (gethash "patch" f)
                             for comments = (cdr (assoc (gethash "filename" f) by-path))
                             when (and comments (stringp patch))
                             sum (octocat-diff--placed-count patch comments)))))
    (vui-vstack
     (let ((after (and (cl-some (lambda (f) (stringp (gethash "patch" f))) files)
                       (cons (octocat-vui-expand-all-button
                              bulk (vui-async-callback (v) (vui-set-state :bulk v)))
                             (and (> placed 0)
                                  (list (vui-button (format "%s comments (%d)"
                                                            (if hide "Show" "Hide") placed)
                                          :face 'octocat-dimmed
                                          :key 'hide-comments
                                          :help-echo (octocat--key-help
                                                      #'octocat-diff-toggle-comments
                                                      (if hide
                                                          "show the comments in the diff"
                                                        "hide the comments in the diff"))
                                          :on-click #'octocat-diff-toggle-comments)))))))
       (if underline
           (apply #'octocat-vui-section-heading heading width after)
         (apply #'vui-hstack :spacing 2
                (vui-text heading :face 'octocat-section-heading) after)))
     (if (zerop (length files))
         (vui-text "  (no files changed)" :face 'octocat-dimmed)
       (vui-list (append files nil)
                 (lambda (f)
                   (octocat-diff--file f (and (not hide)
                                              (cdr (assoc (gethash "filename" f) by-path)))
                                       bulk raw width))
                 (lambda (f) (gethash "filename" f)))))))

(defun octocat-diff-files-section (files by-path hide raw width &optional underline)
  "Return the vnode of the Files section: the heading and one entry per file.
FILES is the files vector and BY-PATH the review comments by file path,
left out when HIDE.
Files start folded, unless the whole diff fits in the window.  The
comments are markdown, rendered unless RAW, to fit WIDTH columns.
UNDERLINE underlines the heading across WIDTH."
  (vui-component 'octocat-diff--files
    :files files
    :by-path by-path
    :hide hide
    :raw raw
    :width width
    :underline underline
    :fits (<= (octocat-diff--line-count files) (octocat-vui-window-height))))

(defun octocat-diff-comments-section (label comments raw width)
  "Return the vnode of the comments section headed LABEL, e.g. \"Comments\".
COMMENTS is the sync snapshot of the comments.  Inline ones are in the
diff, so only counted here; the others are boxed like them.  RAW and
WIDTH are as for `octocat-diff--comment-lines'; the heading is underlined
across WIDTH."
  (let* ((status  (octocat-vui-snapshot-status comments))
         (all     (plist-get comments :data))
         (general (seq-remove (lambda (c) (octocat--nonempty (gethash "path" c))) all))
         (inline  (- (length all) (length general)))
         (noun    (downcase (string-remove-suffix "s" label))))
    (apply #'vui-vstack
           (octocat-vui-section-heading (if (eq status 'ready)
                                            (format "%s (%d)" label (length all))
                                          label)
                                        width)
           (pcase status
             ('pending (list (vui-text (octocat-vui-skeleton '(("  " 36))))))
             ('error   (list (vui-text (concat "  " (octocat-vui-error-text comments))
                               :face 'octocat-dimmed)))
             (_ (if (seq-empty-p all)
                    (list (vui-text (format "  (no %ss)" noun) :face 'octocat-dimmed))
                  (append
                   (and (> inline 0)
                        (list (vui-text (format "  (%d inline %s%s, in the diff above)"
                                                inline noun (if (= inline 1) "" "s"))
                                :face 'octocat-dimmed)))
                   (mapcar (lambda (c)
                             (vui-text (string-join (octocat-diff--comment-lines c raw width)
                                                    "\n")))
                           general))))))))

(provide 'octocat-diff)
;;; octocat-diff.el ends here
