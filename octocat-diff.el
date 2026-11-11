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
;; (octocat-pr.el): a fold per file, its patch in the diff faces, with
;; the inline comments boxed after the lines they are on.  The files
;; start folded unless the whole diff fits in the window.  Commit
;; comments and PR review comments have the same shape, so both pages
;; pass theirs in.  Must not depend on octocat.el or octocat-pr.el, to
;; avoid circular requires.

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

(defface octocat-review-mark
  '((((background dark)) :background "#4a4420" :extend t)
    (t :background "#fff5b1" :extend t))
  "Face for the diff lines a comment being written is on."
  :group 'octocat)


;;;;; File status

(defun octocat-diff--file-icon (status)
  "Return a one-char icon string for STATUS."
  (cond ((equal status "added")    (propertize "A" 'face 'octocat-diff-file-added))
        ((equal status "removed")  (propertize "D" 'face 'octocat-diff-file-removed))
        ((equal status "renamed")  (propertize "R" 'face 'octocat-diff-file-renamed))
        (t                         (propertize "M" 'face 'octocat-diff-file-modified))))

;;;;; Patch text
;;
;; The patch of a file is a list of segments: runs of diff lines, each a
;; string in the diff faces, and between them the inline comment threads
;; placed after the line they are on, each a component of its own (see
;; `octocat-diff--thread').  Each diff line carries the text property
;; `octocat-diff-line', its anchor (PATH SIDE LINE POSITION HUNK): SIDE
;; is "LEFT" for a removed line, at LINE of the old file, and "RIGHT"
;; otherwise, at LINE of the new one, as GitHub anchors review comments;
;; POSITION is its 1-based place in the diff and HUNK the hunk's number.
;; A file's heading carries (PATH), a comment on the whole file.

(defvar octocat-timeline-comment-lines)

(defun octocat-diff--edge-face (comment)
  "Return the face of the box edge of COMMENT: a draft's stands out."
  (if (eq (gethash "pending" comment) t) 'octocat-review-pending 'octocat-dimmed))

(defun octocat-diff--comment-head (comment)
  "Return the author, date and reactions of COMMENT, propertized.
A draft, with \"pending\" set, says so."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user)
                          (octocat--nonempty (gethash "login" user)))
                     ""))
         (date   (octocat--format-ts-relative
                  (or (octocat--nonempty (gethash "created_at" comment)) "")))
         (reactions (octocat--reactions-string comment)))
    (concat (propertize (if (string-empty-p login) "(unknown)" (concat "@" login))
                        'face 'octocat-pr-author)
            (if (eq (gethash "pending" comment) t)
                (propertize "  Pending" 'face 'octocat-review-pending)
              (propertize (concat "  " date) 'face 'octocat-dimmed))
            (if reactions (concat "  " reactions) ""))))

(defun octocat-diff--comment-body (comment prefix raw width)
  "Return the body of COMMENT, each line after PREFIX, without final newline.
RAW and WIDTH are as for `octocat-diff--comment-lines'."
  (let ((body (string-trim (or (gethash "body" comment) ""))))
    (if (string-empty-p body)
        (concat prefix (propertize "(empty)" 'face 'octocat-dimmed))
      (string-remove-suffix "\n" (octocat--markdown-string body prefix raw width)))))

(defun octocat-diff--box-top (comment width)
  "Return the top edge of the box of COMMENT, its heading on it.
A comment on a range of lines names them.  The edge runs on past the
heading, to the middle of WIDTH."
  (let* ((face  (octocat-diff--edge-face comment))
         (start (gethash "start_line" comment))
         (head  (concat (octocat-diff--comment-head comment)
                        (if (integerp start)
                            (propertize (format "  L%d–L%d" start (gethash "line" comment))
                                        'face 'octocat-dimmed)
                          "")))
         (rule (max 3 (- (/ width 2) (string-width "  ┌─ ") (string-width head) 1))))
    (concat (propertize "  ┌─ " 'face face 'octocat-markdown-copy 'drop) head
            (propertize " " 'octocat-markdown-copy 'drop)
            (propertize (make-string rule ?─) 'face face 'octocat-markdown-copy 'drop))))

(defun octocat-diff--reply-head (reply)
  "Return the line leading into REPLY from a bubble on its box's edge."
  (concat (propertize "  ○── " 'face (octocat-diff--edge-face reply) 'octocat-markdown-copy 'drop)
          (octocat-diff--comment-head reply)))

(defun octocat-diff--bar (comment &optional indent)
  "Return the box edge before a body line of COMMENT, then INDENT."
  (concat (propertize "  │ " 'face (octocat-diff--edge-face comment) 'octocat-markdown-copy 'drop)
          indent))

(defun octocat-diff--spacer (root)
  "Return the box edge alone, a row between the comments of ROOT's thread."
  (propertize "  │" 'face (octocat-diff--edge-face root) 'octocat-markdown-copy 'drop))

(defun octocat-diff--comment-lines (comment raw width &optional replies)
  "Return the lines of the boxed inline review COMMENT, without newlines.
REPLIES, the comments answering it, follow in the same box, indented,
each led to from a bubble on its edge.  A body is markdown, rendered unless
RAW, to fit WIDTH columns."
  (append
   (list (octocat-diff--box-top comment width)
         (octocat-diff--comment-body comment (octocat-diff--bar comment) raw width))
   ;; Each reply's bubble sits on the box's edge, as on a timeline's
   ;; rail, a line leading from it into the reply; an edge row sets it
   ;; apart from the comment before.
   (mapcan (lambda (r)
             (list (octocat-diff--spacer comment)
                   (octocat-diff--reply-head r)
                   (octocat-diff--comment-body r (octocat-diff--bar r "  ") raw width)))
           replies)
   (list (propertize "  └─" 'face (octocat-diff--edge-face comment)
                     'octocat-markdown-copy 'drop))))

(defun octocat-diff--timeline (comments raw width)
  "Return COMMENTS, on no line of the diff, as a timeline, without newline.
With nothing to enclose, they are drawn as the PR timeline's comments,
a bullet then the body on a rail.  RAW and WIDTH are as for
`octocat-diff--comment-lines'."
  (let ((rail (propertize "  │ " 'face 'octocat-dimmed 'octocat-markdown-copy 'drop)))
    (mapconcat (lambda (c)
                 (concat (propertize "  ● " 'face 'octocat-dimmed 'octocat-markdown-copy 'drop)
                         (octocat-diff--comment-head c) "\n"
                         (octocat-diff--comment-body c rail raw width)))
               comments
               (concat "\n" (string-trim-right rail) "\n"))))

(defun octocat-diff--threads (comments)
  "Group the review COMMENTS into threads, in order: lists (ROOT . REPLIES).
A reply, with an `in_reply_to_id', joins the thread of the comment it
answers; one whose thread is not among COMMENTS starts its own."
  (let ((root-of (make-hash-table)) ; Comment id to its thread's root id.
        (threads (make-hash-table))
        roots)
    (dolist (c comments)
      (let* ((id     (gethash "id" c))
             (parent (gethash "in_reply_to_id" c))
             (root   (and (integerp parent) (gethash parent root-of))))
        (if root
            (push c (gethash root threads))
          (setq root id)
          (push c roots))
        (when (integerp id) (puthash id root root-of))))
    (mapcar (lambda (r)
              (cons r (and (integerp (gethash "id" r))
                           (reverse (gethash (gethash "id" r) threads)))))
            (nreverse roots))))

(defun octocat-diff--index (comments)
  "Index the review COMMENTS of one file for `octocat-diff--segments'.
Returns (BY-LINE BY-POS FILE): alists mapping (SIDE . LINE), and for
older comments that have no line a diff position, to the list of
threads there, in order, see `octocat-diff--threads'; and the threads
on the whole file.  A thread is placed where its first comment is, the
last line of its range."
  (let (by-line by-pos file)
    (dolist (thread (octocat-diff--threads comments))
      (let* ((c    (car thread))
             (line (let ((v (gethash "line" c))) (and (integerp v) v)))
             (side (if (equal (gethash "side" c) "LEFT") "LEFT" "RIGHT"))
             (pos  (let ((v (gethash "position" c))) (and (integerp v) v))))
        (cond (line (push thread (alist-get (cons side line) by-line nil nil #'equal)))
              (pos  (push thread (alist-get pos by-pos)))
              ((equal (gethash "subject_type" c) "file") (push thread file)))))
    (list (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-line)
          (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-pos)
          (nreverse file))))

(defun octocat-diff--walk (patch index fn)
  "Call FN with each line of the unified diff PATCH, its threads and anchor.
INDEX is the comment index of the file, see `octocat-diff--index'.  FN
gets the line, the list of comment threads placed right after it, and
its anchor (SIDE LINE POSITION HUNK), nil for a hunk heading or a note
\(see \"Patch text\" above).  The line numbers of both sides are
tracked from the `@@' headers.  A thread on no line of PATCH, as an
outdated one, is placed nowhere."
  (let ((by-line (nth 0 index))
        (by-pos  (nth 1 index))
        (left 0) (right 0) (pos 0) (hunk 0))
    (cl-flet ((at (key table) (cdr (assoc key table))))
      (dolist (raw (octocat-diff--split patch))
        (cl-incf pos)
        (pcase (octocat-diff--line-kind raw)
          ('hunk
           (cl-incf hunk)
           (when (string-match "@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw)
             (setq left  (string-to-number (match-string 1 raw))
                   right (string-to-number (match-string 2 raw))))
           (funcall fn raw (at pos by-pos) nil))
          ('note
           (funcall fn raw (at pos by-pos) nil))
          ('removed
           (funcall fn raw (append (at (cons "LEFT" left) by-line) (at pos by-pos))
                    (list "LEFT" left pos hunk))
           (cl-incf left))
          ('added
           (funcall fn raw (append (at (cons "RIGHT" right) by-line) (at pos by-pos))
                    (list "RIGHT" right pos hunk))
           (cl-incf right))
          (_
           (funcall fn raw (append (at (cons "LEFT" left) by-line)
                                   (at (cons "RIGHT" right) by-line)
                                   (at pos by-pos))
                    (list "RIGHT" right pos hunk))
           (cl-incf left)
           (cl-incf right)))))))

(defun octocat-diff--placed-count (patch comments)
  "Return how many of COMMENTS, on the file of PATCH, are placed in its diff."
  (let* ((index (octocat-diff--index comments))
         (n     (apply #'+ (mapcar #'length (nth 2 index)))))
    (octocat-diff--walk patch index
                        (lambda (_line placed _anchor)
                          (dolist (thread placed) (cl-incf n (length thread)))))
    n))

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

(defun octocat-diff--segments (patch path index &optional span)
  "Return the unified diff PATCH as segments, see \"Patch text\" above.
That is a list of strings, runs of lines without final newline, and
threads (ROOT . REPLIES), each placed right after the diff line it is
on, see `octocat-diff--walk'; the threads on the whole file come
first.  PATH is the file's, whose major mode highlights the code, see
`octocat-diff--lines'.  INDEX is the comment index of the file, see
`octocat-diff--index'.  A line is cut at `octocat--max-line-length',
see `octocat--clip-line'.  The lines at the positions SPAN, (START .
END) as `octocat-diff--span' gives them, are in `octocat-line-highlight',
and the first has `octocat-line-target'."
  (let ((lines (octocat-diff--lines patch path))
        (out   (reverse (nth 2 index)))
        run)
    (cl-flet ((flush ()
                (when run
                  ;; The newline after a highlighted line takes its face,
                  ;; so the band reaches the window's edge.
                  (push (cl-loop for (line . more) on (nreverse run)
                                 concat (if (not more) line
                                          (concat line
                                                  (propertize
                                                   "\n" 'face
                                                   (and (get-text-property
                                                         0 'octocat-line-highlight line)
                                                        'octocat-line-highlight)))))
                        out)
                  (setq run nil))))
      ;; Diff lines are not indented, so they copy out as a valid patch.
      (octocat-diff--walk
       patch index
       (lambda (_line placed anchor)
         (let ((line (octocat--clip-line (pop lines) octocat--max-line-length)))
           (when anchor
             (setq line (propertize line 'octocat-diff-line (cons path anchor)))
             (when (and span (<= (car span) (nth 2 anchor) (cdr span)))
               ;; Over the diff's own faces, as GitHub's band is.
               (add-face-text-property 0 (length line) 'octocat-line-highlight nil line)
               (put-text-property 0 (length line) 'octocat-line-highlight t line)
               (when (= (nth 2 anchor) (car span))
                 (put-text-property 0 (length line) 'octocat-line-target t line))))
           (push line run))
         (when placed
           (flush)
           (setq out (append (reverse placed) out)))))
      (flush))
    (nreverse out)))

(defun octocat-diff--thread-height (thread)
  "Return about how many lines THREAD takes, for a fold's unfolding."
  (if (eq (gethash "resolved" (car thread)) t) 1 (+ 2 (* 3 (length thread)))))

(defun octocat-diff--body (segments raw width underline)
  "Return SEGMENTS of a file's diff as the (TOTAL . RENDER) of a fold.
The threads' comments are markdown, rendered unless RAW, to fit WIDTH
columns.  UNDERLINE underlines the last line across WIDTH, see
`octocat-diff--underline-last'."
  (let* ((last  (car (last segments)))
         (items (mapcar (lambda (s)
                          (if (stringp s)
                              (let* ((s (if (and underline (eq s last))
                                            (octocat-diff--underline-last s width)
                                          s))
                                     (ends (octocat-vui-line-ends s)))
                                (list s (1+ (length ends)) ends))
                            (list s (octocat-diff--thread-height s))))
                        segments)))
    (cons (apply #'+ (mapcar #'cadr items))
          (lambda (n)
            (let (out)
              (cl-loop for (seg height ends) in items
                       while (> n 0)
                       do (push (if (stringp seg)
                                    (vui-text (octocat-vui-take-lines seg ends n))
                                  (vui-component 'octocat-diff--thread
                                    :key (octocat-diff--thread-key seg)
                                    :thread seg :raw raw :width width
                                    :underline (and underline (eq seg last) width)))
                                out)
                       do (cl-decf n height))
              (nreverse out))))))

(defun octocat-diff--thread-key (thread)
  "Return the key of THREAD's component: its root's id, kept across refetches."
  (let ((root (car thread)))
    (format "thread-%s" (or (gethash "id" root) (gethash "node_id" root) "new"))))


;;;;; Threads
;;
;; A thread is a box: its first comment, then the replies, each body
;; folded past `octocat-timeline-comment-lines' as a timeline comment is.
;; Every line of it is marked `octocat-comment', for
;; `octocat-diff-toggle-comments' to roll in and out, and
;; `octocat-diff-comment', the comment it shows, for the commands on the
;; comment at point.  A resolved thread folds to one line, as on GitHub.

(defvar-local octocat-diff--comment-backend nil
  "How the comments of this page's diff are written, or nil if they aren't.
A plist of functions, which the page's mode sets: :add of a range, see
`octocat-diff--range', and :reply, :edit and :resolve of a comment.")

(defun octocat-diff--tag (string comment)
  "Return STRING marked as a line of COMMENT's box, see \"Threads\" above."
  (propertize string 'octocat-comment t 'octocat-diff-comment comment))

(defun octocat-diff--resolved-line (root)
  "Return the line a resolved thread ROOT folds to."
  (let ((login (octocat--get root "user" "login"))
        (line  (gethash "line" root))
        (by    (octocat--nonempty (gethash "resolved_by" root))))
    (concat (propertize "  ▸ " 'face 'octocat-dimmed)
            (propertize (if login (concat "@" login) "(unknown)") 'face 'octocat-pr-author)
            (propertize (concat "  " (or (gethash "path" root) "")
                                (if (integerp line) (format ":L%d" line) "")
                                "  Resolved" (if by (concat " by @" by) ""))
                        'face 'octocat-dimmed))))

(defun octocat-diff--folded-body (comment prefix raw width)
  "Return the body of COMMENT after PREFIX, folded as a timeline comment.
RAW and WIDTH are as for `octocat-diff--comment-lines'."
  (let ((text (octocat-diff--tag (octocat-diff--comment-body comment prefix raw width)
                                 comment)))
    (octocat-vui-fold-lines text (octocat-vui-line-ends text)
                            (bound-and-true-p octocat-timeline-comment-lines)
                            (intern (format "more-%s" (or (gethash "id" comment) "new")))
                            (octocat-diff--tag prefix comment))))

(vui-defcomponent octocat-diff--thread (thread raw width underline)
  "THREAD, (ROOT . REPLIES), boxed in a diff; RAW and WIDTH as for its lines.
A resolved one folds to a line, which RET unfolds.  When ROOT may be
resolved, or unresolved, it ends in a button doing it, through the
page's backend (see `octocat-diff--comment-backend').  UNDERLINE, a
width, underlines the last line, see `octocat-diff--underline-last'."
  :state ((open nil))
  :render
  (let* ((root     (car thread))
         (resolved (eq (gethash "resolved" root) t))
         (toggle   (vui-async-callback () (vui-set-state :open (not open))))
         (bottom   (octocat-diff--tag (propertize "  └─" 'face (octocat-diff--edge-face root)
                                                  'octocat-markdown-copy 'drop)
                                      root)))
    (cl-flet ((under (s) (if underline (octocat-diff--underline-last s underline) s)))
      (if (and resolved (not open))
          (octocat-vui-row (octocat-diff--tag (under (octocat-diff--resolved-line root)) root)
                           toggle "RET: show the conversation")
        (apply #'vui-vstack
               (let ((top (octocat-diff--tag (octocat-diff--box-top root width) root)))
                 (if resolved
                     (octocat-vui-row top toggle "RET: fold the conversation")
                   (vui-text top)))
               (octocat-diff--folded-body root (octocat-diff--bar root) raw width)
               (append
                (mapcan (lambda (r)
                          (list (vui-text (octocat-diff--tag (octocat-diff--spacer root) r))
                                (vui-text (octocat-diff--tag (octocat-diff--reply-head r) r))
                                (octocat-diff--folded-body r (octocat-diff--bar r "  ")
                                                           raw width)))
                        (cdr thread))
                ;; An edge row sets the button apart from the last comment.
                (when (eq (gethash (if resolved "can_unresolve" "can_resolve") root) t)
                  (list (vui-text (octocat-diff--tag (octocat-diff--spacer root) root))
                        (vui-hstack
                         :spacing 0
                         (vui-text (octocat-diff--tag (octocat-diff--bar root) root))
                         (vui-button (if resolved "Unresolve conversation" "Resolve conversation")
                           :face 'octocat-dimmed
                           :key 'resolve
                           :on-click (lambda ()
                                       (funcall (octocat-diff--backend :resolve) root))))))
                (list (vui-text (under bottom)))))))))


;;;;; Commenting
;;
;; The commands on the diff's lines and comments, the same on every page
;; with a diff; each page's backend writes the comments its own way.

(defun octocat-diff--line-anchor (pos)
  "Return the anchor on the line at POS, see \"Patch text\" above, or nil."
  (save-excursion
    (goto-char pos)
    (let* ((bol (line-beginning-position))
           (eol (line-end-position))
           (at  (if (get-text-property bol 'octocat-diff-line)
                    bol
                  (next-single-property-change bol 'octocat-diff-line nil eol))))
      (and (< at eol) (get-text-property at 'octocat-diff-line)))))

(defun octocat-diff--anchors (beg end)
  "Return the anchors of the lines from BEG to END, in order.
A line with none, as a hunk heading or a comment, is left out."
  (save-excursion
    (goto-char beg)
    (let (out)
      (while (progn (when-let* ((a (octocat-diff--line-anchor (point)))) (push a out))
                    (and (zerop (forward-line 1)) (< (point) end) (not (eobp)))))
      (nreverse out))))

(defun octocat-diff--url-fragment ()
  "Return \"#diff-…\" naming the diff line at point or the region's, or \"\".
On a file's heading it names the file; a region across files names
its first file's lines.  See `octocat--diff-fragment'."
  (let* ((span    (octocat--point-or-region))
         (anchors (octocat-diff--anchors (car span) (1+ (cdr span))))
         (path    (car (car anchors)))
         (lines   (seq-filter (lambda (a) (and (equal (car a) path) (cdr a))) anchors))
         (at      (lambda (a) (cons (nth 1 a) (nth 2 a)))))
    (cond (lines (concat "#" (octocat--diff-fragment
                              path (funcall at (car lines))
                              (funcall at (car (last lines))))))
          (path  (concat "#" (octocat--diff-fragment path)))
          (t     ""))))

(defun octocat-diff--range (anchors)
  "Return the range a comment on the lines of ANCHORS is on.
It is a plist, as `octocat-model--review-new-thread' takes it; a file's
heading alone is the whole file.  A range across files or hunks signals
a `user-error', as GitHub rejects one across hunks."
  (let ((first (car anchors))
        (last  (car (last anchors))))
    (cond
     ((null anchors)
      (user-error "Octocat: Not on a line of the diff"))
     ((and (null (cdr anchors)) (null (cdr first)))
      (list :path (car first) :file t))
     ((or (seq-some (lambda (a) (null (cdr a))) anchors)
          (seq-some (lambda (a) (not (equal (car a) (car first)))) anchors))
      (user-error "Octocat: A comment's lines must be in one file"))
     ((seq-some (lambda (a) (not (eql (nth 4 a) (nth 4 first)))) anchors)
      (user-error "Octocat: A comment's lines must be in one hunk"))
     (t
      (append (list :path (car first) :side (nth 1 last) :line (nth 2 last))
              (unless (eq first last)
                (list :start-side (nth 1 first) :start-line (nth 2 first))))))))

(defun octocat-diff-range-label (range)
  "Return RANGE, as `octocat-diff--range' gives it, as \"path:L12-L18\"."
  (cl-flet ((at (side line) (format "%sL%d" (if (equal side "LEFT") "old " "") line)))
    (concat (plist-get range :path)
            (cond ((plist-get range :file) "")
                  ((plist-get range :start-line)
                   (concat ":" (at (plist-get range :start-side) (plist-get range :start-line))
                           "–" (at (plist-get range :side) (plist-get range :line))))
                  (t (concat ":" (at (plist-get range :side) (plist-get range :line))))))))

(defun octocat-diff--mark-lines (beg end)
  "Highlight the lines from BEG to END, as being commented on; return the overlay."
  (let ((ov (make-overlay (save-excursion (goto-char beg) (line-beginning-position))
                          (save-excursion (goto-char end) (min (point-max)
                                                               (1+ (line-end-position)))))))
    (overlay-put ov 'face 'octocat-review-mark)
    (overlay-put ov 'priority 10)
    ov))

(defun octocat-diff--backend (key)
  "Return the function KEY of this page's comment backend, or signal."
  (or (plist-get octocat-diff--comment-backend key)
      (user-error "Octocat: Comments can't be written on this page yet")))

(defun octocat-diff-comment-at-point ()
  "Return the comment whose box point is in, or nil."
  (or (get-text-property (point) 'octocat-diff-comment)
      (get-text-property (line-beginning-position) 'octocat-diff-comment)))

(defun octocat-diff-add-comment ()
  "Comment on the diff lines of the region, or of point; or reply.
On a file's heading the comment is on the whole file, and in a
comment's box it is a reply to its conversation.  The lines stay
highlighted while the comment is being written."
  (interactive)
  (let ((comment (and (not (use-region-p)) (octocat-diff-comment-at-point))))
    (if comment
        (funcall (octocat-diff--backend :reply) comment)
      (let* ((add (octocat-diff--backend :add))
             (beg (if (use-region-p) (region-beginning) (point)))
             ;; A region ending at a line's start leaves that line out.
             (end (if (and (use-region-p) (> (region-end) beg)
                           (save-excursion (goto-char (region-end)) (bolp)))
                      (1- (region-end))
                    (if (use-region-p) (region-end) (point))))
             (range (octocat-diff--range (octocat-diff--anchors beg end)))
             (mark  (octocat-diff--mark-lines beg end)))
        (deactivate-mark)
        (let ((win (condition-case err
                       (funcall add range)
                     (error (delete-overlay mark) (signal (car err) (cdr err))))))
          (if (window-live-p win)
              (with-current-buffer (window-buffer win)
                (add-hook 'kill-buffer-hook (lambda () (delete-overlay mark)) nil t))
            (delete-overlay mark)))))))

(defun octocat-diff-edit-comment ()
  "Edit the comment at point, if it is yours."
  (interactive)
  (let ((comment (or (octocat-diff-comment-at-point)
                     (user-error "Octocat: No comment at point"))))
    (unless (eq (gethash "can_edit" comment) t)
      (user-error "Octocat: You can only edit your own comments"))
    (funcall (octocat-diff--backend :edit) comment)))


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
    (octocat--set-mode-for-path path)
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


;;;;; Components

(defun octocat-diff--underline-last (text width)
  "Return TEXT with its last line underlined across WIDTH columns.
The underline closes a file's diff, setting it apart from the next
file; it shows only once the diff is unfolded to its end."
  (let ((text  (copy-sequence text))
        (start (1+ (or (cl-position ?\n text :from-end t) -1))))
    (add-face-text-property start (length text) 'underline t text)
    (concat text (propertize " " 'face 'underline 'display `(space :align-to ,width)))))

(defun octocat-diff--no-diff-note (status changes)
  "Return why a file of STATUS has no patch, or nil.
CHANGES is how many of its lines changed.  GitHub sends no patch for a
binary file, nor for a diff too large; an empty file, as a binary one,
has no lines changed.  A rename alone has no diff to explain."
  (cond ((and (equal status "renamed") (eql changes 0)) nil)
        ((eql changes 0) "binary or empty")
        (t "diff too large to show")))

(defun octocat-diff--url-path (path)
  "Return PATH URL-encoded part by part, keeping its slashes."
  (mapconcat #'url-hexify-string (split-string path "/") "/"))

(defun octocat-diff--merge-base (repo base head callback)
  "Call CALLBACK with the merge base of BASE and HEAD in REPO, or (error . MSG)."
  (octocat--run-gh
   "merge-base"
   (list "api" (format "repos/%s/compare/%s...%s?per_page=1" repo
                       (octocat-diff--url-path base) (octocat-diff--url-path head))
         "--jq" ".merge_base_commit.sha")
   #'string-trim callback))

(defun octocat-diff--fetch-text (repo ref path callback)
  "Call CALLBACK with the content of PATH at REF in REPO, or (error . MSG).
Without REF, the file is not on that side, and its content is empty."
  (if (null ref)
      (funcall callback "")
    (octocat-sync-get (list 'file-text repo ref path)
                      (octocat--then (lambda (data) (gethash "text" data)) callback))))

(defun octocat-diff--show-large (old-path path old new)
  "Show the diff of OLD, the text of OLD-PATH, and NEW, that of PATH."
  (let ((a   (make-temp-file "octocat-a-" nil nil old))
        (b   (make-temp-file "octocat-b-" nil nil new))
        (buf (get-buffer-create (format "*octocat diff %s*" path))))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (call-process diff-command nil t nil "-u"
                          "--label" (concat "a/" old-path) "--label" (concat "b/" path)
                          a b))
          (diff-mode)
          (setq buffer-read-only t)
          (goto-char (point-min)))
      (delete-file a)
      (delete-file b))
    (pop-to-buffer buf)))

(defun octocat-diff-open-large (repo file revs)
  "Diff FILE of REPO, whose diff GitHub won't send, in a buffer of its own.
Asks first, as both versions of the file are fetched whole.  REVS is
\=(OLD . NEW), the commits compared; OLD may instead be a function
that calls its callback with the commit, or with (error . MSG)."
  (let* ((path     (gethash "filename" file))
         (old-path (or (octocat--nonempty (gethash "previous_filename" file)) path))
         (status   (gethash "status" file))
         (fail     (lambda (r) (message "Octocat: %s" (cdr r)))))
    (when (y-or-n-p (format "Fetch both versions of %s and diff them? " path))
      (message "Octocat: Fetching %s..." path)
      (funcall
       (if (functionp (car revs)) (car revs) (lambda (k) (funcall k (car revs))))
       (lambda (old)
         (if (eq (car-safe old) 'error)
             (funcall fail old)
           (octocat-diff--fetch-text
            repo (and (not (equal status "added")) old) old-path
            (lambda (a)
              (if (eq (car-safe a) 'error)
                  (funcall fail a)
                (octocat-diff--fetch-text
                 repo (and (not (equal status "removed")) (cdr revs)) path
                 (lambda (b)
                   (if (eq (car-safe b) 'error)
                       (funcall fail b)
                     (message nil)
                     (octocat-diff--show-large old-path path a b)))))))))))))

(vui-defcomponent octocat-diff--image (repo sha width last)
  "The image of blob SHA of REPO, no wider than WIDTH columns.
Unless LAST, a line across WIDTH follows it, see
`octocat-diff--underline-last'."
  :render
  (let* ((snap (octocat-vui-use-resource (list 'blob repo sha) nil))
         (data (plist-get snap :data))
         (text (vui-use-memo (data width last)
                 (and data
                      (let ((image (octocat--image-text
                                    (octocat-model-blob-content data) width)))
                        ;; Under the image: on its line, the underline
                        ;; would cross it at the text's baseline.
                        (if last image
                          (concat image "\n" (octocat-diff--underline-last "" width))))))))
    (pcase (octocat-vui-snapshot-status snap)
      ('pending (vui-text (octocat-vui-skeleton '(("" 24)))))
      ('error   (vui-text (octocat-vui-error-text snap) :face 'error))
      (_        (vui-text text)))))

(defun octocat-diff--file (repo file comments bulk raw width last &optional at revs)
  "Return one changed FILE (a files-endpoint hash-table) of REPO.
Its inline COMMENTS are placed in its diff.  It is folded unless BULK,
as for `octocat-vui-fold', says otherwise.  An image added or modified
unfolds to the image, see `octocat-diff--image', but only by its own
RET: \"Expand all\" leaves it folded, so no image is fetched unasked.
Another file without
a patch is just its heading, which says why, see
`octocat-diff--no-diff-note'; given REVS, as for
`octocat-diff-open-large', RET on one too large diffs it in a buffer.
RAW and WIDTH are as for `octocat-diff--comment-lines'.  Unless LAST,
the file being the last one, its diff ends underlined, see
`octocat-diff--underline-last'.  AT, (diff HASH FROM TO) as
`octocat--url-lines' reads a link to this file, unfolds it and
highlights lines FROM to TO; without them, or with neither in the
patch, the heading is the place scrolled to."
  (let* ((filename (or (gethash "filename" file) ""))
         (status   (or (gethash "status" file) "modified"))
         (patch    (let ((p (gethash "patch" file)))
                     (and (stringp p) (not (string-empty-p p)) p)))
         (changes  (or (gethash "changes" file) 0))
         (span     (and at (nth 2 at) patch (octocat-diff--span patch (nth 2 at) (nth 3 at))))
         (bulk     (or bulk (and at patch '(-1 . t))))
         (sha      (gethash "sha" file))
         (image    (and (null patch) (stringp sha)
                        (member status '("added" "modified"))
                        (octocat--image-file-p filename)))
         (title    (concat (octocat-diff--file-icon status)
                           " "
                           ;; The anchor of a comment on the whole file.
                           (propertize filename 'face 'octocat-diff-file-name
                                       'octocat-diff-line (list filename))
                           ;; Nothing to count in a file with no lines changed.
                           (unless (and (null patch) (eql changes 0))
                             (propertize (format "  +%d -%d"
                                                 (or (gethash "additions" file) 0)
                                                 (or (gethash "deletions" file) 0))
                                         'face 'octocat-dimmed))))
         (title    (if (and at (not span)) (propertize title 'octocat-line-target t) title)))
    (cond
     (image
      (vui-component 'octocat-vui-fold
        :key (intern filename)
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show image" . "RET: hide image")))
        :deps (list repo sha width last)
        :prepare (lambda ()
                   (cons 1 (lambda (_n)
                             (list (vui-component 'octocat-diff--image
                                     :repo repo :sha sha :width width :last last)))))))
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
        :bulk bulk
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show diff" . "RET: hide diff")))
        :deps (list patch comments raw width last span)
        :prepare (lambda ()
                   (octocat-diff--body (octocat-diff--segments
                                        patch filename (octocat-diff--index comments) span)
                                       raw width (not last))))))))

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

(defvar-local octocat-diff--at nil
  "The lines a link to this page named, (diff HASH FROM TO), or nil.
See `octocat--url-lines'.  The user's refresh drops them.")

(defvar-local octocat-diff--hide-comments nil
  "Non-nil leaves the inline comments out of this page's diff.
Opening the page shows them again.")

(defun octocat-diff-toggle-comments ()
  "Show or hide the inline comments in the diff of this page.
They roll down out of their first line, and back up into it."
  (interactive)
  (let* ((buf  (current-buffer))
         (hide (not octocat-diff--hide-comments))
         (show (lambda ()
                 (setq octocat-diff--hide-comments hide)
                 (message "Diff comments: %s" (if hide "hidden" "shown"))
                 (octocat-vui-update-page :hide-comments hide))))
    (if hide
        (octocat-vui-roll buf 'octocat-comment 'out show)
      (funcall show)
      (octocat-vui-roll buf 'octocat-comment 'in))))

(defun octocat-diff--comments-switch (hide count)
  "Return the pill switching the diff's COUNT comments on and off.
HIDE is whether they are hidden; the hint names the key that switches."
  (cl-flet ((help (action)
              (octocat--key-help #'octocat-diff-toggle-comments action)))
    (octocat-vui-segmented
     (list (list (format "Comments (%d)" count) (not hide)
                 (help "show the comments in the diff")
                 #'octocat-diff-toggle-comments)
           (list "Diff only" hide
                 (help "hide the comments in the diff")
                 #'octocat-diff-toggle-comments)))))

(vui-defcomponent octocat-diff--files
    (repo files by-path hide fits raw width underline at total revs)
  "The Files section: FILES of REPO with the review comments BY-PATH, folded.
They start unfolded when FITS, the whole diff fitting in the window.
HIDE leaves the comments out.  RAW and WIDTH are as for
`octocat-diff--comment-lines'; UNDERLINE underlines the heading across
WIDTH, but for a page whose tab row heads the section.  The heading's
\"Expand all\" button unfolds or folds every file, and its switch of the
comments, there when the diff shows some, runs
`octocat-diff-toggle-comments'.  AT, the lines a link named, is
scrolled to, see `octocat-diff--file'; the user's refresh drops it.
TOTAL, how many files changed, says at the end how many GitHub left out.
REVS is as for `octocat-diff-open-large', for the files too large to diff."
  :state ((bulk (and fits (cons 0 t))))
  :render
  (let* ((buf (current-buffer))
         (_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :bulk (and fits (cons 0 t)))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when octocat-diff--at
                     (setq octocat-diff--at nil)
                     (octocat-vui-update-page :at nil)))))))
         (heading (format "Files (%d)" (length files)))
         ;; Only those the diff places: an outdated comment's line is gone.
         (placed  (vui-use-memo (files by-path)
                    (cl-loop for f across files
                             for patch = (gethash "patch" f)
                             for comments = (cdr (assoc (gethash "filename" f) by-path))
                             when (and comments (stringp patch))
                             sum (octocat-diff--placed-count patch comments)))))
    (vui-use-effect (at)
      (when at (octocat--goto-line-target buf))
      nil)
    (vui-vstack
     (let ((after (and (cl-some (lambda (f) (stringp (gethash "patch" f))) files)
                       (cons (octocat-vui-expand-all-button
                              bulk (vui-async-callback (v) (vui-set-state :bulk v)))
                             (and (> placed 0)
                                  (list (octocat-diff--comments-switch hide placed)))))))
       (if underline
           (apply #'octocat-vui-section-heading heading width after)
         (apply #'vui-hstack :spacing 2
                (vui-text heading :face 'octocat-section-heading) after)))
     (if (zerop (length files))
         (vui-text "  (no files changed)" :face 'octocat-dimmed)
       (vui-list (append files nil)
                 (lambda (f)
                   (octocat-diff--file repo f (and (not hide)
                                                   (cdr (assoc (gethash "filename" f) by-path)))
                                       bulk raw width
                                       (eq f (aref files (1- (length files))))
                                       (and at (octocat--diff-path-hash-p
                                                (nth 1 at) (or (gethash "filename" f) ""))
                                            at)
                                       revs))
                 (lambda (f) (gethash "filename" f))))
     (when (and total (> total (length files)))
       (vui-text (format "  %d more files changed than GitHub's API lists"
                         (- total (length files)))
         :face 'octocat-dimmed)))))

(defun octocat-diff-files-section (repo files by-path hide raw width
                                        &optional underline at total revs)
  "Return the vnode of the Files section: the heading and one entry per file.
FILES is REPO's files vector and BY-PATH the review comments by file path,
left out when HIDE.
Files start folded, unless the whole diff fits in the window.  The
comments are markdown, rendered unless RAW, to fit WIDTH columns.
UNDERLINE underlines the heading across WIDTH.  AT is the lines a
link named, see `octocat-diff--file'.  TOTAL is how many files changed,
when FILES may be fewer.  REVS, the commits compared, is as for
`octocat-diff-open-large'."
  (vui-component 'octocat-diff--files
    :repo repo
    :files files
    :by-path by-path
    :hide hide
    :raw raw
    :width width
    :underline underline
    :at at
    :total total
    :revs revs
    :fits (<= (octocat-diff--line-count files) (octocat-vui-window-height))))

(defun octocat-diff-comments-section (label comments raw width)
  "Return the vnode of the comments section headed LABEL, e.g. \"Comments\".
COMMENTS is the sync snapshot of the comments.  Inline ones are in the
diff, so only counted here; the others are a timeline.  RAW and
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
                   (list (vui-text (octocat-diff--timeline general raw width))))))))))


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

(defvar-local octocat-commit--patch nil
  "Non-nil when the commit shows as a patch, see `octocat-commit-toggle-patch'.")


;;;;; Sections
;;
;; Each returns the vnodes of one part of the page.  The files reuse the
;; PR diff's file component: commit comments have the same shape as PR
;; review comments.

(defun octocat-commit--view-segments (patch)
  "Return the segments of the commit page's views, the one of PATCH current.
`Diff' is the page, `Patch' the commit as `git format-patch' writes it;
the hint of the other names the key that switches them.  See
`octocat-vui-segmented'."
  (let ((key (substitute-command-keys "\\[octocat-commit-toggle-patch]")))
    (list (list "Diff" (not patch)
                (propertize (format "RET, %s: show the diff" key) 'octocat-key-help t)
                #'octocat-commit-toggle-patch)
          (list "Patch" patch
                (propertize (format "RET, %s: show the patch" key) 'octocat-key-help t)
                #'octocat-commit-toggle-patch))))

(defun octocat-commit--view-tabs (patch)
  "Return the commit page's views as a pill, the one of PATCH filled in."
  (octocat-vui-segmented (octocat-commit--view-segments patch)))

(defun octocat-commit--top-line (repo sha patch width)
  "Return the top line of commit SHA of REPO, as the tree browser's.
That is owner/repo@SHA, a button to browse the files of the repository
at it, then the tabs of the views, PATCH the one shown, see
`octocat-commit--view-tabs'.  SHA is cut to keep the line within WIDTH
columns, ElDoc showing it whole."
  (let ((browse "[Browse files]")
        (tabs   " Diff  Patch "))
    (vui-hstack :spacing 0
                (octocat-vui-repo-heading repo)
                (vui-text (concat "@" (octocat-vui--fit
                                       sha (- width (string-width repo) 1 2
                                              (string-width browse) 2
                                              (string-width tabs))))
                  :face 'octocat-commit-sha)
                (vui-text "  ")
                (vui-button browse
                  :no-decoration t
                  :face 'octocat-dimmed
                  :help-echo "RET: browse the repository's files at this commit"
                  :on-click (lambda () (octocat-open 'tree repo sha)))
                (vui-text "  ")
                (octocat-commit--view-tabs patch))))

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
        (holder  (let ((d (plist-get branch :data)))
                   (and d (octocat--nonempty (gethash "name" d))))))
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

(defun octocat-commit--async-status (snap empty)
  "Return a dimmed vnode for the sync snapshot SNAP if failed or empty, else nil.
EMPTY is the text shown when it is ready but has no data.  Grey bars
while it is pending."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28)))))
    ('error   (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'octocat-dimmed))
    (_ (and (zerop (length (plist-get snap :data)))
            (vui-text (concat "  " empty) :face 'octocat-dimmed)))))

(defun octocat-commit--heading (label snap width)
  "Return the section heading LABEL, with the count of SNAP's data once known.
It is underlined across WIDTH columns."
  (octocat-vui-section-heading (if (plist-get snap :data)
                                   (format "%s (%d)" label (length (plist-get snap :data)))
                                 label)
                               width))

(defun octocat-commit--checks (repo sha checks width)
  "Return the CI section of commit SHA of REPO, or nil when it has none.
Its check-runs are in CHECKS, a sync snapshot.  Its heading is
underlined across WIDTH columns."
  (unless (and (plist-get checks :data)
               (zerop (length (plist-get checks :data))))
    (or (and (eq (octocat-vui-snapshot-status checks) 'pending)
             (octocat-commit--heading "Checks" checks width))
        (when-let* ((status (octocat-commit--async-status checks "(no checks)")))
          (vui-vstack (octocat-commit--heading "Checks" checks width) status))
        (apply #'vui-vstack
               (octocat-checks-block
                (cl-map 'vector #'octocat-checks-from-rest (plist-get checks :data))
                (lambda () (octocat-checks-open repo sha nil))
                width)))))


;;;;; Patch

(defun octocat-commit--patch-file (file)
  "Return the diff of changed FILE, as git writes it, propertized.
FILE is an entry of the commit's \"files\".  Without a patch, as of
a binary or very large file, git's line saying it differs stands in."
  (let* ((new    (or (gethash "filename" file) ""))
         (old    (or (octocat--nonempty (gethash "previous_filename" file)) new))
         (status (gethash "status" file))
         (patch  (gethash "patch" file))
         (a      (if (equal status "added") "/dev/null" (concat "a/" old)))
         (b      (if (equal status "removed") "/dev/null" (concat "b/" new))))
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
       (format "Binary files %s and %s differ" a b)))))

(defun octocat-commit--patch-text (commit)
  "Return COMMIT as `git format-patch' writes it, as GitHub's .patch.
Its header, message, then each file's diff, see
`octocat-commit--patch-file'.  Not indented, so it copies out as a
patch `git am' applies."
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
     (mapconcat #'octocat-commit--patch-file (gethash "files" commit) "\n"))))

(defun octocat-commit-toggle-patch ()
  "Show the commit as a patch, as GitHub's .patch, or back as its page."
  (interactive)
  (unless (derived-mode-p 'octocat-commit-mode)
    (user-error "Octocat: Not in a commit buffer"))
  (setq octocat-commit--patch (not octocat-commit--patch))
  (message "Commit view: %s" (if octocat-commit--patch "patch" "diff"))
  (octocat-vui-update-page :patch octocat-commit--patch))


;;;;; Page

(vui-defcomponent octocat-commit--page (repo sha hide-comments raw patch at tick)
  "Commit SHA of REPO: top line, then as `git show': who and when, the
message, then checks, files and comments.  HIDE-COMMENTS leaves the
inline comments out of the diff.  RAW shows markdown verbatim.  PATCH
shows the commit as a patch instead, see `octocat-commit--patch-text'.
AT is the lines a link named, see `octocat-diff--file'.  The
commit, its checks, its comments and the branch holding it are fetched
independently; each shows what the store holds until then.  A new TICK
fetches them again."
  :render
  (let* ((width    (octocat-vui-window-width))
         (commit   (octocat-vui-use-resource (list 'commit repo sha) tick))
         (checks   (octocat-vui-use-resource (list 'checks repo sha) tick))
         (comments (octocat-vui-use-resource (list 'commit-comments repo sha) tick))
         (branch   (octocat-vui-use-resource (list 'commit-branch repo sha) tick))
         (data     (plist-get commit :data))
         (md-width (progn width (octocat--markdown-width)))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data))))
         (message  (vui-use-memo (data)
                     (and data (octocat-commit--message data))))
         (text     (vui-use-memo (data patch)
                     (and data patch (octocat-commit--patch-text data)))))
    (octocat-vui-page
     (octocat-vui-commit-pin repo (or (and data (gethash "sha" data)) sha)
                             (octocat-vui-segmented-pin (octocat-commit--view-segments patch)))
     (vui-vstack
      (octocat-commit--top-line repo (or (and data (gethash "sha" data)) sha) patch width)
      (octocat-vui-resource-view
       commit
       :skeleton (lambda (_) (vui-text (octocat-commit--skeleton width)))
       :render
       (lambda (_)
         (if text
             (vui-text text)
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
                         (octocat-diff-files-section
                          repo (or (gethash "files" data) []) by-path hide-comments raw md-width t
                          at nil (cons (let ((parents (gethash "parents" data)))
                                         (and (> (length parents) 0)
                                              (gethash "sha" (aref parents 0))))
                                       (gethash "sha" data)))
                         ;; Most commits have none, so the section is left
                         ;; out unless there are any, or they failed to load.
                         (when (or (not (seq-empty-p (plist-get comments :data)))
                                   (eq (octocat-vui-snapshot-status comments) 'error))
                           (vui-fragment
                            (vui-newline)
                            (octocat-diff-comments-section
                             "Comments" comments raw md-width))))))))))))))


;;;;; Major mode

(defun octocat-commit--page-url ()
  "Return the URL of this commit, at the diff line of point or the region."
  (and octocat--commit-repo octocat--commit-sha
       (concat (octocat--web-url "%s/commit/%s" octocat--commit-repo octocat--commit-sha)
               (octocat-diff--url-fragment))))

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-v") #'octocat-commit-toggle-patch)
    map)
  "Keymap for `octocat-commit-mode'.")

(define-derived-mode octocat-commit-mode octocat-page-mode "Octocat-Commit"
  "Major mode for viewing a GitHub commit.

\\{octocat-commit-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-commit-refresh)
  (setq-local octocat--url-function #'octocat-commit--page-url)
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
                                  :hide-comments octocat-diff--hide-comments
                                  :raw octocat--markdown-raw
                                  :patch octocat-commit--patch
                                  :at octocat-diff--at)))

(defun octocat-commit-open (repo sha &optional at)
  "Show commit SHA of REPO in its own buffer, AT the lines a link named.
See `octocat-diff--file'."
  (let ((buf (get-buffer-create
              (format "*%s commit %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-commit-mode)
      (octocat-commit-mode))
    (setq octocat--commit-repo repo
          octocat--commit-sha  sha
          octocat-diff--hide-comments nil
          octocat-diff--at at)
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
COMMITS is a REST commits vector of REPO."
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

(defun octocat-compare--top-row (repo base dots head data)
  "Return the top row of the comparison of BASE and HEAD of REPO.
That is `owner/repo BASE...HEAD', as the commit page's `owner/repo@sha',
then the counts of DATA, the comparison, once it is loaded."
  (vui-hstack :spacing 0
              (octocat-vui-repo-heading repo)
              (vui-text (concat "  "
                                (octocat-compare--ref-label base)
                                (propertize dots 'face 'octocat-dimmed)
                                (octocat-compare--ref-label head)
                                (and data
                                     (propertize (concat " · " (octocat-compare--counts data))
                                                 'face 'octocat-dimmed))))))


;;;;; Page

(vui-defcomponent octocat-compare--page (repo base dots head raw at tick)
  "The comparison of BASE and HEAD of REPO: its commits, then its files.
DOTS is as in `octocat--compare-refs'.  RAW shows markdown verbatim.
AT is the lines a link named, see `octocat-diff--file'.  A new TICK
fetches it again."
  :render
  (let* ((width    (octocat--markdown-width))
         (snap     (octocat-vui-use-resource (list 'compare repo base head) tick)))
    (octocat-vui-page
     (octocat-vui-pin (propertize repo 'face 'octocat-repo)
                      (concat (octocat-compare--ref-label base)
                              (propertize dots 'face 'octocat-dimmed)
                              (octocat-compare--ref-label head)))
     (vui-vstack
      (octocat-compare--top-row repo base dots head (plist-get snap :data))
      (octocat-vui-resource-view
       snap
       :skeleton (lambda (_)
                   (vui-text (octocat-vui-skeleton
                              '(nil (26) ("  " 7 "  " 40) ("  " 7 "  " 34) nil
                                    (12) ("  " 40) ("  " 28))
                              (octocat-vui-window-width))))
       :render
       (lambda (data)
         (apply #'vui-vstack
                (append
                 (mapcar (lambda (line) (vui-text line :face 'octocat-dimmed))
                         (octocat-compare--summary data dots))
                 (list (vui-newline))
                 (octocat-compare--commits repo (or (gethash "commits" data) []) width)
                 (list (octocat-diff-files-section
                        repo (or (gethash "files" data) []) nil nil raw width t at nil
                        (cons (octocat--get data "merge_base_commit" "sha") head)))))))))))


;;;;; Major mode

(defun octocat-compare--url (repo refs)
  "Return the web page comparing REFS, as `octocat--compare-refs', of REPO."
  (octocat--web-url "%s/compare/%s" repo (apply #'concat refs)))

(defun octocat-compare--page-url ()
  "Return the URL of this comparison, at the diff line of point or the region."
  (and octocat--compare-repo octocat--compare-refs
       (concat (octocat-compare--url octocat--compare-repo octocat--compare-refs)
               (octocat-diff--url-fragment))))

(defvar octocat-compare-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-compare-mode'.")

(define-derived-mode octocat-compare-mode octocat-page-mode "Octocat-Compare"
  "Major mode for viewing the comparison of two refs of a GitHub repository.

\\{octocat-compare-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-compare-refresh)
  (setq-local octocat--url-function #'octocat-compare--page-url)
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
                                    :raw octocat--markdown-raw
                                    :at octocat-diff--at))))

(defun octocat-compare-open (repo base dots head &optional at)
  "Show the comparison of BASE and HEAD of REPO in its own buffer.
DOTS is \"...\", or \"..\" for a two-dot link (see the Commentary).
AT is the lines a link named, see `octocat-diff--file'."
  (let ((buf (get-buffer-create (format "*%s compare %s%s%s*" repo base dots head))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-compare-mode)
      (octocat-compare-mode))
    (setq octocat--compare-repo repo
          octocat--compare-refs (list base dots head)
          octocat-diff--at at)
    (octocat-compare-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'compare)) repo base dots head &optional at)
  "Open the comparison of BASE DOTS HEAD in REPO, AT the lines a link named.
See `octocat-compare-open'."
  (apply #'octocat-compare-open repo base dots head (and at (list at))))

(provide 'octocat-diff)
;;; octocat-diff.el ends here
