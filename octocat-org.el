;;; octocat-org.el --- Turn org text into GitHub markdown  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Turns an org file, such as a README.org, into GitHub markdown for
;; `octocat-markdown' to render.  This module has no dependencies, not
;; even on Org: like GitHub's own, it reads only the org READMEs use,
;; and nothing in it can run code, unlike Org's exporter (macros,
;; #+INCLUDE, babel).
;;
;; Converted: headings, #+TITLE, src, example, quote and HTML blocks,
;; fixed-width lines, tables, lists with checkboxes and descriptions,
;; rules, links, emphasis and verbatim.  Other keywords, comments and
;; drawers are dropped; anything else passes through as text.
;;
;; The one entry point is `octocat-org-to-markdown'.

;;; Code:

(require 'seq)
(require 'subr-x)

(defun octocat-org--emphasis-end (line marker start)
  "Return where emphasis by MARKER opened before START in LINE closes, or nil.
The body may not start or end with whitespace, and the closing marker
must be followed by the end of LINE or punctuation, as Org has it."
  (and (< start (length line))
       (not (memq (aref line start) '(?\s ?\t)))
       (let ((end start) found)
         (while (and (not found)
                     (setq end (string-search (char-to-string marker) line (1+ end))))
           (when (and (not (memq (aref line (1- end)) '(?\s ?\t)))
                      (or (= (1+ end) (length line))
                          (string-match-p "[-[:space:].,:!?;'\")}\\[]"
                                          (string (aref line (1+ end))))))
             (setq found end)))
         found)))

(defun octocat-org--url (url)
  "Return org link target URL as a markdown link target.
A file: link becomes relative, as markdown's are; spaces are escaped."
  (string-replace " " "%20" (string-remove-prefix "file:" url)))

(defun octocat-org--image-p (url)
  "Return non-nil when URL names an image, by its extension."
  (string-match-p "\\.\\(?:png\\|jpe?g\\|gif\\|svg\\|webp\\)\\'" (downcase url)))

(defun octocat-org--link (url desc)
  "Return the markdown of an org link to URL, described by DESC or nil."
  (let ((target (octocat-org--url url)))
    (cond ((and desc (octocat-org--image-p desc))
           (format "[![](%s)](%s)" (octocat-org--url desc) target))
          (desc (format "[%s](%s)" (octocat-org--inline desc) target))
          ((octocat-org--image-p target) (format "![](%s)" target))
          (t (format "[%s](%s)" (string-remove-prefix "file:" url) target)))))

(defun octocat-org--inline (line)
  "Return the org markup within LINE, links and emphasis, as markdown."
  (let ((i 0) (n (length line)) out)
    (while (< i n)
      (let ((c (aref line i)))
        (cond
         ((and (eq c ?\[)
               (eq (string-match "\\[\\[\\([^]]+\\)\\]\\(?:\\[\\(.+?\\)\\]\\)?\\]" line i) i))
          (push (octocat-org--link (match-string 1 line) (match-string 2 line)) out)
          (setq i (match-end 0)))
         ((and (memq c '(?* ?/ ?+ ?_ ?= ?~))
               (or (= i 0)
                   (string-match-p "[-[:space:]('\"{]" (string (aref line (1- i)))))
               (let ((end (octocat-org--emphasis-end line c (1+ i))))
                 (when end
                   (let ((body (substring line (1+ i) end)))
                     (push (pcase c
                             ((or ?= ?~) (if (string-search "`" body)
                                             (concat "`` " body " ``")
                                           (concat "`" body "`")))
                             (?* (concat "**" (octocat-org--inline body) "**"))
                             (?/ (concat "*" (octocat-org--inline body) "*"))
                             (?+ (concat "~~" (octocat-org--inline body) "~~"))
                             (?_ (concat "<u>" (octocat-org--inline body) "</u>")))
                           out)
                     (setq i (1+ end)))))))
         (t (push (string c) out)
            (setq i (1+ i))))))
    (apply #'concat (nreverse out))))

(defun octocat-org--cells (row)
  "Return the cells of table ROW, a line starting with |, trimmed."
  (mapcar #'string-trim
          (split-string (string-remove-suffix "|" (string-trim (string-trim row) "|")) "|")))

(defun octocat-org--table (rows)
  "Return the org table ROWS, its lines, as markdown table lines.
The first row is the header, as GitHub makes it; markdown has no rules
within a table, so those are dropped."
  (let* ((rows (seq-remove (lambda (r) (string-match-p "\\`[ \t]*|-" r)) rows))
         (line (lambda (cells)
                 (concat "| " (mapconcat #'octocat-org--inline cells " | ") " |"))))
    (when rows
      (let ((header (octocat-org--cells (car rows))))
        (append (list (funcall line header)
                      (concat "|" (mapconcat (lambda (_) "---|") header "")))
                (mapcar (lambda (r) (funcall line (octocat-org--cells r))) (cdr rows)))))))

(defun octocat-org--list-item (line)
  "Return list item LINE as markdown, or nil when it is not one."
  (when (string-match "\\`\\([ \t]*\\)\\([-+*]\\|[0-9]+[.)]\\)[ \t]+\\(.*\\)\\'" line)
    (let ((indent (match-string 1 line))
          (bullet (match-string 2 line))
          (rest   (match-string 3 line)))
      ;; A * at the margin is a heading.
      (unless (and (equal bullet "*") (equal indent ""))
        (let ((box (and (string-match "\\`\\[\\([ X-]\\)\\][ \t]+" rest)
                        (prog1 (if (equal (match-string 1 rest) "X") "[x] " "[ ] ")
                          (setq rest (substring rest (match-end 0)))))))
          (concat indent
                  (if (string-match-p "[0-9]" bullet)
                      (concat (substring bullet 0 -1) ".")
                    "-")
                  " " box
                  (if (string-match "\\`\\(.*?\\)[ \t]+::\\(?:[ \t]+\\(.*\\)\\)?\\'" rest)
                      (concat "**" (octocat-org--inline (match-string 1 rest)) "**"
                              (if (match-string 2 rest)
                                  (concat ": " (octocat-org--inline (match-string 2 rest)))
                                ""))
                    (octocat-org--inline rest))))))))

(defun octocat-org--fence (lang lines)
  "Return LINES, verbatim, fenced as code in language LANG or none."
  (let ((fence (if (seq-some (lambda (l) (string-search "```" l)) lines) "~~~~" "```")))
    (append (list (concat fence (or lang ""))) lines (list fence))))

(defun octocat-org-to-markdown (text)
  "Return org TEXT as GitHub markdown, for `octocat-markdown-render'."
  (let ((lines (split-string text "\n"))
        (case-fold-search t)
        out)
    (while lines
      (let ((line (pop lines)))
        (cond
         ;; A block: its lines up to the #+end_ of its kind.
         ((string-match "\\`[ \t]*#\\+begin_\\([a-z]+\\)\\(?:[ \t]+\\([^ \t]+\\)\\)?" line)
          (let* ((kind (downcase (match-string 1 line)))
                 (arg  (and (match-string 2 line) (downcase (match-string 2 line))))
                 (end  (concat "\\`[ \t]*#\\+end_" kind "\\b"))
                 body)
            (while (and lines (not (string-match-p end (car lines))))
              (push (pop lines) body))
            (pop lines)
            ;; In a block, Org escapes a leading * or #+ with a comma.
            (setq body (mapcar (lambda (l) (replace-regexp-in-string
                                            "\\`\\([ \t]*\\),\\([*,]\\|#\\+\\)" "\\1\\2" l))
                               (nreverse body)))
            (setq out
                  (append
                   (reverse
                    (pcase kind
                      ("src"     (octocat-org--fence arg body))
                      ("example" (octocat-org--fence nil body))
                      ("quote"   (mapcar (lambda (l) (concat "> " (octocat-org--inline l)))
                                         body))
                      ;; Raw HTML, set apart so markdown takes it as a block.
                      ((or "html" (and "export" (guard (equal arg "html"))))
                       `("" ,@body ""))
                      ((or "comment" "export") nil)
                      (_ (mapcar #'octocat-org--inline body))))
                   out))))
         ((string-match "\\`#\\+title:[ \t]*\\(.*\\)" line)
          (push (concat "# " (octocat-org--inline (match-string 1 line))) out))
         ;; Other keywords, and comments.
         ((string-match-p "\\`[ \t]*\\(?:#\\+[a-z_]+:\\|#\\(?: \\|\\'\\)\\)" line))
         ;; A drawer, such as :PROPERTIES:, up to its :END:.
         ((string-match-p "\\`[ \t]*:[a-z_-]+:[ \t]*\\'" line)
          (while (and lines (not (string-match-p "\\`[ \t]*:end:" (pop lines))))))
         ((string-match "\\`\\(\\*+\\)[ \t]+\\(.*?\\)\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*\\'"
                        line)
          (push (concat (make-string (min 6 (length (match-string 1 line))) ?#) " "
                        (octocat-org--inline (match-string 2 line)))
                out))
         ((string-match-p "\\`[ \t]*|" line)
          (let ((rows (list line)))
            (while (and lines (string-match-p "\\`[ \t]*|" (car lines)))
              (push (pop lines) rows))
            (setq out (append (reverse (octocat-org--table (nreverse rows))) out))))
         ;; Fixed-width lines, ": text".
         ((string-match-p "\\`[ \t]*:\\(?: \\|\\'\\)" line)
          (let ((rows (list line)))
            (while (and lines (string-match-p "\\`[ \t]*:\\(?: \\|\\'\\)" (car lines)))
              (push (pop lines) rows))
            (setq out (append (reverse (octocat-org--fence
                                        nil (mapcar (lambda (l)
                                                      (replace-regexp-in-string
                                                       "\\`[ \t]*: ?" "" l))
                                                    (nreverse rows))))
                              out))))
         ((string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
          (push "---" out))
         (t (push (or (octocat-org--list-item line) (octocat-org--inline line)) out)))))
    (string-join (nreverse out) "\n")))

(provide 'octocat-org)
;;; octocat-org.el ends here
