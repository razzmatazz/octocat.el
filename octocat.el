;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: Saulius Menkevicius <sauliusmenkevicius@fastmail.com>
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (consult "1.0") (vui "0.1"))
;; Keywords: tools, vc, github
;; URL: https://github.com/razzmatazz/octocat.el

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

;; Emacs client for GitHub, powered by the gh CLI.
;;
;; Entry points:
;;   M-x octocat      — GitHub account dashboard (your open PRs and issues,
;;                      recent repos, activity feed)
;;   M-x octocat-repo — Per-repository view (summary, Commits)
;;   M-x octocat-pr-list / octocat-issue-list / octocat-actions — list pages
;;   M-x octocat-run-list / octocat-workflow-list — the Actions pages

;;; Code:

(require 'octocat-core)
(require 'octocat-image)
(require 'octocat-sync)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-compare)
(require 'octocat-pr-diff)
(require 'octocat-issue)
(require 'octocat-timeline)
(require 'octocat-workflow)
(require 'octocat-run)
(require 'octocat-job)
(require 'octocat-checks)
(require 'octocat-vui)
(require 'octocat-repo)
(require 'octocat-user)
(require 'octocat-tree)
(require 'octocat-search)

;; Buffer-locals of other files, used below.
(defvar octocat-repo--repo)           ; defined as buffer-local in octocat-repo.el
(defvar octocat-repo--ref)            ; likewise

;; Evil integration is optional; declare its entry point to silence the
;; byte-compiler when `octocat-evil' has not been loaded yet.
(declare-function octocat-evil-setup "octocat-evil" ())

;; Repo-mode entry point (defined in octocat-repo.el, already required).
(declare-function octocat-repo-refresh      "octocat-repo" (&optional _ignore-auto _noconfirm))
(declare-function octocat-repo--local-dir-for "octocat-repo" (repo))


;;;; Dashboard major mode

(defcustom octocat-feed-limit 15
  "Number of feed events to fetch initially on the dashboard.
Each `octocat-feed-load-more' call fetches this many additional events."
  :type 'integer
  :group 'octocat)

(defcustom octocat-dashboard-item-limit 5
  "Number of open pull requests, and of issues, the dashboard lists."
  :type 'integer
  :group 'octocat)

(defvar-local octocat--feed-limit nil
  "Per-buffer feed event fetch limit.
Starts at `octocat-feed-limit' and grows with `octocat-feed-load-more'.")

(defun octocat-dashboard-browse ()
  "Open the pull request, issue or repository at point in a browser.
Falls back to the user's GitHub page when point is not on a row."
  (interactive)
  (let ((url  (get-text-property (point) 'octocat-dashboard-url))
        (repo (get-text-property (point) 'octocat-dashboard-repo)))
    (cond (url
           (message "Octocat: Opening %s in browser…" url)
           (octocat-browse-external url))
          (repo
           (message "Octocat: Opening %s in browser…" repo)
           (octocat-browse-external (format "https://github.com/%s" repo)))
          (t
           (message "Octocat: Opening GitHub in browser…")
           (octocat-browse-external "https://github.com")))))

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "+")       #'octocat-feed-load-more)
    (define-key map (kbd "C-c C-o") #'octocat-dashboard-browse)
    map)
  "Keymap for `octocat-mode' (GitHub account dashboard).")
(define-derived-mode octocat-mode vui-mode "Octocat"
  "Major mode for the GitHub account dashboard.

\\{octocat-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-refresh)
  (add-hook 'post-command-hook #'octocat-vui--prefetch-schedule nil t)
  (octocat--ts-eldoc-setup))


;;;; Dashboard fetch helpers

(defun octocat--fetch-recent-repos (callback)
  "Fetch the authenticated user's recently-pushed repos via gh.
Calls CALLBACK with a list of hash-tables (GitHub REST user/repos
response), or an (error . MSG) cons on failure."
  (octocat--run-gh
   "dashboard-repos"
   (list "api" "user/repos?sort=pushed&per_page=10")
   #'octocat--parse-json-list
   callback))

(defun octocat--fetch-viewer-login (callback)
  "Fetch the authenticated user's GitHub login via gh.
Calls CALLBACK with the login string, or an (error . MSG) cons."
  (octocat--run-gh
   "dashboard-login"
   (list "api" "user" "--jq" ".login")
   (lambda (output) (string-trim output))
   callback))

;; As github.com's dashboard: the open items the user opened, is assigned
;; to, was asked to review, is mentioned in or commented on, across
;; every repository.  The rows are the list pages', so the fields are
;; theirs, with the repository each item is in.

(defun octocat--dashboard-search-query (kind)
  "Return the GitHub search string for the dashboard's KIND items.
KIND is `issues' or `pulls'."
  (format "is:open archived:false involves:@me sort:updated-desc type:%s"
          (if (eq kind 'pulls) "pr" "issue")))

(defun octocat--dashboard-items-query (kind)
  "Return the GraphQL search query for the dashboard's KIND items."
  (format (concat "query($q:String!,$limit:Int!){search(query:$q,type:ISSUE_ADVANCED,"
                  "first:$limit){nodes{...on Issue{repository{nameWithOwner}} ...on "
                  "PullRequest{repository{nameWithOwner}} %s}pageInfo{hasNextPage "
                  "endCursor}}}")
          (alist-get kind octocat--list-item-fields)))

(defun octocat--fetch-dashboard-items (kind limit callback)
  "Fetch the first LIMIT of the dashboard's KIND items via gh.
KIND is `issues' or `pulls'.  CALLBACK is called with the plist from
`octocat--parse-list-items', or an (error . MSG) cons."
  (octocat--run-gh
   (format "dashboard-%s" kind)
   (list "api" "graphql"
         "-f" (concat "query=" (octocat--dashboard-items-query kind))
         "-f" (concat "q=" (octocat--dashboard-search-query kind))
         "-F" (format "limit=%d" limit))
   #'octocat--parse-list-items
   callback))

(defun octocat--dashboard-items-tree (kind page)
  "Return PAGE, the dashboard's KIND items, as its resource's tree.
PAGE is as `octocat--parse-list-items' returns.  Each item becomes a
table of its \"repo\" and its entity, \"item\", shared with the lists."
  (let ((type (if (eq kind 'pulls) 'pr 'issue)))
    (vconcat
     (mapcar (lambda (item)
               (let ((node (make-hash-table :test #'equal))
                     (repo (gethash "nameWithOwner" (gethash "repository" item))))
                 (remhash "repository" item)
                 (puthash "repo" repo node)
                 (puthash "item" (octocat-sync-item type repo item) node)
                 node))
             (plist-get page :items)))))

(defun octocat--fetch-received-events (login limit callback)
  "Fetch the received events feed for the user with LOGIN via gh.
LIMIT is the maximum number of events to request (per_page).
Calls CALLBACK with a list of hash-tables, or an (error . MSG) cons."
  (octocat--run-gh
   "dashboard-feed"
   (list "api" (format "users/%s/received_events?per_page=%d" login limit))
   #'octocat--parse-json-list
   callback))


;;;; Dashboard rendering helpers

(defun octocat--dashboard-event-icon (type)
  "Return a short propertized label string for dashboard feed event TYPE."
  (pcase type
    ("PushEvent"                    (propertize "push        " 'face 'octocat-dimmed))
    ("PullRequestEvent"             (propertize "pr          " 'face 'octocat-pr-state-open))
    ("IssueCommentEvent"            (propertize "comment     " 'face 'octocat-dimmed))
    ("IssuesEvent"                  (propertize "issue       " 'face 'octocat-dimmed))
    ("WatchEvent"                   (propertize "star        " 'face 'octocat-dimmed))
    ("ForkEvent"                    (propertize "fork        " 'face 'octocat-dimmed))
    ("CreateEvent"                  (propertize "create      " 'face 'octocat-dimmed))
    ("DeleteEvent"                  (propertize "delete      " 'face 'octocat-dimmed))
    ("ReleaseEvent"                 (propertize "release     " 'face 'octocat-dimmed))
    ("MemberEvent"                  (propertize "member      " 'face 'octocat-dimmed))
    ("GollumEvent"                  (propertize "wiki        " 'face 'octocat-dimmed))
    ("PullRequestReviewEvent"       (propertize "review      " 'face 'octocat-dimmed))
    ("PullRequestReviewCommentEvent" (propertize "review cmt  " 'face 'octocat-dimmed))
    ("CommitCommentEvent"           (propertize "cmt comment " 'face 'octocat-dimmed))
    ("PublicEvent"                  (propertize "public      " 'face 'octocat-dimmed))
    ("SponsorshipEvent"             (propertize "sponsor     " 'face 'octocat-dimmed))
    (_                              (propertize (format "%-12s" (or type "event"))
                                                'face 'octocat-dimmed))))

(defun octocat--dashboard-event-detail (event)
  "Return a short human-readable detail string for feed EVENT hash-table.
EVENT is a hash-table from the GitHub received_events REST endpoint.
The detail text is derived from the event type and payload fields."
  (let* ((type    (or (gethash "type"    event) ""))
         (payload (or (gethash "payload" event) (make-hash-table)))
         (action  (and (hash-table-p payload)
                       (octocat--nonempty (gethash "action" payload)))))
    (pcase type
      ("PushEvent"
       ;; The /received_events API omits commits[] and size for watched
       ;; repos — only ref, head, and before are provided.  Show the branch
       ;; and a short SHA instead of an unreliable commit count.
       (let* ((ref    (and (hash-table-p payload)
                           (octocat--nonempty (gethash "ref" payload))))
              (branch (if ref
                          (replace-regexp-in-string "^refs/heads/" "" ref)
                        "?"))
              (head   (and (hash-table-p payload)
                           (octocat--nonempty (gethash "head" payload))))
              (short  (and head (substring head 0 (min 7 (length head))))))
         (if short
             (format "pushed to %s (%s)" branch short)
           (format "pushed to %s" branch))))
      ("PullRequestEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (title  (and (hash-table-p pr) (octocat--nonempty (gethash "title" pr))))
              (number (and (hash-table-p pr) (gethash "number" pr))))
         (format "%s PR%s%s"
                 (or action "opened")
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 30 nil nil "…")) ""))))
      ("IssuesEvent"
       (let* ((issue  (and (hash-table-p payload) (gethash "issue" payload)))
              (number (and (hash-table-p issue) (gethash "number" issue)))
              (title  (and (hash-table-p issue)
                           (octocat--nonempty (gethash "title" issue)))))
         (format "%s issue%s%s"
                 (or action "opened")
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 35 nil nil "…")) ""))))
      ("IssueCommentEvent"
       (let* ((issue  (and (hash-table-p payload) (gethash "issue" payload)))
              (number (and (hash-table-p issue) (gethash "number" issue)))
              (title  (and (hash-table-p issue)
                           (octocat--nonempty (gethash "title" issue)))))
         (format "commented on issue%s%s"
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 30 nil nil "…")) ""))))
      ("WatchEvent"   "starred")
      ("ForkEvent"    "forked")
      ("PullRequestReviewEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (number (and (hash-table-p pr) (gethash "number" pr)))
              (state  (and (hash-table-p payload)
                           (octocat--nonempty (gethash "state" payload)))))
         (format "reviewed PR%s%s"
                 (if number (format " #%d" number) "")
                 (if state (format " (%s)" state) ""))))
      ("PullRequestReviewCommentEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (number (and (hash-table-p pr) (gethash "number" pr))))
         (format "commented on PR%s review"
                 (if number (format " #%d" number) ""))))
      ("CommitCommentEvent"
       (let* ((comment (and (hash-table-p payload) (gethash "comment" payload)))
              (sha     (and (hash-table-p comment)
                            (octocat--nonempty (gethash "commit_id" comment)))))
         (format "commented on commit%s"
                 (if sha (format " %.7s" sha) ""))))
      ("GollumEvent"
       (let* ((pages (and (hash-table-p payload) (gethash "pages" payload)))
              (page  (and (vectorp pages) (> (length pages) 0) (aref pages 0)))
              (title (and (hash-table-p page)
                          (octocat--nonempty (gethash "title" page)))))
         (format "edited wiki%s" (if title (format ": %s" title) ""))))
      ("CreateEvent"
       (let ((ref-type (and (hash-table-p payload)
                            (octocat--nonempty (gethash "ref_type" payload)))))
         (format "created %s" (or ref-type "branch"))))
      ("DeleteEvent"
       (let ((ref-type (and (hash-table-p payload)
                            (octocat--nonempty (gethash "ref_type" payload)))))
         (format "deleted %s" (or ref-type "branch"))))
      ("ReleaseEvent"
       (let* ((release (and (hash-table-p payload) (gethash "release" payload)))
              (tag     (and (hash-table-p release)
                            (octocat--nonempty (gethash "tag_name" release)))))
         (format "released%s" (if tag (format " %s" tag) ""))))
      ("MemberEvent"
       (format "%s member" (or action "added")))
      (_
       (or action type "event")))))

(defun octocat--dashboard-visit-event (ev)
  "Open the buffer that best matches feed event EV.
Dispatches on the event type:
  PushEvent                       → octocat-commit for the head SHA
  PullRequestEvent / Review*      → octocat-pr for the PR number
  IssuesEvent / IssueCommentEvent → octocat-issue for the issue number
  everything else                 → octocat-repo for the repo"
  (let* ((type      (and (hash-table-p ev) (gethash "type" ev)))
         (repo-obj  (and (hash-table-p ev) (gethash "repo" ev)))
         (full-name (and (hash-table-p repo-obj)
                         (octocat--nonempty (gethash "name" repo-obj))))
         (payload   (and (hash-table-p ev) (gethash "payload" ev))))
    (cond
     ((not full-name)
      (message "Octocat: No repository associated with this event"))
     ((equal type "PushEvent")
      (octocat-commit-open
       full-name
       (or (and (hash-table-p payload)
                (octocat--nonempty (gethash "head" payload)))
           "")))
     ((member type '("PullRequestEvent"
                     "PullRequestReviewEvent"
                     "PullRequestReviewCommentEvent"))
      (let* ((pr-obj (and (hash-table-p payload)
                          (gethash "pull_request" payload)))
             (number (or (and (hash-table-p payload)
                              (gethash "number" payload))
                         (and (hash-table-p pr-obj)
                              (gethash "number" pr-obj)))))
        (if number
            (octocat-pr-open full-name number)
          (message "Octocat: No PR number in event payload"))))
     ((member type '("IssuesEvent" "IssueCommentEvent"))
      (let* ((issue-obj (and (hash-table-p payload)
                             (gethash "issue" payload)))
             (number    (and (hash-table-p issue-obj)
                             (gethash "number" issue-obj))))
        (if number
            (octocat-issue-open full-name number)
          (message "Octocat: No issue number in event payload"))))
     (t (octocat-visit-repo full-name)))))

(defun octocat--dashboard-repo-row (r)
  "Return the RET-able row vnode for R, the fields of a `repo' entity."
  (let* ((full-name (or (gethash "nameWithOwner" r) ""))
         (desc      (octocat--nonempty (gethash "description" r)))
         (lang      (or (let ((l (gethash "primaryLanguage" r)))
                          (and l (octocat--nonempty (gethash "name" l))))
                        ""))
         (date      (octocat--format-ts-relative (or (gethash "pushedAt" r) ""))))
    (octocat-vui-row
     (propertize
      (concat (propertize (format "  %-35s" full-name) 'face 'octocat-repo)
              (propertize (format "  %-14s" lang) 'face 'octocat-dimmed)
              (propertize (format "  %-12s" date) 'face 'octocat-dimmed)
              (propertize (format "  %s" (or desc "")) 'face 'octocat-dimmed))
      'octocat-dashboard-repo full-name)
     (lambda () (octocat-visit-repo full-name))
     "RET: open repo  C-c C-o: browse on GitHub")))

(defun octocat--dashboard-item-row (kind node width bg)
  "Return the RET-able row vnode for NODE, one of the dashboard's KIND items.
NODE is as `octocat--dashboard-items-tree' makes it.  The row is the list
pages' two lines, cut to WIDTH; BG is as for `octocat--label-face'."
  (let* ((repo   (gethash "repo" node))
         (item   (gethash "item" node))
         (number (gethash "number" item))
         (pr     (eq kind 'pulls)))
    (octocat-vui-row
     (propertize
      (mapconcat #'identity
                 (octocat-repo-vui--item-lines
                  (octocat-repo-vui--state-label (gethash "state" item)
                                                 (gethash "isDraft" item))
                  (octocat-repo-vui--cells repo item bg)
                  '(:review :ci :prs :comments) width)
                 "\n")
      'octocat-dashboard-url (format "https://github.com/%s/%s/%d"
                                     repo (if pr "pull" "issues") number)
      'octocat-sync-prefetch `((,(if pr 'pr 'issue) ,repo ,number)
                               (timeline-events ,repo ,number)))
     (lambda () (if pr (octocat-pr-open repo number) (octocat-issue-open repo number)))
     (format "RET: view %s  C-c C-o: browse on GitHub" (if pr "pull request" "issue")))))

(defun octocat--dashboard-feed-row (ev)
  "Return the RET-able row vnode for feed event hash-table EV."
  (let* ((type   (or (gethash "type" ev) ""))
         (actor  (let ((a (gethash "actor" ev)))
                   (if (hash-table-p a) (or (gethash "login" a) "") "")))
         (repo   (let ((r (gethash "repo" ev)))
                   (if (hash-table-p r) (or (gethash "name" r) "") "")))
         (detail (octocat--dashboard-event-detail ev))
         (date   (octocat--format-ts-relative (or (gethash "created_at" ev) ""))))
    (octocat-vui-row
     (propertize
      (concat "  "
              (octocat--dashboard-event-icon type)
              "  "
              (propertize (format "%-16s" actor) 'face 'octocat-pr-author)
              "  "
              (propertize (format "%-35s" repo) 'face 'octocat-branch)
              "  "
              (octocat--format-title detail)
              "  "
              (propertize date 'face 'octocat-dimmed))
      'octocat-dashboard-repo (octocat--nonempty repo))
     (lambda () (octocat--dashboard-visit-event ev))
     "RET: open commit or repo  C-c C-o: browse repo on GitHub")))

(defun octocat--dashboard-section (title items error empty rows)
  "Return a section vnode: heading TITLE, then the rows of ITEMS.
ITEMS is a list, or the symbol `pending' while there are none yet;
ERROR, a message, shows when they failed to load.  EMPTY is the text
shown when there is nothing to list, and ROWS a function turning ITEMS
into the vnode of their rows."
  (vui-vstack
   (vui-text title :face 'octocat-section-heading)
   (cond
    (error (vui-text (format "  %s" error) :face 'octocat-dimmed))
    ((eq items 'pending) (vui-text (octocat-vui-line-skeleton "  ")))
    ((null items) (vui-text (concat "  " empty) :face 'octocat-dimmed))
    (t (funcall rows items)))))

(octocat-sync-define-resource dashboard-repos ()
  :fetch (lambda (done)
           (octocat--fetch-recent-repos
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (cl-map 'vector #'octocat-sync-repo-rest r)))))))

(octocat-sync-define-resource dashboard-items (kind limit)
  :fetch (lambda (done)
           (octocat--fetch-dashboard-items
            kind limit
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat--dashboard-items-tree kind r)))))))

(octocat-sync-define-resource dashboard-feed (limit)
  :fetch (lambda (done)
           (octocat--fetch-viewer-login
            (lambda (login)
              (if (eq (car-safe login) 'error)
                  (funcall done login)
                (octocat--fetch-received-events
                 login limit
                 (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r))))))))))

(defun octocat--dashboard-items-section (title kind snap width bg)
  "Return the section vnode TITLE listing the dashboard's KIND items.
SNAP is the snapshot of their resource; the rows are cut to WIDTH, and
BG is as for `octocat--label-face'."
  (octocat--dashboard-section
   title
   (if (plist-get snap :data) (append (plist-get snap :data) nil) 'pending)
   (and (eq (octocat-vui-snapshot-status snap) 'error) (octocat-vui-error-text snap))
   (format "(no open %s involving you)" (if (eq kind 'pulls) "pull requests" "issues"))
   (lambda (data)
     (vui-list data
               (lambda (node) (octocat--dashboard-item-row kind node width bg))
               (lambda (node) (format "%s#%d" (gethash "repo" node)
                                      (gethash "number" (gethash "item" node))))))))

(vui-defcomponent octocat-dashboard--root (feed-limit tick)
  "Root component of the dashboard.
It lists your open pull requests and issues, as github.com's dashboard
does, then your recent repositories and the feed.  FEED-LIMIT is how
many feed events to fetch.  Each section paints from the sync store
until the fresh data arrives; a new TICK fetches them all again."
  :render
  (let* ((width   (octocat-vui-window-width))
         (bg      (octocat--label-background))
         (prs     (octocat-vui-use-resource
                   (list 'dashboard-items 'pulls octocat-dashboard-item-limit) tick))
         (issues  (octocat-vui-use-resource
                   (list 'dashboard-items 'issues octocat-dashboard-item-limit) tick))
         (repos   (octocat-vui-use-resource '(dashboard-repos) tick))
         (feed    (octocat-vui-use-resource (list 'dashboard-feed feed-limit) tick))
         (shown   (vui-use-ref nil)))
    ;; Each limit is its own resource: keep the shorter feed while the
    ;; longer one loads.
    (when (plist-get feed :data) (setcar shown (append (plist-get feed :data) nil)))
    (vui-vstack
     (vui-text "GitHub Dashboard" :face 'octocat-repo)
     (octocat--dashboard-items-section "Pull Requests" 'pulls prs width bg)
     (vui-newline)
     (octocat--dashboard-items-section "Issues" 'issues issues width bg)
     (vui-newline)
     (octocat--dashboard-section
      "Recent Repositories"
      (if (plist-get repos :data) (append (plist-get repos :data) nil) 'pending)
      (and (eq (octocat-vui-snapshot-status repos) 'error) (octocat-vui-error-text repos))
      "(no repositories)"
      (lambda (data)
        (vui-list data #'octocat--dashboard-repo-row
                  (lambda (r) (gethash "nameWithOwner" r)))))
     (vui-newline)
     (octocat--dashboard-section
      "Feed"
      (if (or (car shown) (plist-get feed :data)) (car shown) 'pending)
      (and (null (car shown)) (eq (octocat-vui-snapshot-status feed) 'error)
           (octocat-vui-error-text feed))
      "(no recent activity)"
      (lambda (data)
        (vui-fragment
         (octocat-vui-reveal-list data #'octocat--dashboard-feed-row
                                  (lambda (ev) (gethash "id" ev)))
         (when (or (>= (length data) feed-limit)
                   ;; Keep the button in place while a further page
                   ;; loads (the limit has already grown).
                   (and (plist-get feed :loading)
                        (> feed-limit octocat-feed-limit)))
           (octocat-vui-load-more-button
            'load-more-feed octocat-feed-limit
            "RET / +: load more feed events"
            #'octocat-feed-load-more
            (and (plist-get feed :loading) (< (length data) feed-limit))
            nil (octocat-vui-line-skeleton)))))))))


;;;; Dashboard refresh

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the octocat dashboard buffer.
The dashboard paints from the sync store at once and fetches each
section in the background, in place."
  (interactive)
  (octocat-vui-refresh-page 'octocat-dashboard--root nil
                            (list :feed-limit (or octocat--feed-limit
                                                  octocat-feed-limit))))



;;;; Feed load-more command

(defun octocat-feed-load-more ()
  "Fetch additional feed events in the dashboard buffer.
Increments the per-session feed fetch limit by `octocat-feed-limit' and
re-runs `octocat-refresh'."
  (interactive)
  (unless (derived-mode-p 'octocat-mode)
    (user-error "Octocat: Not in the dashboard buffer"))
  (unless octocat--feed-limit
    (setq octocat--feed-limit octocat-feed-limit))
  (cl-incf octocat--feed-limit octocat-feed-limit)
  (or (octocat-vui-update-page :feed-limit octocat--feed-limit)
      (octocat-refresh)))


;;;; Entry points
;;
;; All `;;;###autoload' commands live here, even when the mode/logic they
;; open is defined in another file (e.g. `octocat-repo' below only calls
;; into `octocat-repo.el').  This funnels every user-facing entry point
;; through this one file, guaranteeing `octocat--evil-init' (bottom of this
;; file) always runs on the very first octocat command of a session.  See
;; CONTRIBUTING.md, "Entry points", and
;; plans/repo-mode-evil-ret-binding.md for the bug this convention fixes.

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat GitHub account dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*octocat*")))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (octocat-refresh)))

;;;###autoload
(defun octocat-repo ()
  "Open (or switch to) the octocat-repo buffer for the current GitHub repository.
When invoked from inside a git working tree the buffer is opened in
\\='attached\\=' mode: `octocat-repo--local-dir' is set to the root of that
working tree, and the repo is derived from its \\='origin\\=' remote.
When invoked without a detectable working tree (or when the user supplies
a REPO argument in a future extension), the buffer runs in \\='detached\\='
mode with no local directory bound."
  (interactive)
  (let* ((repo     (octocat-repo--current-repo))
         (local-dir (locate-dominating-file default-directory ".git"))
         (buf-name (format "*%s*" repo))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (and local-dir
                                       (expand-file-name local-dir))
          octocat-repo--ref       nil)
    (octocat-repo-refresh)))

;;;###autoload
(defun octocat-user (login)
  "Open the page of the GitHub user or organization LOGIN, e.g. \"@octocat\".
With a nil or empty LOGIN, open the authenticated user's own page.
Interactively that is the default; with a prefix argument, prompt for
the handle instead (a leading \"@\" is optional)."
  (interactive
   (list (and current-prefix-arg
              (read-string "GitHub user or organization: "
                           (and (derived-mode-p 'octocat-user-mode)
                                octocat-user--login)))))
  (if (string-empty-p (string-trim (or login "")))
      (progn
        (message "Octocat: Looking up your GitHub login…")
        (octocat--fetch-viewer-login
         (lambda (result)
           (if (eq (car-safe result) 'error)
               (message "Octocat: Could not look up your login: %s" (cdr result))
             (octocat-user-open result)))))
    (octocat-user-open login)))

(defun octocat--open-list (mode name path &optional repo)
  "Open (or switch to) the list page for the current repository.
MODE is the list major mode to enable, NAME the suffix of the buffer
name, and PATH the github.com sub-path `octocat-vui-list-browse' opens.
REPO, an \"owner/name\" string, overrides the repository below.
Inside an octocat repo or list buffer the page is for that buffer's
repository and local clone; elsewhere the repository is derived from
the current git working tree.  A page already open isn't refreshed."
  (let* ((repo      (cond (repo)
                          ((derived-mode-p 'octocat-repo-mode) octocat-repo--repo)
                          ((derived-mode-p 'octocat-vui-list-mode) octocat-vui-list--repo)
                          (t (octocat-repo--current-repo))))
         (local-dir (if (derived-mode-p 'octocat-repo-mode)
                        octocat-repo--local-dir
                      (octocat-repo--local-dir-for repo)))
         (buf       (get-buffer-create (format "*%s %s*" repo name))))
    (octocat-display-buffer buf)
    (when local-dir
      (setq default-directory (file-name-as-directory local-dir)))
    (if (and (derived-mode-p mode) octocat-vui--page)
        (octocat-vui-revisit-page)
      (funcall mode)
      (setq octocat-vui-list--repo repo
            octocat-vui-list--path path)
      (funcall revert-buffer-function))))

;;;###autoload
(defun octocat-pr-list (&optional repo)
  "Open the pull request list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-pr-list-mode "pr-list" "pulls" repo))

;;;###autoload
(defun octocat-issue-list (&optional repo)
  "Open the issue list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-issue-list-mode "issue-list" "issues" repo))

;;;###autoload
(defun octocat-run-list (&optional repo)
  "Open the run list of the current GitHub repository.
It lists the recent workflow runs across all workflows.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-run-list-mode "run-list" "actions" repo))

;;;###autoload
(defun octocat-workflow-list (&optional repo)
  "Open the list of workflows of the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-workflow-list-mode "workflow-list" "actions" repo))

;;;###autoload
(defun octocat-actions (&optional repo)
  "Open the Actions tab of the current GitHub repository.
That is its run list, `octocat-run-list'; see also `octocat-workflow-list'.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat-run-list repo))


;;;; Evil integration

(defun octocat--evil-init ()
  "Load and activate `octocat-evil' when Evil mode is enabled."
  (require 'octocat-evil)
  (octocat-evil-setup))

;; Run immediately if Evil is already active, otherwise hook into evil-mode.
(if (bound-and-true-p evil-mode)
    (octocat--evil-init)
  (add-hook 'evil-mode-hook #'octocat--evil-init))

(provide 'octocat)
;;; octocat.el ends here
