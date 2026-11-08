;;; octocat-model.el --- The GitHub data octocat syncs  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-sonnet-5-5
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

;; What octocat syncs: the entities pages share, every resource a page
;; reads and every mutation it sends, with the queries and parsers they
;; fetch through.  `octocat-sync' is the machinery that runs them; this
;; file only says what to fetch and send, and how GitHub's answers are
;; stored.  It draws nothing: pages read what it defines.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'octocat-core)
(require 'octocat-sync)

;;;; Entities
;;
;; Builders for the entities several pages share.  Fields keep the names
;; of GitHub's GraphQL API, which `gh ... --json' also uses.

(defun octocat-model--item-type (kind)
  "Return the entity type, `pr' or `issue', of KIND.
KIND is any name the pages give it: \"pr\" or \"issue\" as `gh' has
them, `pr' or `issue', or `pulls' or `issues' as the lists have them."
  (if (member kind '("pr" pr pulls)) 'pr 'issue))

(defun octocat-model--list-kind (kind)
  "Return KIND, as `octocat-model--item-type' takes it, as the lists name it."
  (if (eq (octocat-model--item-type kind) 'pr) 'pulls 'issues))

(defun octocat-model-item-key (kind repo number)
  "Return the key of issue or PR NUMBER of REPO.
KIND is as `octocat-model--item-type' takes it."
  (format "%s:%s#%d" (octocat-model--item-type kind) (downcase repo) number))

(defun octocat-model--item-lists (kind repo)
  "Return the specs of the lists and counts of the KIND items of REPO.
What opening, closing or merging one of them changes."
  (let ((kind (octocat-model--list-kind kind)))
    `((list-items ,kind ,repo _ _) (counts ,kind ,repo) (repo-summary ,repo))))

(defun octocat-model-user (user)
  "Return the `user' entity of USER, a table with a \"login\", or USER.
Only the login is kept: the fields beside it vary with the source."
  (let ((login (and (hash-table-p user) (gethash "login" user))))
    (if (not (stringp login))
        user
      (octocat-sync-entity 'user (concat "user:" (downcase login))
                           (octocat--table "login" login)))))

(defun octocat-model-label (repo label)
  "Return the `label' entity of LABEL of REPO, a table with name and colour."
  (octocat-sync-entity 'label (format "label:%s/%s" (downcase repo) (gethash "name" label))
                       (octocat--table "name" (gethash "name" label)
                                       "color" (gethash "color" label))))

(defun octocat-model--item-ref (ref)
  "Return REF, an issue or PR another one refers to, as its number and repo."
  (let ((h     (octocat--table "number" (gethash "number" ref)))
        (other (gethash "repository" ref)))
    (when (hash-table-p other)
      (puthash "repository"
               (octocat--table "name" (gethash "name" other)
                               "owner" (octocat--table
                                        "login" (octocat--get other "owner" "login")))
               h))
    h))

(defun octocat-model-item (type repo item)
  "Return the entity of the issue or PR ITEM of REPO; TYPE is `issue' or `pr'.
ITEM is a table of its fields.  Its author, assignees and labels become
entities too.  Labels must be the whole set: an entity's list fields
are never a page of it."
  (let ((fields (copy-hash-table item)))
    (when-let* ((author (gethash "author" item)))
      (puthash "author" (octocat-model-user author) fields))
    (when-let* ((assignees (gethash "assignees" item)))
      (puthash "assignees" (cl-map 'vector #'octocat-model-user assignees) fields))
    (when-let* ((labels (gethash "labels" item)))
      (when (sequencep labels)
        (puthash "labels" (cl-map 'vector (lambda (l) (octocat-model-label repo l)) labels)
                 fields)))
    ;; The lists and the page fetch these with different fields; keep
    ;; those both have, so the entity reads the same from either.
    (dolist (key '("closedByPullRequestsReferences" "closingIssuesReferences"))
      (when-let* ((refs (gethash key item)))
        (when (sequencep refs)
          (puthash key (cl-map 'vector #'octocat-model--item-ref refs) fields))))
    (octocat-sync-entity type (octocat-model-item-key type repo (gethash "number" item))
                         fields)))

(defun octocat-model-repo (fields)
  "Return the `repo' entity of FIELDS, a table in GraphQL's names."
  (octocat-sync-entity 'repo (concat "repo:" (downcase (gethash "nameWithOwner" fields)))
                       fields))

(defun octocat-model-repo-rest (repo)
  "Return the `repo' entity of REPO, a repository from GitHub's REST API.
Its fields are mapped to GraphQL's names, as every repo entity has them."
  (let ((lang (gethash "language" repo)))
    (octocat-model-repo
     (octocat--table "nameWithOwner" (gethash "full_name" repo)
                     "description" (gethash "description" repo)
                     "stargazerCount" (gethash "stargazers_count" repo)
                     "primaryLanguage" (and (stringp lang) (octocat--table "name" lang))
                     "pushedAt" (gethash "pushed_at" repo)
                     "isFork" (gethash "fork" repo)
                     "isArchived" (gethash "archived" repo)))))

(defun octocat-model-run (repo run)
  "Return the `run' entity of RUN, a workflow run of REPO, by `gh run' names."
  (octocat-sync-entity 'run (format "run:%s/%s" (downcase repo) (gethash "databaseId" run))
                       (copy-hash-table run)))

(defun octocat-model-detail (item parts make)
  "Return ITEM, such as an issue, as the tree of its page's resource.
MAKE returns the entity of a table of fields, such as
`octocat-model-item' does; the entity goes under \"item\", shared with
the lists that show it.  PARTS are the keys of ITEM that are pages of a
connection, such as \"comments\": an entity holds no such field, so
they stay with the resource.  The comments are counted on the entity,
as the lists count them."
  (let ((fields (copy-hash-table item))
        (tree   (make-hash-table :test #'equal)))
    (dolist (part parts)
      (puthash part (gethash part item) tree)
      (remhash part fields))
    (when (member "comments" parts)
      (puthash "commentCount" (length (gethash "comments" item)) fields))
    (puthash "item" (funcall make fields) tree)
    tree))

(defun octocat-model-detail-item (data)
  "Return the item of DATA, read from an `octocat-model-detail' tree.
Its parts are put back in it, so it has the shape `gh ... view' gives."
  (let ((item (copy-hash-table (gethash "item" data))))
    (maphash (lambda (k v) (unless (equal k "item") (puthash k v item))) data)
    item))

(defun octocat-model-detail-read (spec)
  "Return the item of the detail resource SPEC as the store has it, or nil."
  (let ((data (plist-get (octocat-sync-read spec) :data)))
    (and data (octocat-model-detail-item data))))

;;;; Shared resources

(defcustom octocat-repo-summary-ttl 300
  "Seconds a repo's summary, with its open issue and PR counts, is reused.
Within this, opening a page with the repo tabs doesn't refetch it; `g',
or closing, reopening or merging an item of the repo, does.  It is at
least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(defconst octocat-model--repo-summary-query
  (concat "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){"
          "defaultBranchRef{name} parent{nameWithOwner} issues(states:OPEN){totalCount} "
          "pullRequests(states:OPEN){totalCount}}}")
  "GraphQL query behind the `repo-summary' resource.
One request, in place of separate default-branch, fork-parent and
issue and PR count lookups.")

(defun octocat-model--parse-repo-summary (data)
  "Return the summary in DATA, the answer to `octocat-model--repo-summary-query'.
A table of \"default-branch\", \"fork-parent\", \"owner/repo\", each nil
when there is none, and the counts \"open-issues\" and \"open-prs\"."
  (let ((repo (gethash "repository" data)))
    (octocat--table "default-branch" (octocat--get repo "defaultBranchRef" "name")
                    "fork-parent"    (octocat--get repo "parent" "nameWithOwner")
                    "open-issues"    (octocat--get repo "issues" "totalCount")
                    "open-prs"       (octocat--get repo "pullRequests" "totalCount"))))

(octocat-sync-define-resource repo-summary (repo)
  :max-age octocat-repo-summary-ttl
  :graphql octocat-model--repo-summary-query
  :repo repo
  :parse #'octocat-model--parse-repo-summary)

(defun octocat-model--counts-query (kind)
  "Return the GraphQL query counting items of KIND (`issues' or `pulls')."
  (let ((field (if (eq kind 'pulls) "pullRequests" "issues"))
        (states (if (eq kind 'pulls)
                    '(("open" . "OPEN") ("closed" . "CLOSED") ("merged" . "MERGED"))
                  '(("open" . "OPEN") ("closed" . "CLOSED")))))
    (format "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){%s}}"
            (mapconcat (lambda (s)
                         (format "%s:%s(states:%s){totalCount}" (car s) field (cdr s)))
                       states " "))))

(defun octocat-model--parse-counts (data)
  "Return the counts in DATA, the answer to `octocat-model--counts-query'.
A table of \"open\", \"closed\" and, of pull requests, \"merged\"."
  (let ((counts (octocat--table)))
    (dolist (state '("open" "closed" "merged"))
      (when-let* ((n (octocat--get data "repository" state "totalCount")))
        (puthash state n counts)))
    counts))

(octocat-sync-define-resource counts (kind repo)
  :poll octocat-sync-poll-slow
  ;; Without KIND, nothing to count.
  :fetch (and (null kind) (lambda (done) (funcall done (octocat--table))))
  :graphql (and kind (octocat-model--counts-query kind))
  :repo repo
  :parse #'octocat-model--parse-counts)

(defconst octocat--list-item-fields
  `((pulls  . ,(concat "...on PullRequest{number title state isDraft reviewDecision "
                       "createdAt author{login} labels(first:100){nodes{name color}} "
                       "assignees(first:100){nodes{login}} "
                       ;; Not reviewRequests: the PR page keeps that apart.
                       "requestedReviewers:reviewRequests(first:100){nodes{requestedReviewer{"
                       "...on User{login} ...on Team{name}}}} "
                       "comments{totalCount} commits(last:1){nodes{commit{statusCheckRollup{"
                       "state contexts{checkRunCountsByState{state count} "
                       "statusContextCountsByState{state count}}}}}}}"))
    (issues . ,(concat "...on Issue{number title state createdAt author{login} "
                       "labels(first:100){nodes{name color}} comments{totalCount} "
                       "assignees(first:100){nodes{login}} "
                       "closedByPullRequestsReferences(first:20){nodes{number repository{"
                       "name owner{login}}}}}")))
  "The GraphQL fields of a list row, by KIND.
Only what the row shows: `gh pr/issue list --json' would fetch every
comment's body and every check run, many times the size and the API cost.
Labels and assignees are all fetched, since the sync store keeps them
on the item's entity, which must hold the whole set; the Marked bar
toggles them.")

(defun octocat--list-items-query (kind)
  "Return the GraphQL search query for a page of KIND list items."
  (format (concat "query($q:String!,$limit:Int!,$after:String){search(query:$q,"
                  "type:ISSUE_ADVANCED,first:$limit,after:$after){nodes{%s}pageInfo{"
                  "hasNextPage endCursor}}}")
          (alist-get kind octocat--list-item-fields)))

(defun octocat--flatten-list-item (item)
  "Flatten the connections of the search result ITEM in place; return it.
\"labels\", \"assignees\" and \"closedByPullRequestsReferences\" become
vectors of their nodes, as gh's JSON has them; the comments become their
count, \"commentCount\"; a PR's \"requestedReviewers\" the users and
teams asked to review it; and the head commit's checks become GitHub's
rolled-up state, \"ciState\", and how many passed of how many,
\"ciPassed\" and \"ciTotal\", absent without checks."
  (dolist (key '("labels" "assignees" "closedByPullRequestsReferences"))
    (let ((conn (gethash key item)))
      (when (hash-table-p conn)
        (puthash key (gethash "nodes" conn) item))))
  (let ((requests (gethash "requestedReviewers" item)))
    (when (hash-table-p requests)
      (puthash "requestedReviewers"
               (cl-map 'vector (lambda (n) (gethash "requestedReviewer" n))
                       (gethash "nodes" requests))
               item)))
  (let ((comments (gethash "comments" item)))
    (when (hash-table-p comments)
      (puthash "commentCount" (gethash "totalCount" comments) item)
      (remhash "comments" item)))
  (let* ((commits (gethash "commits" item))
         ;; A closed PR may come with no commits: [].
         (node    (and (hash-table-p commits) (car (append (gethash "nodes" commits) nil))))
         (rollup  (and node (gethash "statusCheckRollup" (gethash "commit" node)))))
    (when (hash-table-p rollup)
      (puthash "ciState" (gethash "state" rollup) item)
      (let ((ctx (gethash "contexts" rollup)) (passed 0) (total 0))
        (when (hash-table-p ctx)
          (dolist (kind '(("checkRunCountsByState" "SUCCESS" "NEUTRAL" "SKIPPED")
                          ("statusContextCountsByState" "SUCCESS")))
            (seq-doseq (c (or (gethash (car kind) ctx) []))
              (let ((n (gethash "count" c)))
                (setq total (+ total n))
                (when (member (gethash "state" c) (cdr kind))
                  (setq passed (+ passed n))))))
          (puthash "ciPassed" passed item)
          (puthash "ciTotal" total item))))
    (remhash "commits" item))
  item)

(defun octocat--list-page (data)
  "Return DATA, a list search's answer, as (:items LIST :cursor C).
The items are flattened by `octocat--flatten-list-item'.  C is the cursor
to pass for the next page, or nil on the last."
  (let* ((search (gethash "search" data))
         (info   (gethash "pageInfo" search)))
    (list :items  (mapcar #'octocat--flatten-list-item (gethash "nodes" search))
          :cursor (and (eq (gethash "hasNextPage" info) t)
                       (octocat--nonempty (gethash "endCursor" info))))))

(defun octocat--parse-list-items (json-string)
  "Parse JSON-STRING, a list search's response, as `octocat--list-page' does."
  (octocat--list-page (gethash "data" (json-parse-string json-string))))

(defun octocat--list-items (kind repo callback &optional query after limit)
  "Fetch a page of the KIND items of REPO matching the search QUERY.
KIND is `issues' or `pulls'.  AFTER, a cursor from an earlier page,
fetches the page after it; a page is LIMIT items, by default
`octocat-list-page-size'.
CALLBACK is called with the plist from `octocat--parse-list-items', or a
cons \\=(error . MSG).  One API call."
  (octocat--gh-graphql
   (symbol-name kind) nil (octocat--list-items-query kind)
   `(("q" . ,(octocat--search-query repo kind query))
     ("limit" . ,(or limit octocat-list-page-size))
     ("after" . ,after))
   #'octocat--parse-list-items
   callback))

(defun octocat-model-list-tree (kind repo page)
  "Return PAGE, a page of KIND items of REPO, as a list resource's tree.
PAGE is as `octocat--parse-list-items' returns; each item is an entity."
  (let ((type (octocat-model--item-type kind)))
    (octocat--table "nodes" (vconcat (mapcar (lambda (item) (octocat-model-item type repo item))
                                             (plist-get page :items)))
                    "cursor" (plist-get page :cursor))))

(octocat-sync-define-resource list-items (kind repo query limit)
  :fetch (lambda (done)
           ;; As many as "load more" stored, so a refetch keeps them.
           (let ((data (plist-get (octocat-sync-read
                                   (list 'list-items kind repo query limit))
                                  :data)))
             (octocat--list-items
              kind repo
              (octocat--then (lambda (page) (octocat-model-list-tree kind repo page)) done)
              query nil (min 100 (max limit (length (and data (gethash "nodes" data)))))))))

(octocat-sync-define-resource labels (repo)
  :poll octocat-sync-poll-slow
  :gh (list "label" "list" "--repo" repo "--limit" "200" "--json" "name,color")
  :parse (lambda (labels) (cl-map 'vector (lambda (l) (octocat-model-label repo l)) labels)))

(octocat-sync-define-resource assignees (repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done) (octocat--list-people repo (octocat--then #'vconcat done))))

(defconst octocat-model--fixed-max-age (* 30 24 60 60)
  "Seconds to keep what a SHA names, which never changes.")

;; The content is kept base64-encoded, as GitHub sends it, so it can be
;; stored as JSON: a file need not be text.
(octocat-sync-define-resource blob (repo sha)
  :max-age octocat-model--fixed-max-age
  ;; No SHA, no file: a page asks for one before it knows it.
  :fetch (and (null sha) (lambda (done) (funcall done (octocat--table "base64" ""))))
  :gh (list "api" (format "repos/%s/git/blobs/%s" repo sha))
  ;; GitHub wraps lines at 60 chars.
  :parse (lambda (blob)
           (octocat--table "base64" (replace-regexp-in-string "\n" "" (gethash "content" blob)))))

(defun octocat-model-blob-content (data)
  "Return the content of a file from DATA, the `blob' resource's."
  (base64-decode-string (gethash "base64" data)))

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
  :gh (octocat--repo-search-args query)
  :parse (lambda (results)
           (cl-map 'vector (lambda (r)
                             (if-let* ((login (gethash "login" r)))
                                 (concat "@" login)
                               (gethash "fullName" r)))
                   results)))

(octocat-sync-define-resource branches (repo)
  :fetch (lambda (done) (octocat--list-branches repo (octocat--then #'vconcat done))))

;;;; Issues and PRs

;; Its "events" are those of all pages.
(octocat-sync-define-resource timeline-events (repo number)
  :gh (list "api" "--paginate" "--slurp" (format "repos/%s/issues/%d/timeline" repo number))
  :parse (lambda (pages) (octocat--table "events" (apply #'vconcat (append pages nil)))))

(defconst octocat-model-pending "octocatPending"
  "Key of what is being done to a comment, or to an item's opening post.
Only the edits of a pending mutation set it, so it is never stored.")

(defun octocat-model-detail-spec (kind repo number)
  "Return the spec of the page resource of issue or PR (KIND) NUMBER of REPO."
  (list (octocat-model--item-type kind) repo number))

(defun octocat-model--detail-edit (kind repo number fn)
  "Return the :edits of the page resource of issue or PR (KIND) NUMBER of REPO.
FN gets its data and returns it changed."
  (list (cons (octocat-model-detail-spec kind repo number) fn)))

;; The login a comment being posted shows as its author.
(octocat-sync-define-resource viewer ()
  :max-age 86400
  :gh (list "api" "user")
  :parse (lambda (user) (octocat--table "login" (gethash "login" user))))

(defun octocat-model--pending-comment (body login now)
  "Return the comment of BODY being posted by LOGIN (or nil) at NOW.
NOW is an ISO 8601 time.  It has no id or URL until GitHub answers."
  (octocat--table "author" (and login (octocat--table "login" login))
                  "body" body
                  "createdAt" now
                  "viewerDidAuthor" t
                  octocat-model-pending "posting…"))

(defun octocat-model--rest-comment (comment)
  "Return COMMENT, from GitHub's REST API, in the fields `gh ... view' gives."
  (octocat--table "id" (octocat--get comment "node_id")
                  "author" (octocat--table "login" (octocat--get comment "user" "login"))
                  "authorAssociation" (octocat--get comment "author_association")
                  "body" (or (octocat--get comment "body") "")
                  "createdAt" (octocat--get comment "created_at")
                  "url" (octocat--get comment "html_url")
                  "viewerDidAuthor" t))

(defun octocat-model--put-comment (data comment)
  "Return DATA, a page resource's body, with COMMENT added to its comments.
A comment of the same id, as a refetch may already have, is replaced."
  (let* ((id       (gethash "id" comment))
         (comments (append (gethash "comments" data) nil))
         (old      (and id (seq-find (lambda (c) (equal (gethash "id" c) id)) comments))))
    (puthash "comments"
             (vconcat (if old
                          (mapcar (lambda (c) (if (eq c old) comment c)) comments)
                        (append comments (list comment))))
             data)
    data))

(defun octocat-model--set-comment-body (data comment-id body pending)
  "Return DATA, a page resource's body, with comment COMMENT-ID's BODY set.
COMMENT-ID is the numeric REST id.  PENDING, if non-nil, is shown as
what is being done to it, such as \"saving…\"."
  (puthash "comments"
           (cl-map 'vector
                   (lambda (c)
                     (if (not (equal (octocat--comment-numeric-id c) comment-id))
                         c
                       (let ((c (copy-hash-table c)))
                         (puthash "body" body c)
                         (when pending (puthash octocat-model-pending pending c))
                         c)))
                   (gethash "comments" data))
           data)
  data)

(octocat-sync-define-mutation set-state (kind verb repo number)
  :label (format "%s %s…" (if (equal verb "close") "Closing" "Reopening")
                 (if (equal kind "pr") "pull request" "issue"))
  :resources (list (octocat-model-detail-spec kind repo number))
  :optimistic `((,(octocat-model-item-key kind repo number)
                 ("state" . ,(if (equal verb "close") "CLOSED" "OPEN"))))
  :gh (list kind verb (number-to-string number) "--repo" repo)
  ;; The lists it moves in or out of, their counts, and the new event.
  :invalidates `((timeline-events ,repo ,number) ,@(octocat-model--item-lists kind repo)))

(octocat-sync-define-mutation set-title (kind repo number title)
  :label "Renaming…"
  :resources (list (octocat-model-detail-spec kind repo number))
  :optimistic `((,(octocat-model-item-key kind repo number) ("title" . ,title)))
  :gh (list kind "edit" (number-to-string number) "--repo" repo "--title" title)
  ;; It adds a "changed the title" event.
  :invalidates `((timeline-events ,repo ,number)))

(octocat-sync-define-mutation comment (kind repo number body)
  :label "Posting comment…"
  :slot 'inline
  ;; GitHub answers with the comment, which takes the place of the one
  ;; shown, so it is never gone in between.
  :edits (lambda (answered answer)
           (let ((comment
                  (if answered
                      (octocat-model--rest-comment answer)
                    (octocat-model--pending-comment
                     body
                     (octocat--get (plist-get (octocat-sync-read '(viewer)) :data) "login")
                     (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))))
             (octocat-model--detail-edit
              kind repo number (lambda (data) (octocat-model--put-comment data comment)))))
  :gh (list "api" (format "repos/%s/issues/%d/comments" repo number) "-f" (concat "body=" body))
  :parse #'identity
  ;; The comment count, on the entity.
  :invalidates (list (octocat-model-detail-spec kind repo number)))

(octocat-sync-define-mutation edit-body (kind repo number body)
  :label "Saving description…"
  :slot 'inline
  :optimistic `((,(octocat-model-item-key kind repo number) ("body" . ,body)))
  ;; Only the spinner: the body is the entity's.
  :edits (lambda (answered _)
           (unless answered
             (octocat-model--detail-edit
              kind repo number (lambda (data)
                                 (puthash octocat-model-pending "saving…" data)
                                 data))))
  :gh (list kind "edit" (number-to-string number) "--repo" repo "--body" body))

(octocat-sync-define-mutation edit-comment (kind repo number comment-id body)
  :label "Saving comment…"
  :slot 'inline
  :edits (lambda (answered _)
           (octocat-model--detail-edit
            kind repo number (lambda (data)
                               (octocat-model--set-comment-body
                                data comment-id body (unless answered "saving…")))))
  :gh (list "api" (format "repos/%s/issues/comments/%s" repo comment-id)
            "--method" "PATCH" "-f" (format "body=%s" body)))

(octocat-sync-define-mutation edit-values (kind repo number flag add remove)
  :label (format "Saving %ss…" flag)
  :resources (list (octocat-model-detail-spec kind repo number))
  :gh (append (list kind "edit" (number-to-string number) "--repo" repo)
              (and add (list (concat "--add-" flag) (string-join add ",")))
              (and remove (list (concat "--remove-" flag) (string-join remove ","))))
  :invalidates `(,(octocat-model-detail-spec kind repo number)
                 (timeline-events ,repo ,number)
                 (list-items ,(octocat-model--list-kind kind) ,repo _ _)))

;; Kept long: only you change them, and `react' keeps them up to date.
(octocat-sync-define-resource viewer-reactions (subject)
  :max-age 3600
  ;; Not `gh ... view': it leaves out whose they are.
  :graphql (concat "query($id:ID!){node(id:$id){"
                   "...on Reactable{reactionGroups{content viewerHasReacted}}}}")
  :vars `(("id" . ,subject))
  :parse (lambda (data)
           (octocat--table
            "given" (vconcat (delq nil (mapcar (lambda (g)
                                                 (and (eq (gethash "viewerHasReacted" g) t)
                                                      (gethash "content" g)))
                                               (octocat--get data "node" "reactionGroups")))))))

(defun octocat-model--react-comment (data subject content add)
  "Return DATA, a page resource's body, with one CONTENT more on comment SUBJECT.
SUBJECT is the comment's node id; ADD nil takes one away instead."
  (puthash "comments"
           (cl-map 'vector
                   (lambda (c)
                     (if (not (equal (gethash "id" c) subject))
                         c
                       (let ((c (copy-hash-table c)))
                         (puthash "reactionGroups"
                                  (octocat--toggle-reaction (gethash "reactionGroups" c)
                                                            content add)
                                  c)
                         c)))
                   (gethash "comments" data))
           data)
  data)

(octocat-sync-define-mutation react (kind repo number subject content add)
  :label (if add "Reacting…" "Taking reaction back…")
  ;; The changed count is all a page shows of it.
  :slot 'reaction
  :optimistic (let ((item (octocat-model-detail-read
                           (octocat-model-detail-spec kind repo number))))
                (when (equal (octocat--get item "id") subject)
                  `((,(octocat-model-item-key kind repo number)
                     ("reactionGroups" . ,(octocat--toggle-reaction
                                           (gethash "reactionGroups" item) content add))))))
  :edits (lambda (_answered _)
           (list (cons (octocat-model-detail-spec kind repo number)
                       (lambda (data) (octocat-model--react-comment data subject content add)))
                 (cons `(viewer-reactions ,subject)
                       (lambda (data)
                         (let ((given (remove content (append (gethash "given" data) nil))))
                           (puthash "given" (vconcat (if add (cons content given) given)) data)
                           data)))))
  :graphql (format (concat "mutation($id:ID!,$content:ReactionContent!){"
                           "%s(input:{subjectId:$id,content:$content}){clientMutationId}}")
                   (if add "addReaction" "removeReaction"))
  :vars `(("id" . ,subject) ("content" . ,content)))

;;;; Issues

(defun octocat-model--issue-parse-created (output)
  "Return the number of the issue whose URL `gh issue create' printed in OUTPUT."
  (if (string-match "/issues/\\([0-9]+\\)" output)
      (string-to-number (match-string 1 output))
    (error "No issue URL in: %s" (string-trim output))))

(octocat-sync-define-mutation create-issue (repo title body)
  :label "Creating issue…"
  :gh (list "issue" "create" "--repo" repo "--title" title "--body" body)
  :raw t
  :parse #'octocat-model--issue-parse-created
  :invalidates (octocat-model--item-lists 'issue repo))

(octocat-sync-define-resource issue (repo number)
  :entity (octocat-model-item-key 'issue repo number)
  :invalidates (octocat-model--item-lists 'issue repo)
  :gh (list "issue" "view" (number-to-string number) "--repo" repo
            "--json" (concat "id,number,title,author,state,body,"
                             "createdAt,closedAt,"
                             "labels,comments,url,assignees,milestone,reactionGroups,"
                             "closedByPullRequestsReferences"))
  :parse (lambda (item)
           (octocat-model-detail item '("comments")
                                 (lambda (f) (octocat-model-item 'issue repo f)))))

;;;; Pull requests

(defconst octocat-model-pr-merge-methods
  '(("Merge"  "--merge"  "mergeCommitAllowed")
    ("Squash" "--squash" "squashMergeAllowed")
    ("Rebase" "--rebase" "rebaseMergeAllowed"))
  "Merge methods: name, `gh pr merge' flag, and the repo field allowing it.")

(defun octocat-model--pr-merge-args (repo number method text delete)
  "Return the `gh' arguments merging PR NUMBER of REPO by METHOD.
TEXT is the commit message, its first line the subject; a rebase has
none.  DELETE non-nil deletes the head branch as well."
  (let ((lines (split-string text "\n")))
    (append (list "pr" "merge" (number-to-string number) "--repo" repo
                  (nth 1 (assoc method octocat-model-pr-merge-methods)))
            (unless (equal method "Rebase")
              (list "--subject" (car lines)
                    "--body" (string-trim (mapconcat #'identity (cdr lines) "\n"))))
            (and delete (list "--delete-branch")))))

(octocat-sync-define-mutation merge-pr (repo number method text delete)
  :label "Merging pull request…"
  :slot 'merge
  :resources `((pr ,repo ,number))
  :gh (octocat-model--pr-merge-args repo number method text delete)
  :invalidates `((pr ,repo ,number) (timeline-events ,repo ,number)
                 ,@(octocat-model--item-lists 'pr repo)))

(octocat-sync-define-mutation approve-runs (repo number ids)
  :label "Approving workflows…"
  :slot 'approve
  :resources `((pr ,repo ,number))
  ;; One request per run; a failure is reported once all were tried.
  :send (lambda (done)
          (let (failed)
            (cl-labels ((next (ids)
                          (if (null ids)
                              (funcall done (and failed (cons 'error failed)))
                            (octocat--run-gh "approve-run"
                                             (list "api" "--method" "POST"
                                                   (format "repos/%s/actions/runs/%s/approve"
                                                           repo (car ids)))
                                             #'ignore
                                             (lambda (result)
                                               (when (eq (car-safe result) 'error)
                                                 (setq failed (cdr result)))
                                               (next (cdr ids)))))))
              (next ids))))
  :invalidates `((pr ,repo ,number) (awaiting-runs ,repo _)))

(octocat-sync-define-mutation set-draft (repo number draft)
  :label (if draft "Converting to draft…" "Marking ready for review…")
  :slot 'merge
  :resources `((pr ,repo ,number))
  :optimistic `((,(octocat-model-item-key 'pr repo number) ("isDraft" . ,(if draft t :false))))
  :gh (append (list "pr" "ready" (number-to-string number) "--repo" repo)
              (and draft (list "--undo")))
  ;; It adds an event, and may change what the merge box allows.
  :invalidates `((pr ,repo ,number) (timeline-events ,repo ,number)))


(defconst octocat-model--pr-parts
  '("comments" "reviews" "latestReviews" "reviewRequests" "commits" "statusCheckRollup")
  "The fields of a PR page's data kept with its resource, not its entity.
Pages of connections, and what belongs to the head commit, which the
lists do not share.")

(octocat-sync-define-resource pr (repo number)
  :entity (octocat-model-item-key 'pr repo number)
  :invalidates (octocat-model--item-lists 'pr repo)
  :gh (list "pr" "view" (number-to-string number) "--repo" repo
            "--json" (concat "id,number,title,author,state,body,"
                             "createdAt,mergedAt,closedAt,"
                             "baseRefName,headRefName,headRepositoryOwner,"
                             "isDraft,mergeable,mergeStateStatus,"
                             "changedFiles,"
                             "labels,reviewDecision,reviews,"
                             "comments,statusCheckRollup,url,commits,"
                             "assignees,milestone,latestReviews,reactionGroups,"
                             "reviewRequests,closingIssuesReferences"))
  :parse (lambda (item)
           (octocat-model-detail item octocat-model--pr-parts
                                 (lambda (f) (octocat-model-item 'pr repo f)))))

;; The runs of commit SHA awaiting approval.
(octocat-sync-define-resource awaiting-runs (repo sha)
  ;; No SHA, no runs: a page asks before it knows it.
  :fetch (and (null sha) (lambda (done) (funcall done [])))
  :gh (list "api" (format (concat "repos/%s/actions/runs?head_sha=%s"
                                  "&status=action_required&per_page=100")
                          repo sha))
  :parse (lambda (r) (or (gethash "workflow_runs" r) [])))

(defconst octocat-model--pr-stack-query
  (concat "query($owner:String!,$name:String!,$number:Int!){"
          "repository(owner:$owner,name:$name){pullRequest(number:$number){"
          ;; A stack holds at most 100 pull requests.
          "stack{number baseRefName entries(first:100){nodes{position "
          "pullRequest{number title state isDraft mergeable}}}}}}}")
  "GraphQL query for the stack a pull request is in.")

(defun octocat-model--pr-parse-stack (data)
  "Return the stack in DATA, the answer to `octocat-model--pr-stack-query'.
A hash-table whose \"stack\" is the stack, or :null when the pull request
is in none."
  (octocat--table "stack" (or (octocat--get data "repository" "pullRequest" "stack")
                              :null)))

(octocat-sync-define-resource pr-stack (repo number)
  :graphql octocat-model--pr-stack-query
  :repo repo
  :vars `(("number" . ,number))
  :parse #'octocat-model--pr-parse-stack)

(octocat-sync-define-resource pr-merges (repo number)
  ;; Not `gh pr view': it gives no commit's parents.
  :graphql (concat "query($owner:String!,$name:String!,$number:Int!){"
                   "repository(owner:$owner,name:$name){pullRequest(number:$number){"
                   ;; The last 100: a longer PR's first commits show as plain ones.
                   "commits(last:100){nodes{commit{oid parents{totalCount}}}}}}}")
  :repo repo
  :vars `(("number" . ,number))
  :parse (lambda (data)
           (vconcat
            (cl-loop for node across (or (octocat--get data "repository" "pullRequest"
                                                       "commits" "nodes")
                                         [])
                     for commit = (gethash "commit" node)
                     when (> (or (octocat--get commit "parents" "totalCount") 0) 1)
                     collect (gethash "oid" commit)))))

;; Newest first.
(octocat-sync-define-resource repo-stacks (repo)
  :gh (list "api" (format "repos/%s/stacks?per_page=100" repo))
  :parse (lambda (stacks) (octocat--table "stacks" stacks)))

;;;; Reviews

;; A vector of files as the commits API has them: `gh api' joins the
;; pages into one array.  GitHub lists at most 3000.
(octocat-sync-define-resource pr-files (repo number)
  :gh (list "api" "--paginate" (format "repos/%s/pulls/%d/files?per_page=100" repo number)))

(defconst octocat-model--review-comment-fields
  (concat "id databaseId body createdAt state viewerDidAuthor viewerCanUpdate "
          "viewerCanDelete author{login} replyTo{databaseId} "
          "reactionGroups{content users{totalCount}}")
  "The fields of a review comment read from GraphQL.")

(defconst octocat-model--review-thread-fields
  (concat "id isResolved isOutdated path line startLine diffSide startDiffSide "
          "subjectType viewerCanReply viewerCanResolve viewerCanUnresolve "
          "resolvedBy{login} comments(first:100){nodes{"
          octocat-model--review-comment-fields "}}")
  "The fields of a review thread read from GraphQL.")

(defconst octocat-model--review-threads-query
  (concat "query($owner:String!,$name:String!,$number:Int!,$endCursor:String){"
          "repository(owner:$owner,name:$name){pullRequest(number:$number){"
          "id headRefOid reviews(states:PENDING,first:1){nodes{id commit{oid}}} "
          "reviewThreads(first:50,after:$endCursor){nodes{"
          octocat-model--review-thread-fields
          "} pageInfo{hasNextPage endCursor}}}}}")
  "GraphQL query for a PR's review threads and your pending review.")

(defun octocat-model--review-parse-threads (output)
  "Return the review threads of OUTPUT, `gh api --paginate --slurp's pages.
That is a table of the PR's \"id\", its \"head\" commit, the
\"threads\" of all pages, and \"pending\", your pending review, a table
of its \"id\" and \"commit\", or nil."
  (let* ((pages (append (json-parse-string output) nil))
         (pr    (octocat--get (car pages) "data" "repository" "pullRequest"))
         (review (car (append (octocat--get pr "reviews" "nodes") nil))))
    (octocat--table "id" (gethash "id" pr)
                    "head" (gethash "headRefOid" pr)
                    "pending" (and review (octocat-model--review review))
                    "threads" (apply #'vconcat
                                     (mapcar (lambda (p)
                                               (octocat--get p "data" "repository" "pullRequest"
                                                             "reviewThreads" "nodes"))
                                             pages)))))

(defun octocat-model--review (node)
  "Return the pending review NODE, from GraphQL, as a table of id and commit."
  (octocat--table "id" (gethash "id" node) "commit" (octocat--get node "commit" "oid")))

(octocat-sync-define-resource pr-review-threads (repo number)
  :graphql octocat-model--review-threads-query
  :repo repo
  :vars `(("number" . ,number))
  ;; The pages, slurped into an array, not one answer.
  :args '("--paginate" "--slurp")
  :raw t
  :parse #'octocat-model--review-parse-threads)

;; Each change to a comment is a mutation whose edits of the
;; `pr-review-threads' show it at once, and write GitHub's answer.  The
;; threads are not refetched after a deletion: GitHub may still return
;; what was deleted for a moment.

(defun octocat-model--review-graphql (name query vars parse done)
  "Run GraphQL QUERY as `gh' call NAME with VARS, an alist; call DONE.
A string value is passed as a string, a number as a number, and a nil
one not at all.  PARSE gets the answer's \"data\"."
  (octocat--gh-graphql name nil query vars
                       (lambda (output) (funcall parse (gethash "data" (json-parse-string output))))
                       done))

(defun octocat-model--with-review (pr-id review-id commit k)
  "Call K with REVIEW-ID, or the id of a pending review started at COMMIT.
PR-ID is the PR's node id.  K is called with (error . MESSAGE) instead
when the review cannot be started."
  (if review-id
      (funcall k review-id)
    (octocat-model--review-graphql
     "review-start"
     (concat "mutation($pr:ID!,$commit:GitObjectID){addPullRequestReview("
             "input:{pullRequestId:$pr,commitOID:$commit}){pullRequestReview{id commit{oid}}}}")
     `(("pr" . ,pr-id) ("commit" . ,commit))
     (lambda (data) (octocat--get data "addPullRequestReview" "pullRequestReview"))
     (lambda (review)
       (funcall k (if (eq (car-safe review) 'error) review (gethash "id" review)))))))

(defun octocat-model--review-draft (body login)
  "Return a draft comment of BODY by LOGIN, shown until GitHub answers."
  (octocat--table "author" (octocat--table "login" login)
                  "body" body
                  "createdAt" (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                  "state" "PENDING"
                  "viewerCanUpdate" t))

(defun octocat-model--review-map-threads (data fn)
  "Return DATA, the `pr-review-threads', its threads replaced by FN's.
FN gets each thread and returns it, changed, or nil to drop it."
  (when data
    (puthash "threads" (vconcat (delq nil (mapcar fn (append (gethash "threads" data) nil))))
             data))
  data)

(defun octocat-model--review-map-comments (data fn)
  "Return DATA, the `pr-review-threads', each comment replaced by FN's.
FN gets each comment and returns it, changed, or nil to drop it; a
thread left with no comment is dropped."
  (octocat-model--review-map-threads
   data
   (lambda (thread)
     (let* ((thread (copy-hash-table thread))
            (conn   (copy-hash-table (gethash "comments" thread)))
            (nodes  (delq nil (mapcar fn (append (gethash "nodes" conn) nil)))))
       (puthash "nodes" (vconcat nodes) conn)
       (puthash "comments" conn thread)
       (and nodes thread)))))

(defun octocat-model--review-set-pending (data review)
  "Return DATA, the `pr-review-threads', with REVIEW as the pending one."
  (when data (puthash "pending" review data))
  data)

(defun octocat-model--review-new-thread (range comment)
  "Return a thread on RANGE, see `octocat-diff--range', holding COMMENT."
  (octocat--table "comments" (octocat--table "nodes" (vector comment))
                  "path" (plist-get range :path)
                  "line" (plist-get range :line)
                  "diffSide" (plist-get range :side)
                  "startLine" (plist-get range :start-line)
                  "startDiffSide" (plist-get range :start-side)
                  "subjectType" (if (plist-get range :file) "FILE" "LINE")))

(defun octocat-model-review-threads-spec (repo number)
  "Return the spec of the review threads of PR NUMBER of REPO."
  `(pr-review-threads ,repo ,number))

(defun octocat-model--threads-edit (repo number fn)
  "Return the :edits of the review threads of PR NUMBER of REPO.
FN gets their data and returns it changed."
  (list (cons (octocat-model-review-threads-spec repo number) fn)))

(octocat-sync-define-mutation review-draft-add (repo number pr-id review-id commit range body login)
  :label "Saving draft…"
  :slot 'inline
  ;; GitHub answers with the pending review's id and the new thread.
  :edits (lambda (answered answer)
           (octocat-model--threads-edit
            repo number
            (lambda (data)
              (when (and answered (not review-id))
                (octocat-model--review-set-pending
                 data (octocat--table "id" (car answer) "commit" commit)))
              (let ((thread (if answered
                                (cdr answer)
                              (octocat-model--review-new-thread
                               range (octocat-model--review-draft body login)))))
                (when data
                  (puthash "threads" (vconcat (gethash "threads" data) (vector thread)) data)))
              data)))
  :send (lambda (done)
          (octocat-model--with-review
           pr-id review-id commit
           (lambda (review)
             (if (eq (car-safe review) 'error)
                 (funcall done review)
               (octocat-model--review-graphql
                "review-draft-add"
                (concat "mutation($review:ID!,$path:String!,$body:String!,$line:Int,"
                        "$side:DiffSide,$startLine:Int,$startSide:DiffSide,"
                        "$subject:PullRequestReviewThreadSubjectType){"
                        "addPullRequestReviewThread(input:{pullRequestReviewId:$review,"
                        "path:$path,body:$body,line:$line,side:$side,startLine:$startLine,"
                        "startSide:$startSide,subjectType:$subject}){thread{"
                        octocat-model--review-thread-fields "}}}")
                `(("review" . ,review) ("path" . ,(plist-get range :path)) ("body" . ,body)
                  ("line" . ,(plist-get range :line)) ("side" . ,(plist-get range :side))
                  ("startLine" . ,(plist-get range :start-line))
                  ("startSide" . ,(plist-get range :start-side))
                  ("subject" . ,(if (plist-get range :file) "FILE" "LINE")))
                (lambda (data)
                  (cons review (octocat--get data "addPullRequestReviewThread" "thread")))
                done))))))

(defun octocat-model--review-add-reply (data thread-id comment)
  "Return DATA, the `pr-review-threads', with COMMENT ending thread THREAD-ID."
  (octocat-model--review-map-threads
   data
   (lambda (thread)
     (if (not (equal (gethash "id" thread) thread-id))
         thread
       (let ((thread (copy-hash-table thread))
             (conn   (copy-hash-table (gethash "comments" thread))))
         (puthash "nodes" (vconcat (gethash "nodes" conn) (vector comment)) conn)
         (puthash "comments" conn thread)
         thread)))))

(octocat-sync-define-mutation review-draft-reply
    (repo number pr-id review-id commit thread-id body login)
  :label "Saving draft…"
  :slot 'inline
  :edits (lambda (answered answer)
           (octocat-model--threads-edit
            repo number
            (lambda (data)
              (when (and answered (not review-id))
                (octocat-model--review-set-pending
                 data (octocat--table "id" (car answer) "commit" commit)))
              (octocat-model--review-add-reply
               data thread-id
               (if answered (cdr answer) (octocat-model--review-draft body login))))))
  :send (lambda (done)
          (octocat-model--with-review
           pr-id review-id commit
           (lambda (review)
             (if (eq (car-safe review) 'error)
                 (funcall done review)
               (octocat-model--review-graphql
                "review-draft-reply"
                (concat "mutation($review:ID!,$thread:ID!,$body:String!){"
                        "addPullRequestReviewThreadReply(input:{pullRequestReviewId:$review,"
                        "pullRequestReviewThreadId:$thread,body:$body}){comment{"
                        octocat-model--review-comment-fields "}}}")
                `(("review" . ,review) ("thread" . ,thread-id) ("body" . ,body))
                (lambda (data)
                  (cons review (octocat--get data "addPullRequestReviewThreadReply" "comment")))
                done))))))

(octocat-sync-define-mutation review-reply-now (repo number thread-id comment-id body login)
  :label "Posting reply…"
  :slot 'inline
  :edits (lambda (answered _)
           (unless answered
             (let ((c (octocat-model--review-draft body login)))
               (puthash "state" "SUBMITTED" c)
               (octocat-model--threads-edit
                repo number (lambda (data) (octocat-model--review-add-reply data thread-id c))))))
  :gh (list "api" (format "repos/%s/pulls/%d/comments/%d/replies" repo number comment-id)
            "-f" (concat "body=" body))
  :invalidates (list (octocat-model-review-threads-spec repo number)))

(octocat-sync-define-mutation review-comment-edit (repo number node-id body)
  :label "Saving comment…"
  :slot 'inline
  :edits (lambda (_answered _)
           (octocat-model--threads-edit
            repo number
            (lambda (data)
              (octocat-model--review-map-comments
               data (lambda (c)
                      (if (not (equal (gethash "id" c) node-id))
                          c
                        (let ((c (copy-hash-table c)))
                          (puthash "body" body c)
                          c)))))))
  :graphql (concat "mutation($id:ID!,$body:String!){updatePullRequestReviewComment("
                   "input:{pullRequestReviewCommentId:$id,body:$body}){"
                   "pullRequestReviewComment{id}}}")
  :vars `(("id" . ,node-id) ("body" . ,body)))

(octocat-sync-define-mutation review-comment-delete (repo number node-id)
  :label "Deleting comment…"
  :slot 'inline
  :edits (lambda (_answered _)
           (octocat-model--threads-edit
            repo number
            (lambda (data)
              (octocat-model--review-map-comments
               data (lambda (c) (unless (equal (gethash "id" c) node-id) c))))))
  :graphql (concat "mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){"
                   "clientMutationId}}")
  :vars `(("id" . ,node-id)))

(octocat-sync-define-mutation review-thread-resolve (repo number thread-id resolve)
  :label (if resolve "Resolving…" "Unresolving…")
  :slot 'inline
  :edits (lambda (answered answer)
           (octocat-model--threads-edit
            repo number
            (lambda (data)
              (octocat-model--review-map-threads
               data (lambda (thread)
                      (cond ((not (equal (gethash "id" thread) thread-id)) thread)
                            (answered answer)
                            (t (let ((thread (copy-hash-table thread)))
                                 (puthash "isResolved" (and resolve t) thread)
                                 thread))))))))
  :send (lambda (done)
          (let ((field (if resolve "resolveReviewThread" "unresolveReviewThread")))
            (octocat-model--review-graphql
             "review-thread-resolve"
             (format "mutation($id:ID!){%s(input:{threadId:$id}){thread{%s}}}"
                     field octocat-model--review-thread-fields)
             `(("id" . ,thread-id))
             (lambda (data) (octocat--get data field "thread"))
             done))))

(defun octocat-model--review-drop-drafts (data)
  "Return DATA, the `pr-review-threads', without drafts or a pending review."
  (octocat-model--review-set-pending
   (octocat-model--review-map-comments
    data (lambda (c) (unless (equal (gethash "state" c) "PENDING") c)))
   nil))

(octocat-sync-define-mutation review-discard (repo number review-id)
  :label "Discarding review…"
  :slot 'inline
  :edits (lambda (_answered _)
           (octocat-model--threads-edit repo number #'octocat-model--review-drop-drafts))
  :graphql (concat "mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){"
                   "clientMutationId}}")
  :vars `(("id" . ,review-id)))

(defconst octocat-model-review-events
  '(("Comment"         "--comment"         "COMMENT")
    ("Approve"         "--approve"         "APPROVE")
    ("Request changes" "--request-changes" "REQUEST_CHANGES"))
  "Review events offered on submit: their `gh pr review' flag and GraphQL event.")

(defun octocat-model--review-args (repo number flag body)
  "Return the `gh' arguments submitting a FLAG review of PR NUMBER of REPO.
An empty BODY is left out, as `gh' rejects an empty --body."
  (append (list "pr" "review" (number-to-string number) "--repo" repo flag)
          (unless (string-empty-p body) (list "--body" body))))

(octocat-sync-define-mutation review-pr (repo number flag body &optional review-id)
  :label "Submitting review…"
  :slot 'review
  :resources `((pr ,repo ,number) ,(octocat-model-review-threads-spec repo number))
  ;; The drafts are no longer drafts.
  :edits (lambda (_answered _)
           (when review-id
             (octocat-model--threads-edit
              repo number
              (lambda (data)
                (octocat-model--review-set-pending
                 (octocat-model--review-map-comments
                  data (lambda (c)
                         (if (not (equal (gethash "state" c) "PENDING"))
                             c
                           (let ((c (copy-hash-table c)))
                             (puthash "state" "SUBMITTED" c)
                             c))))
                 nil)))))
  ;; `gh pr review' fails while you have a pending review: it is
  ;; submitted through GraphQL instead.
  :send (lambda (done)
          (if review-id
              (octocat-model--review-graphql
               "review"
               (concat "mutation($id:ID!,$event:PullRequestReviewEvent!,$body:String){"
                       "submitPullRequestReview(input:{pullRequestReviewId:$id,event:$event,"
                       "body:$body}){clientMutationId}}")
               `(("id" . ,review-id)
                 ("event" . ,(nth 2 (seq-find (lambda (e) (equal (cadr e) flag))
                                              octocat-model-review-events)))
                 ("body" . ,(and (not (string-empty-p body)) body)))
               #'ignore done)
            (octocat--run-gh "review" (octocat-model--review-args repo number flag body)
                             #'ignore done)))
  ;; The review joins the timeline, may add review comments and may
  ;; change the merge box.
  :invalidates `((pr ,repo ,number) (timeline-events ,repo ,number)
                 ,(octocat-model-review-threads-spec repo number)))

;;;; Commits and compares

(octocat-sync-define-resource commit (repo sha)
  ;; What a SHA names never changes.
  :max-age octocat-model--fixed-max-age
  :gh (list "api" (format "repos/%s/commits/%s" repo sha)))

;; General comments, whose "path" is :null, and inline ones, on a
;; "path" and "line".
(octocat-sync-define-resource commit-comments (repo sha)
  :gh (list "api" (format "repos/%s/commits/%s/comments" repo sha)))

;; Not REST: it has no way to ask whether a branch holds a commit.
(defconst octocat-model--commit-branch-query
  (concat "query($owner:String!,$name:String!,$sha:String!){repository(owner:$owner,"
          "name:$name){defaultBranchRef{name compare(headRef:$sha){status}}}}")
  "GraphQL query behind the `commit-branch' resource.")

(defun octocat-model--commit-parse-branch (data)
  "Return the branch in DATA, the answer to `octocat-model--commit-branch-query'.
A hash-table whose \"name\" is the default branch when it holds the
commit, the commit being behind it or at its head, else :null."
  (let ((ref (octocat--get data "repository" "defaultBranchRef")))
    (octocat--table "name" (if (member (octocat--get ref "compare" "status")
                                       '("BEHIND" "IDENTICAL"))
                               (gethash "name" ref)
                             :null))))

(octocat-sync-define-resource commit-branch (repo sha)
  :poll octocat-sync-poll-slow
  :graphql octocat-model--commit-branch-query
  :repo repo
  :vars `(("sha" . ,sha))
  :parse #'octocat-model--commit-parse-branch)

(defun octocat-model-compare-sha-p (ref)
  "Return non-nil when REF is a commit SHA, as a commit link's is.
Unlike a branch or tag, it names the same commit for good."
  (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" ref))

(octocat-sync-define-resource compare (repo base head)
  ;; Comparing two commits never changes, as a commit doesn't; refs move.
  :max-age (and (octocat-model-compare-sha-p base)
                (octocat-model-compare-sha-p head)
                octocat-model--fixed-max-age)
  :gh (list "api" (format "repos/%s/compare/%s...%s" repo base head)))

;;;; Repository code

(defcustom octocat-repo-commits-page-size 25
  "Number of commits the commits page shows, and loads, at a time."
  :type 'integer
  :group 'octocat)

(defconst octocat-model--repo-history-query
  (concat "query($owner:String!,$name:String!,$ref:String!,$limit:Int!,$after:String,"
          "$path:String){repository(owner:$owner,name:$name){object(expression:$ref){...on "
          "Commit{history(first:$limit,after:$after,path:$path){totalCount edges{cursor "
          "node{oid messageHeadline authoredDate committedDate author{name email user{"
          "login}} parents(first:2){nodes{oid}}}}}}}}}")
  "GraphQL query behind `octocat-model-repo-list-commits'.
Only what a row shows: the REST commits endpoint sends ~15 times as much.")

(defun octocat-model-repo-list-commits (repo ref path callback &optional after)
  "Fetch a page of the commits of REPO, from REF back.
REF is a branch or SHA; nil means the head of the default branch.  PATH,
when non-nil, keeps only the commits that touched it.
AFTER, a commit's \"cursor\", fetches the page after that commit.  A
page holds `octocat-repo-commits-page-size' commits.  Calls CALLBACK with
a list of commits from `octocat-model--repo-parse-history', or a cons
\\=(error . MSG)."
  (octocat--gh-graphql "commits" repo octocat-model--repo-history-query
                       `(("ref" . ,(or ref "HEAD"))
                         ("limit" . ,octocat-repo-commits-page-size)
                         ("after" . ,after)
                         ("path" . ,path))
                       #'octocat-model--repo-parse-history callback))

(defun octocat-model--repo-history-commit (node)
  "Return the commit NODE of a GraphQL history shaped as REST has it.
That is what the rows read: \"sha\"; \"commit\", with the \"message\"
\(its headline only), the git \"author\" (name, email, date) and the
\"committer\" (date); \"author\", the GitHub user or :null; and, when
NODE has them, the SHAs of its \"parents\", for the graph beside it."
  (let* ((a      (gethash "author" node))
         (user   (and (hash-table-p a) (gethash "user" a)))
         (git    (octocat--table "date" (gethash "authoredDate" node)))
         (commit (octocat--table
                  "sha" (gethash "oid" node)
                  "commit" (octocat--table
                            "message" (gethash "messageHeadline" node)
                            "author" git
                            "committer" (octocat--table "date" (gethash "committedDate" node)))
                  "author" (if (hash-table-p user) user :null))))
    (when (hash-table-p a)
      (puthash "name" (gethash "name" a) git)
      (puthash "email" (gethash "email" a) git))
    (when-let* ((parents (gethash "parents" node)))
      (puthash "parents" (vconcat (mapcar (lambda (p) (gethash "oid" p))
                                          (gethash "nodes" parents)))
               commit))
    commit))

(defun octocat-model--repo-parse-history (json-string)
  "Parse the commit history response JSON-STRING into a list of commits.
Each is shaped by `octocat-model--repo-history-commit', with its \"cursor\",
for the page after it, and \"total\", the commits of the whole history."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (obj  (and (hash-table-p repo) (gethash "object" repo))))
    (unless (hash-table-p obj)
      (error "No such branch or commit"))
    (let ((history (gethash "history" obj)))
      (mapcar (lambda (edge)
                (let ((commit (octocat-model--repo-history-commit (gethash "node" edge))))
                  (puthash "cursor" (gethash "cursor" edge) commit)
                  (puthash "total" (gethash "totalCount" history) commit)
                  commit))
              (gethash "edges" history)))))

(defconst octocat-model--repo-head-query
  (concat "query($owner:String!,$name:String!,$expr:String!,$dir:String!,$path:String){"
          "repository(owner:$owner,name:$name){object(expression:$expr){...on Commit{"
          "history(first:1,path:$path){totalCount nodes{oid messageHeadline authoredDate "
          "committedDate author{name email user{login}}}}}} dir:object(expression:$dir){"
          "__typename oid ...on Blob{byteSize isBinary}}}}")
  "GraphQL query behind the `repo-head' resource.")

(defun octocat-model--repo-parse-head (data ref path)
  "Return the head in DATA, the answer to `octocat-model--repo-head-query'.
It is for PATH, nil for the root, at REF.  Return the last commit that
touched PATH, as `octocat-model--repo-history-commit' shapes it, with
\"tree\", the SHA of PATH's tree, or its blob's when \"kind\" is
\"blob\", and \"total\", the commits that touched PATH.  Of a blob,
\"size\" is its bytes and \"binary\" t when it is not text."
  (let* ((repo   (gethash "repository" data))
         (obj    (and (hash-table-p repo) (gethash "object" repo)))
         (dir    (and (hash-table-p repo) (gethash "dir" repo)))
         (hist   (and (hash-table-p obj) (gethash "history" obj)))
         (nodes  (and hist (gethash "nodes" hist)))
         (node   (and (> (length nodes) 0) (aref nodes 0))))
    (unless (hash-table-p obj)
      (error "No branch, tag or commit %s" (or ref "HEAD")))
    (unless (and (hash-table-p dir) (hash-table-p node))
      (error "No %s at %s" path (or ref "HEAD")))
    (let ((commit (octocat-model--repo-history-commit node)))
      (puthash "tree" (gethash "oid" dir) commit)
      (puthash "kind" (if (equal (gethash "__typename" dir) "Blob") "blob" "tree") commit)
      (puthash "total" (gethash "totalCount" hist) commit)
      (puthash "size" (gethash "byteSize" dir) commit)
      (puthash "binary" (eq (gethash "isBinary" dir) t) commit)
      commit)))

;; The last commit and the tree of PATH at REF: a branch, tag or SHA, as
;; on github.com, nil for the default branch.  PATH nil is the root.
(octocat-sync-define-resource repo-head (repo ref path)
  :graphql octocat-model--repo-head-query
  :repo repo
  ;; Peels an annotated tag to its commit.
  :vars `(("expr" . ,(concat (or ref "HEAD") "^{commit}"))
          ("dir" . ,(concat (or ref "HEAD") ":" path))
          ("path" . ,path))
  :parse (lambda (data) (octocat-model--repo-parse-head data ref path)))

(defconst octocat-model--repo-blame-query
  (concat "query($owner:String!,$name:String!,$expr:String!,$path:String!){"
          "repository(owner:$owner,name:$name){object(expression:$expr){...on Commit{"
          "blame(path:$path){ranges{startingLine endingLine commit{oid messageHeadline "
          "authoredDate committedDate author{name email user{login}}}}}}}}}")
  "GraphQL query behind the `blame' resource.")

(defun octocat-model--repo-parse-blame (data)
  "Return the ranges in DATA, the answer to `octocat-model--repo-blame-query'.
That is a vector of hash-tables of \"start\" and \"end\",
the first and last line, and \"commit\", the commit that last changed
them, as `octocat-model--repo-history-commit' shapes it."
  (let ((blame (octocat--get data "repository" "object" "blame")))
    (unless (hash-table-p blame)
      (error "No such commit"))
    (vconcat
     (mapcar (lambda (r)
               (octocat--table "start" (gethash "startingLine" r)
                               "end" (gethash "endingLine" r)
                               "commit" (octocat-model--repo-history-commit (gethash "commit" r))))
             (gethash "ranges" blame)))))

(octocat-sync-define-resource blame (repo commit path)
  ;; COMMIT names the history, so what it says never changes.
  :max-age octocat-model--fixed-max-age
  :graphql octocat-model--repo-blame-query
  :repo repo
  :vars `(("expr" . ,commit) ("path" . ,path))
  :parse #'octocat-model--repo-parse-blame)

;; Directory listings and file contents are named by tree and blob SHA,
;; which name fixed contents, so they are kept for
;; `octocat-model--fixed-max-age'.  The tree of a directory at a ref comes
;; with its last commit, the repo page's `repo-head' resource.

(defun octocat-model--tree-fetch-all-files (repo sha callback)
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

(defconst octocat-model--tree-last-commits-chunk 50
  "Entries whose last commit one query asks for.
Each walks the history on GitHub's side, so a large directory is split.")

(defun octocat-model--tree-last-commits-query (n)
  "Return the GraphQL query of the last commits of N paths, $p0 to $pN-1.
Each is history alias eI, one commit long."
  (concat "query($owner:String!,$name:String!,$expr:String!"
          (mapconcat (lambda (i) (format ",$p%d:String!" i)) (number-sequence 0 (1- n)) "")
          "){repository(owner:$owner,name:$name){object(expression:$expr){...on Commit{"
          (mapconcat (lambda (i)
                       (format "e%d:history(first:1,path:$p%d){nodes{oid messageHeadline \
authoredDate committedDate author{name email user{login}}}}" i i))
                     (number-sequence 0 (1- n)) " ")
          "}}}}"))

(defun octocat-model--tree-parse-last-commits (json paths)
  "Return a hash-table of each of PATHS to its last commit, from JSON.
JSON answers `octocat-model--tree-last-commits-query' for PATHS.  A commit is
shaped by `octocat-model--repo-history-commit'; a path with none is left out."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json))))
         (obj  (and (hash-table-p repo) (gethash "object" repo)))
         (out  (make-hash-table :test #'equal)))
    (unless (hash-table-p obj)
      (error "No such commit"))
    (seq-do-indexed
     (lambda (path i)
       (let* ((hist  (gethash (format "e%d" i) obj))
              (nodes (and (hash-table-p hist) (gethash "nodes" hist))))
         (when (> (length nodes) 0)
           (puthash path (octocat-model--repo-history-commit (aref nodes 0)) out))))
     paths)
    out))

(defun octocat-model--tree-fetch-last-commits (repo commit paths callback)
  "Fetch the last commit of each of PATHS of REPO, from COMMIT back.
Calls CALLBACK once with a hash-table of path to commit, see
`octocat-model--tree-parse-last-commits', or a cons (error . MSG)."
  (let* ((chunks (seq-partition paths octocat-model--tree-last-commits-chunk))
         (left   (length chunks))
         (out    (make-hash-table :test #'equal))
         failed)
    (if (null chunks)
        (funcall callback out)
      (dolist (chunk chunks)
        (octocat--gh-graphql
         "tree-commits" repo (octocat-model--tree-last-commits-query (length chunk))
         (cons (cons "expr" commit)
               (seq-map-indexed (lambda (p i) (cons (format "p%d" i) p)) chunk))
         (lambda (json) (octocat-model--tree-parse-last-commits json chunk))
         (lambda (r)
           (if (eq (car-safe r) 'error)
               (setq failed r)
             (maphash (lambda (k v) (puthash k v out)) r))
           (when (zerop (cl-decf left))
             (funcall callback (or failed out)))))))))

;; The children of directory SHA, a vector of entries.
(octocat-sync-define-resource tree-dir (repo sha)
  :max-age octocat-model--fixed-max-age
  :gh (list "api" (format "repos/%s/git/trees/%s" repo sha))
  :parse (lambda (r)
           (let ((tree (gethash "tree" r)))
             (if (vectorp tree) tree (error "Unexpected tree response format")))))

(octocat-sync-define-resource tree-commits (repo commit dir sha)
  ;; COMMIT names the history, so what it says never changes.
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done)
           ;; No COMMIT yet: the page asks before it knows it.
           (if (null commit)
               (funcall done (octocat--table))
             (octocat-sync-get
              (list 'tree-dir repo sha)
              (lambda (entries)
                (if (eq (car-safe entries) 'error)
                    (funcall done entries)
                  (octocat-model--tree-fetch-last-commits
                   repo commit
                   (mapcar (lambda (e) (octocat-model-tree-join dir (gethash "path" e)))
                           entries)
                   done)))))))

(defun octocat-model--file-table (files)
  "Return FILES, an alist of (PATH . BLOB-SHA), as a hash-table."
  (let ((h (make-hash-table :test #'equal :size (length files))))
    (pcase-dolist (`(,path . ,blob) files)
      (puthash path blob h))
    h))

(octocat-sync-define-resource tree-files (repo sha)
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done)
           (octocat-model--tree-fetch-all-files
            repo sha (octocat--then #'octocat-model--file-table done))))

(defun octocat-model-tree-join (dir name)
  "Return the path of NAME inside directory path DIR (\"\" for the root)."
  (if (string-empty-p dir) name (concat dir "/" name)))

(octocat-sync-define-resource commits (repo ref path)
  :fetch (lambda (done)
           (octocat-model-repo-list-commits repo ref path (octocat--then #'vconcat done))))

(defun octocat-model-tree-load-files (repo ref callback)
  "Call CALLBACK with every file of REPO at REF, nil for the default branch.
They are a hash-table of path to blob SHA, from the store when there,
or (error . MSG)."
  (octocat-sync-get
   (list 'repo-head repo ref nil)
   (lambda (head)
     (if (eq (car-safe head) 'error)
         (funcall callback head)
       (octocat-sync-get (list 'tree-files repo (gethash "tree" head)) callback)))))

;;;; Actions

(defun octocat-model--poll-status (&rest statuses)
  "Return the :poll interval of a run, a job or a check of status STATUSES.
While any is under way, they are refetched every
`octocat-sync-poll-active' seconds; once all are completed, never."
  (and (seq-some (lambda (s) (and (stringp s) (not (equal (downcase s) "completed"))))
                 statuses)
       octocat-sync-poll-active))

(defun octocat-model--parse-annotations (output)
  "Return the check-run annotations in OUTPUT, a vector, \\=[] when unreadable."
  (condition-case nil
      (let ((parsed (json-parse-string (string-trim output))))
        (if (vectorp parsed) parsed []))
    (error [])))

(defun octocat-model--parse-artifacts (output)
  "Return the run artifacts in OUTPUT, a vector, \\=[] when unreadable."
  (condition-case nil
      (let ((parsed (json-parse-string (string-trim output))))
        (or (and (hash-table-p parsed) (gethash "artifacts" parsed))
            []))
    (error [])))

(defun octocat-model--job-tree (job annotations artifacts)
  "Return the tree of the `job' resource from what GitHub answered.
JOB is the job, as the REST API has it; ANNOTATIONS and ARTIFACTS are
vectors.  Any may be (error . MESSAGE) instead.  The tree holds them as
\"job\", \"annotations\" and \"artifacts\", those two \\=[] when
unavailable.  Without JOB there is no page to show, so its error is
returned."
  (if (eq (car-safe job) 'error)
      job
    (octocat--table "job" job
                    "annotations" (if (eq (car-safe annotations) 'error) [] annotations)
                    "artifacts" (if (eq (car-safe artifacts) 'error) [] artifacts))))

(octocat-sync-define-resource job (repo run-id job-id)
  :poll (lambda (data) (octocat-model--poll-status (octocat--get data "job" "status")))
  :fetch (lambda (done)
           ;; Three calls at once, answered in RESULTS as they come.
           (let* ((results (make-vector 3 'pending))
                  (answer  (lambda (i)
                             (lambda (r)
                               (aset results i r)
                               (unless (memq 'pending (append results nil))
                                 (funcall done (apply #'octocat-model--job-tree
                                                      (append results nil))))))))
             (octocat--run-gh "job-detail"
                              (list "api" (format "repos/%s/actions/jobs/%s" repo
                                                  (number-to-string job-id)))
                              (lambda (output) (json-parse-string (string-trim output)))
                              (funcall answer 0))
             (octocat--run-gh "job-annotations"
                              (list "api" (format "repos/%s/check-runs/%s/annotations?per_page=100"
                                                  repo (number-to-string job-id)))
                              #'octocat-model--parse-annotations
                              (funcall answer 1))
             (if (not run-id)
                 (funcall (funcall answer 2) [])
               (octocat--run-gh "job-artifacts"
                                (list "api"
                                      (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                                              repo (number-to-string run-id)))
                                #'octocat-model--parse-artifacts
                                (funcall answer 2))))))

(octocat-sync-define-resource job-log (repo job-id)
  ;; Apart from `job', so the steps show before a long log has come; the
  ;; job page refetches it as the job runs, see `octocat-job--page'.
  ;; Its data is the raw text as "log", see `octocat--job-parse-log'.
  :poll nil
  :gh (list "run" "view" "--log" "--job" (number-to-string job-id) "--repo" repo)
  :raw t
  :parse (lambda (raw) (octocat--table "log" raw)))

(defun octocat--fetch-run (repo run-id callback)
  "Fetch detail for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a hash-table of run data (including a \\='jobs\\=' key
whose value is a vector of job hash-tables), or a cons \\=(error . MSG)."
  (octocat--run-gh
   "run-view"
   (list "run" "view"
         (number-to-string run-id)
         "--repo" repo
         "--json" (concat "databaseId,number,displayTitle,status,conclusion,"
                          "createdAt,updatedAt,headBranch,headSha,"
                          "event,workflowName,workflowDatabaseId,jobs"))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))

(defun octocat--fetch-run-annotations (repo jobs callback)
  "Fetch check-run annotations for every job in the JOBS vector from REPO.
Fires one async request per job in parallel.  Calls CALLBACK with a list
of (JOB-ID JOB-NAME ANNOTATIONS-VECTOR) in the order of JOBS, or nil when
JOBS is empty.
Individual job annotation failures are silently treated as empty vectors."
  (let* ((job-list (cl-coerce jobs 'list))
         (pending  (length job-list))
         (results  nil))
    (if (zerop pending)
        (funcall callback nil)
      (dolist (job job-list)
        (let* ((job-id   (gethash "databaseId" job))
               (job-name (or (gethash "name" job) "")))
          (octocat--run-gh
           "run-annotations"
           (list "api"
                 (format "repos/%s/check-runs/%s/annotations?per_page=100"
                         repo (number-to-string job-id)))
           #'octocat-model--parse-annotations
           (lambda (ann-result)
             (let ((anns (if (eq (car-safe ann-result) 'error) [] ann-result)))
               (push (list job-id job-name anns) results))
             (cl-decf pending)
             ;; In the jobs' order, not the order their answers came in.
             (when (zerop pending)
               (funcall callback
                        (mapcar (lambda (job) (assq (gethash "databaseId" job) results))
                                job-list))))))))))


(defun octocat-model--run-annotation-entries (results)
  "Return the RESULTS of `octocat--fetch-run-annotations' as a vector.
Each entry is a hash-table of \"job\", its name, and \"annotations\", a
vector: a shape the store can hold as JSON."
  (vconcat
   (mapcar (lambda (r) (octocat--table "job" (nth 1 r) "annotations" (nth 2 r))) results)))

(octocat-sync-define-resource run (repo run-id)
  :entity (format "run:%s/%s" (downcase repo) run-id)
  ;; Annotations come as the run's jobs finish.
  :invalidates `((runs ,repo _ _) (workflow ,repo _ _) (run-annotations ,repo ,run-id))
  :poll (lambda (data) (octocat-model--poll-status (octocat--get data "item" "status")))
  :fetch (lambda (done)
           (octocat--fetch-run
            repo run-id
            (octocat--then (lambda (run)
                             (octocat-model-detail run '("jobs")
                                                   (lambda (f) (octocat-model-run repo f))))
                           done))))

(octocat-sync-define-resource run-annotations (repo run-id)
  ;; The run's jobs are fetched here, not taken from the page: keyed by
  ;; them, the annotations would vanish whenever the jobs changed.
  :fetch (lambda (done)
           (octocat--fetch-run
            repo run-id
            (lambda (run)
              (if (eq (car-safe run) 'error)
                  (funcall done run)
                (octocat--fetch-run-annotations
                 repo (gethash "jobs" run)
                 (lambda (r) (funcall done (octocat-model--run-annotation-entries r)))))))))

;; Failing, it is [], as the page shows no error for it.
(octocat-sync-define-resource run-artifacts (repo run-id)
  :fetch (lambda (done)
           (octocat--run-gh "run-artifacts"
                            (list "api" (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                                                repo (number-to-string run-id)))
                            #'octocat-model--parse-artifacts
                            (lambda (r) (funcall done (if (eq (car-safe r) 'error) [] r))))))

;; The LIMIT most recent runs of all workflows.
(octocat-sync-define-resource runs (repo limit args)
  ;; ARGS are `gh run list' options filtering the runs, such as
  ;; ("--branch" "main").
  :gh (append (list "run" "list" "--repo" repo "--limit" (number-to-string limit)
                    "--json" (concat "databaseId,number,displayTitle,status,conclusion,"
                                     "createdAt,headBranch,workflowName,workflowDatabaseId"))
              args)
  :parse (lambda (runs)
           (octocat--table "nodes" (cl-map 'vector (lambda (run) (octocat-model-run repo run))
                                           runs))))


;; GitHub's API doesn't say what a `workflow_dispatch' trigger asks:
;; it is read from the workflow's file, at the branch it is to run on.
;; Elisp has no YAML reader, so `octocat-model--workflow-yaml-parse' reads
;; the little of YAML that triggers are written in, and only the `on'
;; block is given to it.

(defun octocat-model--workflow-yaml-uncomment (line)
  "Return LINE without its comment and trailing blanks.
A comment starts at a `#' outside quotes, first or after a blank."
  (let ((i 0) (n (length line)) quote end)
    (while (and (< i n) (not end))
      (let ((c (aref line i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((and (eq c ?#) (or (zerop i) (memq (aref line (1- i)) '(?\s ?\t))))
               (setq end i))))
      (setq i (1+ i)))
    (string-trim-right (substring line 0 end))))

(defun octocat-model--workflow-yaml-item-p (text)
  "Return non-nil if TEXT, a trimmed line, is an item of a block sequence."
  (or (equal text "-") (string-prefix-p "- " text)))

(defun octocat-model--workflow-yaml-key (text)
  "Return (KEY . REST) if TEXT, a trimmed line, is a mapping entry.
REST is what follows the colon, \"\" when nothing does."
  (when (string-match (concat "\\`\\(\"[^\"]*\"\\|'[^']*'\\|[^\"' ][^:]*?\\)"
                              "[ \t]*:\\(?:[ \t]+\\(.*\\)\\)?\\'")
                      text)
    (cons (octocat-model--workflow-yaml-scalar (match-string 1 text))
          (or (match-string 2 text) ""))))

(defun octocat-model--workflow-yaml-split (text)
  "Return TEXT, the inside of a flow collection, split at its top commas."
  (let ((i 0) (start 0) (depth 0) quote parts)
    (while (< i (length text))
      (let ((c (aref text i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((memq c '(?\[ ?\{)) (setq depth (1+ depth)))
              ((memq c '(?\] ?\})) (setq depth (1- depth)))
              ((and (eq c ?,) (zerop depth))
               (push (substring text start i) parts)
               (setq start (1+ i)))))
      (setq i (1+ i)))
    (push (substring text start) parts)
    (seq-remove #'string-empty-p (mapcar #'string-trim (nreverse parts)))))

(defun octocat-model--workflow-yaml-scalar (text)
  "Return TEXT, a value on one line, as `octocat-model--workflow-yaml-parse' does."
  (cond
   ((member text '("" "~" "null" "Null" "NULL")) nil)
   ((string-match "\\`\"\\(.*\\)\"\\'" text)
    (condition-case nil (read text) (error (match-string 1 text))))
   ((string-match "\\`'\\(.*\\)'\\'" text)
    (string-replace "''" "'" (match-string 1 text)))
   ((string-match "\\`\\[\\(.*\\)\\]\\'" text)
    (vconcat (mapcar #'octocat-model--workflow-yaml-scalar
                     (octocat-model--workflow-yaml-split (match-string 1 text)))))
   ((string-match "\\`{\\(.*\\)}\\'" text)
    (delq nil (mapcar (lambda (part)
                        (when-let* ((pair (octocat-model--workflow-yaml-key part)))
                          (cons (car pair) (octocat-model--workflow-yaml-scalar (cdr pair)))))
                      (octocat-model--workflow-yaml-split (match-string 1 text)))))
   (t text)))

(defun octocat-model--workflow-yaml-parse (text)
  "Return TEXT, YAML, as Lisp.
A mapping is an alist of (KEY . VALUE), in order, a sequence a vector,
a scalar a string, and an empty value nil.  It reads block mappings
and sequences, flow ones on one line, quoted and plain scalars and
block scalars (`|', `>'): what triggers are written in.  Anchors, tags
and values over several lines otherwise are not read."
  (let* ((lines (vconcat
                 (mapcar (lambda (raw)
                           (let ((s (octocat-model--workflow-yaml-uncomment raw)))
                             ;; (INDENT TEXT RAW); INDENT nil for a blank line
                             (list (and (not (string-blank-p s))
                                        (- (length s) (length (string-trim-left s))))
                                   (string-trim s) raw)))
                         (split-string text "\n"))))
         (i 0))
    (cl-labels
        ((indent ()
           (while (and (< i (length lines)) (null (car (aref lines i))))
             (setq i (1+ i)))
           (and (< i (length lines)) (car (aref lines i))))
         (line () (nth 1 (aref lines i)))
         (node (min)
           (let ((ind (indent)))
             (cond ((or (null ind) (< ind min)) nil)
                   ((octocat-model--workflow-yaml-item-p (line)) (items ind))
                   (t (pairs ind)))))
         (items (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-model--workflow-yaml-item-p (line)))
               (let ((rest (string-trim-left (substring (line) 1))))
                 (cond ((string-empty-p rest)
                        (setq i (1+ i))
                        (push (node (1+ ind)) out))
                       ((octocat-model--workflow-yaml-key rest)
                        ;; "- key: value" starts a mapping at key's column.
                        (aset lines i (list (+ ind (- (length (line)) (length rest))) rest nil))
                        (push (pairs (car (aref lines i))) out))
                       (t (setq i (1+ i))
                          (push (octocat-model--workflow-yaml-scalar rest) out)))))
             (vconcat (nreverse out))))
         (pairs (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-model--workflow-yaml-key (line)))
               (pcase-let ((`(,key . ,rest) (octocat-model--workflow-yaml-key (line))))
                 (setq i (1+ i))
                 (push (cons key
                             (cond ((string-match-p "\\`[|>][-+0-9]*\\'" rest)
                                    (block ind (eq (aref rest 0) ?>)))
                                   ((not (string-empty-p rest))
                                    (octocat-model--workflow-yaml-scalar rest))
                                   ;; A sequence may sit at its key's indent.
                                   ((and (eql (indent) ind)
                                         (octocat-model--workflow-yaml-item-p (line)))
                                    (items ind))
                                   (t (node (1+ ind)))))
                       out)))
             (nreverse out)))
         (block (ind folded)
           (let (raws)
             (while (and (< i (length lines))
                         (let ((raw (nth 2 (aref lines i))))
                           (and raw (or (string-blank-p raw)
                                        (> (- (length raw) (length (string-trim-left raw)))
                                           ind)))))
               (push (nth 2 (aref lines i)) raws)
               (setq i (1+ i)))
             (let* ((raws (nreverse raws))
                    (cut  (apply #'min most-positive-fixnum
                                 (mapcar (lambda (r) (- (length r) (length (string-trim-left r))))
                                         (seq-remove #'string-blank-p raws)))))
               (string-trim-right
                (string-join (mapcar (lambda (r) (if (string-blank-p r) "" (substring r cut)))
                                     raws)
                             (if folded " " "\n")))))))
      (node 0))))

(defun octocat-model--workflow-yaml-on (yaml)
  "Return the triggers of workflow file YAML, its `on' value, as Lisp.
Only the `on' block is read, so what the jobs are written in does not
matter.  YAML 1.1 reads a bare `on' as true, so `true' is taken too."
  (let ((lines (split-string yaml "\n")) block)
    (while (and lines (not (string-match-p "\\`\\(on\\|\"on\"\\|'on'\\|true\\)[ \t]*:"
                                           (car lines))))
      (setq lines (cdr lines)))
    (when lines
      (push (car lines) block)
      (setq lines (cdr lines))
      (while (and lines (let ((l (octocat-model--workflow-yaml-uncomment (car lines))))
                          (or (string-empty-p l) (memq (aref l 0) '(?\s ?\t ?-)))))
        (push (car lines) block)
        (setq lines (cdr lines)))
      (cdar (octocat-model--workflow-yaml-parse (string-join (nreverse block) "\n"))))))

(defun octocat-model--workflow-dispatch-spec (yaml)
  "Return what running workflow file YAML by hand asks, as a hash-table.
\"dispatch\" is t when it has a `workflow_dispatch' trigger, else
`:false', and \"inputs\" a vector of its inputs, each with its
\"name\", \"type\", \"required\" (t or `:false'), \"options\" and,
when given, \"description\" and \"default\", strings."
  (let* ((on       (octocat-model--workflow-yaml-on yaml))
         (trigger  (cond ((stringp on) (and (equal on "workflow_dispatch") (list on)))
                         ((vectorp on) (and (seq-contains-p on "workflow_dispatch") (list on)))
                         ((consp on)   (assoc "workflow_dispatch" on))))
         (inputs   (let ((v (cdr trigger))) (and (consp v) (cdr (assoc "inputs" v)))))
         (spec     (make-hash-table :test #'equal)))
    (puthash "dispatch" (if trigger t :false) spec)
    (puthash "inputs"
             (vconcat
              (mapcar (pcase-lambda (`(,name . ,props))
                        (let ((in  (make-hash-table :test #'equal))
                              (get (lambda (k) (and (consp props) (cdr (assoc k props))))))
                          (puthash "name" name in)
                          (puthash "type" (or (funcall get "type") "string") in)
                          (puthash "required"
                                   (if (member (funcall get "required") '("true" "True" "TRUE"))
                                       t :false)
                                   in)
                          (puthash "options" (vconcat (funcall get "options")) in)
                          (dolist (k '("description" "default"))
                            (when (stringp (funcall get k))
                              (puthash k (funcall get k) in)))
                          in))
                      (and (consp inputs) inputs)))
             spec)
    spec))

;; GitHub's API doesn't say which jobs of a run wait for which: their
;; `needs' is read from the workflow's file, at the run's commit, for
;; the run page's job graph (see "Jobs" under "Runs").

(defconst octocat-model--workflow-max-file-size (* 512 1024)
  "The longest workflow file read for its jobs; a longer one has none.")

(defun octocat-model--workflow-yaml-jobs (yaml)
  "Return the jobs of workflow file YAML as a vector of hash-tables.
Each has the job's \"id\", its \"name\" when it has one, and \"needs\",
a vector of the ids of the jobs it waits for.  Only those two keys of
each job are given to `octocat-model--workflow-yaml-parse', so what its steps
are written in does not matter.  A file longer than
`octocat-model--workflow-max-file-size' is not read."
  (let* ((lines (and (<= (length yaml) octocat-model--workflow-max-file-size)
                     (mapcar (lambda (l) (string-trim-right l "[ \t\r]+"))
                             (split-string yaml "\n"))))
         (indent (lambda (l) (- (length l) (length (string-trim-left l)))))
         (blank-p (lambda (l) (string-empty-p (octocat-model--workflow-yaml-uncomment l))))
         jobs)
    (while (and lines (not (string-match-p "\\`jobs[ \t]*:[ \t]*\\(#.*\\)?\\'" (car lines))))
      (setq lines (cdr lines)))
    (setq lines (cdr lines))
    ;; The jobs' block: what follows `jobs:', up to the next top-level key.
    (let* ((block (cl-loop for l in lines
                           until (and (not (funcall blank-p l)) (zerop (funcall indent l)))
                           unless (funcall blank-p l) collect l))
           (job-ind (and block (funcall indent (car block)))))
      (while block
        (let ((id (car (octocat-model--workflow-yaml-key (string-trim (car block)))))
              body)
          (setq block (cdr block))
          (while (and block (> (funcall indent (car block)) job-ind))
            (push (car block) body)
            (setq block (cdr block)))
          (setq body (nreverse body))
          (when (stringp id)
            (let* ((key-ind (and body (funcall indent (car body))))
                   (kept (cl-loop with keep = nil
                                  for l in body
                                  for ind = (funcall indent l)
                                  do (when (= ind key-ind)
                                       (setq keep (string-match-p
                                                   "\\`\\(name\\|needs\\)[ \t]*:"
                                                   (string-trim-left l))))
                                  when keep collect (substring l (min key-ind (length l)))))
                   (props (and kept (octocat-model--workflow-yaml-parse (string-join kept "\n"))))
                   (needs (cdr (assoc "needs" props)))
                   (name (cdr (assoc "name" props)))
                   (job (make-hash-table :test #'equal)))
              (puthash "id" id job)
              (when (stringp name) (puthash "name" name job))
              (puthash "needs" (vconcat (seq-filter #'stringp (if (stringp needs)
                                                                  (list needs)
                                                                (append needs nil))))
                       job)
              (push job jobs))))))
    (vconcat (nreverse jobs))))

(defun octocat-model--workflow-file-args (repo path ref)
  "Return the `gh' arguments printing the workflow file PATH of REPO at REF."
  (list "api" "-X" "GET"
        (format "repos/%s/contents/%s" repo
                (mapconcat #'url-hexify-string (split-string path "/") "/"))
        "-f" (concat "ref=" ref)
        "-H" "Accept: application/vnd.github.raw"))

(octocat-sync-define-resource workflow-jobs (repo path sha)
  ;; A file at a commit never changes.
  :max-age octocat-model--fixed-max-age
  :gh (octocat-model--workflow-file-args repo path sha)
  :raw t
  :parse #'octocat-model--workflow-yaml-jobs)

(octocat-sync-define-resource workflow-dispatch (repo path ref)
  :max-age 300
  :poll 300
  :gh (octocat-model--workflow-file-args repo path ref)
  :raw t
  :parse #'octocat-model--workflow-dispatch-spec)

(defun octocat-model--workflow-parse-dispatched (output)
  "Return the ID of the run GitHub started, from OUTPUT, or nil.
Asked for with `return_run_details'; a GitHub without it answers with
nothing."
  (let ((text (string-trim output)))
    (and (not (string-empty-p text))
         (octocat--get (json-parse-string text) "workflow_run_id"))))

(octocat-sync-define-mutation dispatch-workflow (repo id ref inputs)
  :label "Starting workflow…"
  :slot 'dispatch
  :resources `((workflow ,repo ,id))
  :gh (append (list "api" "--method" "POST"
                    (format "repos/%s/actions/workflows/%s/dispatches" repo id)
                    "-f" (concat "ref=" ref)
                    "-F" "return_run_details=true")
              (mapcan (pcase-lambda (`(,name . ,value))
                        (list "-f" (format "inputs[%s]=%s" name value)))
                      inputs))
  :raw t
  :parse #'octocat-model--workflow-parse-dispatched
  :invalidates `((runs ,repo _ _)))

(octocat-sync-define-resource workflow (repo id)
  :gh (list "api" (format "repos/%s/actions/workflows/%s" repo id)))

(defun octocat-model--workflow-list (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(octocat-sync-define-resource workflows (repo)
  :fetch (lambda (done) (octocat-model--workflow-list repo (octocat--then #'vconcat done))))

;; The first 100 check runs of SHA.
(octocat-sync-define-resource checks (repo sha)
  ;; None yet: they may still start.
  :poll (lambda (data)
          (if (seq-empty-p data)
              octocat-sync-poll-interval
            (apply #'octocat-model--poll-status
                   (mapcar (lambda (c) (gethash "status" c)) data))))
  :gh (list "api" (format "repos/%s/commits/%s/check-runs?per_page=100" repo sha))
  :parse (lambda (r)
           (let ((runs (and (hash-table-p r) (gethash "check_runs" r))))
             (if (vectorp runs) runs []))))

;;;; Dashboard

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


(defun octocat--dashboard-items-tree (kind page)
  "Return PAGE, the dashboard's KIND items, as its resource's tree.
PAGE is as `octocat--list-page' returns.  Each item becomes a
table of its \"repo\" and its entity, \"item\", shared with the lists."
  (let ((type (if (eq kind 'pulls) 'pr 'issue)))
    (vconcat
     (mapcar (lambda (item)
               (let ((repo (gethash "nameWithOwner" (gethash "repository" item))))
                 (remhash "repository" item)
                 (octocat--table "repo" repo "item" (octocat-model-item type repo item))))
             (plist-get page :items)))))

;; The repositories you pushed to last.
(octocat-sync-define-resource dashboard-repos ()
  :gh (list "api" "user/repos?sort=pushed&per_page=10")
  :parse (lambda (repos) (cl-map 'vector #'octocat-model-repo-rest repos)))

(octocat-sync-define-resource dashboard-items (kind limit)
  :graphql (octocat--dashboard-items-query kind)
  :vars `(("q" . ,(octocat--dashboard-search-query kind)) ("limit" . ,limit))
  :parse (lambda (data) (octocat--dashboard-items-tree kind (octocat--list-page data))))

;; The events of the people you follow and the repositories you watch.
(octocat-sync-define-resource dashboard-feed (limit)
  :fetch (lambda (done)
           (octocat-sync-get
            '(viewer)
            (lambda (viewer)
              (if (eq (car-safe viewer) 'error)
                  (funcall done viewer)
                (octocat--run-gh "dashboard-feed"
                                 (list "api" (format "users/%s/received_events?per_page=%d"
                                                     (gethash "login" viewer) limit))
                                 (lambda (output) (vconcat (octocat--parse-json-list output)))
                                 done))))))

;;;; Users

(defun octocat-model--user-parse-profile (p)
  "Return P, the user of a `users/LOGIN' response, as the profile resource.
The user is an entity; the counts belong to this resource."
  (octocat--table
   "user" (octocat-sync-entity
           'user (concat "user:" (downcase (gethash "login" p)))
           (octocat--table
            "login" (gethash "login" p)
            "__typename" (gethash "type" p)
            "name" (gethash "name" p)
            "bio" (gethash "bio" p)
            "company" (gethash "company" p)
            "location" (gethash "location" p)
            "websiteUrl" (gethash "blog" p)
            "avatarUrl" (gethash "avatar_url" p)))
   "followers" (gethash "followers" p)
   "following" (gethash "following" p)
   "publicRepos" (gethash "public_repos" p)))

(defun octocat-model--user-parse-repos (repos)
  "Return REPOS, a `users/LOGIN/repos' response, as a list resource."
  (octocat--table "nodes" (cl-map 'vector #'octocat-model-repo-rest repos)))

(defconst octocat-model--user-pinned-query
  (concat "query($login:String!){repositoryOwner(login:$login){... on ProfileOwner{"
          "pinnedItems(first:6,types:REPOSITORY){nodes{... on Repository{nameWithOwner "
          "description stargazerCount primaryLanguage{name} pushedAt isFork "
          "isArchived}}}}}}")
  "GraphQL query behind the `user-pinned' resource.
The REST API does not expose pinned repositories.")

(defun octocat-model--user-parse-pinned (data)
  "Return the pinned repos in DATA, the `octocat-model--user-pinned-query' answer.
Pinned gists, which come back as empty nodes, are left out."
  (octocat--table
   "nodes" (vconcat (delq nil (mapcar (lambda (node)
                                        (and node (gethash "nameWithOwner" node)
                                             (octocat-model-repo node)))
                                      (octocat--get data "repositoryOwner"
                                                    "pinnedItems" "nodes"))))))

(octocat-sync-define-resource user-profile (login)
  :poll octocat-sync-poll-slow
  :gh (list "api" (format "users/%s" login))
  :parse #'octocat-model--user-parse-profile)

(octocat-sync-define-resource user-repos (login limit)
  :poll octocat-sync-poll-slow
  ;; The limit is in the URL so that `gh api' issues a GET.
  :gh (list "api" (format "users/%s/repos?sort=pushed&per_page=%d" login limit))
  :parse #'octocat-model--user-parse-repos)

(octocat-sync-define-resource user-pinned (login)
  :poll octocat-sync-poll-slow
  :graphql octocat-model--user-pinned-query
  :vars `(("login" . ,login))
  :parse #'octocat-model--user-parse-pinned)

;;;; Search

(defcustom octocat-search-cache-ttl 60
  "Seconds an object-search result is reused by `octocat-search-repo'.
A stored result for a query always shows at once.  Within this it is
not refetched; older, it is, and the list is updated when the response
arrives.  It is at least `octocat-sync-fresh-for'."
  :type 'integer
  :group 'octocat)

(defconst octocat-model--search-fields
  '(("prs"     . "number,title,state,author")
    ("issues"  . "number,title,state,author")
    ("commits" . "sha,commit,author"))
  "The fields an `object-search' asks `gh search' for, by its type.")

;; Plain results, not entities: `gh search' gives fewer fields than the
;; pages' issues and PRs, and their state in lower case.
(octocat-sync-define-resource object-search (repo type query)
  :max-age octocat-search-cache-ttl
  :gh (list "search" type (format "--repo=%s" repo)
            "--json" (alist-get type octocat-model--search-fields nil nil #'equal)
            "--limit" "30" query))

(defconst octocat--search-files-ttl 600
  "Seconds a stored repository file list is reused without a refetch.")

;; As `tree-files', by ref rather than a tree SHA: REF nil is the default
;; branch, which `octocat-model-tree-load-files' would ask GitHub for first.
(octocat-sync-define-resource search-files (repo ref)
  :max-age octocat--search-files-ttl
  :fetch (lambda (done)
           (if ref
               (octocat-model-tree-load-files repo ref done)
             (octocat-model--tree-fetch-all-files
              repo "HEAD" (octocat--then #'octocat-model--file-table done)))))

(provide 'octocat-model)
;;; octocat-model.el ends here
