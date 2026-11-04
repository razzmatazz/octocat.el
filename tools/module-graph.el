;;; module-graph.el --- Draw octocat's module graph into docs/architecture.md  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run by `make update-architecture-md', which rewrites the parts of
;; docs/architecture.md between `<!-- module-graph -->' and
;; `<!-- /module-graph -->', and between `<!-- module-list -->' and
;; `<!-- /module-list -->', and by `make lint', given `check', which
;; exits 1 when they are out of date instead.
;;
;; An edge is a `(require 'octocat-...)': solid at top level, dashed
;; when inside a function, so loaded only when it runs.  Every require
;; is drawn, even one a longer path implies, so the graph shows how
;; tangled the modules are.
;;
;; `octocat-evil' requires every page it binds keys in, which would
;; double the main graph's arrows to say nothing new, so it has a graph
;; of its own, between `<!-- evil-graph -->' and `<!-- /evil-graph -->'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst module-graph-doc "docs/architecture.md")

(defconst module-graph-evil "octocat-evil")

(defun module-graph--requires (form top)
  "Return the octocat features FORM requires, as (FEATURE . TOP) pairs.
TOP is non-nil when FORM is a top-level form."
  (cond
   ((and (eq (car-safe form) 'require)
         (eq (car-safe (cadr form)) 'quote)
         (string-prefix-p "octocat" (symbol-name (cadr (cadr form)))))
    (list (cons (symbol-name (cadr (cadr form))) top)))
   ((consp form)
    (let (acc)
      (while (consp form)
        (setq acc (nconc acc (module-graph--requires (car form) nil))
              form (cdr form)))
      acc))))

(defun module-graph--read (file)
  "Return (NAME SUMMARY HARD LAZY) for FILE.
HARD and LAZY are the features it requires at top level and inside
functions."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((name (file-name-base file))
          (summary (and (looking-at ";;; [^ ]+ --- \\(.*?\\)  -\\*-")
                        (match-string 1)))
          hard lazy form)
      (while (setq form (condition-case nil (read (current-buffer))
                          (end-of-file nil)))
        (pcase-dolist (`(,feature . ,top) (module-graph--requires form t))
          (if top (cl-pushnew feature hard :test #'equal)
            (cl-pushnew feature lazy :test #'equal))))
      (list name summary (sort hard #'string<)
            (sort (cl-set-difference lazy hard :test #'equal) #'string<)))))

(defun module-graph--id (name)
  "Return a mermaid node id for module NAME."
  (string-replace "-" "_" name))

(defun module-graph--mermaid (modules)
  "Return the mermaid flowchart of MODULES, as `module-graph--read' gives."
  (concat
   "```mermaid\nflowchart TD\n"
   (mapconcat (lambda (m)
                (format "  %s[%s]\n" (module-graph--id (car m)) (car m)))
              modules "")
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

(defun module-graph--without-evil (modules)
  "Return MODULES without `module-graph-evil', nor any arrow to it."
  (delq nil
        (mapcar (pcase-lambda (`(,name ,summary ,hard ,lazy))
                  (unless (equal name module-graph-evil)
                    (list name summary
                          (remove module-graph-evil hard)
                          (remove module-graph-evil lazy))))
                modules)))

(defun module-graph--evil (modules)
  "Return the part of MODULES `module-graph-evil''s graph draws.
That is the modules requiring it, it, and the modules it requires, the
arrows of the first two kept and of the last left out."
  (let* ((evil (assoc module-graph-evil modules))
         (deps (append (nth 2 evil) (nth 3 evil))))
    (delq nil
          (mapcar
           (pcase-lambda (`(,name ,summary ,hard ,lazy))
             (cond
              ((equal name module-graph-evil) (list name summary hard lazy))
              ((or (member module-graph-evil hard) (member module-graph-evil lazy))
               (list name summary
                     (and (member module-graph-evil hard) (list module-graph-evil))
                     (and (member module-graph-evil lazy) (list module-graph-evil))))
              ((member name deps) (list name summary nil nil))))
           modules))))

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

(let* ((modules (mapcar #'module-graph--read
                        (directory-files default-directory t
                                         "\\`octocat.*\\.el\\'")))
       (old (with-temp-buffer
              (insert-file-contents module-graph-doc)
              (buffer-string)))
       (new (module-graph--replace
             (module-graph--replace
              (module-graph--replace
               old "module-graph"
               (module-graph--mermaid (module-graph--without-evil modules)))
              "evil-graph" (module-graph--mermaid (module-graph--evil modules)))
             "module-list" (module-graph--list modules))))
  (cond
   ((equal old new))
   ((member "check" command-line-args-left)
    (message "%s is out of date: run make update-architecture-md"
             module-graph-doc)
    (kill-emacs 1))
   (t (with-temp-file module-graph-doc (insert new)))))

;;; module-graph.el ends here
