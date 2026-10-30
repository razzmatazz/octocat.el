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
(require 'octocat-tree) ; The `blob' resource.
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

(defface octocat-review-pending
  '((t :inherit warning))
  "Face for a draft review comment's edge and its Pending label."
  :group 'octocat)

(defface octocat-review-mark
  '((((background dark)) :background "#4a4420" :extend t)
    (t :background "#fff5b1" :extend t))
  "Face for the diff lines a comment being written is on."
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
    (concat (propertize "  ┌─ " 'face face) head " "
            (propertize (make-string rule ?─) 'face face))))

(defun octocat-diff--reply-head (reply)
  "Return the line leading into REPLY from a bubble on its box's edge."
  (concat (propertize "  ○── " 'face (octocat-diff--edge-face reply))
          (octocat-diff--comment-head reply)))

(defun octocat-diff--bar (comment &optional indent)
  "Return the box edge before a body line of COMMENT, then INDENT."
  (concat (propertize "  │ " 'face (octocat-diff--edge-face comment)) indent))

(defun octocat-diff--spacer (root)
  "Return the box edge alone, a row between the comments of ROOT's thread."
  (propertize "  │" 'face (octocat-diff--edge-face root)))

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
   (list (propertize "  └─" 'face (octocat-diff--edge-face comment)))))

(defun octocat-diff--timeline (comments raw width)
  "Return COMMENTS, on no line of the diff, as a timeline, without newline.
With nothing to enclose, they are drawn as the PR timeline's comments,
a bullet then the body on a rail.  RAW and WIDTH are as for
`octocat-diff--comment-lines'."
  (let ((rail (propertize "  │ " 'face 'octocat-dimmed)))
    (mapconcat (lambda (c)
                 (concat (propertize "  ● " 'face 'octocat-dimmed)
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

(defun octocat-diff--segments (patch path index)
  "Return the unified diff PATCH as segments, see \"Patch text\" above.
That is a list of strings, runs of lines without final newline, and
threads (ROOT . REPLIES), each placed right after the diff line it is
on, see `octocat-diff--walk'; the threads on the whole file come
first.  PATH is the file's, whose major mode highlights the code, see
`octocat-diff--lines'.  INDEX is the comment index of the file, see
`octocat-diff--index'.  A line is cut at `octocat--max-line-length',
see `octocat--clip-line'."
  (let ((lines (octocat-diff--lines patch path))
        (out   (reverse (nth 2 index)))
        run)
    (cl-flet ((flush ()
                (when run
                  (push (mapconcat #'identity (nreverse run) "\n") out)
                  (setq run nil))))
      ;; Diff lines are not indented, so they copy out as a valid patch.
      (octocat-diff--walk
       patch index
       (lambda (_line placed anchor)
         (let ((line (octocat--clip-line (pop lines) octocat--max-line-length)))
           (push (if anchor (propertize line 'octocat-diff-line (cons path anchor)) line)
                 run))
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


;;;; Threads
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
         (bottom   (octocat-diff--tag (propertize "  └─" 'face (octocat-diff--edge-face root))
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


;;;; Commenting
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

(defun octocat-diff--range (anchors)
  "Return the range a comment on the lines of ANCHORS is on, a plist.
It has :path, :line and :side, the last line's, and for more than one
line :start-line and :start-side; or :path and :file for a file's
heading alone.  A range across files or hunks signals a `user-error',
as GitHub rejects one across hunks."
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


;;;; Components

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
                                    (octocat-tree--blob-content data) width)))
                        ;; Under the image: on its line, the underline
                        ;; would cross it at the text's baseline.
                        (if last image
                          (concat image "\n" (octocat-diff--underline-last "" width))))))))
    (pcase (octocat-vui-snapshot-status snap)
      ('pending (vui-text (octocat-vui-skeleton '(("" 24)))))
      ('error   (vui-text (octocat-vui-error-text snap) :face 'error))
      (_        (vui-text text)))))

(defun octocat-diff--file (repo file comments bulk raw width last)
  "Return one changed FILE (a files-endpoint hash-table) of REPO.
Its inline COMMENTS are placed in its diff.  It is folded unless BULK,
as for `octocat-vui-fold', says otherwise.  An image added or modified
unfolds to the image, see `octocat-diff--image', but only by its own
RET: \"Expand all\" leaves it folded, so no image is fetched unasked.
Another file without
a patch is just its heading, which says why, see
`octocat-diff--no-diff-note'.  RAW and WIDTH
are as for `octocat-diff--comment-lines'.  Unless LAST, the file being
the last one, its diff ends underlined, see
`octocat-diff--underline-last'."
  (let* ((filename (or (gethash "filename" file) ""))
         (status   (or (gethash "status" file) "modified"))
         (patch    (let ((p (gethash "patch" file)))
                     (and (stringp p) (not (string-empty-p p)) p)))
         (changes  (or (gethash "changes" file) 0))
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
                                         'face 'octocat-dimmed)))))
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
      (vui-text (concat "  " title
                        (when-let* ((note (octocat-diff--no-diff-note status changes)))
                          (propertize (concat "  " note) 'face 'octocat-dimmed)))))
     (t
      (vui-component 'octocat-vui-fold
        :key (intern filename)
        :bulk bulk
        :header (lambda (open toggle)
                  (octocat-vui-fold-header "" open toggle title
                                           '("RET: show diff" . "RET: hide diff")))
        :deps (list patch comments raw width last)
        :prepare (lambda ()
                   (octocat-diff--body (octocat-diff--segments
                                        patch filename (octocat-diff--index comments))
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

(vui-defcomponent octocat-diff--files (repo files by-path hide fits raw width underline)
  "The Files section: FILES of REPO with the review comments BY-PATH, folded.
They start unfolded when FITS, the whole diff fitting in the window.
HIDE leaves the comments out.  RAW and WIDTH are as for
`octocat-diff--comment-lines'; UNDERLINE underlines the heading across
WIDTH, but for a page whose tab row heads the section.  The heading's
\"Expand all\" button unfolds or folds every file, and its switch of the
comments, there when the diff shows some, runs
`octocat-diff-toggle-comments'."
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
                                       (eq f (aref files (1- (length files))))))
                 (lambda (f) (gethash "filename" f)))))))

(defun octocat-diff-files-section (repo files by-path hide raw width &optional underline)
  "Return the vnode of the Files section: the heading and one entry per file.
FILES is REPO's files vector and BY-PATH the review comments by file path,
left out when HIDE.
Files start folded, unless the whole diff fits in the window.  The
comments are markdown, rendered unless RAW, to fit WIDTH columns.
UNDERLINE underlines the heading across WIDTH."
  (vui-component 'octocat-diff--files
    :repo repo
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

(provide 'octocat-diff)
;;; octocat-diff.el ends here
