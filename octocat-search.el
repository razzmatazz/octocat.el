;;; octocat-search.el --- Repo-wide PR, issue and commit search for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; `octocat-search-repo' (bound to C-c C-s in every octocat view) searches
;; the pull requests, issues and commits of the current repository with
;; live `gh search' queries, through a consult async pipeline.  File paths
;; of the repository's default branch are matched too, locally, against a
;; file list fetched once and kept in memory.
;;
;; Results are kept in the sync store per (repo, type, query).  A stored
;; result shows at once and is refreshed behind it, the list being rebuilt
;; when the response arrives.
;;
;; It also holds the stage of `octocat-switch-repo', which searches all
;; of GitHub's repos, and the branch picker, `octocat--read-branch'; both
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


;;;; Repository file list

(defconst octocat--search-files-ttl 600
  "Seconds an in-memory repository file list is reused by the search.")

(defconst octocat--search-files-limit 30
  "Maximum number of file candidates shown for one query.")

(defvar octocat--search-files-cache (make-hash-table :test #'equal)
  "Map from \"owner/name\" to (TIMESTAMP . ((PATH . BLOB-SHA) ...)).")

(defun octocat--search-files-cached (repo)
  "Return the fresh cached file list of REPO, or nil."
  (when-let* ((entry (gethash repo octocat--search-files-cache)))
    (when (< (- (float-time) (car entry)) octocat--search-files-ttl)
      (cdr entry))))

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

(defun octocat--async-search-repo-objects (repo)
  "Build a consult async pipeline stage for live object search in REPO.
On each input string (minimum 2 chars) it searches the pull requests,
issues and commits of REPO, each an `object-search' resource of the
lower-cased input.  Stored results show at once, and each fetched one
replaces its type's as it lands.  New input cancels the fetches of the
last still queued.  The indicator shows `running' while any type of the
current input is awaited."
  (lambda (sink)
    (let ((current  nil)                              ; normalized current input
          (results  nil)                              ; alist TYPE -> candidates
          (waiting  nil)                              ; types awaited for current
          (files-loading nil))                        ; file list fetch in flight
      (cl-labels
          ((spec (type query) (list 'object-search repo type query))
           (candidates (type items)
             (let ((make (nth 2 (assoc type octocat--search-types))))
               (mapcar (lambda (item) (funcall make item repo)) items)))
           ;; Replace the displayed list with RESULTS and update the indicator.
           (publish ()
             (funcall sink 'flush)
             (when-let* ((all (apply #'append
                                     (mapcar (lambda (type) (cdr (assoc type results)))
                                             (append (mapcar #'car octocat--search-types)
                                                     (list "files"))))))
               (funcall sink all))
             (funcall sink (if (or files-loading waiting)
                               [indicator running]
                             [indicator finished])))
           (cancel ()
             (when current
               (dolist (entry octocat--search-types)
                 (octocat-sync-cancel (spec (car entry) current)))))
           ;; Show the files of the cached list matching the current input.
           (match-files ()
             (when-let* ((files (octocat--search-files-cached repo)))
               (setf (alist-get "files" results nil nil #'equal)
                     (mapcar (lambda (f) (octocat--search-make-file-candidate f repo))
                             (octocat--search-files-match files current)))))
           ;; Fetch the repository file list once; it is matched locally.
           (load-files ()
             (unless (or files-loading (octocat--search-files-cached repo))
               (setq files-loading t)
               (octocat-tree--fetch-all-files
                repo "HEAD"
                (lambda (result)
                  (setq files-loading nil)
                  (unless (eq (car-safe result) 'error)
                    (puthash repo (cons (float-time) result)
                             octocat--search-files-cache)
                    (when current
                      (match-files)))
                  (when current
                    (publish)))))))
        (lambda (action)
          (pcase action
            ;; New input: show what is stored, then what is fetched.
            ((pred stringp)
             (let ((query (downcase (string-trim action))))
               (cancel)
               (setq current query
                     results nil
                     waiting (mapcar #'car octocat--search-types))
               (dolist (type (mapcar #'car octocat--search-types))
                 (when-let* ((stored (plist-get (octocat-sync-read (spec type query)) :data)))
                   (push (cons type (candidates type stored)) results)))
               ;; Not over `waiting': a stored result calls back at once,
               ;; deleting from it.
               (dolist (type (mapcar #'car octocat--search-types))
                 (octocat-sync-get
                  (spec type query)
                  (lambda (result)
                    (when (equal query current)
                      (setq waiting (delete type waiting))
                      (unless (eq (car-safe result) 'error)
                        (setf (alist-get type results nil nil #'equal)
                              (candidates type result)))
                      (publish)))))
               (match-files)
               (load-files)
               (publish)))
            ((or 'cancel 'destroy)
             (cancel)
             (setq current nil)
             (funcall sink action))
            ;; All other consult actions: pass through unchanged.
            (_ (funcall sink action))))))))

(defun octocat-search-repo ()
  "Search for a PR, issue, commit, or file in the current repository.

Fires live `gh search' queries (PRs, issues, and commits in parallel)
against the repository associated with the current buffer.  Results
update as each query completes.  File paths containing every word of
the query are listed too.  Selecting a candidate opens the
corresponding detail view.

The query is matched against titles, commit messages, and bodies.
Prefix a hash (e.g. \"a1b2c3\") to narrow to a specific commit."
  (interactive)
  (let ((repo (octocat--search-repo--current-repo)))
    (unless repo
      (user-error "Octocat: Cannot determine current repository"))
    (let* ((chosen (consult--read
                    (consult--async-pipeline
                     (consult--async-min-input 2)
                     (consult--async-throttle)
                     (octocat--async-search-repo-objects repo))
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

(octocat-sync-define-resource repo-search (query)
  :max-age octocat-repo-search-cache-ttl
  :fetch (lambda (done)
           (octocat--run-gh
            "search-repos"
            (if (string-prefix-p "@" query)
                ;; `gh search' has no users subcommand; -X GET keeps -f
                ;; fields in the query string.
                (list "api" "-X" "GET" "search/users"
                      "-f" (concat "q=" (substring query 1))
                      "-f" "per_page=15"
                      "--jq" "[.items[] | {login}]")
              (list "search" "repos" "--limit" "30" "--json" "fullName" query))
            (lambda (output)
              (vconcat (mapcar (lambda (r)
                                 (if-let* ((login (gethash "login" r)))
                                     (concat "@" login)
                                   (gethash "fullName" r)))
                               (octocat--parse-json-list output))))
            done)))

(defun octocat--async-search-repos ()
  "Return a consult async stage searching GitHub for the input's repos.
Input starting with \"@\" searches users instead.  The stored result of
the input shows at once, and the fetched one replaces it.  New input
cancels the fetch of the last if it is still queued, so it never waits
behind input typed past.  Debounce it upstream with
`consult--async-min-input' and `consult--async-throttle'."
  (lambda (sink)
    (let (current)
      (lambda (action)
        (pcase action
          ((pred stringp)
           (when current (octocat-sync-cancel current))
           (let ((spec (list 'repo-search action)))
             (setq current spec)
             (funcall sink 'flush)
             (when-let* ((stored (plist-get (octocat-sync-read spec) :data)))
               (funcall sink (append stored nil)))
             (funcall sink [indicator running])
             (octocat-sync-get
              spec
              (lambda (result)
                (when (eq current spec)
                  (if (eq (car-safe result) 'error)
                      (funcall sink [indicator failed])
                    (funcall sink 'flush)
                    (when (> (length result) 0)
                      (funcall sink (append result nil)))
                    (funcall sink [indicator finished])))))))
          ((or 'cancel 'destroy)
           (when current (octocat-sync-cancel current))
           (setq current nil)
           (funcall sink action))
          (_ (funcall sink action)))))))

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
