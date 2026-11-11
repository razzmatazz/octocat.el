;;; octocat-repo.el --- Repository overview, tree, files and history for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5

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

;; A repository's code, as GitHub's Code tab has it, in four pages:
;;
;;   `octocat-repo-mode'        — the overview: the ref shown with its last
;;                                commit, the root's first files and its README
;;   `octocat-tree-mode'        — the whole tree, which RET on a directory opens
;;   `octocat-file-mode'        — one file at one ref, highlighted, rendered if
;;                                markdown or org, or its blame
;;   `octocat-commit-list-mode' — the history of the ref or of a path
;;
;; The tree browser and the commits page derive from the repo page, for
;; its state.  The file viewer's top is the tree browser's, so one reads
;; on from the other; each ref of a file has a buffer of its own.
;; `octocat-tree-find-file' (C-c C-f) finds the file shown in the local clone.
;;
;; Each line of a tree carries text properties so commands work
;; regardless of keymap precedence (e.g. under Evil):
;;
;;   octocat-tree--type      \\='dir | \\='file  — kind of entry
;;   octocat-tree--entry     <hash-table>    — the GitHub API entry object
;;   octocat-tree--activate  <function>      — what RET does on the line
;;
;; The `M-x octocat-repo' entry point is defined in octocat.el (see
;; CONTRIBUTING.md, "Entry points").

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'dom)
(require 'seq)
(require 'url-util)
(require 'octocat-core)
(require 'octocat-sync)
(require 'octocat-model)
(require 'octocat-markdown)
(require 'octocat-vui)

(require 'vui)


;;;; User options

(defcustom octocat-repo-doc-lines 20
  "Lines of the repo buffer's README shown before the rest is folded away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defcustom octocat-tree-entries 15
  "Entries of the root the repo page lists before its Browse code button.
The rest are in the whole tree, which that button and opening a
directory show.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defcustom octocat-repo-commits-page-size 25
  "Number of commits the commits page shows, and loads, at a time."
  :type 'integer
  :group 'octocat)


;;;; Buffer-local state
;;
;; Only the two identifying values survive as plain buffer-locals: they
;; are set directly by external callers (`octocat.el', `octocat-visit-repo'
;; in octocat-core.el) before `octocat-repo-refresh' is invoked.  Collapse
;; state, per-section pagination limits, and fetched data all live as vui
;; component state/hook results instead -- see the Commentary above.

(defvar-local octocat-repo--repo nil
  "The \"owner/repo\" string this buffer is tracking.")

(defvar-local octocat-repo--local-dir nil
  "Absolute path to the local clone directory, or nil when detached.
Set at buffer-open time from `default-directory' when the buffer is
opened from inside a git working tree.  Nil means the buffer was opened
in detached mode — tracking a remote repository without a local clone.")

(defvar-local octocat-repo--ref nil
  "Ref the page shows: a branch, tag or SHA, or nil to follow the clone.
Nil shows `octocat-repo--tracked', or else the default branch.
Chosen with `octocat-repo-switch-branch' or by a github.com link; kept
by `g', cleared when the page is opened anew.")

(defvar-local octocat-repo--path nil
  "The path the commits page is of, or nil for all the commits.")

(defvar-local octocat-repo--reveal nil
  "Path the tree browser was opened down to, or nil.")

(defvar-local octocat-repo--focus nil
  "Path of the entry for the tree browser to put point on, or nil.")

(defvar-local octocat-repo--default-branch nil
  "The repository's default branch, once its summary is known.")

(defvar-local octocat-repo--tracked nil
  "The GitHub branch the local clone has checked out, or nil.
Read by `octocat-repo--sync-checkout' on each refresh; a page with no
`octocat-repo--ref' shows it.")

;; The file viewer's.

(defvar-local octocat-tree--file-repo nil
  "The \"owner/repo\" string for the file viewer buffer.")

(defvar-local octocat-tree--file-path nil
  "Relative file path being displayed in the file viewer buffer.")

(defvar-local octocat-tree--file-branch nil
  "Branch/ref name for the file being displayed, \"HEAD\" for the default.")

(defvar-local octocat-tree--file-lines nil
  "The lines a link named, (START . END), highlighted and scrolled to, or nil.")

(defvar-local octocat-tree--file-blame nil
  "Non-nil when the file viewer shows the blame, see `octocat-file-cycle-view'.")

(defvar-local octocat-repo--blame-pins nil
  "The overlays pinning a blame's commit, see `octocat-repo--blame-pin'.")

(defvar-local octocat-repo--blame-sliding nil
  "Non-nil while the blame column slides, which a pin would cover.")


;;;; Repo detection

(defun octocat-repo--local-dir-for (repo)
  "Return the local clone directory for REPO, or nil.
REPO is an \"owner/repo\" string.  Returns the absolute path to the root
of the current working tree when its \\='origin\\=' remote resolves to REPO,
and nil in every other case — including when `default-directory' is not
inside any git repository, when there is no \\='origin\\=' remote, or when
the remote points to a different repository."
  (condition-case nil
      (let ((root (locate-dominating-file default-directory ".git")))
        (and root
             (string= repo (octocat-repo--current-repo))
             (expand-file-name root)))
    (error nil)))


;;;; Unpushed commits

(defun octocat-repo--git-lines (dir &rest args)
  "Return the output lines of git ARGS run in DIR, or nil when it fails."
  (let ((default-directory dir))
    (with-temp-buffer
      (and (eq 0 (apply #'process-file "git" nil '(t nil) nil args))
           (split-string (buffer-string) "\n" t)))))

(defun octocat-repo--parse-unpushed (lines)
  "Parse LINES of \"SHA NUL SUBJECT\" into plists."
  (mapcar (lambda (l)
            (pcase-let ((`(,sha ,subject) (split-string l "\0")))
              (list :sha sha :subject subject)))
          lines))

(defun octocat-repo--unpushed (dir)
  "Return the local commits in DIR not yet on GitHub, or nil when none.
The result is a plist: :commits from `octocat-repo--parse-unpushed',
newest first, :upstream the remote-tracking branch they are counted
against (nil for a branch never pushed, counted against every origin
branch), and :behind how many upstream commits HEAD lacks, as of the
last fetch; non-zero means the branches diverged.  Reads git synchronously."
  (let* ((upstream (car (octocat-repo--git-lines
                         dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}")))
         (log      (append '("log" "--format=%H%x00%s")
                           (if upstream
                               '("@{u}..HEAD")
                             '("HEAD" "--not" "--remotes=origin"))))
         (commits  (octocat-repo--parse-unpushed
                    (apply #'octocat-repo--git-lines dir log))))
    (when commits
      (list :commits commits
            :upstream upstream
            :behind (if upstream
                        (string-to-number
                         (or (car (octocat-repo--git-lines
                                   dir "rev-list" "--count" "HEAD..@{u}"))
                             "0"))
                      0)))))

;;;; Checked-out branch

(defun octocat-repo--tracked-branch (dir)
  "Return the GitHub branch the clone in DIR has checked out, or nil.
That is its upstream on origin, or else origin's branch of the same
name, as of the last fetch.  Nil when DIR is nil, HEAD is detached or
the branch was never pushed: GitHub has nothing to show for it."
  (when-let* ((dir)
              (branch (car (octocat-repo--git-lines dir "symbolic-ref" "--short" "HEAD"))))
    (let ((upstream (car (octocat-repo--git-lines
                          dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}"))))
      (cond ((and upstream (string-prefix-p "origin/" upstream))
             (substring upstream (length "origin/")))
            ((octocat-repo--git-lines dir "rev-parse" "--verify" "--quiet"
                                      (concat "refs/remotes/origin/" branch))
             branch)))))

;;;; This file or directory on GitHub, for `octocat-here'

(defun octocat-repo--git-ok (dir &rest args)
  "Return non-nil when git ARGS run in DIR succeeds."
  (let ((default-directory dir))
    (eq 0 (apply #'process-file "git" nil nil nil args))))

(defun octocat-repo--here-ref (dir)
  "Return (REF . REV) for what GitHub has of the checkout of the clone in DIR.
REF names it to GitHub: the tracked branch, else a detached HEAD's SHA
once origin has it, else nil for the default branch.  REV names that
commit to the clone's git, as of the last fetch."
  (if-let* ((branch (octocat-repo--tracked-branch dir)))
      (cons branch (concat "origin/" branch))
    (let ((sha (and (not (octocat-repo--git-ok dir "symbolic-ref" "--quiet" "HEAD"))
                    (octocat-repo--git-lines dir "branch" "--remotes" "--contains" "HEAD"
                                             "--list" "origin/*")
                    (car (octocat-repo--git-lines dir "rev-parse" "HEAD")))))
      (if sha (cons sha sha) (cons nil "origin/HEAD")))))

(defun octocat-repo--here-target (repo ref path dir-p at exists-p &optional follow)
  "Return the `octocat-open' arguments to show PATH of REPO at REF.
PATH is relative to the clone's root, nil for the root; DIR-P says it
is a directory, AT is the lines to show of a file.  EXISTS-P, called
with a path, says whether REF has it; when it hasn't, the nearest
directory above that it has is shown instead.  A workflow's file
opens its workflow page.  FOLLOW says REF is the checkout's branch:
the repo and tree pages are then given no ref, to follow the checkout."
  (let ((shown    path)
        (page-ref (unless follow ref)))
    (while (and shown (not (funcall exists-p shown)))
      (setq shown (file-name-directory (directory-file-name shown))
            shown (and shown (directory-file-name shown))))
    (cond ((null shown)                          (list 'repo repo page-ref))
          ((or dir-p (not (equal shown path)))   (list 'tree repo page-ref shown))
          ((string-match "\\`\\.github/workflows/\\([^/]+\\.ya?ml\\)\\'" shown)
           (let ((file (match-string 1 shown)))
             (list 'workflow repo file file shown)))
          (t (append (list 'file repo ref shown) (and at (list at)))))))

(defun octocat-repo--sync-checkout ()
  "Re-read the local clone's checkout into this page's state.
Return the new `octocat-repo--tracked'."
  (when octocat-repo--local-dir
    ;; `octocat--head-info' reads `default-directory' at render time.
    (setq default-directory (file-name-as-directory octocat-repo--local-dir)))
  (setq octocat-repo--tracked (octocat-repo--tracked-branch octocat-repo--local-dir)))

(defun octocat-repo--follow-checkout (window)
  "Refresh the page in WINDOW if its clone has checked out another branch.
Run as the page is shown or selected, so a `git checkout' made
elsewhere is followed; a page on a picked ref stays on it."
  (with-current-buffer (window-buffer window)
    (when (and octocat-repo--local-dir (null octocat-repo--ref) octocat-vui--page
               (not (equal octocat-repo--tracked
                           (octocat-repo--tracked-branch octocat-repo--local-dir))))
      (funcall revert-buffer-function))))


;;;; Branch picker
;;
;; The branch picker of the repo, file and workflow pages, which keeps
;; the branches in the sync store.

(defun octocat--branch-candidates (names default local)
  "Return branch NAMES ordered for a picker, as GitHub's branch dropdown.
DEFAULT (the default branch) comes first, then LOCAL (the checked-out
branch) when it was pushed, then the rest as given."
  (let ((front (delete-dups (seq-filter (lambda (b) (and b (member b names)))
                                        (list default local)))))
    (append front (seq-difference names front))))

(defun octocat--branch-note (branch default local)
  "Return the picker annotation of BRANCH, given DEFAULT and LOCAL, or nil."
  (cond ((equal branch default) "  default")
        ((equal branch local)   "  checked out")))

(defun octocat--async-branches (repo default local)
  "Return a consult async stage listing the branches of REPO.
The stored list shows at once; a fetch, unless it is fresh, replaces it.
DEFAULT and LOCAL order it (see `octocat--branch-candidates').  Input
is not passed on: the completion style filters the list."
  (lambda (sink)
    (let ((spec (list 'branches repo))
          live)
      (lambda (action)
        (pcase action
          ('setup
           (setq live t)
           (funcall sink 'setup)
           (when-let* ((stored (plist-get (octocat-sync-read spec) :data)))
             (funcall sink (octocat--branch-candidates (append stored nil) default local)))
           (funcall sink [indicator running])
           (octocat-sync-get
            spec
            (lambda (result)
              (when live
                (if (eq (car-safe result) 'error)
                    (progn (funcall sink [indicator failed])
                           (message "Octocat: %s" (cdr result)))
                  (funcall sink 'flush)
                  (funcall sink (octocat--branch-candidates (append result nil) default local))
                  (funcall sink [indicator finished]))))))
          ((or 'cancel 'destroy)
           (setq live nil)
           (funcall sink action))
          ((pred stringp) nil)
          (_ (funcall sink action)))))))

(defun octocat--read-branch (repo default local shown)
  "Prompt for a branch of REPO and return its name.
DEFAULT and LOCAL are as in `octocat--branch-candidates'; SHOWN is the
branch on screen, which an empty answer keeps."
  (consult--read
   (octocat--async-branches repo default local)
   :prompt      (format "Branch (shown: %s): " shown)
   :default     shown
   :require-match t
   :sort        nil
   :category    'octocat-branch
   :annotate    (lambda (b) (octocat--branch-note b default local))
   ;; Without `consult--async-split', so the input filters the list.
   :async-wrap  (lambda (async)
                  (consult--async-pipeline async
                                           (consult--async-indicator)
                                           (consult--async-refresh)))))


;;;; gh integration

(defconst octocat-repo--doc-kinds
  '((readme   "README"          "readme")
    (coc      "Code of conduct" "code[-_]of[-_]conduct")
    (contrib  "Contributing"    "contributing")
    (license  "License"         "\\(?:licen[cs]e\\|copying\\)")
    (security "Security"        "security"))
  "The documents GitHub offers below a repository's files, in its order.
Each is (KIND LABEL STEM): a root file is one when its name, ignoring
case, is STEM, a regexp, with or without an extension.")

(defconst octocat-repo--formats
  '(("\\.\\(?:md\\|markdown\\|mdown\\|mkdn?\\)\\'" . identity)
    ("\\.org\\'" . octocat-markdown-from-org))
  "The formats of files shown rendered, in order of preference.
Each is (REGEXP . FUNCTION): a file whose name matches REGEXP, ignoring
case, is turned into markdown by FUNCTION, then rendered.")

(defun octocat-repo--format (name)
  "Return the entry of `octocat-repo--formats' file NAME is in, or nil."
  (let ((case-fold-search t))
    (seq-find (lambda (f) (string-match-p (car f) name)) octocat-repo--formats)))

(defun octocat-repo--docs (entries)
  "Return the documents among ENTRIES, the root's `tree-dir' entries.
Each is (KIND LABEL ENTRY), in the order of `octocat-repo--doc-kinds'.
Of several files of a kind a rendered one wins, see
`octocat-repo--formats', then the shortest name, then the earlier
format, so README.md beats README.txt, README and README.org."
  (delq nil
        (mapcar
         (pcase-lambda (`(,kind ,label ,stem))
           (let* ((re (concat "\\`" stem "\\(?:\\.[^.]+\\)?\\'"))
                  (hits (seq-filter (lambda (e)
                                      (let ((case-fold-search t))
                                        (and (equal (gethash "type" e) "blob")
                                             (string-match-p re (gethash "path" e)))))
                                    entries))
                  (rank (lambda (e)
                          (let ((n (gethash "path" e)))
                            (let ((fmt (octocat-repo--format n)))
                              (+ (if fmt 0 100000)
                                 (* 10 (length n))
                                 (or (seq-position octocat-repo--formats fmt) 0)))))))
             (when hits
               (list kind label
                     (car (sort hits (lambda (a b) (< (funcall rank a)
                                                      (funcall rank b)))))))))
         octocat-repo--doc-kinds)))


(defun octocat-repo-vui--unpushed-row (commit)
  "Return a line for COMMIT, a plist from `octocat-repo--parse-unpushed'.
Not RET-able: the commit page reads from GitHub, which lacks it."
  (let ((sha (plist-get commit :sha)))
    (vui-text
        (concat
         (propertize (substring sha 0 (min 7 (length sha))) 'face 'octocat-commit-sha)
         " "
         (plist-get commit :subject)))))


;;;; API fetch helpers


(defconst octocat-tree--blob-query
  (concat "query($owner:String!,$name:String!,$expr:String!){repository(owner:$owner,"
          "name:$name){object(expression:$expr){...on Blob{oid}}}}")
  "GraphQL query behind `octocat-tree--fetch-blob-sha'.")

(defun octocat-tree--fetch-blob-sha (repo ref path callback)
  "Fetch the blob SHA of file PATH of REPO at REF.
Calls CALLBACK with the SHA, or a cons (error . MSG)."
  (octocat--gh-graphql
   "blob-sha" repo octocat-tree--blob-query `(("expr" . ,(concat ref ":" path)))
   (lambda (json)
     (let* ((r   (gethash "repository"
                          (gethash "data" (json-parse-string json :null-object nil))))
            (obj (and r (gethash "object" r))))
       (or (and obj (gethash "oid" obj))
           (error "No file %s at %s" path ref))))
   callback))


;;;; Sync resources

(defun octocat-tree--load-blob (repo sha callback)
  "Call CALLBACK with the content of blob SHA in REPO, or (error . MSG).
From the store at once when there, else once fetched."
  (octocat-sync-get (list 'blob repo sha)
                    (lambda (r)
                      (funcall callback (if (eq (car-safe r) 'error)
                                            r
                                          (octocat-model-blob-content r))))))

(defun octocat-tree--image-file (repo ref path callback)
  "Call CALLBACK with the bytes of file PATH of REPO at REF, or nil.
For `octocat-image-file-function': the blob is stored, so an image is
fetched once."
  (octocat-tree--fetch-blob-sha
   repo ref path
   (lambda (sha)
     (if (eq (car-safe sha) 'error)
         (funcall callback nil)
       (octocat-tree--load-blob
        repo sha (lambda (r) (funcall callback (and (stringp r) r))))))))

(defvar octocat-tree--proxied (make-hash-table :test #'equal)
  "File (REPO REF PATH) to its images' URLs on GitHub's proxy.
Each is a hash table from an image's own URL to the proxy's.")

(defun octocat-tree--proxied-urls (html)
  "Return the table of the images of GitHub's HTML, their URL to the proxy's.
GitHub gives each image of another site as its proxy's, the image's
own URL as `data-canonical-src'."
  (let ((table (make-hash-table :test #'equal)))
    (when (libxml-available-p)
      (with-temp-buffer
        (insert html)
        (dolist (img (dom-by-tag (libxml-parse-html-region (point-min) (point-max)) 'img))
          (let ((src  (dom-attr img 'src))
                (orig (dom-attr img 'data-canonical-src)))
            (when (and src orig)
              (puthash orig src table))))))
    table))

(defun octocat-tree--proxied-url (repo ref path url callback)
  "Call CALLBACK with the URL of image URL on GitHub's proxy, or nil.
URL is shown by file PATH of REPO at REF.  For
`octocat-image-proxy-function': the proxy's URLs are signed, so they
are read from GitHub's rendering of the file, fetched once."
  (let ((key (list repo ref path)))
    (if-let* ((table (gethash key octocat-tree--proxied)))
        (funcall callback (gethash url table))
      (octocat--run-gh
       "proxied"
       (list "api" "-X" "GET"
             (format "repos/%s/contents/%s" repo
                     (mapconcat #'url-hexify-string (split-string path "/") "/"))
             "-f" (concat "ref=" ref)
             "-H" "Accept: application/vnd.github.html")
       #'octocat-tree--proxied-urls
       (lambda (r)
         (if (hash-table-p r)
             (progn (puthash key r octocat-tree--proxied)
                    (funcall callback (gethash url r)))
           (funcall callback nil)))))))

;;;; Syntax highlighting

(defun octocat-tree--fontify (path content)
  "Return CONTENT string with face properties from the appropriate major mode.
PATH, relative to the repository root, is used only to select the mode
via `auto-mode-alist'."
  (with-temp-buffer
    (insert content)
    (octocat--set-mode-for-path path)
    ;; A mode's broken font-lock rules should not lose the file's text.
    (with-demoted-errors "Octocat: cannot highlight: %S" (font-lock-ensure))
    (buffer-string)))


;;;; Rendering helpers

(defun octocat-tree--last-commit-text (label commit width)
  "Return what follows LABEL, a tree line's text, to show COMMIT, or \"\".
COMMIT is the last that touched the entry, as GitHub's tree shows it:
its subject from a third of WIDTH on, cut to fit, and its age at the
right.  While it loads, COMMIT is `loading' and grey bars stand in."
  (cond
   ((eq commit 'loading)
    (let* ((col  (max (+ (string-width label) 2) (min 40 (/ width 3))))
           ;; Of the name's length, so the bars are not all alike.
           (bar  (min (- width col 14) (+ 18 (* 7 (% (length label) 4)))))
           (age  10))
      (if (< bar 8)
          ""
        (concat (make-string (- col (string-width label)) ?\s)
                (octocat-vui-skeleton-bar bar)
                (make-string (- width col bar age) ?\s)
                (octocat-vui-skeleton-bar age)))))
   ((not (hash-table-p commit)) "")
   (t
    (let* ((age     (let ((ts (octocat--commit-date commit)))
                      (if (string-empty-p ts) "" (octocat--format-ts-relative ts))))
           (subject (car (split-string (or (gethash "message" (gethash "commit" commit)) "")
                                       "\n")))
           (col     (max (+ (string-width label) 2) (min 40 (/ width 3))))
           (room    (- width col 2 (string-width age)))
           (shown   (if (< room 8) ""
                      (truncate-string-to-width subject room nil nil "…"))))
      (concat (make-string (- col (string-width label)) ?\s)
              (propertize shown 'face 'octocat-dimmed
                          'octocat-full-text (unless (equal shown subject) subject))
              (make-string (max 2 (- width col (string-width shown) (string-width age))) ?\s)
              (propertize age 'face 'octocat-dimmed))))))

(defun octocat-tree--entry-line (indent name face type entry path activate
                                        &optional commit width)
  "Return one tree line as a vnode (no trailing newline).
INDENT is a string of leading spaces.  NAME is the file/dir name, with
any glyph before it, drawn in FACE.  TYPE is \\='dir or \\='file.
ENTRY is the API hash-table.  PATH is the entry's full repository path:
the API's own \"path\" field is only the name within its directory.
ACTIVATE is a zero-argument function run by RET on the line.  COMMIT,
the last that touched it or `loading', follows it to fit WIDTH, see
`octocat-tree--last-commit-text'.

The line is not a button, so TAB does not stop on every entry: in a
long listing, walking the page's buttons would be walking its files.
The type/entry/path/activate properties span the entire line, indent
included, so `get-text-property' at `line-beginning-position' finds
them.  Commands read them rather than relying on the line's keymap, so
they keep working under Evil, whose state keymaps outrank text-property
keymaps."
  (let ((map   (make-sparse-keymap))
        (help  (concat (if (eq type 'dir) "RET: open directory" "RET: view file")
                       "  S-RET: in other window  C-c C-o: browse on GitHub"))
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
                                                     'help-echo help)
                                         (octocat-tree--last-commit-text
                                          (concat indent name) commit (or width 0)))
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
      (when (and focus (member focus paths))
        (octocat-tree--jump-to buf focus))
      nil)))

(defun octocat-tree--older-last-commits (stored commit sha)
  "Return the last commits that STORED has of a directory, or nil.
STORED is `octocat-sync-stored' of its `tree-commits' resources, of any
commit but COMMIT.  The newest fetched of those at its tree SHA, whose
entries are as at COMMIT, else the newest of all."
  (let ((older (seq-filter (pcase-lambda (`((,_ ,_ ,c ,_ ,_) ,data ,_))
                             (and c (not (equal c commit))
                                  (hash-table-p data) (not (hash-table-empty-p data))))
                           stored)))
    (nth 1 (car (sort older
                      (pcase-lambda (`((,_ ,_ ,_ ,_ ,sa) ,_ ,ta) `((,_ ,_ ,_ ,_ ,sb) ,_ ,tb))
                        (let ((a (equal sa sha)) (b (equal sb sha)))
                          (if (eq a b) (> (or ta 0) (or tb 0)) a))))))))

(defun octocat-tree--use-last-commits (repo commit dir sha)
  "Return the last commits of the entries of DIR, tree SHA, of REPO.
A hash-table of path to commit, from COMMIT back, or, while it loads,
`loading', or (loading . TABLE) when an older commit's are stored: those
stand in meanwhile, see `octocat-tree--older-last-commits'.  Read it with
`octocat-tree--last-of'.  Empty when COMMIT is nil or the fetch failed.
Pass COMMIT only once the listing is shown: the fetch reads it from the
store.  A hook: call it during render."
  (let* ((snap    (octocat-vui-use-resource (list 'tree-commits repo commit dir sha) nil))
         (data    (plist-get snap :data))
         (waiting (and commit (not (hash-table-p data))
                       (eq (octocat-vui-snapshot-status snap) 'pending)))
         (older   (vui-use-memo (repo commit dir sha waiting)
                    (and waiting
                         (octocat-tree--older-last-commits
                          (seq-filter (lambda (s) (equal (nth 3 (car s)) dir))
                                      (octocat-sync-stored 'tree-commits repo))
                          commit sha)))))
    (cond ((hash-table-p data) data)
          (waiting (if older (cons 'loading older) 'loading))
          (t (make-hash-table :test #'equal)))))

(defun octocat-tree--last-of (last path)
  "Return the last commit of PATH in LAST, of `octocat-tree--use-last-commits'.
That is `loading' while LAST is, or while it is an older commit's
without PATH."
  (cond ((hash-table-p last) (gethash path last))
        ((consp last) (gethash path (cdr last) 'loading))
        (t last)))

(vui-defcomponent octocat-tree--dir (repo branch sha commit on-dir on-browse)
  "The root's entries, its tree SHA of REPO at BRANCH, as GitHub lists them.
Each shows the last commit that touched it, from COMMIT back.
RET on a directory calls ON-DIR with its path; on a file it opens it.
Only the first `octocat-tree-entries' show, so the README below is near;
a Browse code button after them, saying how many more there are, calls
ON-BROWSE, for the whole tree."
  :render
  (let* ((result  (octocat-vui-use-latest-resource (list 'tree-dir repo sha) nil))
         (entries (octocat-tree--sorted-entries (plist-get result :data)))
         (shown   (if octocat-tree-entries (seq-take entries octocat-tree-entries) entries))
         (more    (- (length entries) (length shown)))
         (last    (octocat-tree--use-last-commits repo (and entries commit) "" sha))
         (width   (octocat-vui-window-width)))
    (pcase (octocat-vui-snapshot-status result)
      ('pending (vui-text (octocat-tree--skeleton)))
      ('error   (vui-text (propertize (octocat-vui-error-text result) 'face 'error)))
      ((guard (null entries)) (vui-text (propertize "(empty)" 'face 'octocat-dimmed)))
      (_
       (vui-vstack
        (vui-list
         shown
         (lambda (entry)
           (let ((name (gethash "path" entry)))
             (if (equal (gethash "type" entry) "tree")
                 (octocat-tree--entry-line "" (concat name "/") 'octocat-branch 'dir entry name
                                           (lambda () (funcall on-dir name))
                                           (octocat-tree--last-of last name) width)
               (octocat-tree--entry-line "" name 'default 'file entry name
                                         (lambda ()
                                           (octocat-tree--open-file-by-path
                                            repo branch name))
                                         (octocat-tree--last-of last name) width))))
         (lambda (entry) (gethash "path" entry)))
        (vui-button (if (> more 0)
                        (format "[Browse code (%d more %s)]" more (if (= more 1) "entry" "entries"))
                      "[Browse code]")
          :no-decoration t
          :face 'octocat-dimmed
          :help-echo "RET: browse the whole tree"
          :on-click on-browse))))))

(vui-defcomponent octocat-tree--subtree
    (repo branch sha commit depth path reveal focus)
  "The entries of directory PATH, tree SHA, at nesting DEPTH of the tree.
They are of REPO at BRANCH, each with the last commit that touched it,
from COMMIT back.  Directories on the way to REVEAL start
expanded.  RET on a directory only toggles it, so the rest of the page
stays put; on a file it opens it.  Point moves to FOCUS, an entry's
path, once it is listed.  Unlike the root's listing it does not fold:
it is for browsing."
  :render
  (let* ((indent  (make-string (* depth 2) ?\s))
         (result  (octocat-vui-use-latest-resource (list 'tree-dir repo sha) nil path))
         (entries (octocat-tree--sorted-entries (plist-get result :data)))
         (last    (octocat-tree--use-last-commits repo (and entries commit) path sha)))
    (octocat-tree--use-focus
     focus (mapcar (lambda (e) (file-name-concat path (gethash "path" e))) entries))
    (pcase (octocat-vui-snapshot-status result)
      ('pending (vui-text (octocat-tree--skeleton indent)))
      ('error   (vui-text (propertize (concat indent (octocat-vui-error-text result))
                                      'face 'error)))
      (_ (if (null entries)
             (vui-text (propertize (concat indent "(empty)") 'face 'octocat-dimmed))
           (vui-list entries
                     (lambda (entry)
                       (vui-component 'octocat-tree--node
                         :repo repo :branch branch :entry entry :commit commit
                         :last (octocat-tree--last-of
                                last (file-name-concat path (gethash "path" entry)))
                         :depth depth :parent path :reveal reveal :focus focus))
                     (lambda (entry) (gethash "path" entry))))))))

(vui-defcomponent octocat-tree--node
    (repo branch entry commit last depth parent reveal focus)
  "One tree ENTRY (hash-table) at nesting DEPTH, inside directory PARENT.
LAST is the last commit that touched it, `loading' while it loads.  The other
arguments are as for `octocat-tree--subtree'."
  :state ((expanded (octocat-tree--reveals-p
                     (file-name-concat parent (or (gethash "path" entry) ""))
                     reveal)))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :expanded (octocat-tree--reveals-p
                                         (file-name-concat
                                          parent (or (gethash "path" entry) ""))
                                         reveal)))))
         (name   (or (gethash "path" entry) ""))
         (path   (file-name-concat parent name))
         (sha    (or (gethash "sha" entry) ""))
         (indent (make-string (* depth 2) ?\s))
         (width  (octocat-vui-window-width)))
    (if (equal (gethash "type" entry) "tree")
        (vui-fragment
         (octocat-tree--entry-line
          indent (concat (if expanded "▾ " "▸ ") name "/")
          'octocat-branch 'dir entry path
          (vui-with-async-context
           (vui-set-state :expanded (lambda (old) (not old))))
          last width)
         (when expanded
           (vui-fragment
            (vui-newline)
            (vui-component 'octocat-tree--subtree
              :repo repo :branch branch :sha sha :commit commit :depth (1+ depth)
              :path path :reveal reveal :focus focus))))
      ;; Two spaces stand for "▸ ", so names line up with directories'.
      (octocat-tree--entry-line
       indent (concat "  " name) 'default
       'file entry path
       (lambda () (octocat-tree--open-file-by-path repo branch path))
       last width))))

(defun octocat-tree--skeleton (&optional indent)
  "Return grey bars shaped like a few tree entries, each after INDENT."
  (octocat-vui-skeleton (mapcar (lambda (n) (list (or indent "") n)) '(14 22 10 18))))


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


;;;; Sections
;;
;; Each section reads its sync resource and, for the pageable ones,
;; keeps its "load more" limit (`:state').

(defun octocat-repo-vui--unpushed-section (unpushed)
  "Return the section listing UNPUSHED, from `octocat-repo--unpushed'.
It is apart from the commits section: the local branch need not be the
default branch, nor sit on top of it."
  (let ((commits (plist-get unpushed :commits))
        (behind  (plist-get unpushed :behind)))
    (vui-vstack
     (vui-text
         (concat (propertize "Local commits not on " 'face 'octocat-section-heading)
                 (propertize (or (plist-get unpushed :upstream) "origin") 'face 'octocat-branch)
                 (propertize (format " (%d)" (length commits)) 'face 'octocat-section-heading)
                 (when (> behind 0)
                   (propertize (format "  diverged, %d behind" behind) 'face 'octocat-dimmed))))
     (apply #'vui-vstack (mapcar #'octocat-repo-vui--unpushed-row commits))
     (vui-newline))))

(defcustom octocat-ref-max-width 24
  "Longest a branch or tag name is shown, beyond which its middle is cut.
Picking a branch always shows names in full, and so does the help of
a cut one."
  :type 'natnum
  :group 'octocat)

(defun octocat-repo-vui--ref-label (ref)
  "Return how a page names REF.
A full SHA is cut to seven characters, and a name longer than
`octocat-ref-max-width' in its middle, keeping both ends: a branch is
told apart by its prefix, as \"feature/\", and its last words."
  (let ((max (max 5 octocat-ref-max-width)))
    (cond ((string-match-p "\\`[0-9a-f]\\{40\\}\\'" ref) (substring ref 0 7))
          ((<= (length ref) max) ref)
          (t (let ((tail (/ (1- max) 2)))
               (concat (substring ref 0 (- max 1 tail)) "…"
                       (substring ref (- (length ref) tail))))))))

(defun octocat-repo-vui--picker-labels (label reset default)
  "Return the labels of the buttons of the picker of the ref named LABEL.
The second, with RESET non-nil, goes back to the DEFAULT branch."
  (cons (format "[%s ▾]" (octocat-repo-vui--ref-label label))
        (and reset (list (octocat-repo-vui--reset-label default)))))

(defun octocat-repo-vui--reset-label (default)
  "Return the label of the button back to the DEFAULT branch."
  (if default (format "[reset to %s]" (octocat-repo-vui--ref-label default)) "[reset]"))

(defun octocat-repo-vui--reset-button (default)
  "Return the button back to the DEFAULT branch."
  (vui-button (octocat-repo-vui--reset-label default)
    :no-decoration t
    :face 'octocat-dimmed
    :help-echo (octocat--button-help
                (format "RET: show %s" (or default "the default branch"))
                #'octocat-repo-reset-branch)
    :on-click #'octocat-repo-reset-branch))

(defun octocat-repo--resettable-p (ref default)
  "Return non-nil when REF is shown in place of the DEFAULT branch.
The default branch named, as by a link to it, is not."
  (and ref (not (equal ref default))))

(defun octocat-repo-vui--ref-picker (label current-branch reset default &optional switch)
  "Return the picker of the ref named LABEL, as GitHub's branch dropdown.
It is highlighted when it is the local CURRENT-BRANCH.  RESET non-nil
adds a button back to the DEFAULT branch.  SWITCH is the command that
picks another, `octocat-repo-switch-branch' when nil.  Nil while LABEL
is unknown."
  (when (and (stringp label) (not (string-empty-p label)))
    (let* ((switch (or switch #'octocat-repo-switch-branch))
           (help   (octocat--key-help switch "show another branch"))
           (pick   (vui-button (car (octocat-repo-vui--picker-labels label nil nil))
                     :no-decoration t
                     :face (if (equal label current-branch)
                               'octocat-branch-current
                             'octocat-branch)
                     ;; Its name in full, when cut.
                     :help-echo (if (equal (octocat-repo-vui--ref-label label) label)
                                    help
                                  (concat label "\n" help))
                     :on-click switch)))
      (if reset
          (vui-hstack :spacing 1 pick (octocat-repo-vui--reset-button default))
        pick))))

(vui-defcomponent octocat-repo-vui--commits-section
    (repo ref path default-branch current-branch head-info tick)
  "Commits section for REPO, under the top line the tree browser has.
The commits are those of REF, or of the default branch when nil, that
touched PATH, or all of them when nil.  The top line is the picker of
the ref, highlighted when it is the local CURRENT-BRANCH, then PATH,
whose directories show their own commits, how many commits there are,
and a button back to DEFAULT-BRANCH when REF is another.
HEAD-INFO is the plist from `octocat--head-info', used to highlight
the local HEAD commit.  The
commits are a sync resource; \"load more\" appends the page after the
last to it (see `octocat-sync-more'), pinned to the head shown."
  :state ((fetching nil))
  :render
  (let* ((spec    (list 'commits repo ref path octocat-repo-commits-page-size))
         (snap    (octocat-vui-use-resource spec tick))
         (data    (plist-get snap :data))
         (commits (append (and data (gethash "nodes" data)) nil))
         (status  (octocat-vui-snapshot-status snap))
         (label   (or ref default-branch)))
    (octocat-vui-use-mode-line-loading fetching)
    (vui-vstack
     (octocat-repo-vui--top-line
      repo label path current-branch nil
      (lambda (dir) (octocat-commit-list-open repo ref (octocat--nonempty dir)))
      (when-let* ((total (and commits (gethash "total" (car commits)))))
        (vui-text (format "%d commit%s" total (if (= total 1) "" "s"))
          :face 'octocat-dimmed))
      (and (octocat-repo--resettable-p ref default-branch)
           (octocat-repo-vui--reset-button default-branch)))
     (vui-newline)
     (pcase status
       ('pending (vui-text (octocat-vui-line-skeleton)))
       ('error   (vui-text (octocat-vui-error-text snap) :face 'octocat-dimmed))
       ('ready
        (vui-fragment
         (if (null commits)
             (vui-text "(no commits)" :face 'octocat-dimmed)
           ;; A path's history skips the parents between: no graph.
           (let* ((lanes     (and (null path) (octocat-vui--commit-lanes commits)))
                  ;; Beyond the symbol's own column.
                  (lanes-w   (if lanes
                                 (1- (string-width (car (car (hash-table-values lanes)))))
                               0))
                  (author-w  (octocat-vui--author-width commits))
                  (subject-w (octocat-vui--subject-width
                              commits (- (octocat-vui-window-width) lanes-w) author-w))
                  (date-w    (octocat-vui--date-width commits)))
             (octocat-vui-reveal-list
              commits
              (lambda (c)
                (octocat-vui--commit-row repo c head-info author-w subject-w date-w
                                         (and lanes (gethash (gethash "sha" c) lanes))))
              (lambda (c) (gethash "sha" c)))))
         (when (and commits (gethash "cursor" data))
           (octocat-vui-load-more-button
            'load-more-commits octocat-repo-commits-page-size
            "RET: load more commits"
            (lambda ()
              (vui-set-state :fetching t)
              (octocat-sync-more
               spec (octocat-model-commits-more repo path (gethash "sha" (car commits))
                                                octocat-repo-commits-page-size)
               (vui-async-callback (r)
                 (vui-set-state :fetching nil)
                 (when r (message "Octocat: %s" (cdr r))))))
            fetching 0 (octocat-vui-line-skeleton)))))))))

(defun octocat-repo-vui--head-row (repo ref path commit width)
  "Return the line atop the files: COMMIT, of PATH at REF.
COMMIT is the last that touched PATH, nil for the root.  It shows its
subject, a TAB stop, then, at the right of WIDTH columns, its short SHA
and age, as GitHub's \"1a95462 · 2 hours ago\", RET opening it, and a
button to the commits page of PATH at REF of REPO, with the count of its
history.
The author is left out for room: the commit page has it.  The subject
is cut so the line fits."
  (let* ((sha       (or (gethash "sha" commit) ""))
         (subject   (octocat-vui--subject commit))
         (date      (let ((ts (octocat--commit-date commit)))
                      (if (string-empty-p ts) "" (octocat--format-ts-relative ts))))
         (count     (format "[%s commits]" (gethash "total" commit)))
         (tail      (+ 7 3 (string-width date) 2 (string-width count)))
         (subject-w (max 1 (min (string-width subject) (- width tail 2))))
         (gap       (max 2 (- width subject-w tail)))
         (open      (lambda () (octocat-vui--open-commit repo commit))))
    (octocat-vui-row
     ;; A face that sets nothing: nil would be `link', and `default'
     ;; would mask the underline the file page adds.
     (list (octocat-vui--link
            (truncate-string-to-width subject subject-w nil nil "…")
            '(:inherit nil) open "RET: view commit")
           (make-string gap ?\s)
           (concat (propertize (substring sha 0 (min 7 (length sha)))
                               'face 'octocat-commit-sha)
                   (propertize " · " 'face 'octocat-dimmed)
                   (propertize date 'face 'octocat-dimmed))
           "  "
           (vui-button count
             :no-decoration t
             :face 'octocat-dimmed
             :help-echo "RET: list the commits"
             :on-click (lambda () (octocat-commit-list-open repo ref path))))
     open
     "RET: view commit"
     (octocat--web-url "%s/commit/%s" repo sha))))

;;;; Docs

(defun octocat-repo-vui--doc-tabs (docs shown width)
  "Return the selector of DOCS, from `octocat-repo--docs', as GitHub's.
SHOWN is the kind of the one shown.  See `octocat-vui-tab-row' for WIDTH."
  (octocat-vui-tab-row
   (mapcar (pcase-lambda (`(,kind ,label ,entry))
             (list label (format "RET: show %s" (gethash "name" entry))
                   (unless (eq kind shown)
                     (lambda () (vui-set-state :kind kind)))))
           docs)
   width))

(defun octocat-repo--doc-text (repo ref name content raw width)
  "Return the rows of file NAME's CONTENT, rendered when it is markdown.
Another format of `octocat-repo--formats' is turned into markdown
first, unless RAW.  NAME is its path in REPO at REF, which its
relative links point into.  RAW and WIDTH are as for
`octocat--markdown-string'.  Not indented, so it copies as from the
file.  A document larger than `octocat--max-file-size' is shown as it
is, its long lines clipped, see `octocat--clip-line'."
  (let ((text (decode-coding-string content 'utf-8))
        (fmt (octocat-repo--format name))
        (octocat-markdown-base (list repo (or ref "HEAD") (or (file-name-directory name) "")))
        (octocat-markdown-document (list repo (or ref "HEAD") name)))
    (string-remove-suffix
     "\n" (if (and fmt (<= (length content) octocat--max-file-size))
              (octocat--markdown-string (if raw text (funcall (cdr fmt) text))
                                        "" raw width t)
            (octocat-markdown-render-verbatim
             (octocat--clip-lines text octocat--max-line-length)
             "")))))

(vui-defcomponent octocat-repo-vui--docs-section (repo ref tree raw)
  "The README of REPO at REF, root TREE, and a selector of its other documents.
They are those of `octocat-repo--doc-kinds' among the files of TREE,
the root tree of the commit shown; while its listing loads, grey bars
stand in for the section.  RAW shows markdown verbatim.  A long
document is folded after `octocat-repo-doc-lines'.  The listing is the
tree's own and a file is stored under its blob SHA, so while the branch
stays put no request is made."
  :state ((kind nil))
  :render
  (let* ((root  (octocat-vui-use-latest-resource (list 'tree-dir repo tree) nil))
         (docs  (and (plist-get root :data)
                     (octocat-repo--docs (append (plist-get root :data) nil))))
         (doc   (or (assq kind docs) (car docs)))
         (entry (nth 2 doc))
         (oid   (and entry (gethash "sha" entry)))
         (blob  (octocat-vui-use-latest-resource (list 'blob repo oid) nil (car doc)))
         (width (octocat--markdown-width))
         (text  (vui-use-memo ((plist-get blob :data) ref raw width)
                  (and entry (plist-get blob :data)
                       (octocat-repo--doc-text repo ref (gethash "path" entry)
                                               (octocat-model-blob-content
                                                (plist-get blob :data))
                                               raw width)))))
    (cond
     (docs
      (vui-vstack
       (vui-newline)
       (octocat-repo-vui--doc-tabs docs (car doc) width)
       (pcase (octocat-vui-snapshot-status blob)
         ('pending (vui-text (octocat-vui-line-skeleton)))
         ('error   (vui-text (octocat-vui-error-text blob) :face 'octocat-dimmed))
         (_        (let ((text (or text "")))
                     (octocat-vui-fold-lines
                      text (octocat-vui-line-ends text) octocat-repo-doc-lines
                      ;; One per document, so switching starts folded.
                      (intern (format "doc-fold-%s" (car doc))) ""))))))
     ((eq (octocat-vui-snapshot-status root) 'pending)
      (octocat-repo-vui--docs-skeleton)))))

(defun octocat-repo-vui--docs-skeleton ()
  "Return grey bars standing in for the docs section."
  (vui-vstack
   (vui-newline)
   (vui-text (concat (octocat-vui-skeleton '((6 "  " 12 "  " 7)))
                     "\n" (octocat-vui-line-skeleton)))))

;;;; Root

(defun octocat-repo-vui--path-nodes (path on-dir)
  "Return the nodes of PATH from the root, as GitHub's breadcrumb.
Each directory on the way, \"/\" the root first, is a button calling
ON-DIR with its path, \"\" for the root; the last, where the page is,
is plain."
  (let* ((segs  (and path (split-string path "/" t)))
         (crumb (lambda (label dir)
                  (vui-button label
                    :no-decoration t
                    :face 'octocat-branch
                    :help-echo (format "RET: browse %s"
                                       (if (string-empty-p dir) "the root"
                                         (concat dir "/")))
                    :on-click (lambda () (funcall on-dir dir)))))
         (nodes (list (if segs (funcall crumb "/" "") (vui-text "/")))))
    (cl-loop for (seg . rest) on segs
             for i from 1
             do (if rest
                    (setq nodes (append (list (vui-text "/")
                                              (funcall crumb seg
                                                       (string-join (seq-take segs i) "/")))
                                        nodes))
                  (push (vui-text seg) nodes)))
    (nreverse nodes)))

(defun octocat-repo--pin (repo label path current-branch &optional after)
  "Return the pin of a page of PATH of REPO at the ref named LABEL.
AFTER, a string or nil, follows it.  See `octocat-vui-page'; it reads
as `octocat-repo-vui--top-line'."
  (octocat-vui-pin (propertize repo 'face 'octocat-repo)
                   (when-let* ((label (octocat--nonempty label)))
                     (concat (propertize label 'face (if (equal label current-branch)
                                                         'octocat-branch-current
                                                       'octocat-branch))
                             (and path ":/") path))
                   after))

(defun octocat-repo-vui--top-line (repo label path current-branch switch on-dir &rest after)
  "Return the top line of a page of PATH of REPO at the ref named LABEL.
That is owner/repo  [LABEL ▾]:/PATH, repo opening the repository page,
the picker of `octocat-repo-vui--ref-picker' running SWITCH, highlighted
when LABEL is the local CURRENT-BRANCH, and the directories of PATH
buttons calling ON-DIR, see `octocat-repo-vui--path-nodes'.  AFTER,
nodes or nils, follow it."
  (apply #'vui-hstack :spacing 0
         (octocat-vui-repo-heading repo t)
         (vui-text "  ")
         (or (octocat-repo-vui--ref-picker label current-branch nil nil switch)
             (vui-text (octocat-vui-skeleton '((8)))))
         (vui-text ":")
         (append (octocat-repo-vui--path-nodes path on-dir)
                 (mapcan (lambda (node) (list (vui-text "  ") node)) (delq nil after)))))

(defun octocat-repo-vui--head-line (repo ref path head-snap)
  "Return the line of the last commit of PATH of REPO at REF.
HEAD-SNAP is the snapshot of PATH's `repo-head'.  The line is
underlined: it heads the files."
  (octocat-vui-underlined
   (octocat-vui-window-width)
   (pcase (octocat-vui-snapshot-status head-snap)
     ('error (vui-text (octocat-vui-error-text head-snap) :face 'octocat-dimmed))
     ('ready (octocat-repo-vui--head-row
              repo ref path (plist-get head-snap :data) (octocat-vui-window-width)))
     (_ (vui-text (octocat-vui-skeleton '((7 "  " 40 "  " 12))))))))

(vui-defcomponent octocat-repo-vui--root (repo ref tracked local-dir unpushed raw tick)
  "Root component for the repo buffer, as GitHub's Code tab: header, the
picker of REF and tabs, local-head/fork-parent info, the UNPUSHED
section, then REF's last commit, the root's first files and its README.  REF
is a branch, tag or SHA, nil for TRACKED, the clone's branch, or else
the default branch.  RAW shows markdown verbatim.  The header comes from
one summary resource and the rest from the root's `repo-head' at REF."
  :render
  (let* ((buf            (current-buffer))
         (head-info      (octocat--head-info))
         (current-branch (plist-get head-info :branch))
         (snap           (octocat-vui-use-resource (list 'repo-summary repo) tick))
         (summary        (plist-get snap :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (shown          (or ref tracked))
         (fork-parent    (and summary (gethash "fork-parent" summary)))
         (head-snap      (octocat-vui-use-resource (list 'repo-head repo shown nil) tick))
         (tree           (let ((d (plist-get head-snap :data))) (and d (gethash "tree" d)))))
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (octocat-vui-page
     (octocat-repo--pin repo (or shown default-branch) nil current-branch)
     (vui-vstack
      (apply #'vui-hstack :spacing 2
             (octocat-vui-repo-heading repo)
             (or (octocat-repo-vui--ref-picker
                  (or shown default-branch) current-branch
                  (octocat-repo--resettable-p ref (or tracked default-branch))
                  (or tracked default-branch))
                 (vui-text (octocat-vui-skeleton '((8)))))
             (octocat-vui-repo-tabs repo 'code tick))
      (when local-dir
        (vui-text
            (concat (propertize "Local clone:" 'face 'octocat-dimmed)
                    "  "
                    (propertize local-dir 'face 'octocat-branch)
                    (cond (current-branch
                           (concat "  " (propertize current-branch 'face 'octocat-branch-current)))
                          ((plist-get head-info :hash)
                           (concat "  detached at "
                                   (propertize (plist-get head-info :hash)
                                               'face 'octocat-commit-sha)))))))
      (when fork-parent
        (octocat-vui-row
         (concat "Forked from  " (propertize fork-parent 'face 'octocat-repo))
         (lambda () (octocat-visit-repo fork-parent))
         "RET: open parent repo view"
         (octocat--web-url "%s" fork-parent)))
      (vui-newline)
      (when unpushed
        (octocat-repo-vui--unpushed-section unpushed))
      (octocat-repo-vui--head-line repo ref nil head-snap)
      (if tree
          (vui-component 'octocat-tree--dir
            :key shown :repo repo :branch (or shown default-branch "HEAD") :sha tree
            :commit (gethash "sha" (plist-get head-snap :data))
            :on-dir (lambda (dir) (octocat-tree-open repo ref dir))
            :on-browse (lambda () (octocat-tree-open repo ref)))
        (vui-text (octocat-tree--skeleton)))
      (if tree
          (vui-component 'octocat-repo-vui--docs-section
            :key shown :repo repo :ref (or shown default-branch "HEAD")
            :tree tree :raw raw)
        (octocat-repo-vui--docs-skeleton))))))

(vui-defcomponent octocat-repo-vui--tree-page (repo ref tracked reveal focus tick)
  "Root component of the tree browser: the whole tree of REF of REPO.
As GitHub's sidebar, it is opened down to REVEAL, and point goes to
FOCUS, an entry's path, once it is shown.  Above it are REF's picker
and REVEAL's path, its directories RET-able, then the root's last
commit, underlined, which expanding a directory leaves be.  REF is a branch, tag
or SHA, nil for TRACKED, the clone's branch, or else the default
branch."
  :render
  (let* ((buf            (current-buffer))
         (current-branch (plist-get (octocat--head-info) :branch))
         (summary        (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick)
                                    :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (shown          (or ref tracked))
         (head-snap      (octocat-vui-use-resource (list 'repo-head repo shown nil) tick))
         (root           (plist-get head-snap :data)))
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (octocat-vui-page
     (octocat-repo--pin repo (or ref tracked default-branch) reveal current-branch)
     (vui-vstack
      (octocat-repo-vui--top-line
       repo (or ref tracked default-branch) reveal current-branch nil
       (lambda (dir) (octocat-tree-open repo ref (octocat--nonempty dir)))
       (and (octocat-repo--resettable-p ref (or tracked default-branch))
            (octocat-repo-vui--reset-button (or tracked default-branch))))
      (vui-newline)
      (octocat-repo-vui--head-line repo ref nil head-snap)
      (if root
          ;; Each ref, and each opening from elsewhere, starts the tree
          ;; afresh.
          (vui-component 'octocat-tree--subtree
            :key (list shown reveal)
            :repo repo :branch (or shown default-branch "HEAD")
            :sha (gethash "tree" root) :commit (gethash "sha" root)
            :depth 0 :path "" :reveal reveal :focus focus)
        (vui-text (octocat-tree--skeleton)))))))

(defun octocat-repo--file-text (repo ref path content raw width)
  "Return file PATH's CONTENT as the file viewer is to show it.
Markdown, or another format of `octocat-repo--formats', is rendered,
unless RAW, its relative links into REPO at REF, to fit WIDTH; an
image is shown, see `octocat--image-text'; anything else is
highlighted as its major mode would.  A file larger
than `octocat--max-file-size', shown when asked, is plain text.  Long
lines are clipped, see `octocat--clip-line'."
  (let ((large (> (length content) octocat--max-file-size)))
    (cond ((and (not raw) (not large) (octocat-repo--format path))
           (octocat-repo--doc-text repo ref path content nil width))
          ((octocat--image-file-p path)
           (octocat--image-text content width))
          (t (let ((text (decode-coding-string content 'utf-8)))
               (octocat--clip-lines (if large text (octocat-tree--fontify path text))
                                    octocat--max-line-length))))))

(defun octocat-repo--file-notice (path head)
  "Return why the file viewer does not show file PATH unasked, or nil.
HEAD is PATH's `repo-head'.  A file that is not text, or is larger than
`octocat--max-file-size', is not fetched; an image always is."
  (let ((size (gethash "size" head)))
    (unless (octocat--image-file-p path)
      (cond ((gethash "binary" head)
             (format "A binary file%s; C-c C-o opens it on GitHub."
                     (if (integerp size)
                         (concat " of " (file-size-human-readable size))
                       "")))
            ((and (integerp size) (> size octocat--max-file-size))
             (format "A file of %s, too large to show at once; C-c C-o opens it on GitHub."
                     (file-size-human-readable size)))))))

(defun octocat-repo--blame-margin (commit width)
  "Return the blame margin of COMMIT, WIDTH wide.
That is its subject, cut to fit, then its age at the right, as GitHub's
blame shows it, RET opening the commit."
  (let* ((age     (let ((ts (octocat--commit-date commit)))
                    (if (string-empty-p ts) "" (octocat--format-ts-relative ts))))
         (subject (octocat-vui--subject commit))
         (shown   (truncate-string-to-width subject (max 1 (- width (string-width age) 2))
                                            nil nil "…")))
    (concat (propertize shown 'mouse-face 'highlight 'help-echo "RET: view commit"
                        'octocat-full-text (unless (equal shown subject) subject))
            (make-string (max 2 (- width (string-width shown) (string-width age))) ?\s)
            (propertize age 'face 'octocat-dimmed))))

(defconst octocat-repo--blame-width 32
  "The columns of the blame margin.
It is fixed, not a share of the window, so resizing it does not reflow
the blame.")

(defun octocat-repo--blame-column-width ()
  "Return the columns of the blame before the code: its margin and rule."
  (+ octocat-repo--blame-width 3))

(defun octocat-repo--blame-text (repo text ranges edge)
  "Return TEXT, a file of REPO, with the blame RANGES in a margin.
RANGES are as `octocat-model--repo-parse-blame' gives them.  The first line
of each range is headed by its commit, see `octocat-repo--blame-margin',
in `octocat-repo--blame-width' columns; every line is numbered, and the
last of a range is underlined to column EDGE, parting it from the next.
The blank margin of each other line has that head in `octocat-blame-head',
for `octocat-repo--blame-pin'.  RET on a range's margin opens its commit,
and \\[octocat-browse] browses it.  RANGES nil, while they load, puts
grey bars at the head of every few lines instead."
  (let* ((lines   (vconcat (split-string text "\n")))
         (num-w   (length (number-to-string (length lines))))
         (margin  octocat-repo--blame-width)
         (blank   (make-string margin ?\s))
         (sep     (propertize " │ " 'face 'octocat-dimmed))
         ;; The blame column, all but the code, slides in and out.
         (line    (lambda (n head)
                    (concat (propertize
                             (concat head sep
                                     (propertize (string-pad (number-to-string n) num-w nil t)
                                                 'face 'octocat-dimmed)
                                     " ")
                             'octocat-blame t 'octocat-markdown-copy 'drop)
                            (aref lines (1- n)))))
         (out     nil))
    (if (null ranges)
        (dotimes (i (length lines))
          (push (funcall line (1+ i)
                         (if (/= (% i 4) 0)
                             blank
                           (let ((bar (- margin 14 (% (* i 3) 9))))
                             (concat (octocat-vui-skeleton-bar bar)
                                     (make-string (- margin bar 10) ?\s)
                                     (octocat-vui-skeleton-bar 10)))))
                out))
      (seq-do
       (lambda (range)
         (let* ((commit (gethash "commit" range))
                (sha    (or (gethash "sha" commit) ""))
                (last   (min (gethash "end" range) (length lines)))
                (head   (octocat-repo--blame-margin commit margin))
                (map    (let ((m (make-sparse-keymap)))
                          (define-key m (kbd "RET")
                                      (lambda () (interactive)
                                        (octocat-vui--open-commit repo commit)))
                          m)))
           (cl-loop for n from (gethash "start" range) to (gethash "end" range)
                    while (<= n (length lines))
                    do (let* ((ruled (and (= n last) (< n (length lines))))
                              (s (funcall
                                  line n
                                  (propertize (if (= n (gethash "start" range))
                                                  head
                                                (propertize
                                                 blank 'octocat-blame-head
                                                 (if ruled
                                                     (let ((h (copy-sequence head)))
                                                       (add-face-text-property
                                                        0 (length h) 'octocat-blame-rule t h)
                                                       h)
                                                   head)))
                                              'keymap map
                                              'octocat-url (octocat--web-url "%s/commit/%s"
                                                                             repo sha)))))
                         (when ruled
                           (setq s (concat s (propertize " " 'display
                                                         `(space :align-to ,edge)
                                                         'octocat-markdown-copy 'drop)))
                           (add-face-text-property 0 (length s) 'octocat-blame-rule t s))
                         (push s out)))))
       ranges))
    (string-join (nreverse out) "\n")))

(defun octocat-repo--blame-pin (window &optional start)
  "Show in WINDOW the commit of the blame run its top line is in.
When the run's head is above the window, scrolled past, the top line's
blank margin shows it, from its `octocat-blame-head'.  START defaults to
WINDOW's start; the pin is WINDOW's, as each window's top differs."
  (setq octocat-repo--blame-pins
        (seq-remove (lambda (ov)
                      (when (or (eq (overlay-get ov 'window) window)
                                (not (window-live-p (overlay-get ov 'window)))
                                (not (overlay-buffer ov)))
                        (delete-overlay ov)
                        t))
                    octocat-repo--blame-pins))
  (unless octocat-repo--blame-sliding
    (let* ((bol  (save-excursion (goto-char (or start (window-start window)))
                                 (line-beginning-position)))
           (head (get-text-property bol 'octocat-blame-head)))
      (when head
        (let ((ov (make-overlay bol (next-single-property-change
                                     bol 'octocat-blame-head nil (point-max)))))
          (overlay-put ov 'window window)
          (overlay-put ov 'display head)
          (overlay-put ov 'evaporate t)
          (push ov octocat-repo--blame-pins))))))

(defun octocat-repo--blame-pin-all (buf)
  "Pin the blame's commit in each window showing BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (dolist (win (get-buffer-window-list buf nil t))
        (octocat-repo--blame-pin win)))))

(defun octocat-repo--blame-unpin (buf)
  "Take the blame's pins out of BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (mapc #'delete-overlay octocat-repo--blame-pins)
      (setq octocat-repo--blame-pins nil))))

(defun octocat-repo--mark-lines (text lines)
  "Return TEXT, a file's lines, each with its number in `octocat-file-line'.
LINES, (START . END) or nil, are highlighted in `octocat-line-highlight',
and START's line has `octocat-line-target', for the page to scroll to."
  (let ((text (copy-sequence text))
        (n 1) (beg 0))
    (while (< beg (length text))
      (let ((end (or (and (string-match "\n" text beg) (match-end 0)) (length text))))
        (put-text-property beg end 'octocat-file-line n text)
        (when (and lines (<= (car lines) n (cdr lines)))
          (add-face-text-property beg end 'octocat-line-highlight t text)
          (when (= n (car lines))
            (put-text-property beg end 'octocat-line-target t text)))
        (setq n (1+ n) beg end)))
    text))

(defun octocat-repo--source-text (path content)
  "Return file PATH's CONTENT highlighted, its long lines clipped."
  (string-remove-suffix
   "\n" (octocat--clip-lines (octocat-tree--fontify path (decode-coding-string content 'utf-8))
                             octocat--max-line-length)))

(vui-defcomponent octocat-repo-vui--file-blame (repo path blob commit lines)
  "The blame of file PATH, BLOB, of REPO at COMMIT: its source, highlighted,
each line beside the commit that last changed it, as GitHub's Blame.
LINES are as for `octocat-repo--mark-lines'."
  :render
  (let* ((buf   (current-buffer))
         (file  (octocat-vui-use-resource (list 'blob repo blob) nil))
         (snap  (octocat-vui-use-resource (list 'blame repo commit path) nil))
         (win   (get-buffer-window (current-buffer) t))
         (width (octocat-vui-window-width))
         ;; The page's width, but short of the window's edge, which
         ;; would mark the line cut.
         (edge  (if (and win (>= width (window-body-width win))) (1- width) width))
         ;; The source shows at once, grey bars beside it until the blame lands.
         (text  (vui-use-memo ((plist-get file :data) (plist-get snap :data) edge lines)
                  (and (plist-get file :data)
                       (octocat-repo--mark-lines
                        (octocat-repo--blame-text
                         repo (octocat-repo--source-text
                               path (octocat-model-blob-content (plist-get file :data)))
                         (plist-get snap :data) edge)
                        lines))))
         (ready (and text t)))
    (vui-use-effect (lines ready)
      (when (and lines ready) (octocat--goto-line-target buf))
      nil)
    ;; Each render puts in new text, which the pins must follow.
    (vui-use-effect (text)
      (add-hook 'window-scroll-functions #'octocat-repo--blame-pin nil t)
      (octocat-repo--blame-pin-all buf)
      (lambda ()
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (remove-hook 'window-scroll-functions #'octocat-repo--blame-pin t)))
        (octocat-repo--blame-unpin buf)))
    (cond ((eq (octocat-vui-snapshot-status file) 'error)
           (vui-text (octocat-vui-error-text file) :face 'error))
          ((eq (octocat-vui-snapshot-status snap) 'error)
           (vui-text (octocat-vui-error-text snap) :face 'error))
          (text (vui-text text))
          (t (vui-text (octocat-tree--skeleton))))))

(vui-defcomponent octocat-repo-vui--file-content (repo ref path blob raw lines)
  "The content of file PATH, BLOB, of REPO at REF.
RAW shows markdown as is.  In the code view, LINES are as for
`octocat-repo--mark-lines'."
  :render
  (let* ((buf   (current-buffer))
         (snap  (octocat-vui-use-resource (list 'blob repo blob) nil))
         (width (octocat--markdown-width))
         (code  (and (eq (octocat-file--view path raw nil) 'code)
                     (not (octocat--image-file-p path))))
         (text  (vui-use-memo ((plist-get snap :data) raw width lines)
                  (when-let* ((data (plist-get snap :data)))
                    (let ((text (octocat-repo--file-text repo ref path
                                                         (octocat-model-blob-content data)
                                                         raw width)))
                      (if code (octocat-repo--mark-lines text lines) text)))))
         (ready (and text t)))
    (vui-use-effect (lines ready)
      (when (and lines ready code) (octocat--goto-line-target buf))
      nil)
    (pcase (octocat-vui-snapshot-status snap)
      ('pending (vui-text (octocat-tree--skeleton)))
      ('error   (vui-text (octocat-vui-error-text snap) :face 'error))
      (_        (vui-text (string-remove-suffix "\n" (or text "")))))))

(defun octocat-repo-vui--view-segments (path raw blame)
  "Return the views of file PATH as segments of a pill, or nil.
The view shown, of RAW and BLAME, is current; the others show theirs,
their hint naming the key that cycles them.  See `octocat-file--views'
and `octocat-vui-segmented'."
  (when-let* ((views (octocat-file--views path)))
    (let ((shown (octocat-file--view path raw blame))
          (key   (substitute-command-keys "\\[octocat-file-cycle-view]")))
      (mapcar (lambda (view)
                (let ((label (capitalize (symbol-name view))))
                  (list label (eq view shown)
                        (propertize (format "RET: show the %s  %s: next view"
                                            (downcase label) key)
                                    'octocat-key-help t)
                        (lambda () (octocat-file-show-view view)))))
              views))))

(defun octocat-repo-vui--view-tabs (path raw blame)
  "Return the views of file PATH as a pill, as GitHub's, or nil.
See `octocat-repo-vui--view-segments' for RAW and BLAME."
  (when-let* ((segments (octocat-repo-vui--view-segments path raw blame)))
    (octocat-vui-segmented segments)))

(vui-defcomponent octocat-repo-vui--file-page (repo ref path raw blame lines tick)
  "Root component of the file viewer: file PATH of REPO at REF.
REF is a branch, tag or SHA, nil for the default branch.  Its top is
the tree browser's, so one reads on from the other: the picker of REF
and PATH, its directories RET-able, then the last commit of PATH,
underlined above the content.  Picking another ref opens the file at it
in its own buffer, see `octocat-file-switch-branch'.
RAW shows markdown as is, and BLAME the source beside the commits that
last changed it, see `octocat-file-cycle-view'.  A file too large to
show unasked, see `octocat-repo--file-notice', has a button to show it
ANYWAY.  LINES, (START . END), a link named: they are highlighted and
scrolled to, until the user's refresh, see `octocat-vui-refresh'."
  :state ((anyway nil))
  :render
  (let* ((buf            (current-buffer))
         (_              (octocat-vui-use-view-reset
                          (vui-async-callback ()
                            (when (buffer-live-p buf)
                              (with-current-buffer buf
                                (setq octocat-tree--file-lines nil)
                                (octocat-vui-update-page :lines nil))))))
         (current-branch (plist-get (octocat--head-info) :branch))
         (summary        (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick)
                                    :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (head-snap      (octocat-vui-use-resource (list 'repo-head repo ref path) tick))
         (head           (plist-get head-snap :data))
         (blob           (and head (equal (gethash "kind" head) "blob")
                              (gethash "tree" head)))
         (notice         (and blob (not anyway) (octocat-repo--file-notice path head))))
    (octocat-vui-page
     (octocat-repo--pin repo (or ref default-branch) path current-branch
                        (octocat-vui-segmented-pin
                         (octocat-repo-vui--view-segments path raw blame)))
     (vui-vstack
      (octocat-repo-vui--top-line
       repo (or ref default-branch) path current-branch #'octocat-file-switch-branch
       (lambda (dir) (octocat-tree-open repo ref (octocat--nonempty dir)))
       (octocat-repo-vui--view-tabs path raw blame))
      (vui-newline)
      (octocat-repo-vui--head-line repo ref path head-snap)
      (cond (notice
             (apply #'vui-hstack :spacing 2
                    (vui-text notice :face 'octocat-dimmed)
                    ;; Not a binary file: it would show as garbage.
                    (unless (gethash "binary" head)
                      (list (vui-button "[Show anyway]"
                              :no-decoration t
                              :help-echo "RET: fetch the file and show it as plain text"
                              :on-click (lambda () (vui-set-state :anyway t)))))))
            ((and blob blame)
             (vui-component 'octocat-repo-vui--file-blame
               :key blob :repo repo :path path :blob blob :commit (gethash "sha" head)
               :lines lines))
            (blob
             (vui-component 'octocat-repo-vui--file-content
               :key blob :repo repo :ref (or ref default-branch "HEAD")
               :path path :blob blob :raw raw :lines lines))
            ;; The head line says why there is none.
            ((eq (octocat-vui-snapshot-status head-snap) 'pending)
             (vui-text (octocat-tree--skeleton))))))))

(vui-defcomponent octocat-repo-vui--commits-page (repo ref tracked path tick)
  "Root component of the commits page: the history of REF of REPO.
REF is a branch, tag or SHA, nil for TRACKED, the clone's branch, or
else the default branch.  PATH, when non-nil, keeps the commits that
touched it, as GitHub's History."
  :render
  (let* ((buf            (current-buffer))
         (head-info      (octocat--head-info))
         (summary        (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick)
                                    :data))
         (default-branch (and summary (gethash "default-branch" summary))))
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (octocat-vui-page
     (octocat-repo--pin repo (or ref tracked default-branch) path
                        (plist-get head-info :branch))
     (vui-vstack
      ;; No tabs: only the repo root and the list pages show them.
      (vui-component 'octocat-repo-vui--commits-section
        :key (list (or ref tracked) path)
        :repo repo :ref (or ref tracked) :path path
        :default-branch (or tracked default-branch)
        :current-branch (plist-get head-info :branch)
        :head-info head-info :tick tick)))))


;;;; Major mode

(defun octocat-repo--page-url ()
  "Return the URL of the tree entry at point, or else of the page.
That is the ref shown, or on the commits page its commits."
  (when-let* ((repo octocat-repo--repo))
    (let* ((shown  (or octocat-repo--ref octocat-repo--tracked))
           (branch (or shown octocat-repo--default-branch "HEAD"))
           ;; The default branch is what the bare repository URL shows.
           (ref    (unless (equal shown octocat-repo--default-branch) shown))
           (path   (and (derived-mode-p 'octocat-commit-list-mode) octocat-repo--path))
           (type   (octocat-tree--type-at-point)))
      (cond ((derived-mode-p 'octocat-commit-list-mode)
             (octocat--web-url "%s/commits%s" repo
                               (cond (path (concat "/" branch "/" path))
                                     (ref  (concat "/" ref))
                                     (t    ""))))
            ((memq type '(file dir))
             (octocat-tree--entry-url repo branch type (octocat-tree--path-at-point)))
            (ref (octocat--web-url "%s/tree/%s" repo ref))
            (t   (octocat--web-url "%s" repo))))))

(defun octocat-repo--show-ref (ref)
  "Show REF on this page, nil to follow the clone, in place.
The tree browser stays in its directory, as GitHub's does."
  (setq octocat-repo--ref ref
        octocat-repo--focus nil)
  (or (if (derived-mode-p 'octocat-tree-mode)
          (octocat-vui-update-page :ref ref :focus nil)
        (octocat-vui-update-page :ref ref))
      (funcall revert-buffer-function)))

(defun octocat-repo-up ()
  "Move point to the directory containing the tree entry at point."
  (interactive)
  (let* ((path   (and (derived-mode-p 'octocat-tree-mode) (octocat-tree--path-at-point)))
         (parent (and path (octocat-tree--parent path))))
    (unless (and parent (not (string-empty-p parent)))
      (user-error "Octocat: Already at the top"))
    (octocat-tree--goto-path parent)))

(defun octocat-repo-switch-branch ()
  "Show another branch, picked from the repository's."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let* ((default octocat-repo--default-branch)
         (home    (or octocat-repo--tracked default))
         (picked  (octocat--read-branch
                   octocat-repo--repo default (plist-get (octocat--head-info) :branch)
                   (or octocat-repo--ref home))))
    (octocat-repo--show-ref (unless (equal picked home) picked))))

(defun octocat-repo-reset-branch ()
  "Show the clone's checked-out branch again, or else the default branch."
  (interactive)
  (octocat-repo--show-ref nil))

(defvar octocat-repo-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "^") #'octocat-repo-up)
    (define-key map (kbd "C-c C-f") #'octocat-tree-find-file)
    (define-key map (kbd "C-c C-b") #'octocat-repo-switch-branch)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    map)
  "Keymap for `octocat-repo-mode'.")

(define-derived-mode octocat-repo-mode octocat-page-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-repo-refresh)
  (add-hook 'window-buffer-change-functions #'octocat-repo--follow-checkout nil t)
  (add-hook 'window-selection-change-functions #'octocat-repo--follow-checkout nil t)
  (setq-local octocat--url-function #'octocat-repo--page-url)
  (setq-local octocat--repo-function (lambda () octocat-repo--repo))
  (setq-local octocat-image-file-function #'octocat-tree--image-file
              octocat-image-proxy-function #'octocat-tree--proxied-url))

;; The commits page and the tree browser derive from the repo page, for
;; its state: so `C-c C-b', `C-c C-f' and `C-c C-o' work on them alike.
(define-derived-mode octocat-tree-mode octocat-repo-mode "Octocat-Tree"
  "Major mode for browsing the whole tree of a repository's ref.

\\{octocat-tree-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-tree-refresh))

(define-derived-mode octocat-commit-list-mode octocat-repo-mode "Octocat-Commits"
  "Major mode for the commits of a repository's branch, tag or commit.

\\{octocat-commit-list-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-commit-list-refresh))

;; Not derived from the repo page: a file has state of its own.
(defvar octocat-file-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    (define-key map (kbd "C-c C-f") #'octocat-tree-find-file)
    (define-key map (kbd "C-c C-l") #'octocat-file-log-open)
    (define-key map (kbd "C-c C-b") #'octocat-file-switch-branch)
    (define-key map (kbd "C-c C-v") #'octocat-file-cycle-view)
    map)
  "Keymap for `octocat-file-mode'.")

(define-derived-mode octocat-file-mode octocat-page-mode "Octocat-File"
  "Major mode for a GitHub file: highlighted, or rendered if markdown or org.

\\{octocat-file-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-file-refresh)
  (setq-local octocat--url-function #'octocat-file--page-url)
  (setq-local octocat--repo-function (lambda () octocat-tree--file-repo))
  (setq-local octocat-image-file-function #'octocat-tree--image-file
              octocat-image-proxy-function #'octocat-tree--proxied-url))

;;;; Interactive commands — tree

(defun octocat-tree-visit ()
  "Open the file or the directory at point.
On a button, such as the header's branch picker, press it: Evil's RET
binding outranks the button's own."
  (interactive)
  (unless (vui-activate)
    (when-let* ((activate (octocat-tree--activate-at-point)))
      (funcall activate))))

(defun octocat-tree--file-ref (repo branch)
  "Return the name the file viewer gives BRANCH of REPO.
\"HEAD\", nil or \"\", the default branch, is named when it is known."
  (if (member branch '(nil "" "HEAD"))
      (let ((summary (plist-get (octocat-sync-read (list 'repo-summary repo)) :data)))
        (or (and summary (gethash "default-branch" summary)) "HEAD"))
    branch))

(defun octocat-tree--open-file-by-path (repo branch path &optional at)
  "Open the file viewer of PATH in REPO at BRANCH.
Each ref of a file has a buffer of its own, named after both.  AT,
\(lines START END) as `octocat--url-lines' reads a link, highlights
those lines and scrolls to them; a rendered file shows its code."
  (let* ((branch (octocat-tree--file-ref repo branch))
         (buf    (get-buffer-create (format "*%s@%s:%s*" repo branch path))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-file-mode)
      (octocat-file-mode))
    (setq octocat-tree--file-repo   repo
          octocat-tree--file-path   path
          octocat-tree--file-branch branch)
    (when at
      (setq octocat-tree--file-lines (cons (nth 1 at) (nth 2 at)))
      (when (octocat-repo--format path)
        (setq octocat--markdown-raw t)))
    (octocat-file-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'file)) repo branch path &optional at)
  "Open file PATH of REPO at BRANCH, AT the lines a link named.
See `octocat-tree--open-file-by-path'."
  (apply #'octocat-tree--open-file-by-path repo branch path (and at (list at))))

(defun octocat-file-switch-branch ()
  "Open this file at another branch, in a buffer of its own."
  (interactive)
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let* ((repo    octocat-tree--file-repo)
         (default (octocat-tree--file-ref repo nil))
         (picked  (octocat--read-branch repo (unless (equal default "HEAD") default)
                                        (plist-get (octocat--head-info) :branch)
                                        octocat-tree--file-branch)))
    (octocat-tree--open-file-by-path repo picked octocat-tree--file-path)))

(defun octocat-tree--find-file-start (path type)
  "Return (INITIAL . DEFAULT) for finding a file from PATH, of TYPE.
PATH is the file shown or the entry at point, nil for none; TYPE is
`file' or `dir'.  INITIAL is the directory to start in, as `find-file'
starts in the current one, and DEFAULT the file itself."
  (when path
    (if (eq type 'dir)
        (cons (file-name-as-directory path) nil)
      (cons (file-name-directory path) path))))

(defun octocat-tree-find-file ()
  "Visit a file of the local clone, as `find-file' does.
The prompt starts in the clone's copy of the file shown, or of the
entry at point, so RET visits it.  Without a local clone, this is a
plain `find-file'."
  (interactive)
  (pcase-let* ((`(,dir . ,file)
                (if (derived-mode-p 'octocat-file-mode)
                    (octocat-tree--find-file-start octocat-tree--file-path 'file)
                  (octocat-tree--find-file-start (octocat-tree--path-at-point)
                                                 (octocat-tree--type-at-point))))
               (local-dir (cond ((derived-mode-p 'octocat-repo-mode) octocat-repo--local-dir)
                                ((derived-mode-p 'octocat-file-mode)
                                 (and octocat-tree--file-repo
                                      (octocat-repo--local-dir-for octocat-tree--file-repo)))
                                (t (user-error "Octocat: Not in a repo or file buffer")))))
    (if (not local-dir)
        (call-interactively #'find-file)
      (find-file (read-file-name "Find file: "
                                 (file-name-as-directory (expand-file-name (or dir "") local-dir))
                                 (and file (expand-file-name file local-dir))
                                 nil (and file (file-name-nondirectory file)))))))

(defun octocat-tree--entry-url (repo ref type path)
  "Return the web URL of the tree entry at PATH of REPO at REF.
TYPE is `file' or `dir'."
  (octocat--web-url "%s/%s/%s/%s"
                    repo (if (eq type 'file) "blob" "tree") ref path))


;;;; Interactive commands — file mode

(defun octocat-file-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file viewer, in place."
  (interactive)
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (octocat-vui-refresh-page
   'octocat-repo-vui--file-page
   (list octocat-tree--file-repo octocat-tree--file-branch octocat-tree--file-path)
   (list :repo octocat-tree--file-repo
         :ref (unless (equal octocat-tree--file-branch "HEAD") octocat-tree--file-branch)
         :path octocat-tree--file-path
         :raw octocat--markdown-raw
         :blame octocat-tree--file-blame
         :lines octocat-tree--file-lines)))

(defun octocat-file--views (path)
  "Return the views of file PATH, in the order `octocat-file-cycle-view' takes.
They are GitHub's: `preview', for markdown and org, `code' and `blame'.
An image has none."
  (unless (octocat--image-file-p path)
    (if (octocat-repo--format path) '(preview code blame) '(code blame))))

(defun octocat-file--view (path raw blame)
  "Return the view of file PATH shown with RAW and BLAME.
It is one of `octocat-file--views'."
  (cond (blame 'blame)
        ((and (not raw) (octocat-repo--format path)) 'preview)
        (t 'code)))

(defun octocat-file-show-view (view)
  "Show the file in VIEW, one of `octocat-file--views'.
The blame slides in from the left edge, and back out of it; the page's
cap widens by its column, so the code keeps its width."
  (unless (and (derived-mode-p 'octocat-file-mode) octocat-tree--file-path)
    (user-error "Octocat: Not in a file viewer buffer"))
  (let ((buf  (current-buffer))
        (show (lambda ()
                (setq octocat-tree--file-blame (eq view 'blame)
                      octocat--markdown-raw (eq view 'code)
                      octocat--cap-extra (if octocat-tree--file-blame
                                             (octocat-repo--blame-column-width)
                                           0))
                (octocat-vui-update-page :raw octocat--markdown-raw
                                         :blame octocat-tree--file-blame))))
    (cond ((eq view (octocat-file--view octocat-tree--file-path octocat--markdown-raw
                                        octocat-tree--file-blame)))
          (octocat-tree--file-blame
           (octocat-repo--blame-unpin buf)
           (setq octocat-repo--blame-sliding t)
           (octocat-vui-slide buf 'octocat-blame 'out
                              (lambda ()
                                (setq octocat-repo--blame-sliding nil)
                                (funcall show))))
          ((eq view 'blame)
           ;; The pin waits for the column, which it would cover.
           (setq octocat-repo--blame-sliding t)
           (funcall show)
           (octocat-vui-slide buf 'octocat-blame 'in
                              (lambda ()
                                (setq octocat-repo--blame-sliding nil)
                                (octocat-repo--blame-pin-all buf))))
          (t (funcall show)))))

(defun octocat-file-cycle-view ()
  "Show the file the next way, as GitHub's Preview, Code and Blame.
Markdown and org go from rendered to raw to blame; other files from
their source to blame.  The blame shows each line beside the commit
that last changed it."
  (interactive)
  (unless (and (derived-mode-p 'octocat-file-mode) octocat-tree--file-path)
    (user-error "Octocat: Not in a file viewer buffer"))
  (let* ((views (or (octocat-file--views octocat-tree--file-path)
                    (user-error "Octocat: An image has no other view")))
         (view  (octocat-file--view octocat-tree--file-path octocat--markdown-raw
                                    octocat-tree--file-blame))
         (next  (or (cadr (memq view views)) (car views))))
    (message "File view: %s" (capitalize (symbol-name next)))
    (octocat-file-show-view next)))

(defun octocat-file--page-url ()
  "Return the URL of the current file, at the line of point or the region.
In the code view of a rendered format it has ?plain=1, or GitHub would
show the preview, where a line has no place."
  (and octocat-tree--file-repo octocat-tree--file-branch octocat-tree--file-path
       (let* ((span  (octocat--point-or-region))
              (start (get-text-property (car span) 'octocat-file-line))
              (end   (get-text-property (cdr span) 'octocat-file-line))
              (start (or start end))
              (end   (or end start)))
         (concat (octocat--web-url "%s/blob/%s/%s"
                                   octocat-tree--file-repo
                                   octocat-tree--file-branch
                                   octocat-tree--file-path)
                 (when start
                   (concat (and (octocat-repo--format octocat-tree--file-path) "?plain=1")
                           "#" (octocat--lines-fragment start end)))))))

;;;; File history

(defun octocat-file-log-open ()
  "Open the commits page of the file shown, from its ref back.
It is the page `[N commits]' opens, see `octocat-commit-list-open'."
  (interactive)
  (unless (and (derived-mode-p 'octocat-file-mode)
               octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Not in a file viewer buffer"))
  (octocat-commit-list-open octocat-tree--file-repo
                            (unless (equal octocat-tree--file-branch "HEAD")
                              octocat-tree--file-branch)
                            octocat-tree--file-path))


;;;; Async refresh

(defun octocat-repo-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-repo buffer, in place.
Every section fetches its own data independently (see the Commentary at
the top of this file)."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--root octocat-repo--repo
                            (list :repo octocat-repo--repo
                                  :ref octocat-repo--ref
                                  :tracked (octocat-repo--sync-checkout)
                                  :local-dir octocat-repo--local-dir
                                  :raw octocat--markdown-raw
                                  :unpushed (and octocat-repo--local-dir
                                                 (octocat-repo--unpushed
                                                  octocat-repo--local-dir)))))

(cl-defmethod octocat-open ((_kind (eql 'repo)) repo &optional ref)
  "Open (or switch to) the *REPO* buffer, at REF; see `octocat-visit-repo'."
  (let* ((buf-name (format "*%s*" repo))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref)
    (octocat-repo-refresh)))

(defun octocat-tree-open (repo &optional ref path)
  "Open (or switch to) the tree browser of REPO at REF.
REF is a branch, tag or SHA, nil to follow the local clone's branch.
PATH, a directory or file, is the one the tree opens down to, with point on it."
  (let ((buf (get-buffer-create (format "*%s tree*" repo))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-tree-mode)
      (octocat-tree-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref
          octocat-repo--reveal    path
          octocat-repo--focus     path)
    (octocat-tree-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'tree)) repo &optional ref path)
  "Open the tree of REPO at REF and PATH, as `octocat-tree-open'."
  (octocat-tree-open repo ref path))

(defun octocat-tree-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current tree browser, in place."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--tree-page octocat-repo--repo
                            (list :repo octocat-repo--repo :ref octocat-repo--ref
                                  :tracked (octocat-repo--sync-checkout)
                                  :reveal octocat-repo--reveal
                                  :focus octocat-repo--focus)))

(defun octocat-commit-list-open (repo &optional ref path)
  "Open (or switch to) the commits page of REPO, from REF back.
REF is a branch, tag or SHA, nil to follow the local clone's branch.
PATH, a file or directory, keeps the commits that touched it."
  (let ((buf (get-buffer-create (format "*%s commits*" repo))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-commit-list-mode)
      (octocat-commit-list-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref
          octocat-repo--path      path)
    (octocat-commit-list-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'commit-list)) repo &optional ref path)
  "Open the commits of REPO at REF and PATH, as `octocat-commit-list-open'."
  (octocat-commit-list-open repo ref path))

(defun octocat-commit-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commits page, in place."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--commits-page octocat-repo--repo
                            (list :repo octocat-repo--repo :ref octocat-repo--ref
                                  :tracked (octocat-repo--sync-checkout)
                                  :path octocat-repo--path)))

;; NOTE: the `M-x octocat-repo' entry point itself (the `;;;###autoload'
;; command) is defined in `octocat.el', not here -- see CONTRIBUTING.md,
;; "Entry points".  This keeps every `;;;###autoload' command funneled
;; through a single file, so loading any octocat entry point always loads
;; `octocat.el' and its `octocat--evil-init' trigger.  This file supplies
;; everything the command needs: `octocat-repo-mode', `octocat-repo--repo',
;; `octocat-repo--local-dir', `octocat-repo--current-repo', and
;; `octocat-repo-refresh'.

(provide 'octocat-repo)
;;; octocat-repo.el ends here

