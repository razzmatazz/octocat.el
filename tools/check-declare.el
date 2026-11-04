;;; check-declare.el --- Check every `declare-function' in octocat  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run by `make lint', through `eldev exec', so that the files of the
;; dependencies, Evil's too, are found and checked against.  Exits 1 when
;; a declaration names the wrong file or arglist: the byte-compiler trusts
;; them, and MELPA's review runs `check-declare' too.
;;
;; Exits 1 too when a declaration is redundant: it repeats one above it,
;; names its own file, or names a module the file already loads through
;; its top-level `require's, directly or not.  A `require' inside a
;; function does not count: it runs only when the function does.

;;; Code:

(require 'check-declare)
(require 'cl-lib)
(require 'subr-x)

(defun check-declare--top-requires (file)
  "Return the octocat features FILE requires at top level, as strings."
  (with-temp-buffer
    (insert-file-contents file)
    (let (features form)
      (while (setq form (condition-case nil (read (current-buffer))
                          (end-of-file nil)))
        (when (and (eq (car-safe form) 'require)
                   (eq (car-safe (cadr form)) 'quote)
                   (string-prefix-p "octocat" (symbol-name (cadr (cadr form)))))
          (push (symbol-name (cadr (cadr form))) features)))
      features)))

(defun check-declare--declarations (file)
  "Return FILE's declarations of octocat functions, as (FN MODULE LINE).
Those in comments and strings are left out."
  (with-temp-buffer
    (insert-file-contents file)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let (acc)
        (while (re-search-forward "(declare-function\\_>" nil t)
          (let ((start (match-beginning 0)))
            (unless (nth 8 (save-excursion (syntax-ppss start)))
              (goto-char start)
              (let ((form (read (current-buffer))))
                (when (and (symbolp (nth 1 form)) (stringp (nth 2 form))
                           (string-prefix-p "octocat" (nth 2 form)))
                  (push (list (nth 1 form) (nth 2 form)
                              (line-number-at-pos start))
                        acc))))))
        (nreverse acc)))))

(defun check-declare--loaded (module requires)
  "Return the modules MODULE loads, given REQUIRES, a hash of top requires."
  (let ((seen nil) (todo (gethash module requires)))
    (while todo
      (let ((m (pop todo)))
        (unless (member m seen)
          (push m seen)
          (setq todo (append (gethash m requires) todo)))))
    seen))

(defun check-declare--redundant (files)
  "Report FILES' redundant declarations; return non-nil if there are any."
  (let ((requires (make-hash-table :test #'equal))
        found)
    (dolist (file files)
      (puthash (file-name-base file) (check-declare--top-requires file)
               requires))
    (dolist (file files)
      (let* ((module (file-name-base file))
             (loaded (check-declare--loaded module requires))
             (seen nil))
        (pcase-dolist (`(,fn ,target ,line) (check-declare--declarations file))
          (let ((why (cond ((memq fn seen) "declared again")
                           ((equal target module) "declared in its own file")
                           ((member target loaded)
                            (format "`%s' is already required" target)))))
            (push fn seen)
            (when why
              (setq found t)
              (message "%s:%d: redundant `declare-function' of `%s': %s"
                       (file-name-nondirectory file) line fn why))))))
    found))

(let ((files (directory-files default-directory t "\\`octocat.*\\.el\\'")))
  (when (or (apply #'check-declare-files files)
            (check-declare--redundant files))
    (kill-emacs 1)))

;;; check-declare.el ends here
