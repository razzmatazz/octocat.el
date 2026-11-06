;;; check-indent.el --- Check the tests' indentation as Emacs's own  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run by `make lint', through `eldev exec', so that Evil and octocat
;; load, whose `indent' declarations Emacs indents by.  Eldev lints only
;; the package's own files; this checks the tests as its elisp linter
;; checks those, and exits 1 naming each line Emacs would indent
;; otherwise.  A paren lost in an edit, and made up further on, leaves a
;; file balanced but swallows the forms in between, which then sit
;; indented as they were, outside the form they are now in.
;;
;; With OCTOCAT_FIX_INDENT set, as `make format' runs it, it reindents
;; the files instead.

;;; Code:

(require 'evil)
(require 'octocat)

;; As the Eldev file has the elisp linter indent it.
(put 'defvar-local 'lisp-indent-function 'defun)

(defun check-indent--file (file fix)
  "Report FILE's lines that Emacs indents otherwise; return non-nil if any.
With FIX, write FILE as Emacs indents it instead."
  ;; Its macros' `indent' declarations, such as a test helper's.
  (load file nil t)
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (setq indent-tabs-mode nil)
    (let ((lines (split-string (buffer-string) "\n"))
          found)
      (indent-region (point-min) (point-max))
      (when fix
        (write-region nil nil file)
        (setq lines (split-string (buffer-string) "\n")))
      (seq-do-indexed
       (lambda (line i)
         (unless (equal line (nth i lines))
           (setq found t)
           (message "%s:%d: Emacs indents it as: %s"
                    (file-relative-name file) (1+ i) (string-trim-left line))))
       (split-string (buffer-string) "\n"))
      found)))

(let ((files (directory-files "test" t "\\.el\\'"))
      (fix   (getenv "OCTOCAT_FIX_INDENT")))
  (when (seq-filter #'identity (mapcar (lambda (f) (check-indent--file f fix)) files))
    (kill-emacs 1)))

;;; check-indent.el ends here
