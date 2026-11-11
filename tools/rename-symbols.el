;;; rename-symbols.el --- Rename Elisp symbols across files  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Renames whole symbols, by Emacs Lisp's own syntax table, so that
;; `octocat--fetch-run' leaves `octocat--fetch-run-annotations' alone.
;; Code, docstrings and comments alike: a docstring's `quoted' symbol
;; is the same name.  Lines it lengthens may need `make format' or a
;; rewrap after.
;;
;;   emacs -Q --batch -l tools/rename-symbols.el OLD=NEW ... -- FILE ...

;;; Code:

(defun rename-symbols--file (file renames)
  "Apply RENAMES, an alist of (OLD . NEW), to FILE; return the count."
  (let ((count 0))
    (with-temp-buffer
      (insert-file-contents file)
      (with-syntax-table emacs-lisp-mode-syntax-table
        (pcase-dolist (`(,old . ,new) renames)
          (goto-char (point-min))
          (while (re-search-forward (concat "\\_<" (regexp-quote old) "\\_>") nil t)
            (replace-match new t t)
            (setq count (1+ count)))))
      (when (> count 0)
        (write-region nil nil file nil 'silent)))
    count))

(let* ((args    command-line-args-left)
       (sep     (member "--" args))
       (renames (mapcar (lambda (a)
                          (let ((parts (split-string a "=")))
                            (unless (= (length parts) 2)
                              (error "Not OLD=NEW: %s" a))
                            (cons (car parts) (cadr parts))))
                        (seq-take args (- (length args) (length sep)))))
       (files   (cdr sep)))
  (dolist (file files)
    (let ((n (rename-symbols--file file renames)))
      (when (> n 0) (message "%s: %d" file n))))
  (setq command-line-args-left nil))

;;; rename-symbols.el ends here
