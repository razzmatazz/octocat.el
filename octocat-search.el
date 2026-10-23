;;; octocat-search.el --- Repo-wide PR, issue and commit search for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; `octocat-search-repo' (C-c C-j in every octocat view) searches
;; the pull requests, issues and commits of the current repository with
;; live `gh search' queries, through a consult async pipeline.  File paths
;; of the repository's default branch are matched too, locally, against a
;; file list kept in the sync store.
;;
;; GitHub is slow to answer, so what octocat has stored of the repo, and
;; the commits `git log' finds in its local clone when there is one, are
;; matched as you type and show first.  They are only a faster source:
;; GitHub's results lead the list as they arrive, each item listed once.
;; Results are kept in the sync store per (repo, type, query).
;;
;; It also holds the stage of `octocat-switch-repo' (C-u C-c C-j), which
;; searches all of GitHub's repos, and the branch picker, `octocat--read-branch'; both
;; keep their results in the sync store.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'consult)
(require 'octocat-core)
(require 'octocat-sync)

(declare-function octocat-pr-open                "octocat-pr"     (repo number))
(declare-function octocat-issue-open             "octocat-issue"  (repo number))
(declare-function octocat-commit-open            "octocat-commit" (repo sha))
(declare-function octocat-tree--fetch-all-files  "octocat-tree"   (repo sha callback))
(declare-function octocat-tree--open-file-by-path "octocat-tree"  (repo branch path sha))
(declare-function octocat-repo--local-dir-for    "octocat-repo"   (repo))
(defvar octocat-repo--local-dir)



;;;; Candidates

(defun octocat--search-make-pr-candidate (pr repo)
  "Return a propertized candidate string for PR hash-table in REPO."
  (let* ((number (gethash "number" pr))
         (title  (or (octocat--nonempty (gethash "title" pr)) ""))
         (state  (or (octocat--nonempty (gethash "state" pr)) "OPEN"))
         (author (octocat--author-login pr))
         ;; `gh search' gives the state in lower case.
         (state-face (pcase (upcase state)
                       ("MERGED" 'octocat-pr-state-merged)
                       ("CLOSED" 'octocat-pr-state-closed)
                       (_        'octocat-pr-state-open)))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[PR]" 'face 'octocat-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'octocat-pr-author)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'pr :repo repo :number number
                             :title title :state state)
                       cand)
    cand))

(defun octocat--search-make-issue-candidate (issue repo)
  "Return a propertized candidate string for ISSUE hash-table in REPO."
  (let* ((number (gethash "number" issue))
         (title  (or (octocat--nonempty (gethash "title" issue)) ""))
         (state  (or (octocat--nonempty (gethash "state" issue)) "OPEN"))
         (author (octocat--author-login issue))
         (state-face (if (equal (upcase state) "OPEN")
                         'octocat-pr-state-open
                       'octocat-pr-state-closed))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[Issue]" 'face 'octocat-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'octocat-pr-author)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'issue :repo repo :number number
                             :title title :state state)
                       cand)
    cand))

(defun octocat--search-make-commit-candidate (commit repo)
  "Return a propertized candidate string for COMMIT hash-table in REPO.
Handles both the REST shape (\"sha\", nested \"commit\") and the GraphQL
shape (\"oid\", nested \"commit\") used in different parts of the codebase."
  (let* ((sha     (or (octocat--nonempty (gethash "sha"    commit))
                      (octocat--nonempty (gethash "oid"    commit)) ""))
         (short   (substring sha 0 (min 7 (length sha))))
         (c       (gethash "commit" commit))
         (msg     (or (and c (octocat--nonempty (gethash "message" c))) ""))
         (subject (car (split-string msg "\n")))
         (author  (octocat--commit-author commit))
         (display
          (format "%-8s %s  %-42s  %s"
                  (propertize "[Commit]" 'face 'octocat-section-heading)
                  (propertize short 'face 'octocat-commit-sha)
                  (octocat--format-title subject)
                  (propertize author 'face 'octocat-pr-author)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'commit :repo repo :sha sha)
                       cand)
    cand))

(defun octocat--search-make-file-candidate (file repo)
  "Return a propertized candidate string for FILE in REPO.
FILE is a (PATH . BLOB-SHA) cons."
  (let* ((path (car file))
         (cand (copy-sequence
                (format "%-8s %s"
                        (propertize "[File]" 'face 'octocat-section-heading)
                        path))))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'file :repo repo :path path :sha (cdr file))
                       cand)
    cand))

(defun octocat--search-open-item (item)
  "Open the octocat buffer described by ITEM, a plist from `octocat-search-item'."
  (let ((type (plist-get item :type))
        (repo (plist-get item :repo)))
    (pcase type
      ('file
       (octocat-tree--open-file-by-path
        repo "HEAD" (plist-get item :path) (plist-get item :sha)))
      ('pr
       (octocat-pr-open repo (plist-get item :number)))
      ('issue
       (octocat-issue-open repo (plist-get item :number)))
      ('commit
       (octocat-commit-open repo (plist-get item :sha))))))


;;;; Stored results

(defcustom octocat-search-cache-ttl 60
  "Seconds an object-search result is reused by `octocat-search-repo'.
A stored result for a query always shows at once.  Within this it is
not refetched; older, it is, and the list is updated when the response
arrives.  It is at least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(defcustom octocat-search-reuse-for (* 7 24 60 60)
  "Seconds a past search result lends its items to other input.
`octocat-search-repo' and `octocat-switch-repo' match what the results
of past input hold, not only the items octocat stored otherwise, against
what is typed; older results are left out.  Items stored otherwise are
always matched: octocat showed them."
  :type 'integer
  :group 'octocat)

(defconst octocat--search-types
  '(("prs"     "number,title,state,author" octocat--search-make-pr-candidate)
    ("issues"  "number,title,state,author" octocat--search-make-issue-candidate)
    ("commits" "sha,commit,author"         octocat--search-make-commit-candidate))
  "The `gh search' types searched: (TYPE JSON-FIELDS MAKE-CANDIDATE).")

;; Plain results, not entities: `gh search' gives fewer fields than the
;; pages' issues and PRs, and their state in lower case.
(octocat-sync-define-resource object-search (repo type query)
  :max-age octocat-search-cache-ttl
  :fetch (lambda (done)
           (octocat--run-gh
            "search-objects"
            (list "search" type (format "--repo=%s" repo)
                  "--json" (nth 1 (assoc type octocat--search-types))
                  "--limit" "30" query)
            (lambda (output) (vconcat (octocat--parse-json-list output)))
            done)))


;;;; Stored and local matches
;;
;; What octocat has stored of the repo, and its local clone when there is
;; one, are matched as you type, before GitHub answers: most of the time
;; the item wanted was seen before.  They are only a faster source;
;; GitHub's answer leads the list once in, see `octocat--search-merge'.

(defconst octocat--search-local-limit 10
  "Maximum number of stored or local matches shown per type.")

(defun octocat--search-normalize (input)
  "Return INPUT as the query of an `object-search' resource."
  (downcase (string-trim (substring-no-properties input))))

(defun octocat--search-item-id (type item)
  "Return what names ITEM of TYPE in every source: its number or SHA."
  (if (equal type "commits")
      (or (gethash "sha" item) (gethash "oid" item))
    (gethash "number" item)))

(defun octocat--search-item-text (type item)
  "Return the text of ITEM of TYPE that input is matched against."
  (if (equal type "commits")
      (let ((c (gethash "commit" item)))
        (concat (octocat--search-item-id type item) " "
                (or (and (hash-table-p c) (octocat--nonempty (gethash "message" c))) "")))
    (format "#%s %s" (gethash "number" item) (or (gethash "title" item) ""))))

(defun octocat--search-match (type items query)
  "Return the ITEMS of TYPE holding every word of QUERY, ignoring case.
At most `octocat--search-local-limit' of them."
  (let ((words (split-string (downcase query) "[ \t]+" t)))
    (when words
      (seq-take (seq-filter
                 (lambda (item)
                   (let ((text (downcase (octocat--search-item-text type item))))
                     (cl-every (lambda (w) (string-search w text)) words)))
                 items)
                octocat--search-local-limit))))

(defun octocat--search-merge (type &rest sources)
  "Return the items of SOURCES, lists of items of TYPE, each once.
An item is kept from the first source that has it: GitHub's answer goes
first, as it is authoritative."
  (let ((seen (make-hash-table :test #'equal))
        items)
    (dolist (source sources)
      (dolist (item source)
        (let ((id (octocat--search-item-id type item)))
          (unless (gethash id seen)
            (puthash id t seen)
            (push item items)))))
    (nreverse items)))

(defun octocat--search-stored-items (repo now)
  "Return an alist TYPE -> items octocat stored of REPO, newest first.
They are the PR and issue entities, the commits of the commit lists and
pages, and the items of the `object-search' results fetched within
`octocat-search-reuse-for' of NOW."
  (let ((repo (downcase repo))
        (dated nil))
    (cl-flet ((add (type item at)
                (push (cons item (or at 0)) (alist-get type dated nil nil #'equal))))
      (pcase-dolist (`(,type . ,entity) '(("prs" . pr) ("issues" . issue)))
        (let ((prefix (format "%s:%s#" entity repo)))
          (pcase-dolist (`(,key ,fields ,at) (octocat-sync-entities entity))
            (when (string-prefix-p prefix key)
              (add type fields at)))))
      (pcase-dolist (`(,spec ,data ,at) (octocat-sync-stored 'object-search))
        (when (and (equal (downcase (nth 1 spec)) repo)
                   (< (- now (or at 0)) octocat-search-reuse-for))
          (seq-doseq (item data) (add (nth 2 spec) item at))))
      (pcase-dolist (`(,spec ,data ,at) (octocat-sync-stored 'commits))
        (when (equal (downcase (nth 1 spec)) repo)
          (seq-doseq (item data) (add "commits" item at))))
      (pcase-dolist (`(,spec ,data ,at) (octocat-sync-stored 'commit))
        (when (and (equal (downcase (nth 1 spec)) repo) (hash-table-p data))
          (add "commits" data at))))
    (mapcar (pcase-lambda (`(,type . ,entries))
              (cons type
                    (octocat--search-merge
                     type (mapcar #'car (sort entries (lambda (a b) (> (cdr a) (cdr b))))))))
            dated)))

(defconst octocat--search-git-format "--format=%H%x00%an%x00%s"
  "The `git log' format `octocat--search-git-parse' reads.")

(defun octocat--search-git-args (query)
  "Return the argument lists of the git commands finding the commits of QUERY.
The commits on origin's branches, which GitHub can show, whose message
holds every word; and when QUERY looks like a SHA, the commit it names."
  (let ((words (split-string query "[ \t]+" t)))
    (append
     (when words
       (list (append (list "log" "--remotes=origin" "-n" "30" "-i" "-F" "--all-match"
                           octocat--search-git-format)
                     (mapcar (lambda (w) (concat "--grep=" w)) words))))
     (when (string-match-p "\\`[0-9a-f]\\{4,40\\}\\'" query)
       (list (list "log" "-n" "1" octocat--search-git-format query "--"))))))

(defun octocat--search-git-parse (lines)
  "Return the commits of LINES, `git log' output, as GitHub's REST gives them.
That is, only the fields `octocat--search-make-commit-candidate' reads."
  (delq nil
        (mapcar (lambda (line)
                  (pcase (split-string line "\0")
                    (`(,sha ,name ,subject)
                     (let ((commit (make-hash-table :test #'equal))
                           (c      (make-hash-table :test #'equal))
                           (author (make-hash-table :test #'equal)))
                       (puthash "name" name author)
                       (puthash "message" subject c)
                       (puthash "author" author c)
                       (puthash "sha" sha commit)
                       (puthash "commit" c commit)
                       commit))))
                lines)))

(defun octocat--search-git (dir arg-lists callback)
  "Run git in DIR with each of ARG-LISTS in turn, then CALLBACK.
CALLBACK gets the output lines of all of them; a command that fails
adds none.  Return a function that stops it, after which CALLBACK is
never called."
  (let (proc lines stopped)
    (cl-labels
        ((next (lists)
           (if (or (null lists) (not (executable-find "git")))
               (funcall callback lines)
             (let ((default-directory dir)
                   (buf (generate-new-buffer " *octocat-git*"))
                   (err (generate-new-buffer " *octocat-git-stderr*")))
               (setq proc
                     (make-process
                      :name "octocat-git" :buffer buf :stderr err :noquery t
                      :connection-type 'pipe :command (cons "git" (car lists))
                      :sentinel
                      (lambda (p _event)
                        (unless (process-live-p p)
                          (let ((out (and (eq (process-status p) 'exit)
                                          (eq 0 (process-exit-status p))
                                          (with-current-buffer buf (buffer-string)))))
                            (kill-buffer buf)
                            ;; As `octocat--run-gh': the stderr pipe may outlive it.
                            (when-let* ((pipe (get-buffer-process err)))
                              (delete-process pipe))
                            (kill-buffer err)
                            (unless stopped
                              (setq lines (append lines (split-string (or out "") "\n" t)))
                              (next (cdr lists))))))))))))
      (next arg-lists)
      (lambda ()
        (setq stopped t)
        (when (process-live-p proc) (delete-process proc))))))


;;;; Repository file list

(defconst octocat--search-files-ttl 600
  "Seconds a stored repository file list is reused without a refetch.")

(defconst octocat--search-files-limit 30
  "Maximum number of file candidates shown for one query.")

;; As `tree-files', by the default branch rather than a tree SHA.
(octocat-sync-define-resource search-files (repo)
  :max-age octocat--search-files-ttl
  :fetch (lambda (done)
           (octocat-tree--fetch-all-files
            repo "HEAD"
            (lambda (r)
              (funcall done
                       (if (eq (car-safe r) 'error)
                           r
                         (let ((h (make-hash-table :test #'equal :size (length r))))
                           (pcase-dolist (`(,path . ,blob) r)
                             (puthash path blob h))
                           h)))))))

(defun octocat--search-files-alist (data)
  "Return the (PATH . BLOB-SHA) entries of DATA, a `search-files' table."
  (when (hash-table-p data)
    (let (files)
      (maphash (lambda (path blob) (push (cons path blob) files)) data)
      (nreverse files))))

(defun octocat--search-files-match (files query)
  "Return the entries of FILES with every word of QUERY in their path.
Matching is case-insensitive; shorter paths sort first."
  (let ((words (split-string (downcase query) "[ \t]+" t))
        matches)
    (when words
      (dolist (file files)
        (let ((path (downcase (car file))))
          (when (cl-every (lambda (w) (string-search w path)) words)
            (push file matches))))
      (setq matches (sort matches (lambda (a b) (< (length (car a)) (length (car b))))))
      (seq-take matches octocat--search-files-limit))))


;;;; Async pipeline and command

(defun octocat--async-search-repo-objects (repo &optional dir gate)
  "Build a consult async pipeline stage for live object search in REPO.
On each input it lists the pull requests, issues and commits of REPO,
and its files.  What octocat stored that matches shows at once, and the
commits of the local clone in DIR, when non-nil, once `git log' is done.
GitHub's results, each type an `object-search' resource of the
normalized input, lead as they arrive: first the stored result of the
input, then the fetched one.  New input cancels the fetches of the last
still queued.  The indicator shows `running' while any is awaited.
GitHub and git are asked through GATE, a consult async stage, by
default `consult--async-throttle'.  Enforce a minimum input upstream
with `consult--async-min-input'."
  (lambda (sink)
    (let ((types    (mapcar #'car octocat--search-types))
          (current  nil)                ; query being fetched
          (input    nil)                ; normalized current input
          (stored   'unread)            ; alist TYPE -> stored items
          (local    nil)                ; alist TYPE -> stored matches
          (remote   nil)                ; alist TYPE -> GitHub's items
          (git      nil)                ; commits git found
          (stop-git nil)
          (waiting  nil)                ; types, or `git', awaited
          (files    'unread)            ; (PATH . BLOB-SHA) list
          (files-loading nil)
          fetch-gate)
      (cl-labels
          ((spec (type query) (list 'object-search repo type query))
           (candidates (type items)
             (let ((make (nth 2 (assoc type octocat--search-types))))
               (mapcar (lambda (item) (funcall make item repo)) items)))
           (publish ()
             (funcall sink 'flush)
             (when-let* ((all
                          (append
                           (mapcan (lambda (type)
                                     (candidates
                                      type
                                      (octocat--search-merge
                                       type
                                       (alist-get type remote nil nil #'equal)
                                       (alist-get type local nil nil #'equal)
                                       (and (equal type "commits") git))))
                                   types)
                           (and (listp files)
                                (mapcar (lambda (f) (octocat--search-make-file-candidate f repo))
                                        (octocat--search-files-match files input))))))
               (funcall sink all))
             (funcall sink (if (or files-loading waiting)
                               [indicator running]
                             [indicator finished])))
           (cancel ()
             (when current
               (dolist (type types)
                 (octocat-sync-cancel (spec type current))))
             (when stop-git
               (funcall stop-git))
             (setq current nil stop-git nil))
           ;; The file list is stored, and refetched once a session when stale.
           (load-files ()
             (when (eq files 'unread)
               (setq files (octocat--search-files-alist
                            (plist-get (octocat-sync-read (list 'search-files repo)) :data))
                     files-loading t)
               (octocat-sync-get
                (list 'search-files repo)
                (lambda (result)
                  (setq files-loading nil)
                  (unless (eq (car-safe result) 'error)
                    (setq files (octocat--search-files-alist result)))
                  (when input (publish))))))
           (fetch (action)
             (pcase action
               ((pred stringp)
                (cancel)
                (let ((query action))
                  (setq current query)
                  (when dir
                    (setq stop-git
                          (octocat--search-git
                           dir (octocat--search-git-args query)
                           (lambda (lines)
                             (when (equal query current)
                               (setq stop-git nil
                                     git (octocat--search-git-parse lines)
                                     waiting (delq 'git waiting))
                               (publish))))))
                  (dolist (type types)
                    (octocat-sync-get
                     (spec type query)
                     (lambda (result)
                       (when (equal query current)
                         (setq waiting (delete type waiting))
                         (unless (eq (car-safe result) 'error)
                           (setf (alist-get type remote nil nil #'equal)
                                 (append result nil)))
                         (publish)))))))
               ('cancel (cancel)))))
        (setq fetch-gate (funcall (or gate (consult--async-throttle)) #'fetch))
        (lambda (action)
          (pcase action
            ;; New input: show what is stored and still matches, then
            ;; what git and GitHub find.
            ((pred stringp)
             (let ((query (octocat--search-normalize action)))
               (when (eq stored 'unread)
                 (setq stored (octocat--search-stored-items repo (float-time))))
               (setq input   query
                     local   (mapcar (lambda (type)
                                       (cons type (octocat--search-match
                                                   type (alist-get type stored nil nil #'equal)
                                                   query)))
                                     types)
                     remote  (mapcar (lambda (type)
                                       (cons type (append (plist-get (octocat-sync-read
                                                                      (spec type query))
                                                                     :data)
                                                          nil)))
                                     types)
                     ;; Commits git found for earlier input that still match.
                     git     (octocat--search-match "commits" git query)
                     waiting (append types (and dir (list 'git))))
               (load-files)
               (publish)
               (funcall fetch-gate query)))
            ((or 'cancel 'destroy)
             (funcall fetch-gate action)
             (cancel)
             (setq input nil)
             (funcall sink action))
            (_
             (funcall fetch-gate action)
             (funcall sink action))))))))

(defun octocat-search-repo ()
  "Search for a PR, issue, commit, or file in the current repository.

The PRs, issues and commits octocat has stored that match show at once,
with the commits of the local clone, when there is one, found by `git
log'.  Live `gh search' queries (PRs, issues, and commits in parallel)
against the repository associated with the current buffer then lead
the list as each completes.  File paths containing every word of the
query are listed too.  Selecting a candidate opens the corresponding
detail view.

The query is matched against titles, commit messages, and bodies.
Prefix a hash (e.g. \"a1b2c3\") to narrow to a specific commit."
  (interactive)
  (let ((repo (octocat--search-repo--current-repo)))
    (unless repo
      (user-error "Octocat: Cannot determine current repository"))
    (let* ((dir    (or (and (boundp 'octocat-repo--local-dir)
                            (ignore-errors octocat-repo--local-dir))
                       (octocat-repo--local-dir-for repo)))
           (chosen (consult--read
                    (consult--async-pipeline
                     (consult--async-min-input 2)
                     (octocat--async-search-repo-objects repo dir))
                    :prompt        (format "Search %s: " repo)
                    :category      'octocat-object
                    :sort          nil
                    ;; The default lookup returns the bare minibuffer text,
                    ;; dropping the `octocat-search-item' property.
                    :lookup        #'consult--lookup-member
                    :require-match t))
           (item (and chosen
                      (get-text-property 0 'octocat-search-item chosen))))
      (when item
        (octocat--search-open-item item)))))

;;;; Repo search

(defcustom octocat-repo-search-cache-ttl 3600
  "Seconds a repo search result is reused by `octocat-switch-repo'.
Within it a query seen before shows its stored result with no `gh
search repos' call; older, the result shows while it is refetched.
It is at least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(defun octocat--repo-search-args (query)
  "Return the `gh' arguments searching for the repos or users of QUERY.
Forks are included: GitHub leaves them out by default, so one's own fork
could not be found even by its full name.  \"owner/name\" searches the
repos of owner, as GitHub's global search does not match a partial name
there."
  (cond
   ((string-prefix-p "@" query)
    ;; `gh search' has no users subcommand; -X GET keeps -f fields in the
    ;; query string.
    (list "api" "-X" "GET" "search/users"
          "-f" (concat "q=" (substring query 1))
          "-f" "per_page=15"
          "--jq" "[.items[] | {login}]"))
   ((string-match "\\`\\([^/ \t]+\\)/\\(.*\\)\\'" query)
    (append (list "search" "repos" "--limit" "30" "--json" "fullName"
                  "--include-forks=true" (concat "--owner=" (match-string 1 query)))
            (let ((name (string-trim (match-string 2 query))))
              (unless (string-empty-p name) (list name)))))
   (t
    (list "search" "repos" "--limit" "30" "--json" "fullName"
          "--include-forks=true" query))))

(octocat-sync-define-resource repo-search (query)
  :max-age octocat-repo-search-cache-ttl
  :fetch (lambda (done)
           (octocat--run-gh
            "search-repos"
            (octocat--repo-search-args query)
            (lambda (output)
              (vconcat (mapcar (lambda (r)
                                 (if-let* ((login (gethash "login" r)))
                                     (concat "@" login)
                                   (gethash "fullName" r)))
                               (octocat--parse-json-list output))))
            done)))

;; Repos and users octocat has stored, matched as you type, show before
;; GitHub's answer: most of the time the one wanted was opened before.
;; The store is only a faster source; GitHub's answer overrides it.

(defconst octocat--repo-search-local-limit 15
  "Maximum number of stored repos or users shown for one input.")

(defun octocat--repo-search-names (entries)
  "Return the names of ENTRIES, (NAME . FETCHED-AT), newest first.
A name seen more than once, in any case, keeps its newest entry."
  (let ((seen (make-hash-table :test #'equal))
        names)
    (dolist (entry (sort (copy-sequence entries)
                         (lambda (a b) (> (or (cdr a) 0) (or (cdr b) 0)))))
      (let ((key (downcase (car entry))))
        (unless (gethash key seen)
          (puthash key t seen)
          (push (car entry) names))))
    (nreverse names)))

(defun octocat--repo-search-stored (now)
  "Return the repos and \"@login\" users in the sync store, newest first.
They are the repo and user entities, and the `repo-search' results
fetched within `octocat-search-reuse-for' of NOW."
  (octocat--repo-search-names
   (append
    (delq nil (mapcar (pcase-lambda (`(,_ ,fields ,at))
                        (when-let* ((name (gethash "nameWithOwner" fields)))
                          (cons name at)))
                      (octocat-sync-entities 'repo)))
    (delq nil (mapcar (pcase-lambda (`(,_ ,fields ,at))
                        (when-let* ((login (gethash "login" fields)))
                          (cons (concat "@" login) at)))
                      (octocat-sync-entities 'user)))
    (mapcan (pcase-lambda (`(,_ ,data ,at))
              (when (< (- now (or at 0)) octocat-search-reuse-for)
                (mapcar (lambda (name) (cons name at)) data)))
            (octocat-sync-stored 'repo-search)))))

(defun octocat--repo-search-match (names input)
  "Return the NAMES matching INPUT, at most `octocat--repo-search-local-limit'.
A name matches when it holds every word of INPUT, ignoring case.  Input
starting with \"@\" matches only the \"@login\" names, other input only
the repos."
  (let* ((users (string-prefix-p "@" input))
         (words (split-string (downcase (if users (substring input 1) input))
                              "[ \t]+" t)))
    (when words
      (seq-take (seq-filter (lambda (name)
                              (and (eq users (string-prefix-p "@" name))
                                   (let ((name (downcase name)))
                                     (cl-every (lambda (w) (string-search w name)) words))))
                            names)
                octocat--repo-search-local-limit))))

(defun octocat--repo-search-merge (local remote)
  "Return REMOTE, then the LOCAL names not in it, ignoring case.
GitHub's REMOTE answer is authoritative, the stored LOCAL matches only
fill in what it lacks, or all of it before it arrives."
  (let ((seen (mapcar #'downcase remote)))
    (append remote
            (seq-remove (lambda (name) (member (downcase name) seen)) local))))

(defun octocat--async-search-repos (&optional gate)
  "Return a consult async stage searching the input's repos.
Input starting with \"@\" searches users instead.  The stored repos and
users matching the input show at once, and GitHub's results, first the
stored result of the input and then the fetched one, take the lead as
they arrive; see `octocat--repo-search-merge'.  New input cancels the
fetch of the last if it is still queued, so it never waits behind input
typed past.
Fetches go through GATE, a consult async stage, by default
`consult--async-throttle'.  Enforce a minimum input upstream with
`consult--async-min-input'."
  (lambda (sink)
    (let (current stored local remote waiting fetch-gate)
      (cl-labels
          ((publish (&optional failed)
             (funcall sink 'flush)
             (when-let* ((all (octocat--repo-search-merge local remote)))
               (funcall sink all))
             (funcall sink (cond (failed [indicator failed])
                                 (waiting [indicator running])
                                 (t [indicator finished]))))
           (cancel ()
             (when current (octocat-sync-cancel current))
             (setq current nil))
           (fetch (action)
             (pcase action
               ((pred stringp)
                (cancel)
                (let ((spec (list 'repo-search (substring-no-properties action))))
                  (setq current spec)
                  (octocat-sync-get
                   spec
                   (lambda (result)
                     (when (eq current spec)
                       (setq waiting nil)
                       (if (eq (car-safe result) 'error)
                           (publish t)
                         (setq remote (append result nil))
                         (publish)))))))
               ('cancel (cancel)))))
        (setq fetch-gate (funcall (or gate (consult--async-throttle)) #'fetch))
        (lambda (action)
          (pcase action
            ((pred stringp)
             (unless stored
               (setq stored (octocat--repo-search-stored (float-time))))
             (setq local   (octocat--repo-search-match stored action)
                   remote  (append (plist-get (octocat-sync-read
                                               (list 'repo-search
                                                     (substring-no-properties action)))
                                              :data)
                                   nil)
                   waiting t)
             (publish)
             (funcall fetch-gate action))
            ((or 'cancel 'destroy)
             (funcall fetch-gate action)
             (cancel)
             (funcall sink action))
            (_
             (funcall fetch-gate action)
             (funcall sink action))))))))

;;;; Branch picker

(octocat-sync-define-resource branches (repo)
  :fetch (lambda (done)
           (octocat--list-branches
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

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

(provide 'octocat-search)
;;; octocat-search.el ends here
