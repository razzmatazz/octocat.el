;;; module-graph.el --- Draw octocat's module graph into docs/architecture.md  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run by `make update-architecture-md', which rewrites the parts of
;; docs/architecture.md between `<!-- module-graph -->' and
;; `<!-- /module-graph -->', and between `<!-- module-list -->' and
;; `<!-- /module-list -->', and by `make lint', given `check', which
;; exits 1 when they are out of date instead.
;;
;; An edge is a `(require ...)' of another module or of a package in
;; octocat.el's Package-Requires: solid at top level, dashed when
;; inside a function, so loaded only when it runs.  A feature counts
;; as package P's when it is P or starts with P-, as vui-components
;; does; one Emacs ships, such as cl-lib, is left out.  Every require
;; is drawn, even one a longer path implies, so the graph shows how
;; tangled the modules are.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst module-graph-doc "docs/architecture.md")

(defun module-graph--packages ()
  "Return the packages octocat.el's Package-Requires names, but Emacs."
  (with-temp-buffer
    (insert-file-contents "octocat.el")
    (re-search-forward "^;; Package-Requires: \\(.*\\)")
    (delete "emacs" (mapcar (lambda (dep) (symbol-name (car dep)))
                            (read (match-string 1))))))

(defun module-graph--node (feature packages)
  "Return the graph node FEATURE belongs to, or nil if none.
PACKAGES are the external packages, as `module-graph--packages' gives."
  (if (string-prefix-p "octocat" feature)
      feature
    (seq-find (lambda (p) (or (equal feature p)
                              (string-prefix-p (concat p "-") feature)))
              packages)))

(defun module-graph--requires (form top packages)
  "Return the nodes FORM requires, as (NODE . TOP) pairs.
TOP is non-nil when FORM is a top-level form.  PACKAGES are as
`module-graph--node' takes."
  (cond
   ((and (eq (car-safe form) 'require)
         (eq (car-safe (cadr form)) 'quote))
    (when-let* ((node (module-graph--node (symbol-name (cadr (cadr form)))
                                          packages)))
      (list (cons node top))))
   ((consp form)
    (let (acc)
      (while (consp form)
        (setq acc (nconc acc (module-graph--requires (car form) nil packages))
              form (cdr form)))
      acc))))

(defun module-graph--read (file packages)
  "Return (NAME SUMMARY HARD LAZY) for FILE.
HARD and LAZY are the nodes it requires at top level and inside
functions.  PACKAGES are as `module-graph--node' takes."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((name (file-name-base file))
          (summary (and (looking-at ";;; [^ ]+ --- \\(.*?\\)  -\\*-")
                        (match-string 1)))
          hard lazy form)
      (while (setq form (condition-case nil (read (current-buffer))
                          (end-of-file nil)))
        (pcase-dolist (`(,node . ,top)
                       (module-graph--requires form t packages))
          (if top (cl-pushnew node hard :test #'equal)
            (cl-pushnew node lazy :test #'equal))))
      (list name summary (sort hard #'string<)
            (sort (cl-set-difference lazy hard :test #'equal) #'string<)))))

(defun module-graph--id (name)
  "Return a mermaid node id for module or package NAME."
  (string-replace "-" "_" name))

(defun module-graph--mermaid (modules packages)
  "Return the mermaid flowchart of MODULES, as `module-graph--read' gives.
PACKAGES, the external packages, are drawn rounded."
  (concat
   "```mermaid\nflowchart TD\n"
   (mapconcat (lambda (m)
                (format "  %s[%s]\n" (module-graph--id (car m)) (car m)))
              modules "")
   (mapconcat (lambda (p) (format "  %s(%s)\n" (module-graph--id p) p))
              packages "")
   (mapconcat
    (pcase-lambda (`(,name ,_ ,hard ,lazy))
      (concat
       (mapconcat (lambda (dep)
                    (format "  %s --> %s\n" (module-graph--id name)
                            (module-graph--id dep)))
                  hard "")
       (mapconcat (lambda (dep)
                    (format "  %s -.-> %s\n" (module-graph--id name)
                            (module-graph--id dep)))
                  lazy "")))
    modules "")
   "```\n"))

(defun module-graph--list (modules)
  "Return the markdown table of MODULES, as `module-graph--read' gives."
  (concat "| Module | What it is | Requires |\n|---|---|---|\n"
          (mapconcat
           (pcase-lambda (`(,name ,summary ,hard ,lazy))
             (format "| `%s` | %s | %s |\n" name summary
                     (string-join
                      (append (mapcar (lambda (d) (format "`%s`" d)) hard)
                              (mapcar (lambda (d) (format "`%s` (lazily)" d))
                                      lazy))
                      ", ")))
           modules "")))

(defun module-graph--replace (text marker content)
  "Return TEXT with what lies between MARKER's comments replaced by CONTENT."
  (let ((re (format "\\(<!-- %s -->\n\\)\\(?:.\\|\n\\)*?\\(<!-- /%s -->\\)"
                    marker marker)))
    (unless (string-match re text)
      (error "%s: no <!-- %s --> ... <!-- /%s --> block"
             module-graph-doc marker marker))
    (replace-match (concat "\\1" (string-replace "\\" "\\\\" content) "\\2")
                   t nil text)))

(let* ((packages (module-graph--packages))
       (modules (mapcar (lambda (file) (module-graph--read file packages))
                        (directory-files default-directory t
                                         "\\`octocat.*\\.el\\'")))
       (old (with-temp-buffer
              (insert-file-contents module-graph-doc)
              (buffer-string)))
       (new (module-graph--replace
             (module-graph--replace old "module-graph"
                                    (module-graph--mermaid modules packages))
             "module-list" (module-graph--list modules))))
  (cond
   ((equal old new))
   ((member "check" command-line-args-left)
    (message "%s is out of date: run make update-architecture-md"
             module-graph-doc)
    (kill-emacs 1))
   (t (with-temp-file module-graph-doc (insert new)))))

;;; module-graph.el ends here
