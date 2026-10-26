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
(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)


;;;; Faces

(defface octocat-commit-file-modified
  '((t :inherit default))
  "Face for a modified file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-added
  '((t :inherit diff-added))
  "Face for an added file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-removed
  '((t :inherit diff-removed))
  "Face for a removed file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-renamed
  '((t :inherit octocat-branch))
  "Face for a renamed file in the commit view."
  :group 'octocat)

(defface octocat-diff-hunk-heading
  '((t :inherit diff-header))
  "Face for a diff hunk header line."
  :group 'octocat)


;;;; File status

(defun octocat-diff--file-face (status)
  "Return a face for a file with given STATUS string."
  (cond ((equal status "added")    'octocat-commit-file-added)
        ((equal status "removed")  'octocat-commit-file-removed)
        ((equal status "renamed")  'octocat-commit-file-renamed)
        (t                         'octocat-commit-file-modified)))

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
         (bar    (propertize "  │ " 'face 'octocat-dimmed)))
    (append
     (list (concat (propertize "  ┌─ " 'face 'octocat-dimmed)
                   (propertize author 'face 'octocat-pr-author)
                   (propertize (concat "  " date) 'face 'octocat-dimmed)))
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
gets the line, its face (nil for context) and the list of comments
placed right after it, found by tracking the right-side line number,
from the `@@' headers, and the 1-based position in the diff.  A comment
on no line of PATCH, as an outdated one, is placed nowhere."
  (let ((by-line (car index))
        (by-pos  (cdr index))
        (right 0)
        (pos   0)
        (lines (split-string patch "\n")))
    (when (equal (car (last lines)) "")
      (setq lines (butlast lines)))
    (cl-flet ((at (key table) (cdr (assq key table))))
      (dolist (raw lines)
        (cl-incf pos)
        (cond
         ((string-prefix-p "@@" raw)
          (when (string-match "@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw)
            (setq right (string-to-number (match-string 1 raw))))
          (funcall fn raw 'octocat-diff-hunk-heading (at pos by-pos)))
         ;; Deleted: only in the old file, so the right line stays.
         ((string-prefix-p "-" raw)
          (funcall fn raw 'diff-removed (at pos by-pos)))
         (t
          (funcall fn raw (and (string-prefix-p "+" raw) 'diff-added)
                   (append (at right by-line) (at pos by-pos)))
          (cl-incf right)))))))

(defun octocat-diff--placed-count (patch comments)
  "Return how many of COMMENTS, on the file of PATCH, are placed in its diff."
  (let ((n 0))
    (octocat-diff--walk patch (octocat-diff--index comments)
                        (lambda (_line _face placed) (cl-incf n (length placed))))
    n))

(defun octocat-diff--patch-text (patch index raw width)
  "Return the unified diff PATCH as a propertized string, without final newline.
INDEX is the comment index of the file, see `octocat-diff--index'.  RAW
and WIDTH are as for `octocat-diff--comment-lines'.  Each comment is
placed right after the diff line it is on, see `octocat-diff--walk'.
A line is cut at `octocat--max-line-length', see `octocat--clip-line'."
  (let (out)
    ;; Diff lines are not indented, so they copy out as a valid patch.
    (octocat-diff--walk
     patch index
     (lambda (line face placed)
       (push (octocat--clip-line (if face (propertize line 'face face) line)
                                 octocat--max-line-length)
             out)
       (dolist (c placed)
         (dolist (l (octocat-diff--comment-lines c raw width))
           (push l out)))))
    (mapconcat #'identity (nreverse out) "\n")))


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
                           (propertize filename 'face (octocat-diff--file-face status))
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
                     patch (octocat-diff--index comments) raw width)))))))

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

(defvar-local octocat-diff--hide-comments t
  "Non-nil leaves the inline comments out of this page's diff.
They start hidden, so the diff reads uninterrupted.")

(defun octocat-diff-toggle-comments ()
  "Show or hide the inline comments in the diff of this page."
  (interactive)
  (setq octocat-diff--hide-comments (not octocat-diff--hide-comments))
  (octocat-vui-update-page :hide-comments octocat-diff--hide-comments))

(vui-defcomponent octocat-diff--files (files by-path hide fits raw width)
  "The Files section: FILES with the review comments BY-PATH, folded.
They start unfolded when FITS, the whole diff fitting in the window.
HIDE leaves the comments out.  RAW and WIDTH are as for
`octocat-diff--comment-lines'.  The heading's \"Expand all\" button
unfolds or folds every file, and its \"Show comments (N)\" button, there
when the diff shows some comment, runs `octocat-diff-toggle-comments'."
  :state ((bulk (and fits (cons 0 t))))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback () (vui-set-state :bulk (and fits (cons 0 t))))))
         (heading (vui-text (propertize (format "Files (%d)" (length files))
                                        'face 'octocat-section-heading)))
         ;; Only those the diff places: an outdated comment's line is gone.
         (placed  (vui-use-memo (files by-path)
                    (cl-loop for f across files
                             for patch = (gethash "patch" f)
                             for comments = (cdr (assoc (gethash "filename" f) by-path))
                             when (and comments (stringp patch))
                             sum (octocat-diff--placed-count patch comments)))))
    (vui-vstack
     (if (cl-some (lambda (f) (stringp (gethash "patch" f))) files)
         (apply #'vui-hstack :spacing 2
                heading
                (octocat-vui-expand-all-button
                 bulk (vui-async-callback (v) (vui-set-state :bulk v)))
                (and (> placed 0)
                     (list (vui-button (format "%s comments (%d)" (if hide "Show" "Hide") placed)
                             :face 'octocat-dimmed
                             :key 'hide-comments
                             :help-echo (octocat--key-help
                                         #'octocat-diff-toggle-comments
                                         (if hide
                                             "show the comments in the diff"
                                           "hide the comments in the diff"))
                             :on-click #'octocat-diff-toggle-comments))))
       heading)
     (if (zerop (length files))
         (vui-text "  (no files changed)" :face 'octocat-dimmed)
       (vui-list (append files nil)
                 (lambda (f)
                   (octocat-diff--file f (and (not hide)
                                              (cdr (assoc (gethash "filename" f) by-path)))
                                       bulk raw width))
                 (lambda (f) (gethash "filename" f)))))))

(defun octocat-diff-files-section (files by-path hide raw width)
  "Return the vnode of the Files section: the heading and one entry per file.
FILES is the files vector and BY-PATH the review comments by file path,
left out when HIDE.
Files start folded, unless the whole diff fits in the window.  The
comments are markdown, rendered unless RAW, to fit WIDTH columns."
  (vui-component 'octocat-diff--files
    :files files
    :by-path by-path
    :hide hide
    :raw raw
    :width width
    :fits (<= (octocat-diff--line-count files) (octocat-vui-window-height))))

(defun octocat-diff-comments-section (label comments raw width)
  "Return the vnode of the comments section headed LABEL, e.g. \"Comments\".
COMMENTS is the sync snapshot of the comments.  Inline ones are in the
diff, so only counted here; the others are boxed like them.  RAW and
WIDTH are as for `octocat-diff--comment-lines'."
  (let* ((status  (octocat-vui-snapshot-status comments))
         (all     (plist-get comments :data))
         (general (seq-remove (lambda (c) (octocat--nonempty (gethash "path" c))) all))
         (inline  (- (length all) (length general)))
         (noun    (downcase (string-remove-suffix "s" label))))
    (apply #'vui-vstack
           (vui-text (propertize (if (eq status 'ready)
                                     (format "%s (%d)" label (length all))
                                   label)
                                 'face 'octocat-section-heading))
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
