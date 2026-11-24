;;; octocat-fontify.el --- Highlight a file's text as its major mode does  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
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

;; A repository file's text highlighted as its major mode would, in a
;; scratch buffer, for the file viewer, blame and diffs.

;;; Code:

;; From markdown-mode, when installed.
(defvar markdown-fontify-code-blocks-natively)

(defun octocat-fontify-set-mode (path)
  "Set the current buffer's major mode as for repository file PATH.
PATH is relative to the repository root.  Mode hooks are delayed."
  ;; Rooted, as some patterns, such as Dockerfile's, need a "/" before
  ;; the name.
  (with-demoted-errors "Octocat: cannot highlight: %S"
    (let ((buffer-file-name (concat "/" path)))
      (delay-mode-hooks (set-auto-mode))))
  ;; markdown-mode finds each fence's mode by asking tree-sitter for a
  ;; grammar, tens of ms a fence when none is installed.
  (setq-local markdown-fontify-code-blocks-natively nil))

(defun octocat-fontify-faces-only (text)
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

(defun octocat-fontify (path text)
  "Return TEXT highlighted as the major mode of repository file PATH would.
It has no property but its faces, see `octocat-fontify-faces-only'."
  (with-temp-buffer
    (insert text)
    (octocat-fontify-set-mode path)
    ;; A mode's broken font-lock rules should not lose the file's text.
    (with-demoted-errors "Octocat: cannot highlight: %S" (font-lock-ensure))
    (octocat-fontify-faces-only (buffer-string))))

(provide 'octocat-fontify)
;;; octocat-fontify.el ends here
