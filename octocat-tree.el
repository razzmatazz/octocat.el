;;; octocat-tree.el --- File tree and file log browser for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6

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

;; A repository's files, as the repo page lists them, and two modes for
;; one file:
;;
;;   `octocat-tree--dir'     — one directory of the repo page, as on GitHub
;;   octocat-file-mode     — read-only file content viewer with syntax highlighting
;;   octocat-file-log-mode — commit log for a single file (git log -- <path>)
;;
;; Entry points:
;;   the repo page (`octocat-visit-repo'), which lists the root's first
;;   entries, and the tree browser (`octocat-tree-open'), the whole tree
;;   `octocat-tree-find-file' — pick any file of the ref shown (C-c C-f)
;;   `octocat-file-log-open'  — open the file commit log (C-c C-l in file mode)
;;
;; octocat-file-mode derives from `special-mode'.
;; octocat-file-log-mode derives from `vui-mode' and is rendered by
;; `octocat-file-log--page': one line per commit, carrying the commit's
;; SHA in the `octocat-file-log--sha' text property, which RET
;; (`octocat-file-log-visit') and C-c C-o (`octocat-file-log-browse') read.
;; The repo page lists the root's first entries flat, as GitHub's does;
;; RET on a directory opens the tree browser, `octocat-tree-mode', the
;; whole tree opened down to it, as GitHub's sidebar (see "Rendering —
;; tree").  Both pages are in octocat-repo.el.
;; Each line carries text properties so commands work regardless of
;; keymap precedence (e.g. under Evil):
;;
;;   octocat-tree--type      \\='dir | \\='file  — kind of entry
;;   octocat-tree--entry     <hash-table>    — the GitHub API entry object
;;   octocat-tree--activate  <function>      — what RET does on the line

;;; Code:

(require 'cl-lib)
(require 'octocat-core)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'octocat-search) ; `octocat--read-branch'
(require 'vui)
(require 'vui-components)

;; The repo page's buffer-locals, read by `octocat-tree-find-file'.
(defvar octocat-repo--repo)
(defvar octocat-repo--ref)
(defvar octocat-repo--default-branch)
(defvar octocat-repo--tracked)

(declare-function octocat-commit-open "octocat-commit" (repo sha))
(declare-function octocat-tree-open "octocat-repo" (repo &optional ref path))
(declare-function octocat-user-open "octocat-user" (login))
(declare-function octocat-vui-repo-heading "octocat-vui" (repo &optional ref here))


;;;; User options

(defcustom octocat-tree-entries 15
  "Entries of the root the repo page lists before its Browse code button.
The rest are in the whole tree, which that button and opening a
directory show.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)


;;;; Buffer-local variables — file mode

(defvar-local octocat-tree--file-repo nil
  "The \"owner/repo\" string for the file viewer buffer.")

(defvar-local octocat-tree--file-path nil
  "Relative file path being displayed in the file viewer buffer.")

(defvar-local octocat-tree--file-sha nil
  "Blob SHA for the file being displayed, or nil when unknown.")

(defvar-local octocat-tree--file-branch nil
  "Branch/ref name for the file being displayed.")


;;;; Mode: octocat-file-mode

(defvar octocat-file-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `octocat-file-mode'.")
(define-key octocat-file-mode-map (kbd "C-c C-o") #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "S-<return>") #'octocat-visit-other-window)
(define-key octocat-file-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-file-mode-map (kbd "C-c C-l") #'octocat-file-log-open)
(define-key octocat-file-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-file-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-file-mode-map (kbd "gr")      #'octocat-file-refresh)

(define-derived-mode octocat-file-mode special-mode "Octocat-File"
  "Major mode for viewing a GitHub file with syntax highlighting.

\\{octocat-file-mode-map}"
  :group 'octocat
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-refresh))


;;;; Buffer-local variables — file log mode

(defvar-local octocat-file-log--repo nil
  "The \"owner/repo\" string for the file log buffer.")

(defvar-local octocat-file-log--path nil
  "Relative file path whose commit history is being shown.")

(defvar-local octocat-file-log--branch nil
  "Ref the file log lists the commits from, or nil for the default branch.")


;;;; Mode: octocat-file-log-mode

(defvar octocat-file-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    map)
  "Keymap for `octocat-file-log-mode'.")
(define-key octocat-file-log-mode-map (kbd "q")       #'octocat-quit-window)
(define-key octocat-file-log-mode-map (kbd "RET")     #'octocat-file-log-visit)
(define-key octocat-file-log-mode-map (kbd "C-c C-o") #'octocat-file-log-browse)
(define-key octocat-file-log-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-file-log-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-file-log-mode-map (kbd "gr")      #'octocat-file-log-refresh)

(define-derived-mode octocat-file-log-mode vui-mode "Octocat-File-Log"
  "Major mode for browsing the commit history of a single file.
The buffer is rendered by vui.el; see `octocat-file-log--page'.

\\{octocat-file-log-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-log-refresh)
  (octocat--ts-eldoc-setup))


;;;; API fetch helpers

(defun octocat-tree--fetch-dir (repo sha callback)
  "Fetch the children of directory with SHA in REPO asynchronously.
Calls CALLBACK with a vector of entry hash-tables, or a cons (error . MSG)."
  (octocat--run-gh
   (format "tree-dir-%s" (substring sha 0 (min 8 (length sha))))
   (list "api"
         (format "repos/%s/git/trees/%s" repo sha))
   (lambda (output)
     (let* ((data  (json-parse-string output))
            (tree  (gethash "tree" data)))
       (if (vectorp tree)
           tree
         (error "Unexpected tree response format"))))
   callback))

(defun octocat-tree--fetch-all-files (repo sha callback)
  "Fetch the full recursive file list for REPO rooted at tree SHA.
Calls CALLBACK with an alist of (PATH . BLOB-SHA) pairs for every blob
in the tree, or a cons (error . MSG) on failure."
  (octocat--run-gh
   "tree-all-files"
   (list "api"
         (format "repos/%s/git/trees/%s?recursive=1" repo sha))
   (lambda (output)
     (let* ((data  (json-parse-string output))
            (tree  (gethash "tree" data)))
       (if (vectorp tree)
           (let (result)
             (seq-doseq (entry tree)
               (when (equal (gethash "type" entry) "blob")
                 (push (cons (gethash "path" entry)
                             (gethash "sha"  entry))
                       result)))
             (nreverse result))
         (error "Unexpected tree response format"))))
   callback))

(defun octocat-tree--fetch-file (repo sha callback)
  "Fetch the content of blob SHA in REPO asynchronously.
CALLBACK is called with the content, base64-encoded as GitHub sends it,
or a cons (error . MSG).  Encoded, it can be stored as JSON: a file need
not be text."
  (octocat--run-gh
   (format "tree-blob-%s" (substring sha 0 (min 8 (length sha))))
   (list "api"
         (format "repos/%s/git/blobs/%s" repo sha)
         "--jq" ".content")
   (lambda (output)
     ;; GitHub wraps lines at 60 chars.
     (replace-regexp-in-string "\n" "" (string-trim output)))
   callback))


(defconst octocat-tree--blob-query
  "query($owner:String!,$name:String!,$expr:String!){repository(owner:$owner,name:$name){object(expression:$expr){...on Blob{oid}}}}"
  "GraphQL query behind `octocat-tree--fetch-blob-sha'.")

(defun octocat-tree--fetch-blob-sha (repo ref path callback)
  "Fetch the blob SHA of file PATH of REPO at REF.
Calls CALLBACK with the SHA, or a cons (error . MSG)."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "blob-sha"
     (list "api" "graphql"
           "-f" (concat "query=" octocat-tree--blob-query)
           "-f" (concat "owner=" (car parts))
           "-f" (concat "name=" (cadr parts))
           "-f" (concat "expr=" ref ":" path))
     (lambda (json)
       (let* ((r   (gethash "repository"
                            (gethash "data" (json-parse-string json :null-object nil))))
              (obj (and r (gethash "object" r))))
         (or (and obj (gethash "oid" obj))
             (error "No file %s at %s" path ref))))
     callback)))


;;;; Sync resources
;;
;; Directory listings and file contents are named by tree and blob SHA,
;; which name fixed contents, so they are kept for
;; `octocat-tree--fixed-max-age'.  The tree of a directory at a ref comes
;; with its last commit, the repo page's `repo-head' resource.

(defconst octocat-tree--fixed-max-age (* 30 24 60 60)
  "Seconds to keep what a SHA names, which never changes.")

(octocat-sync-define-resource tree-dir (repo sha)
  :max-age octocat-tree--fixed-max-age
  :fetch (lambda (done) (octocat-tree--fetch-dir repo sha done)))

(octocat-sync-define-resource blob (repo sha)
  :max-age octocat-tree--fixed-max-age
  :fetch (lambda (done)
           (let ((h (make-hash-table :test #'equal)))
             ;; No SHA, no file: a page asks for one before it knows it.
             (if (null sha)
                 (funcall done (progn (puthash "base64" "" h) h))
               (octocat-tree--fetch-file
                repo sha
                (lambda (r)
                  (funcall done (if (eq (car-safe r) 'error)
                                    r
                                  (progn (puthash "base64" r h) h)))))))))

(octocat-sync-define-resource tree-files (repo sha)
  :max-age octocat-tree--fixed-max-age
  :fetch (lambda (done)
           (octocat-tree--fetch-all-files
            repo sha
            (lambda (r)
              (funcall done
                       (if (eq (car-safe r) 'error)
                           r
                         (let ((h (make-hash-table :test #'equal :size (length r))))
                           (pcase-dolist (`(,path . ,blob) r)
                             (puthash path blob h))
                           h)))))))

(defun octocat-tree--blob-content (data)
  "Return the content of a file from DATA, the `blob' resource's."
  (base64-decode-string (gethash "base64" data)))

(defun octocat-tree--load-blob (repo sha callback)
  "Call CALLBACK with the content of blob SHA in REPO, or (error . MSG).
From the store at once when there, else once fetched."
  (octocat-sync-get (list 'blob repo sha)
                    (lambda (r)
                      (funcall callback (if (eq (car-safe r) 'error)
                                            r
                                          (octocat-tree--blob-content r))))))


;;;; Syntax highlighting

(defun octocat-tree--fontify (path content)
  "Return CONTENT string with face properties from the appropriate major mode.
PATH is used only to select the mode via `auto-mode-alist'."
  (with-temp-buffer
    (insert content)
    (let ((buffer-file-name path))
      (delay-mode-hooks (set-auto-mode)))
    (ignore-errors (font-lock-ensure))
    (buffer-string)))


;;;; Rendering helpers

(defun octocat-tree--entry-line (indent name face type entry path activate)
  "Return one tree line as a vnode (no trailing newline).
INDENT is a string of leading spaces.  NAME is the file/dir name, with
any glyph before it, drawn in FACE.  TYPE is \\='dir or \\='file.
ENTRY is the API hash-table.  PATH is the entry's full repository path:
the API's own \"path\" field is only the name within its directory.
ACTIVATE is a zero-argument function run by RET on the line.

The line is not a button, so TAB does not stop on every entry: in a
long listing, walking the page's buttons would be walking its files.
The type/entry/path/activate properties span the entire line, indent
included, so `get-text-property' at `line-beginning-position' finds
them.  Commands read them rather than relying on the line's keymap, so
they keep working under Evil, whose state keymaps outrank text-property
keymaps."
  (let ((map   (make-sparse-keymap))
        (props (list 'octocat-tree--type     type
                     'octocat-tree--entry    entry
                     'octocat-tree--path     path
                     'octocat-tree--activate activate)))
    (define-key map (kbd "RET") (lambda () (interactive) (funcall activate)))
    (vui-region :keymap map
      (vui-text (apply #'propertize
                       (concat indent
                               (propertize name
                                           'face face 'mouse-face 'highlight
                                           'help-echo
                                           (if (eq type 'dir)
                                               "RET: open directory  S-RET: in other window  C-c C-o: browse on GitHub"
                                             "RET: view file  S-RET: in other window  C-c C-o: browse on GitHub")))
                       props)))))


;;;; Rendering — tree
;;
;; Two views of a ref's files, as GitHub has them.  The repo page lists
;; the root's first entries, `octocat-tree--dir'.  The tree browser shows
;; the whole tree, GitHub's sidebar: a recursion of
;; `octocat-tree--subtree', the entries of one directory, and
;; `octocat-tree--node', one entry, a directory owning whether it is
;; expanded.  Nodes are keyed by path, so a refetch keeps what is open.

(defun octocat-tree--sorted-entries (entries)
  "Return ENTRIES (a vector) as a list sorted dirs-first then alphabetically."
  (cl-sort (cl-coerce entries 'list)
           (lambda (a b)
             (let ((ta (gethash "type" a ""))
                   (tb (gethash "type" b "")))
               (cond
                ((and (equal ta "tree") (equal tb "blob")) t)
                ((and (equal ta "blob") (equal tb "tree")) nil)
                (t (string< (gethash "path" a "")
                            (gethash "path" b ""))))))))

(defun octocat-tree--join (dir name)
  "Return the path of NAME inside directory path DIR (\"\" for the root)."
  (if (string-empty-p dir) name (concat dir "/" name)))

(defun octocat-tree--parent (path)
  "Return the path of the directory containing PATH, \"\" for the root."
  (let ((dir (file-name-directory path)))
    (if dir (directory-file-name dir) "")))

(defun octocat-tree--reveals-p (path reveal)
  "Return non-nil when PATH is REVEAL or a directory on the way to it."
  (and reveal (string-prefix-p (concat path "/") (concat reveal "/"))))

(defun octocat-tree--use-focus (focus paths)
  "Move point to FOCUS once it is among PATHS, the entries listed.
A hook: call it during render."
  (let ((buf (current-buffer)))
    (vui-use-effect (focus paths)
      ;; After the render: a first mount ends at `point-min'.
      (when (and focus (member focus paths))
        (run-at-time 0 nil #'octocat-tree--jump-to buf focus))
      nil)))

(vui-defcomponent octocat-tree--dir (repo branch sha on-dir on-browse)
  "The root's entries, its tree SHA of REPO at BRANCH, as GitHub lists them.
RET on a directory calls ON-DIR with its path; on a file it opens it.
Only the first `octocat-tree-entries' show, so the README below is near;
a Browse code button after them, saying how many more there are, calls
ON-BROWSE, for the whole tree."
  :render
  (let* ((result  (octocat-vui-use-resource (list 'tree-dir repo sha) nil))
         (entries (octocat-tree--sorted-entries (plist-get result :data)))
         (shown   (if octocat-tree-entries (seq-take entries octocat-tree-entries) entries))
         (more    (- (length entries) (length shown))))
    (pcase (octocat-vui-snapshot-status result)
      ('pending (vui-text (octocat-tree--skeleton)))
      ('error   (vui-text (propertize (octocat-vui-error-text result) 'face 'error)))
      ((guard (null entries)) (vui-text (propertize "(empty)" 'face 'octocat-dimmed)))
      (_
       (vui-vstack
        (vui-list
         shown
         (lambda (entry)
           (let ((name (gethash "path" entry))
                 (sha  (gethash "sha" entry)))
             (if (equal (gethash "type" entry) "tree")
                 (octocat-tree--entry-line "" (concat name "/") 'octocat-branch 'dir entry name
                                           (lambda () (funcall on-dir name)))
               (octocat-tree--entry-line "" name 'default 'file entry name
                                         (lambda ()
                                           (octocat-tree--open-file-by-path
                                            repo branch name sha))))))
         (lambda (entry) (gethash "path" entry)))
        (vui-button (if (> more 0)
                        (format "[Browse code (%d more %s)]" more (if (= more 1) "entry" "entries"))
                      "[Browse code]")
                    :no-decoration t
                    :face 'octocat-dimmed
                    :help-echo "RET: browse the whole tree"
                    :on-click on-browse))))))

(vui-defcomponent octocat-tree--subtree
    (repo branch sha depth path reveal current focus on-dir)
  "The entries of directory PATH, tree SHA, at nesting DEPTH of the tree.
They are of REPO at BRANCH.  Directories on the way to REVEAL start
expanded, and CURRENT, the page's directory, is highlighted.  RET on a
directory toggles it and calls ON-DIR with its path; on a file it opens
it.  Point moves to FOCUS, an entry's path, once it is listed.  Unlike
the root's listing it does not fold: it is for browsing."
  :render
  (let* ((indent  (make-string (* depth 2) ?\s))
         (result  (octocat-vui-use-resource (list 'tree-dir repo sha) nil))
         (entries (octocat-tree--sorted-entries (plist-get result :data))))
    (octocat-tree--use-focus
     focus (mapcar (lambda (e) (octocat-tree--join path (gethash "path" e))) entries))
    (pcase (octocat-vui-snapshot-status result)
      ('pending (vui-text (octocat-tree--skeleton indent)))
      ('error   (vui-text (propertize (concat indent (octocat-vui-error-text result))
                                      'face 'error)))
      (_ (if (null entries)
             (vui-text (propertize (concat indent "(empty)") 'face 'octocat-dimmed))
           (vui-list entries
                     (lambda (entry)
                       (vui-component 'octocat-tree--node
                                      :repo repo :branch branch :entry entry :depth depth
                                      :parent path :reveal reveal :current current
                                      :focus focus :on-dir on-dir))
                     (lambda (entry) (gethash "path" entry))))))))

(vui-defcomponent octocat-tree--node
    (repo branch entry depth parent reveal current focus on-dir)
  "One tree ENTRY (hash-table) at nesting DEPTH, inside directory PARENT.
The other arguments are as for `octocat-tree--subtree'."
  :state ((expanded (octocat-tree--reveals-p
                     (octocat-tree--join parent (or (gethash "path" entry) ""))
                     reveal)))
  :render
  (let* ((name   (or (gethash "path" entry) ""))
         (path   (octocat-tree--join parent name))
         (sha    (or (gethash "sha" entry) ""))
         (indent (make-string (* depth 2) ?\s)))
    (if (equal (gethash "type" entry) "tree")
        (vui-fragment
         (octocat-tree--entry-line
          indent (concat (if expanded "▾ " "▸ ") name "/")
          (if (equal path current) '(octocat-section-heading octocat-branch) 'octocat-branch)
          'dir entry path
          (vui-with-async-context
            (vui-set-state :expanded (lambda (old) (not old)))
            (funcall on-dir path)))
         (when expanded
           (vui-fragment
            (vui-newline)
            (vui-component 'octocat-tree--subtree
                           :repo repo :branch branch :sha sha :depth (1+ depth)
                           :path path :reveal reveal :current current
                           :focus focus :on-dir on-dir))))
      ;; Two spaces stand for "▸ ", so names line up with directories'.
      (octocat-tree--entry-line
       indent (concat "  " name) (if (equal path current) 'octocat-section-heading 'default)
       'file entry path
       (lambda () (octocat-tree--open-file-by-path repo branch path sha))))))

(defun octocat-tree--skeleton (&optional indent)
  "Return grey bars shaped like a few tree entries, each after INDENT."
  (octocat-vui-skeleton (mapcar (lambda (n) (list (or indent "") n)) '(14 22 10 18))))


;;;; Rendering — file mode

(defun octocat-tree--insert-repo-heading (repo)
  "Insert REPO as `octocat-vui-repo-heading' draws it, in a plain buffer."
  (pcase-let ((`(,owner ,name) (split-string repo "/"))
              (link (lambda (label help action)
                      (insert-text-button label 'face '(link octocat-repo)
                                          'help-echo help 'follow-link t
                                          'action (lambda (_) (funcall action))))))
    (funcall link owner "RET: open owner page" (lambda () (octocat-user-open owner)))
    (insert (propertize "/" 'face 'octocat-repo))
    (funcall link name "RET: open repository page" (lambda () (octocat-visit-repo repo)))))

(defun octocat-tree--insert-file-header (path)
  "Insert the top of the viewer of file PATH, a rule under it.
Its line ends in a button to the repo page's tree, opened down to PATH."
  (let ((repo   octocat-tree--file-repo)
        (branch octocat-tree--file-branch))
    (when repo
      (octocat-tree--insert-repo-heading repo))
    (insert "  "
            (propertize (or branch "") 'face 'octocat-branch)
            "  "
            (or path "")
            "  ")
    (insert-text-button "[Browse tree]"
                        'face 'octocat-dimmed
                        'help-echo "RET: browse the repository's tree at this file"
                        'follow-link t
                        'action (lambda (_)
                                  (octocat-tree-open
                                   repo (unless (equal branch "HEAD") branch) path)))
    (insert "\n" (propertize (make-string 60 ?━) 'face 'octocat-dimmed) "\n")))

(defun octocat-tree--render-file-loading (path)
  "Render a loading skeleton for file PATH in the current file buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (octocat-tree--insert-file-header path)
    (insert (octocat-vui-skeleton '((30) (46) ("  " 38) ("  " 24) (12))))))

(defun octocat-tree--render-file (path content)
  "Render file PATH with fontified CONTENT in the current file buffer."
  (let* ((inhibit-read-only t)
         (fontified (octocat-tree--fontify path content)))
    (erase-buffer)
    (octocat-tree--insert-file-header path)
    (insert fontified)
    (goto-char (point-min))))


;;;; Point navigation helpers

(defun octocat-tree--type-at-point ()
  "Return the \\='octocat-tree--type symbol on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--type))

(defun octocat-tree--path-at-point ()
  "Return the full repository path of the entry on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--path))

(defun octocat-tree--activate-at-point ()
  "Return the RET action closure stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--activate))

(defun octocat-tree--entry-at-point-p ()
  "Return non-nil when the current line is a file or directory entry."
  (memq (octocat-tree--type-at-point) '(dir file)))

(defun octocat-tree--jump-to (buf path)
  "Move point in BUF, and in the windows showing it, to the entry at PATH."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (octocat-tree--goto-path path)
        (dolist (win (get-buffer-window-list buf nil t))
          (set-window-point win (point)))))))

(defun octocat-tree--goto-path (path)
  "Move point to the name of the entry with PATH, if it is shown."
  (let ((pos (save-excursion
               (goto-char (point-min))
               (catch 'found
                 (while (not (eobp))
                   (when (equal (octocat-tree--path-at-point) path)
                     (throw 'found (line-beginning-position)))
                   (forward-line 1))))))
    (when pos (goto-char pos))))


;;;; Interactive commands — tree

(defun octocat-tree-visit ()
  "Open the file or the directory at point.
On a button, such as the header's branch picker, press it: Evil's RET
binding outranks the button's own."
  (interactive)
  (if (button-at (point))
      (push-button)
    (when-let* ((activate (octocat-tree--activate-at-point)))
      (funcall activate))))

(defun octocat-tree--open-file-by-path (repo branch path sha)
  "Open the file viewer buffer for PATH (blob SHA) in REPO on BRANCH.
With SHA nil, as from a github.com link, it is looked up first."
  (let* ((buf-name (format "*%s:%s*" repo path))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-file-mode)
      (octocat-file-mode))
    (setq octocat-tree--file-repo   repo
          octocat-tree--file-path   path
          octocat-tree--file-sha    sha
          octocat-tree--file-branch branch)
    (octocat-tree--render-file-loading path)
    (octocat-file-refresh)))

(defun octocat-tree--load-files (repo ref callback)
  "Call CALLBACK with every file of REPO at REF, nil for the default branch.
They are a hash-table of path to blob SHA, from the store when there,
or (error . MSG)."
  (octocat-sync-get
   (list 'repo-head repo ref nil)
   (lambda (head)
     (if (eq (car-safe head) 'error)
         (funcall callback head)
       (octocat-sync-get (list 'tree-files repo (gethash "tree" head)) callback)))))

(defun octocat-tree-find-file ()
  "Interactively find and open a file in this repository by path.
Offers every file of the ref shown, through `completing-read', and opens
the one picked in `octocat-file-mode'.  The list is fetched once per
commit.  Works from the repo page and from a file viewer."
  (interactive)
  (pcase-let* ((`(,repo ,ref ,label)
                (cond ((derived-mode-p 'octocat-repo-mode)
                       (let ((ref (or octocat-repo--ref octocat-repo--tracked)))
                         (list octocat-repo--repo ref
                               (or ref octocat-repo--default-branch "HEAD"))))
                      ((derived-mode-p 'octocat-file-mode)
                       (list octocat-tree--file-repo octocat-tree--file-branch
                             octocat-tree--file-branch))
                      (t (user-error "Octocat: Not in a repo or file buffer"))))
               (buf (current-buffer)))
    (unless repo
      (user-error "Octocat: Buffer is not associated with a repository"))
    (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
    (octocat-tree--load-files
     repo ref
     (lambda (files)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe files) 'error)
               (message "Octocat: Error loading file list: %s" (cdr files))
             (let ((path (completing-read "Find file: " files nil t)))
               (octocat-tree--open-file-by-path
                repo label path (gethash path files))))))))))

(defun octocat-tree--entry-url (repo ref type path)
  "Return the github.com URL of the tree entry at PATH of REPO at REF.
TYPE is `file' or `dir'."
  (format "https://github.com/%s/%s/%s/%s"
          repo (if (eq type 'file) "blob" "tree") ref path))


;;;; Interactive commands — file mode

(defun octocat-file-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file viewer buffer from its blob.
The blob is fixed by its SHA, so a stored copy is shown without a fetch."
  (interactive)
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((buf    (current-buffer))
        (repo   octocat-tree--file-repo)
        (sha    octocat-tree--file-sha)
        (path   octocat-tree--file-path))
    (when (and sha (not (plist-get (octocat-sync-read (list 'blob repo sha)) :data)))
      (octocat-tree--render-file-loading path)
      (setq mode-line-process (octocat-vui-mode-line-busy ":loading")))
    (if sha
        (octocat-tree--load-blob
         repo sha
         (lambda (result)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq mode-line-process nil)
               (if (eq (car-safe result) 'error)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert (propertize
                              (format "Error loading file: %s\n" (cdr result))
                              'face 'error)))
                 (octocat-tree--render-file path result))))))
      ;; Known only by path, as from a link: look the blob up.
      (octocat-tree--render-file-loading path)
      (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
      (octocat-tree--fetch-blob-sha
       repo (or octocat-tree--file-branch "HEAD") path
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mode-line-process nil)
             (if (eq (car-safe result) 'error)
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (propertize (format "Error loading file: %s\n" (cdr result))
                                       'face 'error)))
               (setq octocat-tree--file-sha result)
               (octocat-file-refresh)))))))))

(defun octocat-file-browse ()
  "Open the current file on GitHub in the browser."
  (interactive)
  (unless (and octocat-tree--file-repo
               octocat-tree--file-branch
               octocat-tree--file-path)
    (user-error "Octocat: Buffer has no file context"))
  (let ((url (format "https://github.com/%s/blob/%s/%s"
                     octocat-tree--file-repo
                     octocat-tree--file-branch
                     octocat-tree--file-path)))
    (message "Octocat: Opening %s in browser…" octocat-tree--file-path)
    (octocat-browse-external url)))

;;;; API fetch helper — file commits

(defun octocat-tree--fetch-file-commits (repo ref path callback)
  "Fetch commit history for PATH in REPO asynchronously.
Requests up to 25 commits touching PATH, from REF back (nil for the
default branch), using the GitHub REST commits endpoint with the
\\='path\\=' filter.  Calls CALLBACK with a list of commit hash-tables,
or a cons (error . MSG) on failure."
  (octocat--run-gh
   "file-commits"
   (list "api"
         (format "repos/%s/commits?per_page=25&path=%s%s"
                 repo (url-hexify-string path)
                 (if ref (concat "&sha=" (url-hexify-string ref)) "")))
   #'octocat--parse-json-list
   callback))


(octocat-sync-define-resource file-log (repo ref path)
  :fetch (lambda (done)
           (octocat-tree--fetch-file-commits
            repo ref path
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))


;;;; Rendering — file log mode

(defun octocat-file-log--commit-line (commit)
  "Return the log line for COMMIT, a hash-table (no trailing newline).
The line shows the short SHA, date, author and subject.  The full SHA
is in the `octocat-file-log--sha' property across the whole line, which
`octocat-file-log-visit' and `octocat-file-log-browse' read: like the
tree lines, commands read a property rather than a per-line keymap, so
they keep working under Evil."
  (let* ((sha     (or (gethash "sha" commit) ""))
         (short   (substring sha 0 (min 7 (length sha))))
         (c       (gethash "commit" commit))
         (msg     (or (and c (gethash "message" c)) ""))
         (subject (car (split-string msg "\n")))
         (date-s  (or (and c
                           (let ((a (gethash "author" c)))
                             (and a (gethash "date" a))))
                      ""))
         (date    (octocat--format-ts-relative date-s))
         (author  (octocat--commit-author commit))
         (line    (concat
                   "  "
                   (propertize short 'face 'octocat-dimmed)
                   "  "
                   (propertize (format "%-14s" date) 'face 'octocat-dimmed)
                   "  "
                   (propertize (format "%-16s" (truncate-string-to-width author 16 nil ?\s "…"))
                               'face 'octocat-pr-author)
                   "  "
                   (octocat--format-title subject))))
    (add-text-properties 0 (length line)
                         (list 'octocat-file-log--sha sha
                               'mouse-face            'highlight)
                         line)
    (octocat-vui--default-help-echo
     line "RET: open commit details  C-c C-o: browse on GitHub")))

(vui-defcomponent octocat-file-log--page (repo ref path tick)
  "The file log page: a REPO and PATH header, then the commits of PATH.
They are those from REF back, nil for the default branch.  The header
leaves out the commit count until they are known.  A new TICK fetches
them again."
  :render
  (let* ((result  (octocat-vui-use-resource (list 'file-log repo ref path) tick))
         (status  (octocat-vui-snapshot-status result))
         (commits (append (plist-get result :data) nil)))
    (vui-vstack
     (vui-hstack :spacing 0
       (and repo (octocat-vui-repo-heading repo ref))
       (vui-text (concat
                  "  "
                  (propertize (or path "") 'face 'octocat-branch)
                  (when (eq status 'ready)
                    (concat "  "
                            (propertize (format "(%d commits)" (length commits))
                                        'face 'octocat-dimmed))))))
     (pcase status
       ('pending (vui-text (octocat-vui-line-skeleton "  ")))
       ('error
        (vui-text (propertize (concat "  " (octocat-vui-error-text result))
                              'face 'error)))
       (_ (if (null commits)
              (vui-text (propertize "  (no commits found)" 'face 'octocat-dimmed))
            (vui-list commits
                      (lambda (commit) (vui-text (octocat-file-log--commit-line commit)))
                      (lambda (commit) (gethash "sha" commit)))))))))

(defun octocat-file-log--sha-at-point ()
  "Return the full SHA of the commit on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-file-log--sha))


;;;; Interactive commands — file log mode

(defun octocat-file-log-open ()
  "Open the commit log browser for the file shown in the current buffer.
Works from an `octocat-file-mode' buffer."
  (interactive)
  (unless (derived-mode-p 'octocat-file-mode)
    (user-error "Octocat: Not in a file viewer buffer"))
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer has no file context"))
  (octocat-file-log-open-path octocat-tree--file-repo octocat-tree--file-branch
                              octocat-tree--file-path))

(defun octocat-file-log-open-path (repo ref path)
  "Open (or switch to) the \\='*REPO:PATH log*\\=' buffer, from REF back.
REF nil, or \"HEAD\", is the default branch."
  (let ((buf (get-buffer-create (format "*%s:%s log*" repo path)))
        (ref (unless (equal ref "HEAD") ref)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-file-log-mode)
      (octocat-file-log-mode))
    (setq octocat-file-log--repo   repo
          octocat-file-log--path   path
          octocat-file-log--branch ref)
    (octocat-file-log-refresh)))

(defun octocat-file-log-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file log buffer by re-fetching commits from the GitHub API."
  (interactive)
  (unless (and octocat-file-log--repo octocat-file-log--path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (octocat-vui-refresh-page 'octocat-file-log--page
                            (list octocat-file-log--repo octocat-file-log--branch
                                  octocat-file-log--path)
                            (list :repo octocat-file-log--repo
                                  :ref octocat-file-log--branch
                                  :path octocat-file-log--path)))

(defun octocat-file-log-visit ()
  "Open the commit detail view for the commit at point."
  (interactive)
  (when-let* ((sha (octocat-file-log--sha-at-point)))
    (octocat-commit-open octocat-file-log--repo sha)))

(defun octocat-file-log-browse ()
  "Open the commit at point on GitHub.
Away from a commit line, open the file's history page instead."
  (interactive)
  (unless (and octocat-file-log--repo octocat-file-log--path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((sha (octocat-file-log--sha-at-point)))
    (if sha
        (progn
          (message "Octocat: Opening commit %s in browser…"
                   (substring sha 0 (min 7 (length sha))))
          (octocat-browse-external (format "https://github.com/%s/commit/%s"
                                           octocat-file-log--repo sha)))
      (message "Octocat: Opening file history in browser…")
      (octocat-browse-external (format "https://github.com/%s/commits/%s/%s"
                                       octocat-file-log--repo
                                       (or octocat-file-log--branch "HEAD")
                                       octocat-file-log--path)))))


(provide 'octocat-tree)
;;; octocat-tree.el ends here
