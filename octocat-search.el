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
;; of the branch or commit the page shows, else the default branch, are
;; matched too, locally, against a file list kept in the sync store, and
;; so are its workflows.  A word naming a type, as "file", lists that
;; type first.
;;
;; GitHub is slow to answer, so what octocat has stored of the repo, and
;; the commits `git log' finds in its local clone when there is one, are
;; matched as you type and show first.  They are only a faster source:
;; GitHub's results lead the list as they arrive, each item listed once.
;; Results are kept in the sync store per (repo, type, query).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'consult)
(require 'octocat-core)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'octocat-diff)
(require 'octocat-issue)
(require 'octocat-pr)
(require 'octocat-repo)
(require 'octocat-user)
(require 'octocat-actions)




;;;; Candidates

(defconst octocat--search-labels
  '((pr . "PR") (issue . "Issue") (commit . "Commit")
    (workflow . "Workflow") (file . "File"))
  "The label each type of candidate shows, as \"[PR]\".
A word of the input that is one, or its plural, lists that type first.")

(defun octocat--search-label (type)
  "Return the propertized \"[LABEL]\" of candidates of TYPE."
  (propertize (format "[%s]" (alist-get type octocat--search-labels))
              'face 'octocat-section-heading))

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
                  (octocat--search-label 'pr)
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
                  (octocat--search-label 'issue)
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
                  (octocat--search-label 'commit)
                  (propertize short 'face 'octocat-commit-sha)
                  (octocat--format-title subject)
                  (propertize author 'face 'octocat-pr-author)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'commit :repo repo :sha sha)
                       cand)
    cand))

(defun octocat--search-make-file-candidate (file repo &optional ref)
  "Return a propertized candidate string for FILE in REPO at REF.
FILE is a (PATH . BLOB-SHA) cons; REF nil is the default branch."
  (let* ((path (car file))
         (cand (copy-sequence
                (format "%-8s %s" (octocat--search-label 'file) path))))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'file :repo repo :path path :sha (cdr file)
                             :ref ref)
                       cand)
    cand))

(defun octocat--search-make-workflow-candidate (workflow repo)
  "Return a propertized candidate string for WORKFLOW hash-table in REPO."
  (let* ((name (or (octocat--nonempty (gethash "name" workflow)) ""))
         (path (or (gethash "path" workflow) ""))
         (cand (copy-sequence
                (format "%-8s %-42s  %s"
                        (octocat--search-label 'workflow)
                        (octocat--format-title name)
                        (propertize path 'face 'octocat-dimmed)))))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'workflow :repo repo :id (gethash "id" workflow)
                             :name name :path path)
                       cand)
    cand))

(defun octocat--search-open-item (item)
  "Open the octocat buffer described by ITEM, a plist from `octocat-search-item'."
  (let ((type (plist-get item :type))
        (repo (plist-get item :repo)))
    (pcase type
      ('file
       (octocat-tree--open-file-by-path repo (or (plist-get item :ref) "HEAD")
                                        (plist-get item :path)))
      ('pr
       (octocat-pr-open repo (plist-get item :number)))
      ('issue
       (octocat-issue-open repo (plist-get item :number)))
      ('commit
       (octocat-commit-open repo (plist-get item :sha)))
      ('workflow
       (octocat-workflow-open repo (plist-get item :id)
                              (plist-get item :name) (plist-get item :path))))))


;;;; Stored results

(defcustom octocat-search-cache-ttl 60
  "Seconds an object-search result is reused by `octocat-search-repo'.
A stored result for a query always shows at once.  Within this it is
not refetched; older, it is, and the list is updated when the response
arrives.  It is at least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(defconst octocat--search-types
  '(("prs"     "number,title,state,author" octocat--search-make-pr-candidate     pr)
    ("issues"  "number,title,state,author" octocat--search-make-issue-candidate  issue)
    ("commits" "sha,commit,author"         octocat--search-make-commit-candidate commit))
  "The `gh search' types searched: (TYPE JSON-FIELDS MAKE-CANDIDATE LABEL).
LABEL is the key of the candidates' label in `octocat--search-labels'.")

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

(defun octocat--search-split-types (query)
  "Return (TEXT . TYPES) of QUERY, normalized input.
TYPES are the keys of `octocat--search-labels' its words name, as
\"file\" or \"commits\" do; TEXT is the rest of QUERY, what items are
matched against.  A QUERY of nothing but such words is all TEXT."
  (let (words types)
    (dolist (word (split-string query "[ \t]+" t))
      (if-let* ((label (seq-find (lambda (l)
                                   (let ((name (downcase (cdr l))))
                                     (member word (list name (concat name "s")))))
                                 octocat--search-labels)))
          (cl-pushnew (car label) types)
        (push word words)))
    (cons (if words (string-join (nreverse words) " ") query)
          (nreverse types))))

(defun octocat--search-hinted-first (groups types)
  "Return GROUPS, (TYPE . CANDIDATES), those of TYPES first, joined.
The order is otherwise kept."
  (mapcan #'cdr (append (seq-filter (lambda (g) (memq (car g) types)) groups)
                        (seq-remove (lambda (g) (memq (car g) types)) groups))))

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

;; As `tree-files', by ref rather than a tree SHA: REF nil is the default
;; branch, which `octocat-tree--load-files' would ask GitHub for first.
(octocat-sync-define-resource search-files (repo ref)
  :max-age octocat--search-files-ttl
  :fetch (lambda (done)
           (if ref
               (octocat-tree--load-files repo ref done)
             (octocat-tree--fetch-all-files
              repo "HEAD"
              (lambda (r)
                (funcall done
                         (if (eq (car-safe r) 'error)
                             r
                           (let ((h (make-hash-table :test #'equal :size (length r))))
                             (pcase-dolist (`(,path . ,blob) r)
                               (puthash path blob h))
                             h))))))))

(defun octocat--search-current-ref (repo)
  "Return the branch, tag or commit of REPO on screen in this buffer.
Nil when that is the default branch, or there is none."
  (let ((ref (or (bound-and-true-p octocat-repo--ref)
                 (bound-and-true-p octocat-repo--tracked)
                 (bound-and-true-p octocat-tree--file-branch)
                 (bound-and-true-p octocat--commit-sha))))
    (unless (member ref (list nil "" "HEAD" (octocat-tree--file-ref repo nil)))
      ref)))

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

(defun octocat--search-workflows-match (workflows query)
  "Return the WORKFLOWS with every word of QUERY in their name or file.
Matching is case-insensitive."
  (let ((words (split-string (downcase query) "[ \t]+" t)))
    (when words
      (seq-take (seq-filter
                 (lambda (wf)
                   (let ((text (downcase (concat (or (gethash "name" wf) "") " "
                                                 (or (gethash "path" wf) "")))))
                     (cl-every (lambda (w) (string-search w text)) words)))
                 workflows)
                octocat--search-local-limit))))


;;;; Async pipeline and command

(defun octocat--async-search-repo-objects (repo &optional dir gate ref)
  "Build a consult async pipeline stage for live object search in REPO.
On each input it lists the pull requests, issues and commits of REPO,
its workflows and its files at REF, nil for the default branch.  What
octocat stored that matches shows at once, and the commits of the local
clone in DIR, when non-nil, once `git log' is done.  Words of the input
naming a type, see `octocat--search-split-types', list it first.
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
          (hinted   nil)                ; types the input names
          (stored   'unread)            ; alist TYPE -> stored items
          (local    nil)                ; alist TYPE -> stored matches
          (remote   nil)                ; alist TYPE -> GitHub's items
          (git      nil)                ; commits git found
          (stop-git nil)
          (waiting  nil)                ; types, or `git', awaited
          (files    'unread)            ; (PATH . BLOB-SHA) list
          (workflows 'unread)           ; workflow hash-tables
          (lists-loading nil)           ; specs of the lists above awaited
          fetch-gate)
      (cl-labels
          ((spec (type query) (list 'object-search repo type query))
           (candidates (type items)
             (let ((make (nth 2 (assoc type octocat--search-types))))
               (mapcar (lambda (item) (funcall make item repo)) items)))
           (publish ()
             (funcall sink 'flush)
             (when-let* ((all
                          (octocat--search-hinted-first
                           (append
                            (mapcar (lambda (type)
                                      (cons (nth 3 (assoc type octocat--search-types))
                                            (candidates
                                             type
                                             (octocat--search-merge
                                              type
                                              (alist-get type remote nil nil #'equal)
                                              (alist-get type local nil nil #'equal)
                                              (and (equal type "commits") git)))))
                                    types)
                            (list
                             (cons 'workflow
                                   (and (listp workflows)
                                        (mapcar (lambda (wf)
                                                  (octocat--search-make-workflow-candidate
                                                   wf repo))
                                                (octocat--search-workflows-match
                                                 workflows input))))
                             (cons 'file
                                   (and (listp files)
                                        (mapcar (lambda (f)
                                                  (octocat--search-make-file-candidate
                                                   f repo ref))
                                                (octocat--search-files-match files input))))))
                           hinted)))
               (funcall sink all))
             (funcall sink (if (or lists-loading waiting)
                               [indicator running]
                             [indicator finished])))
           (cancel ()
             (when current
               (dolist (type types)
                 (octocat-sync-cancel (spec type current))))
             (when stop-git
               (funcall stop-git))
             (setq current nil stop-git nil))
           ;; The file and workflow lists are stored, and refetched once a
           ;; session when stale.  SET takes a list, CONVERT makes it of
           ;; the resource's data.
           (load-list (spec convert set)
             (funcall set (funcall convert (plist-get (octocat-sync-read spec) :data)))
             (push spec lists-loading)
             (octocat-sync-get
              spec
              (lambda (result)
                (setq lists-loading (delete spec lists-loading))
                (unless (eq (car-safe result) 'error)
                  (funcall set (funcall convert result)))
                (when input (publish)))))
           (load-lists ()
             (when (eq files 'unread)
               (load-list (list 'search-files repo ref) #'octocat--search-files-alist
                          (lambda (l) (setq files l))))
             (when (eq workflows 'unread)
               (load-list (list 'workflows repo) (lambda (d) (append d nil))
                          (lambda (l) (setq workflows l)))))
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
             (pcase-let ((`(,query . ,types-named)
                          (octocat--search-split-types (octocat--search-normalize action))))
               (when (eq stored 'unread)
                 (setq stored (octocat--search-stored-items repo (float-time))))
               (setq input   query
                     hinted  types-named
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
               (load-lists)
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
  "Search for a PR, issue, commit, workflow or file in the current repository.

The PRs, issues and commits octocat has stored that match show at once,
with the commits of the local clone, when there is one, found by `git
log'.  Live `gh search' queries (PRs, issues, and commits in parallel)
against the repository associated with the current buffer then lead
the list as each completes.  File paths containing every word of the
query are listed too, of the branch or commit the buffer shows, else
the default branch, and so are the workflows whose name or file holds
every word.  Selecting a candidate opens the corresponding detail view.

The query is matched against titles, commit messages, and bodies.
Prefix a hash (e.g. \"a1b2c3\") to narrow to a specific commit.  A
word naming a type, as \"file\" or \"commits\", is not matched but
lists that type first."
  (interactive)
  (let ((repo (octocat--search-repo--current-repo)))
    (unless repo
      (user-error "Octocat: Cannot determine current repository"))
    (let* ((dir    (or (bound-and-true-p octocat-repo--local-dir)
                       (octocat-repo--local-dir-for repo)))
           (ref    (octocat--search-current-ref repo))
           (shown  (and ref (if (string-match-p "\\`[0-9a-f]\\{40\\}\\'" ref)
                                (substring ref 0 7)
                              ref)))
           (chosen (consult--read
                    (consult--async-pipeline
                     (consult--async-min-input 2)
                     (octocat--async-search-repo-objects repo dir nil ref))
                    :prompt        (format "Search %s%s: " repo
                                           (if shown (concat "@" shown) ""))
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

;;;; Jumping elsewhere

(defun octocat-switch-repo ()
  "Search GitHub repositories or users interactively with live API queries.
Input starting with \"@\" searches users and organizations instead.
The repos and users octocat has stored that match the input show at
once, newest first.  GitHub's results, debounced by
`consult-async-input-debounce', then lead the list in GitHub's order,
the stored matches it did not return after them.

Uses `consult--read' with a custom async pipeline so Vertico, Embark,
Marginalia, and other consult-aware packages integrate seamlessly.

The selected repository is opened via `octocat-visit-repo', a selected
\"@login\" via `octocat-user-open'."
  (interactive)
  (let ((repo
         (consult--read
          (consult--async-pipeline
           (consult--async-min-input 2)
           (octocat--async-search-repos))
          :prompt   "Search GitHub repos (@ for users): "
          :category 'octocat-repo
          :sort     nil)))          ; preserve server-side ranking
    (when (and repo (not (string-empty-p (string-trim repo))))
      (let ((choice (string-trim repo)))
        (if (string-prefix-p "@" choice)
            (octocat-user-open choice)
          (octocat-visit-repo choice))))))

(defun octocat-jump (&optional other)
  "Find something to open: in the current repository, or elsewhere.
Without a prefix argument OTHER, search the current repository's PRs,
issues, commits and files, as `octocat-search-repo' does.  With one, or
where there is no current repository, search other repositories and
users, as `octocat-switch-repo' does."
  (interactive "P")
  (if (or other (not (octocat--search-repo--current-repo)))
      (octocat-switch-repo)
    (octocat-search-repo)))

(provide 'octocat-search)
;;; octocat-search.el ends here
