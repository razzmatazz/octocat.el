;;; octocat-fontify-tests.el --- ERT tests for octocat-fontify.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-fontify-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(defun octocat-fontify-tests--faces (text)
  "The distinct faces in TEXT."
  (let (faces (pos 0))
    (while (< pos (length text))
      (when-let* ((f (get-text-property pos 'face text)))
        (cl-pushnew f faces :test #'equal))
      (setq pos (next-single-property-change pos 'face text (length text))))
    faces))

(defun octocat-fontify-tests--elisp (size)
  "Elisp of about SIZE characters."
  (let ((form "(defun foo (x) \"Doc.\" (let ((y 1)) (+ x y)))\n"))
    (apply #'concat (make-list (1+ (/ size (length form))) form))))

(ert-deftest octocat-fontify-test-set-mode ()
  "A file at the root matches an `auto-mode-alist' pattern anchored on \"/\"."
  (let ((auto-mode-alist '(("/Rootfile\\'" . emacs-lisp-mode))))
    (with-temp-buffer
      (octocat-fontify-set-mode "Rootfile")
      (should (eq major-mode 'emacs-lisp-mode)))))

(ert-deftest octocat-fontify-test-set-mode-no-native-fences ()
  "Fences of a Markdown file are not highlighted in their own languages."
  (with-temp-buffer
    (octocat-fontify-set-mode "README.md")
    (should (local-variable-p 'markdown-fontify-code-blocks-natively))
    (should-not (symbol-value 'markdown-fontify-code-blocks-natively))))

(ert-deftest octocat-fontify-test-plain-text ()
  "Plain text comes back as it was."
  (let ((content "hello world\n"))
    (should (equal-including-properties (octocat-fontify "plain.txt" content) content))))

(ert-deftest octocat-fontify-test-faces-only ()
  "Elisp comes back with its faces, and no other property."
  (let ((result (octocat-fontify "foo.el" ";; hello\n(defun foo () nil)\n")))
    (should (member 'font-lock-comment-face (octocat-fontify-tests--faces result)))
    (should (equal (seq-uniq (cl-loop for (_ _ props) in (object-intervals result)
                                      append (cl-loop for (k _) on props by #'cddr collect k)))
                   '(face)))))

(ert-deftest octocat-fontify-test-async-small-here ()
  "A small text is highlighted here, before the call returns."
  (let ((octocat-async--log nil) got)
    (should-not (octocat-fontify-async "foo.el" "(defun foo () nil)\n"
                                       (lambda (v) (setq got v))))
    (should (member 'font-lock-keyword-face (octocat-fontify-tests--faces got)))
    (should (eq (aref (car octocat-async--log) 4) 'in-thread))))

(defmacro octocat-fontify-tests--with-worker (&rest body)
  "Run BODY with the worker's state fresh, and the worker stopped after."
  (declare (indent 0))
  `(let ((octocat-async--off nil)
         (octocat-async--failures 0)
         (octocat-async--worker nil)
         (octocat-async--worker-info nil)
         (octocat-async--queue nil)
         (octocat-async--current nil)
         (octocat-async--idle-timer nil)
         (octocat-async--log nil))
     (unwind-protect (progn ,@body)
       (when octocat-async--idle-timer (cancel-timer octocat-async--idle-timer))
       (octocat-async--stop))))

(defun octocat-fontify-tests--wait (pred)
  "Wait until PRED returns non-nil, at most 20 s; return its value."
  (let ((end (+ (float-time) 20)))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.01))
    (funcall pred)))

(ert-deftest octocat-fontify-test-async-large-in-worker ()
  "A large text is highlighted in the worker, as here."
  (octocat-fontify-tests--with-worker
    (let ((text (octocat-fontify-tests--elisp 30000)) got)
      (should (octocat-fontify-async "foo.el" text (lambda (v) (setq got v))))
      (should-not got)
      (should (octocat-fontify-tests--wait (lambda () got)))
      (should (eq (aref (car octocat-async--log) 4) 'ok))
      (should (equal-including-properties got (octocat-fontify "foo.el" text))))))

(vui-defcomponent octocat-fontify-tests--viewer (path text)
  "Shows TEXT, highlighted for PATH by `octocat-vui-use-fontified'."
  :render
  (vui-text (or (octocat-vui-use-fontified path text) text)))

(ert-deftest octocat-fontify-test-hook ()
  "A page shows a small text highlighted at once, a large one once the
worker has highlighted it, and cancels the job of a text it no longer
shows."
  (octocat-fontify-tests--with-worker
    (let ((vui-render-delay nil)
          (buf (get-buffer-create "*octocat-fontify-test*"))
          (large (octocat-fontify-tests--elisp 30000)))
      (cl-flet ((faces () (with-current-buffer buf
                            (octocat-fontify-tests--faces (buffer-string))))
                (show (text) (vui-mount (vui-component 'octocat-fontify-tests--viewer
                                          :path "foo.el" :text text)
                                        "*octocat-fontify-test*")))
        (unwind-protect
            (progn
              (with-current-buffer buf (octocat-page-mode))
              (show "(defun foo () nil)\n")
              (should (faces))
              (show large)
              (should-not (faces))
              (should (octocat-fontify-tests--wait #'faces))
              ;; A job whose text is gone is dropped, its callback not run.
              (show (concat large ";; more\n"))
              (show "plain\n")
              (should (octocat-fontify-tests--wait
                       (lambda () (memq 'dropped (mapcar (lambda (e) (aref e 4))
                                                         octocat-async--log)))))
              (should-not (faces)))
          (kill-buffer buf))))))

(provide 'octocat-fontify-tests)
;;; octocat-fontify-tests.el ends here
