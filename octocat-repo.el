;;; octocat-repo.el --- Per-repository view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Per-repository overview buffer, as GitHub's Code tab: the ref shown
;; with its last commit, the root's first files (octocat-tree.el) and
;; its README.  Two pages of their own are here too: the whole tree,
;; `octocat-tree-mode', which RET on a directory opens, and the history
;; of the ref or of a path, `octocat-commits-mode'.
;; The PR, issue and workflow/run lists live on their own pages; this
;; file still holds their shared row builders and fetchers.
;; The `M-x octocat-repo' entry point is defined in octocat.el (see
;; CONTRIBUTING.md, "Entry points"); this file defines `octocat-repo-mode'
;; and all of its supporting logic.

;;; Code:

(require 'octocat-core)
(require 'seq)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-pr-diff)
(require 'octocat-issue)
(require 'octocat-workflow)
(require 'octocat-run)
(require 'octocat-job)
(require 'octocat-checks)
(require 'octocat-tree)
(require 'octocat-search) ; `octocat--read-branch'
(require 'octocat-vui)

(declare-function octocat-vui-repo-heading "octocat-vui" (repo &optional ref here))
(require 'vui)
(require 'vui-components) ; vui-collapsible, vui-heading-*, etc.

;; Cross-file calls: declared per AGENTS.md's "Byte-compiler warnings about
;; functions not known to be defined" -- `make ci' compiles all files in
;; parallel, so a plain `require' does not guarantee the callee is already
;; compiled when this file is.
(declare-function octocat-run-open                 "octocat-run"      (repo run-id))
(declare-function octocat-tree-find-file           "octocat-tree"     ())
(declare-function octocat-issue-list               "octocat"          ())
(declare-function octocat-pr-list                  "octocat"          ())
(declare-function octocat-actions                  "octocat"          ())
(declare-function octocat-user-open                "octocat-user"     (login))


;;;; User options

(defcustom octocat-section-limit 15
  "Default number of items to display per paged section.
Used as the initial page size for workflow runs and user repos.  Each
section starts with this many items and increments by this amount
every time its \"Load more\" button is used."
  :type 'integer
  :group 'octocat)

(defcustom octocat-repo-commits-page-size 25
  "Number of commits the commits page shows, and loads, at a time."
  :type 'integer
  :group 'octocat)

(defcustom octocat-repo-doc-lines 20
  "Lines of the repo buffer's README shown before the rest is folded away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
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
  "Ref the page shows: a branch, tag or SHA, or nil for the default branch.
Chosen with `octocat-repo-switch-branch' or by a github.com link; kept
by `g', cleared when the page is opened anew.")

(defvar-local octocat-repo--path nil
  "The tree browser's directory, or the path the commits page is of.
Nil is the root, or all the commits.")

(defvar-local octocat-repo--reveal nil
  "Path the tree browser was opened down to, or nil.")

(defvar-local octocat-repo--focus nil
  "Path of the entry for the tree browser to put point on, or nil.")

(defvar-local octocat-repo--default-branch nil
  "The repository's default branch, once its summary is known.")


;;;; Repo detection

(defun octocat-repo--current-repo ()
  "Return the \"owner/repo\" string for the current Git repository.
Reads the \\='origin\\=' remote URL and parses both SSH and HTTPS
GitHub remote forms.  Signals an error when the working directory
is not inside a GitHub repository."
  (let ((url (string-trim
              (shell-command-to-string
               "git remote get-url origin 2>/dev/null"))))
    (when (string-empty-p url)
      (user-error "Octocat: Could not find a Git remote named `origin'"))
    (or
     ;; SSH:  git@github.com:owner/repo.git
     (and (string-match
           "git@github\\.com:\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     ;; HTTPS: https://github.com/owner/repo[.git]
     (and (string-match
           "https://github\\.com/\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     (user-error "Octocat: `%s' does not look like a GitHub remote" url))))


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


;;;; gh integration

(defun octocat-repo--list-workflows (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(defun octocat-repo--list-workflow-runs (repo workflow-id callback)
  "Fetch recent run history for WORKFLOW-ID in REPO asynchronously.
Retrieves the 20 most recent entries and calls CALLBACK with a list of
run hash-tables, or a cons \\=(error . MSG) on failure."
  (octocat--run-gh
   (format "workflow-runs-%d" workflow-id)
   (list "run" "list"
         "--repo"     repo
         "--workflow" (number-to-string workflow-id)
         "--limit"    "20"
         "--json"     "databaseId,displayTitle,status,conclusion,createdAt,headBranch")
   #'octocat--parse-json-list
   callback))

(defun octocat-repo--list-recent-runs (repo limit callback &optional args)
  "Fetch the LIMIT most recent workflow run entries across all workflows in REPO.
ARGS are more `gh run list' options, filtering the runs, such as
\\=(\"--branch\" \"main\").  Call CALLBACK with a list of run hash-tables
\(each including a \\='workflowName\\=' key), or a cons \\=(error . MSG) on
failure."
  (octocat--run-gh
   "recent-runs"
   (append
    (list "run" "list"
          "--repo"  repo
          "--limit" (number-to-string limit)
          "--json"  "databaseId,displayTitle,status,conclusion,createdAt,headBranch,workflowName")
    args)
   #'octocat--parse-json-list
   callback))

(defconst octocat-repo--history-query
  "query($owner:String!,$name:String!,$ref:String!,$limit:Int!,$after:String,$path:String){repository(owner:$owner,name:$name){object(expression:$ref){...on Commit{history(first:$limit,after:$after,path:$path){edges{cursor node{oid messageHeadline authoredDate author{name email user{login}}}}}}}}}"
  "GraphQL query behind `octocat-repo--list-commits'.
Only what a row shows: the REST commits endpoint sends ~15 times as much.")

(defun octocat-repo--list-commits (repo ref path callback &optional after)
  "Fetch a page of the commits of REPO, from REF back.
REF is a branch or SHA; nil means the head of the default branch.  PATH,
when non-nil, keeps only the commits that touched it.
AFTER, a commit's \"cursor\", fetches the page after that commit.  A
page holds `octocat-repo-commits-page-size' commits.  Calls CALLBACK with
a list of commits from `octocat-repo--parse-history', or a cons
\\=(error . MSG)."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "commits"
     (append (list "api" "graphql"
                   "-f" (concat "query=" octocat-repo--history-query)
                   "-f" (concat "owner=" (car parts))
                   "-f" (concat "name=" (cadr parts))
                   "-f" (concat "ref=" (or ref "HEAD"))
                   "-F" (format "limit=%d" octocat-repo-commits-page-size))
             (and after (list "-f" (concat "after=" after)))
             (and path (list "-f" (concat "path=" path))))
     #'octocat-repo--parse-history
     callback)))

(defun octocat-repo--history-commit (node)
  "Return the commit NODE of a GraphQL history shaped as REST has it.
That is what the rows read: \"sha\"; \"commit\", with the \"message\"
\(its headline only) and the git \"author\" (name, email, date); and
\"author\", the GitHub user or :null."
  (let* ((a      (gethash "author" node))
         (user   (and (hash-table-p a) (gethash "user" a)))
         (git    (make-hash-table :test #'equal))
         (c      (make-hash-table :test #'equal))
         (commit (make-hash-table :test #'equal)))
    (when (hash-table-p a)
      (puthash "name" (gethash "name" a) git)
      (puthash "email" (gethash "email" a) git))
    (puthash "date" (gethash "authoredDate" node) git)
    (puthash "message" (gethash "messageHeadline" node) c)
    (puthash "author" git c)
    (puthash "sha" (gethash "oid" node) commit)
    (puthash "commit" c commit)
    (puthash "author" (if (hash-table-p user) user :null) commit)
    commit))

(defun octocat-repo--parse-history (json-string)
  "Parse the commit history response JSON-STRING into a list of commits.
Each is shaped by `octocat-repo--history-commit', with its \"cursor\",
for the page after it."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (obj  (and (hash-table-p repo) (gethash "object" repo))))
    (unless (hash-table-p obj)
      (error "No such branch or commit"))
    (mapcar (lambda (edge)
              (let ((commit (octocat-repo--history-commit (gethash "node" edge))))
                (puthash "cursor" (gethash "cursor" edge) commit)
                commit))
            (gethash "edges" (gethash "history" obj)))))

(defconst octocat-repo--head-query
  "query($owner:String!,$name:String!,$expr:String!,$dir:String!,$path:String){repository(owner:$owner,name:$name){object(expression:$expr){...on Commit{history(first:1,path:$path){totalCount nodes{oid messageHeadline authoredDate author{name email user{login}}}}}} dir:object(expression:$dir){__typename oid}}}"
  "GraphQL query behind `octocat-repo--fetch-head'.")

(defun octocat-repo--parse-head (json-string ref path)
  "Parse the response JSON-STRING of `octocat-repo--head-query'.
It is for PATH, nil for the root, at REF.  Return the last commit that
touched PATH, as `octocat-repo--history-commit' shapes it, with
\"tree\", the SHA of PATH's tree, or its blob's when \"kind\" is
\"blob\", and \"total\", the commits that touched PATH."
  (let* ((repo   (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (obj    (and (hash-table-p repo) (gethash "object" repo)))
         (dir    (and (hash-table-p repo) (gethash "dir" repo)))
         (hist   (and (hash-table-p obj) (gethash "history" obj)))
         (nodes  (and hist (gethash "nodes" hist)))
         (node   (and (> (length nodes) 0) (aref nodes 0))))
    (unless (hash-table-p obj)
      (error "No branch, tag or commit %s" (or ref "HEAD")))
    (unless (and (hash-table-p dir) (hash-table-p node))
      (error "No %s at %s" path (or ref "HEAD")))
    (let ((commit (octocat-repo--history-commit node)))
      (puthash "tree" (gethash "oid" dir) commit)
      (puthash "kind" (if (equal (gethash "__typename" dir) "Blob") "blob" "tree") commit)
      (puthash "total" (gethash "totalCount" hist) commit)
      commit)))

(defun octocat-repo--fetch-head (repo ref path callback)
  "Fetch the last commit and the tree of PATH of REPO at REF.
REF is a branch, tag or SHA, as on github.com, nil for the default
branch; PATH nil is the root.  Calls CALLBACK with the commit from
`octocat-repo--parse-head', or a cons \\=(error . MSG)."
  (let ((parts (split-string repo "/"))
        (rev   (or ref "HEAD")))
    (octocat--run-gh
     "repo-head"
     (append (list "api" "graphql"
                   "-f" (concat "query=" octocat-repo--head-query)
                   "-f" (concat "owner=" (car parts))
                   "-f" (concat "name=" (cadr parts))
                   ;; Peels an annotated tag to its commit.
                   "-f" (concat "expr=" rev "^{commit}")
                   "-f" (concat "dir=" rev ":" path))
             (and path (list "-f" (concat "path=" path))))
     (lambda (json) (octocat-repo--parse-head json ref path))
     callback)))

(octocat-sync-define-resource repo-head (repo ref path)
  :fetch (lambda (done) (octocat-repo--fetch-head repo ref path done)))

(defconst octocat-repo--doc-kinds
  '((readme   "README"          "readme")
    (coc      "Code of conduct" "code[-_]of[-_]conduct")
    (contrib  "Contributing"    "contributing")
    (license  "License"         "\\(?:licen[cs]e\\|copying\\)")
    (security "Security"        "security"))
  "The documents GitHub offers below a repository's files, in its order.
Each is (KIND LABEL STEM): a root file is one when its name, ignoring
case, is STEM, a regexp, with or without an extension.")

(defun octocat-repo--markdown-file-p (name)
  "Return non-nil when file NAME is markdown, by its extension."
  (string-match-p "\\.\\(?:md\\|markdown\\|mdown\\|mkdn?\\)\\'" (downcase name)))

(defun octocat-repo--docs (entries)
  "Return the documents among ENTRIES, the root's `tree-dir' entries.
Each is (KIND LABEL ENTRY), in the order of `octocat-repo--doc-kinds'.
Of several files of a kind a markdown one wins, then the shortest name,
so README.md beats README.txt and README."
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
                            (+ (if (octocat-repo--markdown-file-p n) 0 1000)
                               (length n))))))
             (when hits
               (list kind label
                     (car (sort hits (lambda (a b) (< (funcall rank a)
                                                      (funcall rank b)))))))))
         octocat-repo--doc-kinds)))

(defun octocat-repo--commits-merge (base &rest others)
  "Return the longest of BASE and OTHERS with the head commit of BASE.
Each is a commit list from the top of a history.  A history is fixed by
its head SHA, so lists with the same head are prefixes of one another
and the longest knows the most; one with another head is out of date."
  (let ((head (and base (gethash "sha" (car base)))))
    (seq-reduce (lambda (best l)
                  (if (and l (equal (gethash "sha" (car l)) head)
                           (> (length l) (length best)))
                      l
                    best))
                others base)))

;;;; Row rendering
;;
;; The generic row / sticky-async / load-more helpers live in
;; `octocat-vui.el'; only the per-entity row builders are here (see
;; "Row builders" below).


;;;; Navigation
;;
;; Each of these opens (or switches to) the corresponding detail buffer,
;; from a row's RET handler.

(defun octocat-repo-vui--open-pr (repo pr)
  "Open the PR detail buffer for PR (a hash-table) in REPO."
  (octocat-pr-open repo (gethash "number" pr)))

(defun octocat-repo-vui--open-issue (repo issue)
  "Open the issue detail buffer for ISSUE (a hash-table) in REPO."
  (octocat-issue-open repo (gethash "number" issue)))

(defun octocat-repo-vui--open-commit (repo commit)
  "Open the commit detail buffer for COMMIT (a hash-table) in REPO."
  (octocat-commit-open repo (or (gethash "sha" commit) (gethash "oid" commit) "")))

(defun octocat-repo-vui--open-workflow (repo workflow)
  "Open the workflow detail buffer for WORKFLOW (a hash-table) in REPO."
  (octocat-workflow-open repo (gethash "id" workflow)
                         (or (gethash "name" workflow) "")
                         (gethash "path" workflow)))

(defun octocat-repo-vui--open-workflow-run (repo run)
  "Open the workflow-run detail buffer for RUN (a hash-table) in REPO."
  (octocat-run-open repo (gethash "databaseId" run)))


;;;; Row builders

(defconst octocat-repo-vui--state-width 6
  "Display width of the state column (\"closed\", \"merged\") in PR and issue rows.")

(defun octocat-repo-vui--state-label (state &optional draft)
  "Return the coloured, padded state text for a PR/issue STATE (any case).
DRAFT is the JSON isDraft value; t shows an open pull request as \"draft\"."
  (let* ((state (downcase (or state "open")))
         (text  (cond ((equal state "merged") "merged")
                      ((equal state "closed") "closed")
                      ((eq draft t) "draft")
                      (t "open")))
         (face  (cond ((equal text "merged") 'octocat-pr-state-merged)
                      ((equal text "closed") 'octocat-pr-state-closed)
                      ((equal text "draft")  'octocat-dimmed)
                      (t                     'octocat-pr-state-open))))
    (propertize (format (format "%%-%ds" octocat-repo-vui--state-width) text)
                'face face)))

;; PR and issue rows are two lines, each cut to the window width, as
;; GitHub's: the title and its labels, then its number, who opened it
;; and when, and a dimmed line about its review, checks and comments.
;; The title gives way to the labels.  The branch is left to the page.
;;
;;   open  Another dummy PR  duplicate enhancement
;;         owner/repo#5 by @me · 3 days ago · Review required · ✓ 4/5

(defun octocat-repo-vui--cells (repo item bg)
  "Return the display cells of the PR or issue ITEM of REPO as a plist.
The keys are :title, :chips (label chips), :review, :ci, :author, :prs
\(the PRs that close an issue), :comments, :date and :number
\(\"owner/repo#N\");
a cell that ITEM does not have is nil or empty.  BG is as for
`octocat--label-face'."
  (let* ((checks   (gethash "statusCheckRollup" item))
         (closers  (gethash "closedByPullRequestsReferences" item))
         ;; A list row's item has the count; a page's, the comments.
         (comments (or (gethash "commentCount" item)
                       (let ((c (gethash "comments" item)))
                         (if (vectorp c) (length c) 0)))))
    (list :title  (or (gethash "title" item) "")
          :number (concat (propertize repo 'face 'octocat-repo)
                          (propertize (format "#%d" (gethash "number" item))
                                      'face 'octocat-pr-number))
          :date   (propertize (octocat--format-ts-relative
                               (or (gethash "createdAt" item) ""))
                              'face 'octocat-dimmed)
          :prs    (and (vectorp closers) (> (length closers) 0)
                       (propertize
                        (mapconcat (lambda (pr) (format "#%d" (gethash "number" pr)))
                                   closers " ")
                        'face 'octocat-pr-number))
          :comments (and (> comments 0)
                         (propertize (format "✉ %d" comments)
                                     'face 'octocat-dimmed))
          :chips  (octocat--format-labels (gethash "labels" item) bg)
          ;; As GitHub's list, only while open: a draft says so instead.
          :review (and (equal (upcase (or (gethash "state" item) "")) "OPEN")
                       (not (eq (gethash "isDraft" item) t))
                       (when-let* ((text (pcase (gethash "reviewDecision" item)
                                           ("REVIEW_REQUIRED"   "Review required")
                                           ("APPROVED"          "Approved")
                                           ("CHANGES_REQUESTED" "Changes requested"))))
                         (propertize text 'face 'octocat-dimmed)))
          :ci     (and (or (octocat--nonempty (gethash "ciState" item))
                           (and checks (not (eq checks :null)) (> (length checks) 0)))
                       (octocat--ci-count-label item))
          :author (propertize (octocat--author-login item)
                              'face 'octocat-pr-author))))

(defun octocat-repo-vui--join-cells (cells keys)
  "Return the non-empty CELLS under KEYS, joined by a dimmed dot."
  (mapconcat #'identity
             (seq-remove (lambda (s) (or (null s) (string-empty-p s)))
                         (mapcar (lambda (key) (plist-get cells key)) keys))
             (propertize " · " 'face 'octocat-dimmed)))

(defun octocat-repo-vui--item-lines (state cells keys &optional width)
  "Return the two lines of an item with STATE text, as a list of strings.
The first is the state, title and label chips; the second the number,
author and date, then the cells under KEYS.  CELLS are as made by
`octocat-repo-vui--cells'.  WIDTH, when non-nil, cuts each line to fit,
shortening the title to make room for the chips.  Shared by the list
rows and the page headers so the two read alike."
  (let* ((cap   (and width (max 10 (1- width))))
         (dot   (propertize " · " 'face 'octocat-dimmed))
         (join  (lambda (keys) (octocat-repo-vui--join-cells cells keys)))
         (who   (concat (plist-get cells :number)
                        (propertize " by " 'face 'octocat-dimmed)
                        (funcall join '(:author :date))))
         (title (plist-get cells :title))
         (chips (let ((c (or (plist-get cells :chips) "")))
                  (if (string-empty-p c) "" (concat "  " c))))
         (rest  (funcall join keys))
         (cut   (lambda (s) (if cap (truncate-string-to-width s cap nil nil "…") s))))
    (list
     (funcall cut
              (concat state "  "
                      (if cap
                          (truncate-string-to-width
                           title
                           (max 10 (- cap (string-width state) 2 (string-width chips)))
                           nil nil "…")
                        title)
                      chips))
     (funcall cut
              (concat (make-string (+ octocat-repo-vui--state-width 2) ?\s)
                      who
                      (if (string-empty-p rest) "" (concat dot rest)))))))

(defun octocat-repo-vui--compact-line (state number cells &optional width)
  "Return the one line of an item in a compact list.
That is STATE text, NUMBER (\"#N\"), the title and its label chips, then
the author; CELLS are as made by `octocat-repo-vui--cells'.  A nil STATE
leaves it out.  The repo is
the page's and the age is left out, to make room for the title.
WIDTH, when non-nil, cuts the line to fit, shortening the title first."
  (let* ((cap   (and width (max 10 (1- width))))
         (chips (let ((c (or (plist-get cells :chips) "")))
                  (if (string-empty-p c) "" (concat "  " c))))
         (tail  (concat (propertize " · " 'face 'octocat-dimmed)
                        (plist-get cells :author)))
         (head  (concat (and state (concat state "  ")) number "  "))
         (title (plist-get cells :title))
         (line  (concat head
                        (if cap
                            (truncate-string-to-width
                             title
                             (max 10 (- cap (string-width head) (string-width chips)
                                        (string-width tail)))
                             nil nil "…")
                          title)
                        chips tail)))
    (if cap (truncate-string-to-width line cap nil nil "…") line)))

(defun octocat-repo-vui--item-row (state cells width on-visit help
                                         &optional compact number prefetch)
  "Return the row vnode for an item with STATE text.
CELLS are as made by `octocat-repo-vui--cells'; each line is cut to
WIDTH.  ON-VISIT and HELP are as for `octocat-vui-row'.  COMPACT draws
the one line of `octocat-repo-vui--compact-line', with NUMBER.
PREFETCH is the sync specs ON-VISIT opens, fetched while point rests
on the row (see `octocat-vui--prefetch-schedule')."
  (octocat-vui-row
   (propertize
    (if compact
        (octocat-repo-vui--compact-line state number cells width)
      (mapconcat #'identity
                 (octocat-repo-vui--item-lines
                  state cells '(:review :ci :prs :comments) width)
                 "\n"))
    'octocat-sync-prefetch prefetch)
   on-visit help))

(defun octocat-repo-vui--number (item)
  "Return the \"#N\" of the issue or PR ITEM."
  (propertize (format "#%d" (gethash "number" item)) 'face 'octocat-pr-number))

(defun octocat-repo-vui--pr-row (repo pr width bg &optional compact no-state)
  "Return a row vnode for PR in REPO, cut to WIDTH.
BG is as for `octocat-repo-vui--cells'; COMPACT draws it on one line,
without the state when NO-STATE is non-nil."
  (octocat-repo-vui--item-row
   (unless (and compact no-state)
     (octocat-repo-vui--state-label (gethash "state" pr) (gethash "isDraft" pr)))
   (octocat-repo-vui--cells repo pr bg)
   width
   (lambda () (octocat-repo-vui--open-pr repo pr))
   "RET: view pull request"
   compact (octocat-repo-vui--number pr)
   (let ((n (gethash "number" pr)))
     `((pr ,repo ,n) (timeline-events ,repo ,n)))))

(defun octocat-repo-vui--issue-row (repo issue width bg &optional compact no-state)
  "Return a row vnode for ISSUE in REPO, cut to WIDTH.
BG is as for `octocat-repo-vui--cells'; COMPACT draws it on one line,
without the state when NO-STATE is non-nil."
  (octocat-repo-vui--item-row
   (unless (and compact no-state)
     (octocat-repo-vui--state-label (gethash "state" issue)))
   (octocat-repo-vui--cells repo issue bg)
   width
   (lambda () (octocat-repo-vui--open-issue repo issue))
   "RET: view issue"
   compact (octocat-repo-vui--number issue)
   (let ((n (gethash "number" issue)))
     `((issue ,repo ,n) (timeline-events ,repo ,n)))))

;; The header of an issue or PR page is drawn like a regular list row (see
;; above), so the page continues the list it was opened from: the state
;; before the title with the labels after it, then who opened it and when
;; with its review and branch.

(defun octocat-repo-vui--detail-header (repo item state on-edit-title bg
                                            &optional branch omit)
  "Return the header vnodes of the issue or PR ITEM of REPO.
STATE is its coloured state text (see `octocat-repo-vui--state-label').
The rows are the item's two list lines (see
`octocat-repo-vui--item-lines'), uncut; the first is the `title' target
of the page's edit command, and RET on either calls ON-EDIT-TITLE.  BG
is as for `octocat-repo-vui--cells'.  BRANCH, when non-nil, is shown
after the review.  OMIT is a list of cell keys (see
`octocat-repo-vui--cells') to leave out."
  (let* ((cells (octocat-repo-vui--cells repo item bg))
         (cells (if branch (plist-put cells :branch branch) cells))
         (lines (octocat-repo-vui--item-lines
                 state cells (seq-difference '(:review :branch :ci :prs :comments) omit))))
    (list
     (octocat-vui-row
      (propertize (car lines) 'octocat-timeline-target 'title)
      on-edit-title
      "RET: edit title")
     (octocat-repo-vui--detail-who repo item cells omit on-edit-title))))

(defun octocat-repo-vui--detail-who (repo item cells omit on-edit-title)
  "Return the header row under the title: number, author, date and cells.
As the second of `octocat-repo-vui--item-lines', but REPO is a
breadcrumb (`octocat-vui-repo-heading') and the author a TAB-able link.
ITEM, CELLS, OMIT and ON-EDIT-TITLE are as for
`octocat-repo-vui--detail-header'."
  (let* ((author (plist-get cells :author))
         (rest   (octocat-repo-vui--join-cells
                  cells (cons :date (seq-difference '(:review :branch :ci :prs :comments)
                                                    omit)))))
    (octocat-vui-row
     (list (make-string (+ octocat-repo-vui--state-width 2) ?\s)
           (octocat-vui-repo-heading repo)
           (propertize (format "#%d" (gethash "number" item)) 'face 'octocat-pr-number)
           (propertize " by " 'face 'octocat-dimmed)
           (if (string-empty-p author)
               ""
             (octocat-repo-vui--login-link (substring author 1)))
           (if (or (string-empty-p author) (string-empty-p rest))
               rest
             (concat (propertize " · " 'face 'octocat-dimmed) rest)))
     on-edit-title
     "RET: edit title")))

(defun octocat-repo-vui--detail-fields (fields)
  "Return a vnode listing FIELDS under the title, or nil when none has a value.
FIELDS is a list of (LABEL . VALUE), VALUE a string or a list of vnodes;
a nil or empty VALUE is skipped, and a nil LABEL shows VALUE alone.  The
line is lined up with the title column."
  (let ((parts (delq nil
                     (mapcar (lambda (f)
                               (and (cdr f) (not (equal (cdr f) ""))
                                    (append
                                     (and (car f)
                                          (list (vui-text (concat (car f) " ")
                                                          :face 'octocat-dimmed)))
                                     (if (stringp (cdr f))
                                         (list (vui-text (cdr f)))
                                       (cdr f)))))
                             fields))))
    (and parts
         (vui-hstack :spacing 0
           (vui-text (make-string (+ octocat-repo-vui--state-width 2) ?\s))
           (octocat-repo-vui--separate parts (propertize " · " 'face 'octocat-dimmed))))))

(defun octocat-repo-vui--separate (items sep)
  "Return ITEMS (vnodes or lists of them) with a `vui-text' of SEP between."
  (cdr (mapcan (lambda (item) (list (vui-text sep) item)) items)))

(defun octocat-repo-vui--link (label face action &optional help)
  "Return an unbracketed `vui-button' showing LABEL in FACE: a TAB stop.
ACTION is called on RET or a click; HELP is its hover text, by default
\"RET: open LABEL\"."
  (vui-button label
    :no-decoration t
    :face face
    :help-echo (or help (concat "RET: open " label))
    :on-click action))

(defun octocat-repo-vui--login-link (login)
  "Return \"@LOGIN\" as a link to the page of the user LOGIN."
  (octocat-repo-vui--link (concat "@" login) 'octocat-pr-author
                          (lambda () (octocat-user-open login))))

(defun octocat-repo-vui--logins (users)
  "Return the \"@login\" names of USERS (a vector of user objects), or nil.
A list of vnodes, comma-separated; each opens the page of its user."
  (and (vectorp users) (> (length users) 0)
       (octocat-repo-vui--separate
        (mapcar (lambda (u)
                  (let ((login (gethash "login" u)))
                    (if (octocat--nonempty login)
                        (octocat-repo-vui--login-link login)
                      (vui-text (concat "@" (or (gethash "name" u) ""))
                                :face 'octocat-pr-author))))
                users)
        ", ")))

(defun octocat-repo-vui--numbers (repo refs open)
  "Return the \"#N\" numbers of REFS (a vector of issue/PR objects), or nil.
A list of vnodes, space-separated; each calls OPEN with its repository,
REPO unless it names another, and number."
  (and (vectorp refs) (> (length refs) 0)
       (octocat-repo-vui--separate
        (mapcar (lambda (r)
                  (let* ((n     (gethash "number" r))
                         (other (gethash "repository" r))
                         (owner (and (hash-table-p other) (gethash "owner" other)))
                         (where (if (and (hash-table-p owner) (gethash "login" owner))
                                    (format "%s/%s" (gethash "login" owner)
                                            (gethash "name" other))
                                  repo)))
                    (octocat-repo-vui--link
                     (if (equal where repo) (format "#%d" n) (format "%s#%d" where n))
                     'octocat-pr-number (lambda () (funcall open where n)))))
                refs)
        " ")))

(defun octocat-repo-vui--milestone (item)
  "Return the milestone title of ITEM, or nil."
  (let ((m (gethash "milestone" item)))
    (and (hash-table-p m) (octocat--nonempty (gethash "title" m)))))

(defun octocat-repo-vui--workflow-state (workflow)
  "Return the state of WORKFLOW as shown on its row, such as \"active\"."
  (downcase (or (gethash "state" workflow) "")))

(defun octocat-repo-vui--workflow-file (workflow)
  "Return the file name of WORKFLOW, such as \"test.yml\"."
  (file-name-nondirectory (or (gethash "path" workflow) "")))

(defun octocat-repo-vui--workflow-name-width (workflows width state-w)
  "Return the width of the name column of WORKFLOWS: the longest name.
It is at most what WIDTH columns leave beside the STATE-W wide state and
the longest file name, but cuts no name shorter than 10."
  (let ((longest (lambda (f) (apply #'max 0 (mapcar (lambda (wf) (string-width (funcall f wf)))
                                                    workflows)))))
    (min (funcall longest (lambda (wf) (or (gethash "name" wf) "")))
         (max 10 (- width 1 state-w 2 2
                    (funcall longest #'octocat-repo-vui--workflow-file))))))

(defun octocat-repo-vui--workflow-row (repo workflow &optional state-w name-w)
  "Return a row vnode for WORKFLOW in REPO: its state, name and file name.
The state is padded to STATE-W columns and the name to NAME-W, cut to
it when longer (40 by default), so the columns line up."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (octocat-repo-vui--workflow-state workflow))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
           (propertize (string-pad state (max (or state-w 0) (string-width state)))
                       'face state-face)
           "  "
           (truncate-string-to-width name (or name-w 40) nil ?\s "…")
           "  "
           (propertize (octocat-repo-vui--workflow-file workflow) 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-workflow repo workflow))
                     "RET: viewworkflow")))

(defun octocat-repo-vui--run-title-width (runs width wf-w &optional branch-w)
  "Return the title column's width, that of the longest title.
The titles are those of RUNS.  It is at least
`octocat-repo-vui--subject-min-width', and at most what WIDTH columns
leave beside the other columns of `octocat-repo-vui--workflow-run-row',
the workflow name WF-W wide and the branch BRANCH-W."
  (let ((rest (+ (or branch-w octocat-branch-max-width) 2 11 2 wf-w 2 1 2 2 1
                 (apply #'max 0 (mapcar (lambda (r)
                                          (string-width (octocat--format-ts-relative
                                                         (or (gethash "createdAt" r) ""))))
                                        runs)))))
    (max octocat-repo-vui--subject-min-width
         (min (- width rest)
              (apply #'max 0 (mapcar (lambda (r) (string-width (or (gethash "displayTitle" r) "")))
                                     runs))))))

(defun octocat-repo-vui--workflow-run-row (repo run current-branch wf-w
                                                &optional title-w branch-w)
  "Return a row vnode for RUN in REPO.
CURRENT-BRANCH, when non-nil, highlights a matching run branch.
WF-W is the column width to truncate/pad the workflow name to, TITLE-W
that of the title, `octocat-title-width' by default, and BRANCH-W that
of the branch, `octocat-branch-max-width' by default."
  (let* ((run-id     (or (gethash "databaseId"   run) 0))
         (title      (or (gethash "displayTitle" run) ""))
         (status     (downcase (or (gethash "status" run) "")))
         (conclusion (let ((c (gethash "conclusion" run)))
                       (and (octocat--nonempty c) (downcase c))))
         (branch     (or (gethash "headBranch"   run) ""))
         (activep    (and current-branch (string= branch current-branch)))
         (b-face     (if activep 'octocat-branch-current 'octocat-branch))
         (wf-name    (or (gethash "workflowName" run) ""))
         (created    (or (gethash "createdAt"    run) ""))
         (date       (octocat--format-ts-relative created))
         (icon       (octocat--workflow-run-icon status conclusion))
         (line
          (concat
           (let* ((branch-w (or branch-w octocat-branch-max-width))
                  (name (truncate-string-to-width branch branch-w nil nil "…"))
                  (pad  (make-string (- branch-w (string-width name)) ?\s)))
             (concat (propertize name 'face b-face) pad))
           "  "
           (propertize (format "%-11s" (number-to-string run-id))
                       'face 'octocat-pr-number)
           "  "
           (propertize (truncate-string-to-width wf-name wf-w nil ?\s "…")
                       'face 'octocat-dimmed)
           "  "
           icon
           "  "
           (octocat--format-title title title-w)
           "  "
           (propertize date 'face 'octocat-dimmed))))
    (octocat-vui-row (propertize line 'octocat-sync-prefetch
                                 `((run ,repo ,run-id) (run-artifacts ,repo ,run-id)))
                     (lambda () (octocat-repo-vui--open-workflow-run repo run))
                     "RET: view workflow run")))

(defconst octocat-repo-vui--author-max-width 30
  "Widest author column of the commit list; longer names are truncated.")

(defun octocat-repo-vui--author-width (commits)
  "Return the width of the author column for COMMITS: the longest name.
It is no wider than `octocat-repo-vui--author-max-width', so the dates
line up with no more padding than the different names require."
  (min octocat-repo-vui--author-max-width
       (apply #'max 0 (mapcar (lambda (c) (string-width (octocat--commit-author c)))
                              commits))))

(defun octocat-repo-vui--subject (commit)
  "Return the first line of COMMIT's message."
  (let ((c (gethash "commit" commit)))
    (car (split-string (or (and c (gethash "message" c)) "") "\n"))))

(defconst octocat-repo-vui--subject-min-width 24
  "Narrowest subject column, so short subjects still leave a gap before the author.")

(defun octocat-repo-vui--date (commit)
  "Return the relative author date of COMMIT, as on its row."
  (let* ((c  (gethash "commit" commit))
         (ca (and c (gethash "author" c))))
    (octocat--format-ts-relative (or (and ca (gethash "date" ca)) ""))))

(defun octocat-repo-vui--subject-width (commits width author-w)
  "Return the width of the subject column for COMMITS: the longest subject.
It is at least `octocat-repo-vui--subject-min-width', and at most what
WIDTH columns leave beside the SHA, the AUTHOR-W wide author and the
date, so the rows fill the page but do not wrap."
  (let ((rest (+ 7 2 2 author-w 2
                 (apply #'max 0 (mapcar (lambda (c) (string-width (octocat-repo-vui--date c)))
                                        commits)))))
    (max octocat-repo-vui--subject-min-width
         (min (- width rest)
              (apply #'max 0 (mapcar (lambda (c) (string-width (octocat-repo-vui--subject c)))
                                     commits))))))

(defun octocat-repo-vui--commit-line (commit head-info author-w &optional subject-w)
  "Return the line of COMMIT: its short SHA, subject, author and date.
HEAD-INFO as in `octocat-repo-vui--commits-section'; the local HEAD
commit is highlighted.  AUTHOR-W is the width of the author column, see
`octocat-repo-vui--author-width'; SUBJECT-W that of the subject column,
`octocat-title-width' by default."
  (let* ((subject-w (or subject-w octocat-title-width))
         (head-hash (and head-info (plist-get head-info :hash)))
         (sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 7 (length sha))))
         (is-head   (and head-hash
                        (>= (length sha) (length head-hash))
                        (string-prefix-p head-hash sha)))
         (subject   (octocat-repo-vui--subject commit))
         (author    (octocat--commit-author commit))
         (date      (octocat-repo-vui--date commit)))
    (concat
     (propertize (format "%-7s" short)
                 'face (if is-head 'octocat-branch-current 'octocat-commit-sha))
     "  "
     (if is-head
         (let* ((text (truncate-string-to-width subject subject-w nil nil "…"))
                (pad  (make-string (- subject-w (string-width text)) ?\s)))
           (concat (propertize text 'face 'octocat-branch-current) pad))
       (octocat--format-title subject subject-w))
     "  "
     (propertize (truncate-string-to-width author author-w nil ?\s "…")
                 'face 'octocat-pr-author)
     "  "
     (propertize date 'face 'octocat-dimmed))))

(defun octocat-repo-vui--commit-row (repo commit head-info author-w &optional subject-w)
  "Return a row vnode for COMMIT in REPO, RET opening it.
The other arguments are as for `octocat-repo-vui--commit-line'."
  (octocat-vui-row (octocat-repo-vui--commit-line commit head-info author-w subject-w)
                   (lambda () (octocat-repo-vui--open-commit repo commit))
                   "RET: view commit"))


(defun octocat-repo-vui--unpushed-row (commit)
  "Return a line for COMMIT, a plist from `octocat-repo--parse-unpushed'.
Not RET-able: the commit page reads from GitHub, which lacks it."
  (let ((sha (plist-get commit :sha)))
    (vui-text
     (concat
      (propertize (substring sha 0 (min 7 (length sha))) 'face 'octocat-commit-sha)
      " "
      (plist-get commit :subject)))))


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

(defun octocat-repo-vui--ref-label (ref)
  "Return how the picker names REF: a full SHA is cut to seven characters."
  (if (string-match-p "\\`[0-9a-f]\\{40\\}\\'" ref) (substring ref 0 7) ref))

(defun octocat-repo-vui--picker-labels (label reset default)
  "Return the labels of the buttons of the picker of the ref named LABEL.
The second, with RESET non-nil, goes back to the DEFAULT branch."
  (cons (format "[%s ▾]" (octocat-repo-vui--ref-label label))
        (and reset (list (if default (format "[reset to %s]" default) "[reset]")))))

(defun octocat-repo-vui--picker-width (label reset default)
  "Return the width of the picker `octocat-repo-vui--ref-picker' draws.
LABEL, RESET and DEFAULT are as for it."
  (let ((labels (octocat-repo-vui--picker-labels label reset default)))
    (+ (apply #'+ (mapcar #'string-width labels)) (1- (length labels)))))

(defun octocat-repo--resettable-p (ref default)
  "Return non-nil when REF is shown in place of the DEFAULT branch.
The default branch named, as by a link to it, is not."
  (and ref (not (equal ref default))))

(defun octocat-repo-vui--ref-picker (label current-branch reset default)
  "Return the picker of the ref named LABEL, as GitHub's branch dropdown.
It is highlighted when it is the local CURRENT-BRANCH.  RESET non-nil
adds a button back to the DEFAULT branch.  Nil while LABEL is unknown."
  (when (and (stringp label) (not (string-empty-p label)))
    (pcase-let ((`(,pick ,back) (octocat-repo-vui--picker-labels label reset default)))
      (apply #'vui-hstack :spacing 1
             (vui-button pick
                         :no-decoration t
                         :face (if (equal label current-branch)
                                   'octocat-branch-current
                                 'octocat-branch)
                         :help-echo "RET: show another branch (C-c C-b)"
                         :on-click #'octocat-repo-switch-branch)
             (when back
               (list (vui-button back
                                 :no-decoration t
                                 :face 'octocat-dimmed
                                 :help-echo "RET: show the default branch"
                                 :on-click #'octocat-repo-reset-branch)))))))

(defun octocat-repo-vui--commits-heading (label current-branch reset default)
  "Return the Commits heading, with the picker of the ref named LABEL.
LABEL, CURRENT-BRANCH, RESET and DEFAULT are as for
`octocat-repo-vui--ref-picker'."
  (let ((heading (vui-text "Commits" :face 'octocat-section-heading))
        (picker  (octocat-repo-vui--ref-picker label current-branch reset default)))
    (if picker (vui-hstack :spacing 1 heading picker) heading)))

(octocat-sync-define-resource commits (repo ref path)
  :fetch (lambda (done)
           (octocat-repo--list-commits
            repo ref path
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(vui-defcomponent octocat-repo-vui--commits-section
    (repo ref path default-branch current-branch head-info tick)
  "Commits section for REPO.
The commits are those of REF, or of the default branch when nil, that
touched PATH, or all of them when nil; the ref appears once in the
title instead of on every row, with a button back to DEFAULT-BRANCH
when it is another.  It is highlighted when it is
also the local CURRENT-BRANCH.  HEAD-INFO is the plist from
`octocat--head-info', used to highlight the local HEAD commit.  The
first page is a sync resource; \"load more\" fetches a page at a time,
pinned to the head shown."
  ;; MORE is (:items LIST :done BOOL): the commits after the last load
  ;; more, DONE when that page came back short (end of history).
  :state ((limit octocat-repo-commits-page-size) (more nil) (fetching nil))
  :render
  (let* ((size    octocat-repo-commits-page-size)
         (snap    (octocat-vui-use-resource (list 'commits repo ref path) tick))
         (first   (append (plist-get snap :data) nil))
         (more-items (plist-get more :items))
         (commits (octocat-repo--commits-merge first more-items))
         (status  (octocat-vui-snapshot-status snap))
         (done    (or (and (plist-get more :done) (eq commits more-items))
                      (/= 0 (% (length commits) size))))
         (label   (or ref default-branch)))
    (octocat-vui-use-mode-line-loading fetching)
    (vui-vstack
     (let ((heading (octocat-repo-vui--commits-heading
                     label current-branch
                     (octocat-repo--resettable-p ref default-branch) default-branch)))
       (if path
           (vui-hstack :spacing 2 heading (vui-text path :face 'octocat-branch))
         heading))
     (pcase status
       ('pending (vui-text (octocat-vui-line-skeleton)))
       ('error   (vui-text (octocat-vui-error-text snap) :face 'octocat-dimmed))
       ('ready
        (let ((shown (seq-take commits limit)))
          (vui-fragment
           (if (null shown)
               (vui-text "(no commits)" :face 'octocat-dimmed)
             ;; Columns from all loaded commits, so they hold as more show.
             (let* ((author-w  (octocat-repo-vui--author-width commits))
                    (subject-w (octocat-repo-vui--subject-width
                                commits (octocat-vui-window-width) author-w)))
               (octocat-vui-reveal-list
                shown
                (lambda (c)
                  (octocat-repo-vui--commit-row repo c head-info author-w subject-w))
                (lambda (c) (gethash "sha" c)))))
           (when (and shown (or (> (length commits) limit) (not done)))
             (octocat-vui-load-more-button
              'load-more-commits size
              "RET: load more commits"
              (lambda ()
                (octocat-repo-vui--load-more-commits repo path commits (+ limit size)))
              fetching 0 (octocat-vui-line-skeleton))))))))))

(defun octocat-repo-vui--load-more-commits (repo path commits limit)
  "Show LIMIT of COMMITS of REPO that touched PATH, fetching more when short.
Called from the load-more button of `octocat-repo-vui--commits-section'.
The page is fetched at the head of COMMITS, after the last of them, so
the history it pages through cannot shift under it."
  (vui-set-state :limit limit)
  (when (< (length commits) limit)
    (let ((on-page
           (vui-async-callback (r)
             (vui-set-state :fetching nil)
             (if (eq (car-safe r) 'error)
                 (message "octocat: %s" (cdr r))
               (vui-set-state
                :more (list :items (append commits r)
                            :done (< (length r) octocat-repo-commits-page-size)))))))
      (vui-set-state :fetching t)
      (octocat-repo--list-commits repo (gethash "sha" (car commits)) path on-page
                                  (gethash "cursor" (car (last commits)))))))

(defun octocat-repo-vui--head-row (repo ref path commit picker picker-w width)
  "Return the line atop the files: PICKER, then COMMIT, of PATH at REF.
COMMIT is the last that touched PATH, nil for the root.  PICKER is the
ref picker, PICKER-W columns wide, or nil.  COMMIT shows its short SHA,
subject and date, RET opening it, and ends in a button to the commits
page of PATH at REF of REPO, with the count of its history.  The subject
is cut so the line fits WIDTH columns."
  (let* ((sha       (or (gethash "sha" commit) ""))
         (subject   (octocat-repo-vui--subject commit))
         (date      (octocat-repo-vui--date commit))
         (count     (format "[%s commits]" (gethash "total" commit)))
         (rest      (+ (if picker (+ picker-w 2) 0) 7 2 2 (string-width date)
                       2 (string-width count)))
         (subject-w (max 1 (min (string-width subject) (- width rest))))
         (line      (concat (propertize (substring sha 0 (min 7 (length sha)))
                                        'face 'octocat-commit-sha)
                            "  " (octocat--format-title subject subject-w)
                            "  " (propertize date 'face 'octocat-dimmed))))
    (octocat-vui-row
     (append (and picker (list picker "  "))
             (list line "  "
                   (vui-button count
                               :no-decoration t
                               :face 'octocat-dimmed
                               :help-echo "RET: list the commits"
                               :on-click (lambda () (octocat-commits-open repo ref path)))))
     (lambda () (octocat-repo-vui--open-commit repo commit))
     "RET: view commit")))

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

(defun octocat-repo--doc-text (name content raw width)
  "Return the rows of file NAME's CONTENT, rendered when it is markdown.
RAW and WIDTH are as for `octocat--markdown-string'.  Not indented, so
it copies as from the file."
  (let ((text (decode-coding-string content 'utf-8)))
    (string-remove-suffix
     "\n" (if (octocat-repo--markdown-file-p name)
              (octocat--markdown-string text "" raw width)
            (octocat-markdown-render-verbatim text "")))))

(vui-defcomponent octocat-repo-vui--docs-section (repo tree raw)
  "The README of REPO at root TREE, and a selector of its other documents.
They are those of `octocat-repo--doc-kinds' among the files of TREE,
the root tree of the commit shown; while its listing loads, grey bars
stand in for the section.  RAW shows markdown verbatim.  A long
document is folded after `octocat-repo-doc-lines'.  The listing is the
tree's own and a file is stored under its blob SHA, so while the branch
stays put no request is made."
  :state ((kind nil))
  :render
  (let* ((root  (octocat-vui-use-resource (list 'tree-dir repo tree) nil))
         (docs  (and (plist-get root :data)
                     (octocat-repo--docs (append (plist-get root :data) nil))))
         (doc   (or (assq kind docs) (car docs)))
         (entry (nth 2 doc))
         (oid   (and entry (gethash "sha" entry)))
         (blob  (octocat-vui-use-resource (list 'blob repo oid) nil))
         (width (octocat--markdown-width))
         (text  (vui-use-memo ((plist-get blob :data) raw width)
                  (and entry (plist-get blob :data)
                       (octocat-repo--doc-text (gethash "path" entry)
                                               (octocat-tree--blob-content
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

(defun octocat-repo-vui--path-line (repo path on-dir)
  "Return the path line of PATH of REPO, as GitHub's above files.
Each directory of it but the last is a button calling ON-DIR with its
path; the repository's name leads back to the root, \"\"."
  (let* ((crumb (lambda (label face dir)
                  (vui-button label :no-decoration t :face face
                              :help-echo (format "RET: open %s" (if (string-empty-p dir) "/" dir))
                              :on-click (lambda () (funcall on-dir dir)))))
         (parts (split-string path "/"))
         (nodes (list (funcall crumb (cadr (split-string repo "/")) 'octocat-repo "")))
         (dir   ""))
    (while parts
      (setq dir (octocat-tree--join dir (car parts)))
      (push (vui-text " / " :face 'octocat-dimmed) nodes)
      (push (if (cdr parts)
                (funcall crumb (car parts) 'octocat-branch dir)
              (vui-text (car parts) :face 'octocat-section-heading))
            nodes)
      (setq parts (cdr parts)))
    (apply #'vui-hstack :spacing 0 (nreverse nodes))))

(defun octocat-repo-vui--head-line (repo ref path head-snap default-branch current-branch)
  "Return the line of the picker of REF and the last commit of PATH of REPO.
HEAD-SNAP is the snapshot of PATH's `repo-head'; DEFAULT-BRANCH and
CURRENT-BRANCH are as for `octocat-repo-vui--ref-picker'."
  (let* ((label  (or ref default-branch))
         (reset  (octocat-repo--resettable-p ref default-branch))
         (picker (octocat-repo-vui--ref-picker label current-branch reset default-branch))
         (beside (lambda (node)
                   (if picker (vui-hstack :spacing 2 picker node) node))))
    (pcase (octocat-vui-snapshot-status head-snap)
      ('error (funcall beside (vui-text (octocat-vui-error-text head-snap)
                                        :face 'octocat-dimmed)))
      ('ready (octocat-repo-vui--head-row
               repo ref path (plist-get head-snap :data) picker
               (and picker (octocat-repo-vui--picker-width label reset default-branch))
               (octocat-vui-window-width)))
      (_ (funcall beside (vui-text (octocat-vui-skeleton '((7 "  " 40 "  " 12)))))))))

(vui-defcomponent octocat-repo-vui--root (repo ref local-dir unpushed raw tick)
  "Root component for the repo buffer, as GitHub's Code tab: header and
tabs, local-head/fork-parent info, the UNPUSHED section, then the picker
of REF and its last commit, the root's first files and its README.  REF
is a branch, tag or SHA, nil for the default branch.  RAW shows markdown
verbatim.  The header comes from one summary resource and the rest from
the root's `repo-head' at REF."
  :render
  (let* ((buf            (current-buffer))
         (head-info      (octocat--head-info))
         (current-branch (plist-get head-info :branch))
         (snap           (octocat-vui-use-resource (list 'repo-summary repo) tick))
         (summary        (plist-get snap :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (fork-parent    (and summary (gethash "fork-parent" summary)))
         (head-snap      (octocat-vui-use-resource (list 'repo-head repo ref nil) tick))
         (tree           (let ((d (plist-get head-snap :data))) (and d (gethash "tree" d)))))
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (vui-vstack
     (apply #'vui-hstack :spacing 2
            (octocat-vui-repo-heading repo nil t)
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
        (concat "Forked from  " (propertize fork-parent 'face 'octocat-repo) "\n")
        (lambda () (octocat-visit-repo fork-parent))
        "RET: open parent repo view"))
     (vui-newline)
     (when unpushed
       (octocat-repo-vui--unpushed-section unpushed))
     (octocat-repo-vui--head-line repo ref nil head-snap default-branch current-branch)
     (if tree
         (vui-component 'octocat-tree--dir
                        :key ref :repo repo :branch (or ref default-branch "HEAD") :sha tree
                        :on-dir (lambda (dir) (octocat-tree-open repo ref dir))
                        :on-browse (lambda () (octocat-tree-open repo ref)))
       (vui-text (octocat-tree--skeleton)))
     (if tree
         (vui-component 'octocat-repo-vui--docs-section
                        :key ref :repo repo :tree tree :raw raw)
       (octocat-repo-vui--docs-skeleton)))))

(vui-defcomponent octocat-repo-vui--tree-page (repo ref path reveal focus tick)
  "Root component of the tree browser: the whole tree of REF of REPO.
As GitHub's sidebar, it is opened down to REVEAL.  PATH, the browser's
directory, nil for the root, has the picker's line and the path line,
and is highlighted in the tree.  Point goes to FOCUS, an entry's path,
once it is shown.  REF is a branch, tag or SHA, nil for the default
branch."
  :render
  (let* ((buf            (current-buffer))
         (current-branch (plist-get (octocat--head-info) :branch))
         (summary        (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick)
                                    :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (head-snap      (octocat-vui-use-resource (list 'repo-head repo ref path) tick))
         (root           (plist-get (octocat-vui-use-resource (list 'repo-head repo ref nil) tick)
                                    :data)))
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (vui-vstack
     (octocat-vui-repo-heading repo ref)
     (vui-newline)
     (octocat-repo-vui--head-line repo ref path head-snap default-branch current-branch)
     (when path
       (octocat-repo-vui--path-line
        repo path (lambda (dir) (octocat-repo--show-path dir dir))))
     ;; The tree hangs on the root's head only, so moving within it
     ;; keeps it up while the new directory's commit loads.
     (if root
         ;; Each ref, and each opening from elsewhere, starts the tree
         ;; afresh; moving within it keeps what is open.
         (vui-component 'octocat-tree--subtree
                        :key (list ref reveal)
                        :repo repo :branch (or ref default-branch "HEAD")
                        :sha (gethash "tree" root)
                        :depth 0 :path "" :reveal reveal :current path :focus focus
                        :on-dir (lambda (dir) (octocat-repo--show-path dir)))
       (vui-text (octocat-tree--skeleton))))))

(vui-defcomponent octocat-repo-vui--commits-page (repo ref path tick)
  "Root component of the commits page: the history of REF of REPO.
REF is a branch, tag or SHA, nil for the default branch.  PATH, when
non-nil, keeps the commits that touched it, as GitHub's History."
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
    (vui-vstack
     ;; No tabs: only the repo root and the list pages show them.
     (octocat-vui-repo-heading repo)
     (vui-newline)
     (vui-component 'octocat-repo-vui--commits-section
                    :key (list ref path)
                    :repo repo :ref ref :path path :default-branch default-branch
                    :current-branch (plist-get head-info :branch)
                    :head-info head-info :tick tick))))


;;;; Major mode

(defun octocat-repo-browse ()
  "Open what point is on, or else the page, on GitHub.
On a tree entry that is the file or directory; elsewhere the directory
at the ref shown, or on the commits page its commits."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let* ((repo   octocat-repo--repo)
         (ref    octocat-repo--ref)
         (path   (and (derived-mode-p 'octocat-tree-mode 'octocat-commits-mode)
                      octocat-repo--path))
         (branch (or ref octocat-repo--default-branch "HEAD"))
         (type   (octocat-tree--type-at-point))
         (url    (cond ((derived-mode-p 'octocat-commits-mode)
                        (concat "https://github.com/" repo "/commits"
                                (cond (path (concat "/" branch "/" path))
                                      (ref  (concat "/" ref)))))
                       ((memq type '(file dir))
                        (octocat-tree--entry-url repo branch type (octocat-tree--path-at-point)))
                       (path (format "https://github.com/%s/tree/%s/%s" repo branch path))
                       (ref  (format "https://github.com/%s/tree/%s" repo ref))
                       (t    (concat "https://github.com/" repo)))))
    (message "Octocat: Opening %s in browser…" url)
    (octocat-browse-external url)))

(defun octocat-repo--show-ref (ref)
  "Show REF on this page, nil for the default branch, in place.
The tree browser stays in its directory, as GitHub's does."
  (setq octocat-repo--ref ref
        octocat-repo--focus nil)
  (or (if (derived-mode-p 'octocat-tree-mode)
          (octocat-vui-update-page :ref ref :focus nil)
        (octocat-vui-update-page :ref ref))
      (funcall revert-buffer-function)))

(defun octocat-repo--show-path (dir &optional focus)
  "Make DIR the tree browser's directory, in place; \"\" is the root.
The tree stays as it is; point goes to FOCUS, an entry's path."
  (let ((path (unless (string-empty-p dir) dir)))
    (setq octocat-repo--path  path
          octocat-repo--focus focus)
    (or (octocat-vui-update-page :path path :focus focus)
        (funcall revert-buffer-function))))

(defun octocat-repo-up ()
  "Make the directory containing the tree browser's the one shown.
Point goes to it."
  (interactive)
  (unless (and (derived-mode-p 'octocat-tree-mode) octocat-repo--path)
    (user-error "Octocat: Already at the top"))
  (let ((parent (octocat-tree--parent octocat-repo--path)))
    (octocat-repo--show-path parent (unless (string-empty-p parent) parent))))

(defun octocat-repo-switch-branch ()
  "Show another branch, picked from the repository's."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let* ((default octocat-repo--default-branch)
         (picked  (octocat--read-branch
                   octocat-repo--repo default (plist-get (octocat--head-info) :branch)
                   (or octocat-repo--ref default))))
    (octocat-repo--show-ref (unless (equal picked default) picked))))

(defun octocat-repo-reset-branch ()
  "Show the default branch again."
  (interactive)
  (octocat-repo--show-ref nil))

(defvar octocat-repo-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    map)
  "Keymap for `octocat-repo-mode'.")
(define-key octocat-repo-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-repo-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-repo-mode-map (kbd "^") #'octocat-repo-up)
(define-key octocat-repo-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-repo-mode-map (kbd "C-c C-b") #'octocat-repo-switch-branch)
(define-key octocat-repo-mode-map (kbd "C-c C-o") #'octocat-repo-browse)
(define-key octocat-repo-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-repo-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-repo-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-repo-mode vui-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-repo-refresh)
  (setq-local octocat--refresh-fn #'octocat-repo-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))

;; The commits page and the tree browser derive from the repo page, for
;; its state: so `C-c C-b', `C-c C-f' and `C-c C-o' work on them alike.
(define-derived-mode octocat-tree-mode octocat-repo-mode "Octocat-Tree"
  "Major mode for browsing the whole tree of a repository's ref.

\\{octocat-tree-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-tree-refresh)
  (setq-local octocat--refresh-fn #'octocat-tree-refresh))

(define-derived-mode octocat-commits-mode octocat-repo-mode "Octocat-Commits"
  "Major mode for the commits of a repository's branch, tag or commit.

\\{octocat-commits-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-commits-refresh)
  (setq-local octocat--refresh-fn #'octocat-commits-refresh))


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
                                  :local-dir octocat-repo--local-dir
                                  :raw octocat--markdown-raw
                                  :unpushed (and octocat-repo--local-dir
                                                 (octocat-repo--unpushed
                                                  octocat-repo--local-dir)))))

(defun octocat-tree-open (repo &optional ref path)
  "Open (or switch to) the tree browser of REPO at REF.
REF is a branch, tag or SHA, nil for the default branch.  PATH, a
directory or file, is the one the tree opens down to, with point on it."
  (let ((buf (get-buffer-create (format "*%s tree*" repo))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-tree-mode)
      (octocat-tree-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref
          octocat-repo--path      path
          octocat-repo--reveal    path
          octocat-repo--focus     path)
    (octocat-tree-refresh)))

(defun octocat-tree-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current tree browser, in place."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--tree-page octocat-repo--repo
                            (list :repo octocat-repo--repo :ref octocat-repo--ref
                                  :path octocat-repo--path :reveal octocat-repo--reveal
                                  :focus octocat-repo--focus)))

(defun octocat-commits-open (repo &optional ref path)
  "Open (or switch to) the commits page of REPO, from REF back.
REF is a branch, tag or SHA, nil for the default branch.  PATH, a file
or directory, keeps the commits that touched it."
  (let ((buf (get-buffer-create (format "*%s commits*" repo))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-commits-mode)
      (octocat-commits-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref
          octocat-repo--path      path)
    (octocat-commits-refresh)))

(defun octocat-commits-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commits page, in place."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--commits-page octocat-repo--repo
                            (list :repo octocat-repo--repo :ref octocat-repo--ref
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
