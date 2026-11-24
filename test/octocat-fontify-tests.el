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

(ert-deftest octocat-fontify-test-in-steps ()
  "Highlighting a slice a step gives what highlighting at once does,
a string spanning slices too."
  (let ((octocat-fontify--slice 40)
        (text (concat ";; A file.\n"
                      (apply #'concat (make-list 10 "(defun foo () \"Doc\n\nmore.\" nil)\n"))
                      "(defvar x 1)")))
    (let ((step (octocat-fontify-in-steps "foo.el" text)) (steps 0))
      (while (functionp step)
        (setq step (funcall step) steps (1+ steps)))
      (should (> steps 3))
      (should (equal-including-properties step (octocat-fontify "foo.el" text))))))

(vui-defcomponent octocat-fontify-tests--viewer (path text)
  "Shows TEXT, highlighted for PATH by `octocat-vui-use-fontified'."
  :render
  (vui-text (or (octocat-vui-use-fontified path text) text)))

(ert-deftest octocat-fontify-test-hook ()
  "A page shows a short text highlighted in the render that shows it, a
long one plain until Emacs is idle."
  (let ((vui-render-delay nil)
        (octocat-vui--idle-jobs nil)
        (octocat-vui--idle-timer nil)
        (long (apply #'concat (make-list 300 "(defun foo () nil)\n")))
        (buf (get-buffer-create "*octocat-fontify-test*")))
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
            (show "plain\n")
            (should-not (faces))
            (should (> (length long) octocat-vui--fontify-now))
            (show long)
            (should-not (faces))
            (octocat-vui-idle-flush)
            (should (faces)))
        (when octocat-vui--idle-timer (cancel-timer octocat-vui--idle-timer))
        (kill-buffer buf)))))

(provide 'octocat-fontify-tests)
;;; octocat-fontify-tests.el ends here
