;;; check-declare.el --- Check every `declare-function' in octocat  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run by `make lint', through `eldev exec', so that the files of the
;; dependencies, Evil's too, are found and checked against.  Exits 1 when
;; a declaration names the wrong file or arglist: the byte-compiler trusts
;; them, and MELPA's review runs `check-declare' too.

;;; Code:

(require 'check-declare)

(when (apply #'check-declare-files
             (directory-files default-directory t "\\`octocat.*\\.el\\'"))
  (kill-emacs 1))

;;; check-declare.el ends here
