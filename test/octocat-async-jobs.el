;;; octocat-async-jobs.el --- Jobs for octocat-async-tests.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Loaded by the worker the tests start, and by the tests themselves:
;; each job misbehaves as named in the worker, and in the tests' Emacs,
;; where a failed job falls back to, says it ran there.

;;; Code:

(defvar octocat-async-in-worker)

(defun octocat-async-jobs-run (what &optional value)
  "Do WHAT in the worker, returning (worker . VALUE); here return (here . VALUE)."
  (if (not octocat-async-in-worker)
      (cons 'here value)
    (pcase what
      ('echo (cons 'worker value))
      ('sleep (sleep-for 60))
      ('error (error "Failing on purpose"))
      ('crash (kill-emacs 3))
      ('unreadable (current-buffer))
      ('noise (princ "noise(\n") (cons 'worker value))
      ('message (message "Octocat test: to stderr") (cons 'worker value)))))

(provide 'octocat-async-jobs)
;;; octocat-async-jobs.el ends here
