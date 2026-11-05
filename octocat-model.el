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

(defun octocat-model-item-key (type repo number)
  "Return the key of issue or PR (TYPE `issue' or `pr') NUMBER of REPO."
  (format "%s:%s#%d" type (downcase repo) number))

(defun octocat-model-user (user)
  "Return the `user' entity of USER, a table with a \"login\", or USER.
Only the login is kept: the fields beside it vary with the source."
  (let ((login (and (hash-table-p user) (gethash "login" user))))
    (if (not (stringp login))
        user
      (let ((fields (make-hash-table :test #'equal)))
        (puthash "login" login fields)
        (octocat-sync-entity 'user (concat "user:" (downcase login)) fields)))))

(defun octocat-model-label (repo label)
  "Return the `label' entity of LABEL of REPO, a table with name and colour."
  (let ((fields (make-hash-table :test #'equal)))
    (puthash "name" (gethash "name" label) fields)
    (puthash "color" (gethash "color" label) fields)
    (octocat-sync-entity 'label (format "label:%s/%s" (downcase repo) (gethash "name" label))
                         fields)))

(defun octocat-model--item-ref (ref)
  "Return REF, an issue or PR another one refers to, as its number and repo."
  (let* ((h     (make-hash-table :test #'equal))
         (other (gethash "repository" ref))
         (owner (and (hash-table-p other) (gethash "owner" other))))
    (puthash "number" (gethash "number" ref) h)
    (when (hash-table-p other)
      (let ((r (make-hash-table :test #'equal))
            (o (make-hash-table :test #'equal)))
        (puthash "login" (and (hash-table-p owner) (gethash "login" owner)) o)
        (puthash "name" (gethash "name" other) r)
        (puthash "owner" o r)
        (puthash "repository" r h)))
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
  (let ((fields (make-hash-table :test #'equal))
        (lang   (gethash "language" repo)))
    (puthash "nameWithOwner" (gethash "full_name" repo) fields)
    (puthash "description" (gethash "description" repo) fields)
    (puthash "stargazerCount" (gethash "stargazers_count" repo) fields)
    (puthash "primaryLanguage"
             (and (stringp lang)
                  (let ((l (make-hash-table :test #'equal))) (puthash "name" lang l) l))
             fields)
    (puthash "pushedAt" (gethash "pushed_at" repo) fields)
    (puthash "isFork" (gethash "fork" repo) fields)
    (puthash "isArchived" (gethash "archived" repo) fields)
    (octocat-model-repo fields)))

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

(octocat-sync-define-resource repo-summary (repo)
  :max-age octocat-repo-summary-ttl
  :fetch (lambda (done)
           (octocat--fetch-repo-summary
            repo
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (let ((h (make-hash-table :test #'equal)))
                                (while r
                                  (puthash (substring (symbol-name (pop r)) 1) (pop r) h))
                                h)))))))

(octocat-sync-define-resource counts (kind repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (let ((tree (make-hash-table :test #'equal)))
             (if (null kind)
                 (funcall done tree)
               (octocat--fetch-counts
                repo kind
                (lambda (r)
                  (if (eq (car-safe r) 'error)
                      (funcall done r)
                    (while r
                      (puthash (substring (symbol-name (pop r)) 1) (pop r) tree))
                    (funcall done tree))))))))

(defun octocat-model-list-tree (kind repo page)
  "Return PAGE, a page of KIND items of REPO, as a list resource's tree.
PAGE is as `octocat--parse-list-items' returns; each item is an entity."
  (let ((tree (make-hash-table :test #'equal))
        (type (if (eq kind 'pulls) 'pr 'issue)))
    (puthash "nodes" (vconcat (mapcar (lambda (item) (octocat-model-item type repo item))
                                      (plist-get page :items)))
             tree)
    (puthash "cursor" (plist-get page :cursor) tree)
    tree))

(octocat-sync-define-resource list-items (kind repo query limit)
  :fetch (lambda (done)
           ;; As many as "load more" stored, so a refetch keeps them.
           (let ((data (plist-get (octocat-sync-read
                                   (list 'list-items kind repo query limit))
                                  :data)))
             (octocat--list-items
              kind repo
              (lambda (r)
                (funcall done (if (eq (car-safe r) 'error)
                                  r
                                (octocat-model-list-tree kind repo r))))
              query nil (min 100 (max limit (length (and data (gethash "nodes" data)))))))))

(octocat-sync-define-resource labels (repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--list-labels
            repo (lambda (r)
                   (funcall done (if (eq (car-safe r) 'error)
                                     r
                                   (cl-map 'vector (lambda (l) (octocat-model-label repo l))
                                           r)))))))

(octocat-sync-define-resource assignees (repo)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--list-people
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(defconst octocat-model--fixed-max-age (* 30 24 60 60)
  "Seconds to keep what a SHA names, which never changes.")

(defun octocat-model--fetch-file (repo sha callback)
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

(octocat-sync-define-resource blob (repo sha)
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done)
           (let ((h (make-hash-table :test #'equal)))
             ;; No SHA, no file: a page asks for one before it knows it.
             (if (null sha)
                 (funcall done (progn (puthash "base64" "" h) h))
               (octocat-model--fetch-file
                repo sha
                (lambda (r)
                  (funcall done (if (eq (car-safe r) 'error)
                                    r
                                  (progn (puthash "base64" r h) h)))))))))

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

(octocat-sync-define-resource branches (repo)
  :fetch (lambda (done)
           (octocat--list-branches
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

;;;; Issues and PRs

(defun octocat--fetch-issue-events (repo number callback)
  "Fetch the timeline events of issue or PR NUMBER in REPO asynchronously.
Calls CALLBACK with a hash-table whose \"events\" key holds the vector of
timeline events of all pages, or a cons \\=(error . MSG)."
  (octocat--run-gh "timeline-events"
                   (list "api" "--paginate" "--slurp"
                         (format "repos/%s/issues/%d/timeline" repo number))
                   (lambda (output)
                     (let ((pages (json-parse-string (string-trim output)))
                           (result (make-hash-table :test 'equal)))
                       (puthash "events" (apply #'vconcat (append pages nil)) result)
                       result))
                   callback))

(octocat-sync-define-resource timeline-events (repo number)
  :fetch (lambda (done) (octocat--fetch-issue-events repo number done)))

(defconst octocat-model-pending "octocatPending"
  "Key of what is being done to a comment, or to an item's opening post.
Only the edits of a pending mutation set it, so it is never stored.")

(defun octocat-model-detail-spec (kind repo number)
  "Return the spec of the page resource of issue or PR (KIND) NUMBER of REPO."
  (list (if (equal kind "pr") 'pr 'issue) repo number))

;; The login a comment being posted shows as its author.
(octocat-sync-define-resource viewer ()
  :max-age 86400
  :fetch (lambda (done)
           (octocat--run-gh "viewer" (list "api" "user")
                            (lambda (output)
                              (let ((user (json-parse-string (string-trim output)))
                                    (tree (make-hash-table :test #'equal)))
                                (puthash "login" (gethash "login" user) tree)
                                tree))
                            done)))

(defun octocat-model--pending-comment (body login now)
  "Return the comment of BODY being posted by LOGIN (or nil) at NOW.
NOW is an ISO 8601 time.  It has no id or URL until GitHub answers."
  (let ((comment (make-hash-table :test #'equal))
        (author  (make-hash-table :test #'equal)))
    (puthash "login" login author)
    (puthash "author" (and login author) comment)
    (puthash "body" body comment)
    (puthash "createdAt" now comment)
    (puthash "viewerDidAuthor" t comment)
    (puthash octocat-model-pending "posting…" comment)
    comment))

(defun octocat-model--rest-comment (comment)
  "Return COMMENT, from GitHub's REST API, in the fields `gh ... view' gives."
  (let ((h      (make-hash-table :test #'equal))
        (author (make-hash-table :test #'equal)))
    (puthash "login" (octocat--get comment "user" "login") author)
    (puthash "id" (octocat--get comment "node_id") h)
    (puthash "author" author h)
    (puthash "authorAssociation" (octocat--get comment "author_association") h)
    (puthash "body" (or (octocat--get comment "body") "") h)
    (puthash "createdAt" (octocat--get comment "created_at") h)
    (puthash "url" (octocat--get comment "html_url") h)
    (puthash "viewerDidAuthor" t h)
    h))

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
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
  :optimistic (lambda ()
                `((,(octocat-model-item-key (if (equal kind "pr") 'pr 'issue) repo number)
                   ("state" . ,(if (equal verb "close") "CLOSED" "OPEN")))))
  :send (lambda (done)
          (octocat--run-gh verb (list kind verb (number-to-string number) "--repo" repo)
                           #'ignore done))
  ;; The lists it moves in or out of, their counts, and the new event.
  :invalidates (lambda ()
                 (let ((kind (if (equal kind "pr") 'pulls 'issues)))
                   `((timeline-events ,repo ,number)
                     (list-items ,kind ,repo _ _)
                     (counts ,kind ,repo)
                     (repo-summary ,repo)))))

(octocat-sync-define-mutation set-title (kind repo number title)
  :label "Renaming…"
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
  :optimistic (lambda ()
                `((,(octocat-model-item-key (if (equal kind "pr") 'pr 'issue) repo number)
                   ("title" . ,title))))
  :send (lambda (done)
          (octocat--run-gh "edit-title"
                           (list kind "edit" (number-to-string number) "--repo" repo
                                 "--title" title)
                           #'ignore done))
  ;; It adds a "changed the title" event.
  :invalidates (lambda () `((timeline-events ,repo ,number))))

(octocat-sync-define-mutation comment (kind repo number body)
  :label "Posting comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
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
             (list (cons (octocat-model-detail-spec kind repo number)
                         (lambda (data) (octocat-model--put-comment data comment))))))
  :send (lambda (done)
          (octocat--run-gh "comment"
                           (list "api" (format "repos/%s/issues/%d/comments" repo number)
                                 "-f" (concat "body=" body))
                           (lambda (output) (json-parse-string (string-trim output)))
                           done))
  ;; The comment count, on the entity.
  :invalidates (lambda () (list (octocat-model-detail-spec kind repo number))))

(octocat-sync-define-mutation edit-body (kind repo number body)
  :label "Saving description…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
  :optimistic (lambda ()
                `((,(octocat-model-item-key (if (equal kind "pr") 'pr 'issue) repo number)
                   ("body" . ,body))))
  ;; Only the spinner: the body is the entity's.
  :edits (lambda (answered _)
           (unless answered
             (list (cons (octocat-model-detail-spec kind repo number)
                         (lambda (data)
                           (puthash octocat-model-pending "saving…" data)
                           data)))))
  :send (lambda (done)
          (octocat--run-gh "edit-body"
                           (list kind "edit" (number-to-string number) "--repo" repo
                                 "--body" body)
                           #'ignore done)))

(octocat-sync-define-mutation edit-comment (kind repo number comment-id body)
  :label "Saving comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
  :edits (lambda (answered _)
           (list (cons (octocat-model-detail-spec kind repo number)
                       (lambda (data)
                         (octocat-model--set-comment-body
                          data comment-id body (unless answered "saving…"))))))
  :send (lambda (done)
          (octocat--run-gh "edit-comment"
                           (list "api" (format "repos/%s/issues/comments/%s" repo comment-id)
                                 "--method" "PATCH" "-f" (format "body=%s" body))
                           #'ignore done)))

(octocat-sync-define-mutation edit-values (kind repo number flag add remove)
  :label (format "Saving %ss…" flag)
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)))
  :send (lambda (done)
          (octocat--run-gh (concat "edit-" flag)
                           (append (list kind "edit" (number-to-string number) "--repo" repo)
                                   (and add (list (concat "--add-" flag) (string-join add ",")))
                                   (and remove (list (concat "--remove-" flag)
                                                     (string-join remove ","))))
                           #'ignore done))
  :invalidates (lambda ()
                 `(,(octocat-model-detail-spec kind repo number)
                   (timeline-events ,repo ,number)
                   (list-items ,(if (equal kind "pr") 'pulls 'issues) ,repo _ _))))

(defconst octocat-model--reaction-query
  (concat "query($id:ID!){node(id:$id){"
          "...on Reactable{reactionGroups{content viewerHasReacted}}}}")
  "GraphQL query for the reactions you gave to a post or comment.
`gh ... view' leaves out whose they are.")

;; Kept long: only you change them, and `react' keeps them up to date.
(octocat-sync-define-resource viewer-reactions (subject)
  :max-age 3600
  :fetch (lambda (done)
           (octocat--run-gh
            "viewer-reactions"
            (list "api" "graphql" "-f" (concat "query=" octocat-model--reaction-query)
                  "-f" (concat "id=" subject))
            (lambda (output)
              (let ((groups (octocat--get (json-parse-string output) "data" "node"
                                          "reactionGroups"))
                    (tree   (make-hash-table :test #'equal)))
                (puthash "given"
                         (vconcat (delq nil (mapcar (lambda (g)
                                                      (and (eq (gethash "viewerHasReacted" g) t)
                                                           (gethash "content" g)))
                                                    groups)))
                         tree)
                tree))
            done)))

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
  :resources (lambda () (list (octocat-model-detail-spec kind repo number)
                              `(viewer-reactions ,subject)))
  :optimistic (lambda ()
                (let ((item (octocat-model-detail-read
                             (octocat-model-detail-spec kind repo number))))
                  (when (equal (octocat--get item "id") subject)
                    `((,(octocat-model-item-key (if (equal kind "pr") 'pr 'issue) repo number)
                       ("reactionGroups" . ,(octocat--toggle-reaction
                                             (gethash "reactionGroups" item) content add)))))))
  :edits (lambda (_answered _)
           (list (cons (octocat-model-detail-spec kind repo number)
                       (lambda (data) (octocat-model--react-comment data subject content add)))
                 (cons `(viewer-reactions ,subject)
                       (lambda (data)
                         (let ((given (remove content (append (gethash "given" data) nil))))
                           (puthash "given" (vconcat (if add (cons content given) given)) data)
                           data)))))
  :send (lambda (done)
          (octocat--run-gh
           "react"
           (list "api" "graphql"
                 "-f" (format (concat "query=mutation($id:ID!,$content:ReactionContent!){"
                                      "%s(input:{subjectId:$id,content:$content}){"
                                      "clientMutationId}}")
                              (if add "addReaction" "removeReaction"))
                 "-f" (concat "id=" subject)
                 "-f" (concat "content=" content))
           #'ignore done)))

;;;; Issues

(defun octocat-model--issue-parse-created (output)
  "Return the number of the issue whose URL `gh issue create' printed in OUTPUT."
  (if (string-match "/issues/\\([0-9]+\\)" output)
      (string-to-number (match-string 1 output))
    (error "No issue URL in: %s" (string-trim output))))

(octocat-sync-define-mutation create-issue (repo title body)
  :label "Creating issue…"
  :send (lambda (done)
          (octocat--run-gh "issue-create"
                           (list "issue" "create" "--repo" repo
                                 "--title" title "--body" body)
                           #'octocat-model--issue-parse-created done))
  :invalidates (lambda () `((list-items issues ,repo _ _) (counts issues ,repo)
                            (repo-summary ,repo))))

(defun octocat--fetch-issue (repo number callback)
  "Fetch detail for issue NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of issue data, or a cons \\=(error . MSG)."
  (octocat--run-gh "issue"
                   (list "issue" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "id,number,title,author,state,body,"
                                          "createdAt,closedAt,"
                                          "labels,comments,url,assignees,milestone,reactionGroups,"
                                          "closedByPullRequestsReferences"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))

(octocat-sync-define-resource issue (repo number)
  :entity (octocat-model-item-key 'issue repo number)
  :invalidates (lambda () `((list-items issues ,repo _ _) (counts issues ,repo)
                            (repo-summary ,repo)))
  :fetch (lambda (done)
           (octocat--fetch-issue
            repo number
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat-model-detail
                               r '("comments")
                               (lambda (f) (octocat-model-item 'issue repo f)))))))))

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
  :resources (lambda () `((pr ,repo ,number)))
  :send (lambda (done)
          (octocat--run-gh "merge" (octocat-model--pr-merge-args repo number method text delete)
                           #'ignore done))
  :invalidates (lambda () `((pr ,repo ,number) (timeline-events ,repo ,number)
                            (list-items pulls ,repo _ _) (counts pulls ,repo)
                            (repo-summary ,repo))))

(octocat-sync-define-mutation approve-runs (repo number ids)
  :label "Approving workflows…"
  :slot 'approve
  :resources (lambda () `((pr ,repo ,number)))
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
  :invalidates (lambda () `((pr ,repo ,number) (awaiting-runs ,repo _))))

(octocat-sync-define-mutation set-draft (repo number draft)
  :label (if draft "Converting to draft…" "Marking ready for review…")
  :slot 'merge
  :resources (lambda () `((pr ,repo ,number)))
  :optimistic (lambda ()
                `((,(octocat-model-item-key 'pr repo number) ("isDraft" . ,(if draft t :false)))))
  :send (lambda (done)
          (octocat--run-gh "ready"
                           (append (list "pr" "ready" (number-to-string number) "--repo" repo)
                                   (and draft (list "--undo")))
                           #'ignore done))
  ;; It adds an event, and may change what the merge box allows.
  :invalidates (lambda () `((pr ,repo ,number) (timeline-events ,repo ,number))))

(defun octocat--fetch-pr (repo number callback)
  "Fetch detail for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of PR data, or a cons \\=(error . MSG)."
  (octocat--run-gh "pr"
                   (list "pr" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "id,number,title,author,state,body,"
                                          "createdAt,mergedAt,closedAt,"
                                          "baseRefName,headRefName,headRepositoryOwner,"
                                          "isDraft,mergeable,mergeStateStatus,"
                                          "changedFiles,"
                                          "labels,reviewDecision,reviews,"
                                          "comments,statusCheckRollup,url,commits,"
                                          "assignees,milestone,latestReviews,reactionGroups,"
                                          "reviewRequests,closingIssuesReferences"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))

(defconst octocat-model--pr-parts
  '("comments" "reviews" "latestReviews" "reviewRequests" "commits" "statusCheckRollup")
  "The fields of a PR page's data kept with its resource, not its entity.
Pages of connections, and what belongs to the head commit, which the
lists do not share.")

(octocat-sync-define-resource pr (repo number)
  :entity (octocat-model-item-key 'pr repo number)
  :invalidates (lambda () `((list-items pulls ,repo _ _) (counts pulls ,repo)
                            (repo-summary ,repo)))
  :fetch (lambda (done)
           (octocat--fetch-pr
            repo number
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat-model-detail
                               r octocat-model--pr-parts
                               (lambda (f) (octocat-model-item 'pr repo f)))))))))

(defun octocat-model--pr-fetch-awaiting-runs (repo sha callback)
  "Fetch each workflow run of commit SHA in REPO awaiting approval.
Calls CALLBACK with a list of run hash-tables, or \=(error . MSG)."
  (octocat--run-gh "awaiting-runs"
                   (list "api" (format (concat "repos/%s/actions/runs?head_sha=%s"
                                               "&status=action_required&per_page=100")
                                       repo sha))
                   (lambda (output)
                     (append (gethash "workflow_runs"
                                      (json-parse-string (string-trim output)))
                             nil))
                   callback))

(octocat-sync-define-resource awaiting-runs (repo sha)
  :fetch (lambda (done)
           (if (not sha)
               (funcall done [])
             (octocat-model--pr-fetch-awaiting-runs
              repo sha
              (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r))))))))

(defconst octocat-model--pr-stack-query
  (concat "query($owner:String!,$name:String!,$number:Int!){"
          "repository(owner:$owner,name:$name){pullRequest(number:$number){"
          ;; A stack holds at most 100 pull requests.
          "stack{number baseRefName entries(first:100){nodes{position "
          "pullRequest{number title state isDraft mergeable}}}}}}}")
  "GraphQL query for the stack a pull request is in.")

(defun octocat-model--pr-parse-stack (output)
  "Return the stack in OUTPUT of `octocat-model--pr-stack-query'.
A hash-table whose \"stack\" is the stack, or :null when the pull request
is in none."
  (let ((out (make-hash-table :test #'equal)))
    (puthash "stack" (or (octocat--get (json-parse-string (string-trim output))
                                       "data" "repository" "pullRequest" "stack")
                         :null)
             out)
    out))

(octocat-sync-define-resource pr-stack (repo number)
  :fetch (lambda (done)
           (let ((parts (split-string repo "/")))
             (octocat--run-gh
              "pr-stack"
              (list "api" "graphql"
                    "-f" (concat "query=" octocat-model--pr-stack-query)
                    "-f" (concat "owner=" (car parts))
                    "-f" (concat "name=" (cadr parts))
                    "-F" (format "number=%d" number))
              #'octocat-model--pr-parse-stack
              done))))

(defconst octocat-model--pr-merges-query
  (concat "query($owner:String!,$name:String!,$number:Int!){"
          "repository(owner:$owner,name:$name){pullRequest(number:$number){"
          ;; The last 100: a longer PR's first commits show as plain ones.
          "commits(last:100){nodes{commit{oid parents{totalCount}}}}}}}")
  "GraphQL query for which commits of a pull request are merges.
`gh pr view' gives no commit's parents.")

(defun octocat-model--pr-parse-merges (output)
  "Return the SHAs of the merge commits in OUTPUT.
OUTPUT is the answer to `octocat-model--pr-merges-query'."
  (vconcat
   (cl-loop for node across (or (octocat--get (json-parse-string output)
                                              "data" "repository" "pullRequest" "commits" "nodes")
                                [])
            for commit = (gethash "commit" node)
            when (> (or (octocat--get commit "parents" "totalCount") 0) 1)
            collect (gethash "oid" commit))))

(octocat-sync-define-resource pr-merges (repo number)
  :fetch (lambda (done)
           (let ((parts (split-string repo "/")))
             (octocat--run-gh
              "pr-merges"
              (list "api" "graphql"
                    "-f" (concat "query=" octocat-model--pr-merges-query)
                    "-f" (concat "owner=" (car parts))
                    "-f" (concat "name=" (cadr parts))
                    "-F" (format "number=%d" number))
              #'octocat-model--pr-parse-merges
              done))))

(defun octocat-model--pr-fetch-repo-stacks (repo callback)
  "Fetch the stacks of REPO, newest first; call CALLBACK with them.
They are a hash-table whose \"stacks\" is a vector, or \=(error . MSG)."
  (octocat--run-gh "repo-stacks"
                   (list "api" (format "repos/%s/stacks?per_page=100" repo))
                   (lambda (output)
                     (let ((out (make-hash-table :test #'equal)))
                       (puthash "stacks" (json-parse-string (string-trim output)) out)
                       out))
                   callback))

(octocat-sync-define-resource repo-stacks (repo)
  :fetch (lambda (done) (octocat-model--pr-fetch-repo-stacks repo done)))

;;;; Reviews

(defun octocat--fetch-pr-diff (repo number callback)
  "Fetch the per-file diff for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a vector of file hash-tables (same shape as the
GitHub commits API \\='files\\=' array — each entry has \\='filename\\=',
\\='status\\=', \\='additions\\=', \\='deletions\\=', and \\='patch\\='),
or a cons \\=(error . MSG) on failure.
Uses the GitHub REST API via `gh api', which joins the pages into one
array; GitHub lists at most 3000 files."
  (octocat--run-gh
   "pr-diff"
   (list "api" "--paginate"
         (format "repos/%s/pulls/%d/files?per_page=100" repo number))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))

(octocat-sync-define-resource pr-files (repo number)
  :fetch (lambda (done) (octocat--fetch-pr-diff repo number done)))

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
         (review (car (append (octocat--get pr "reviews" "nodes") nil)))
         (tree  (make-hash-table :test #'equal)))
    (puthash "id" (gethash "id" pr) tree)
    (puthash "head" (gethash "headRefOid" pr) tree)
    (puthash "pending" (and review (octocat-model--review review)) tree)
    (puthash "threads"
             (apply #'vconcat
                    (mapcar (lambda (p)
                              (octocat--get p "data" "repository" "pullRequest"
                                            "reviewThreads" "nodes"))
                            pages))
             tree)
    tree))

(defun octocat-model--review (node)
  "Return the pending review NODE, from GraphQL, as a table of id and commit."
  (let ((h (make-hash-table :test #'equal)))
    (puthash "id" (gethash "id" node) h)
    (puthash "commit" (octocat--get node "commit" "oid") h)
    h))

(octocat-sync-define-resource pr-review-threads (repo number)
  :fetch (lambda (done)
           (pcase-let ((`(,owner ,name) (split-string repo "/")))
             (octocat--run-gh
              "pr-review-threads"
              (list "api" "graphql" "--paginate" "--slurp"
                    "-f" (concat "query=" octocat-model--review-threads-query)
                    "-f" (concat "owner=" owner) "-f" (concat "name=" name)
                    "-F" (format "number=%d" number))
              #'octocat-model--review-parse-threads
              done))))

;; Each change to a comment is a mutation whose edits of the
;; `pr-review-threads' show it at once, and write GitHub's answer.  The
;; threads are not refetched after a deletion: GitHub may still return
;; what was deleted for a moment.

(defun octocat-model--review-graphql (name query vars parse done)
  "Run GraphQL QUERY as `gh' call NAME with VARS, an alist; call DONE.
A string value is passed as a string, a number as a number, and a nil
one not at all.  PARSE gets the answer's \"data\"."
  (octocat--run-gh
   name
   (append (list "api" "graphql" "-f" (concat "query=" query))
           (mapcan (pcase-lambda (`(,k . ,v))
                     (cond ((null v) nil)
                           ((numberp v) (list "-F" (format "%s=%d" k v)))
                           (t (list "-f" (format "%s=%s" k v)))))
                   vars))
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
  (let ((c (make-hash-table :test #'equal))
        (author (make-hash-table :test #'equal)))
    (puthash "login" login author)
    (puthash "author" author c)
    (puthash "body" body c)
    (puthash "createdAt" (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t) c)
    (puthash "state" "PENDING" c)
    (puthash "viewerCanUpdate" t c)
    c))

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
  (let ((thread (make-hash-table :test #'equal))
        (conn   (make-hash-table :test #'equal)))
    (puthash "nodes" (vector comment) conn)
    (puthash "comments" conn thread)
    (puthash "path" (plist-get range :path) thread)
    (puthash "line" (plist-get range :line) thread)
    (puthash "diffSide" (plist-get range :side) thread)
    (puthash "startLine" (plist-get range :start-line) thread)
    (puthash "startDiffSide" (plist-get range :start-side) thread)
    (puthash "subjectType" (if (plist-get range :file) "FILE" "LINE") thread)
    thread))

(defun octocat-model-review-threads-spec (repo number)
  "Return the spec of the review threads of PR NUMBER of REPO."
  `(pr-review-threads ,repo ,number))

(octocat-sync-define-mutation review-draft-add (repo number pr-id review-id commit range body login)
  :label "Saving draft…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  ;; GitHub answers with the pending review's id and the new thread.
  :edits (lambda (answered answer)
           (list (cons (octocat-model-review-threads-spec repo number)
                       (lambda (data)
                         (when answered
                           (unless review-id
                             (let ((r (make-hash-table :test #'equal)))
                               (puthash "id" (car answer) r)
                               (puthash "commit" commit r)
                               (octocat-model--review-set-pending data r))))
                         (let ((thread (if answered
                                           (cdr answer)
                                         (octocat-model--review-new-thread
                                          range (octocat-model--review-draft body login)))))
                           (when data
                             (puthash "threads"
                                      (vconcat (gethash "threads" data) (vector thread))
                                      data)))
                         data))))
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
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (answered answer)
           (list (cons (octocat-model-review-threads-spec repo number)
                       (lambda (data)
                         (when (and answered (not review-id))
                           (let ((r (make-hash-table :test #'equal)))
                             (puthash "id" (car answer) r)
                             (puthash "commit" commit r)
                             (octocat-model--review-set-pending data r)))
                         (octocat-model--review-add-reply
                          data thread-id
                          (if answered (cdr answer) (octocat-model--review-draft body login)))))))
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
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (answered _)
           (unless answered
             (let ((c (octocat-model--review-draft body login)))
               (puthash "state" "SUBMITTED" c)
               (list (cons (octocat-model-review-threads-spec repo number)
                           (lambda (data) (octocat-model--review-add-reply data thread-id c)))))))
  :send (lambda (done)
          (octocat--run-gh "review-reply"
                           (list "api" (format "repos/%s/pulls/%d/comments/%d/replies"
                                               repo number comment-id)
                                 "-f" (concat "body=" body))
                           #'ignore done))
  :invalidates (lambda () (list (octocat-model-review-threads-spec repo number))))

(octocat-sync-define-mutation review-comment-edit (repo number node-id body)
  :label "Saving comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-model-review-threads-spec repo number)
                       (lambda (data)
                         (octocat-model--review-map-comments
                          data (lambda (c)
                                 (if (not (equal (gethash "id" c) node-id))
                                     c
                                   (let ((c (copy-hash-table c)))
                                     (puthash "body" body c)
                                     c))))))))
  :send (lambda (done)
          (octocat-model--review-graphql
           "review-comment-edit"
           (concat "mutation($id:ID!,$body:String!){updatePullRequestReviewComment("
                   "input:{pullRequestReviewCommentId:$id,body:$body}){"
                   "pullRequestReviewComment{id}}}")
           `(("id" . ,node-id) ("body" . ,body))
           #'ignore done)))

(octocat-sync-define-mutation review-comment-delete (repo number node-id)
  :label "Deleting comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-model-review-threads-spec repo number)
                       (lambda (data)
                         (octocat-model--review-map-comments
                          data (lambda (c) (unless (equal (gethash "id" c) node-id) c)))))))
  :send (lambda (done)
          (octocat-model--review-graphql
           "review-comment-delete"
           (concat "mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){"
                   "clientMutationId}}")
           `(("id" . ,node-id))
           #'ignore done)))

(octocat-sync-define-mutation review-thread-resolve (repo number thread-id resolve)
  :label (if resolve "Resolving…" "Unresolving…")
  :slot 'inline
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (answered answer)
           (list (cons (octocat-model-review-threads-spec repo number)
                       (lambda (data)
                         (octocat-model--review-map-threads
                          data (lambda (thread)
                                 (cond ((not (equal (gethash "id" thread) thread-id)) thread)
                                       (answered answer)
                                       (t (let ((thread (copy-hash-table thread)))
                                            (puthash "isResolved" (and resolve t) thread)
                                            thread)))))))))
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
  :resources (lambda () (list (octocat-model-review-threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-model-review-threads-spec repo number)
                       #'octocat-model--review-drop-drafts)))
  :send (lambda (done)
          (octocat-model--review-graphql
           "review-discard"
           (concat "mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){"
                   "clientMutationId}}")
           `(("id" . ,review-id))
           #'ignore done)))

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
  :resources (lambda () `((pr ,repo ,number) ,(octocat-model-review-threads-spec repo number)))
  ;; The drafts are no longer drafts.
  :edits (lambda (_answered _)
           (when review-id
             (list (cons (octocat-model-review-threads-spec repo number)
                         (lambda (data)
                           (octocat-model--review-set-pending
                            (octocat-model--review-map-comments
                             data (lambda (c)
                                    (if (not (equal (gethash "state" c) "PENDING"))
                                        c
                                      (let ((c (copy-hash-table c)))
                                        (puthash "state" "SUBMITTED" c)
                                        c))))
                            nil))))))
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
  :invalidates (lambda () `((pr ,repo ,number) (timeline-events ,repo ,number)
                            ,(octocat-model-review-threads-spec repo number))))

;;;; Commits and compares

(defun octocat--fetch-commit (repo sha callback)
  "Fetch commit detail for SHA in REPO asynchronously.
Calls CALLBACK with a single hash-table of commit data, or the
symbol `error'.  Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "commit"
   (list "api"
         (format "repos/%s/commits/%s" repo sha))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))

(defun octocat--fetch-commit-comments (repo sha callback)
  "Fetch all comments on commit SHA in REPO asynchronously.
Calls CALLBACK with a list of comment hash-tables (snake_case REST API
keys), or a cons \\=(error . MSG) on failure.  The list includes both
general comments (\\='path\\=' is :null or nil) and inline comments
\(\\='path\\=' is a file path string, \\='line\\=' is the target line number)."
  (octocat--run-gh
   "commit-comments"
   (list "api"
         (format "repos/%s/commits/%s/comments" repo sha))
   #'octocat--parse-json-list
   callback))

(octocat-sync-define-resource commit (repo sha)
  ;; What a SHA names never changes.
  :max-age (* 30 24 60 60)
  :fetch (lambda (done) (octocat--fetch-commit repo sha done)))

(octocat-sync-define-resource commit-comments (repo sha)
  :fetch (lambda (done)
           (octocat--fetch-commit-comments
            repo sha
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

;; Not REST: it has no way to ask whether a branch holds a commit.
(defconst octocat-model--commit-branch-query
  (concat "query($owner:String!,$name:String!,$sha:String!){repository(owner:$owner,"
          "name:$name){defaultBranchRef{name compare(headRef:$sha){status}}}}")
  "GraphQL query behind the `commit-branch' resource.")

(defun octocat-model--commit-parse-branch (json-string)
  "Parse JSON-STRING, the response to `octocat-model--commit-branch-query'.
Return a hash-table whose \"name\" is the default branch when it holds
the commit, the commit being behind it or at its head, else :null."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (ref  (and (hash-table-p repo) (gethash "defaultBranchRef" repo)))
         (cmp  (and (hash-table-p ref) (gethash "compare" ref)))
         (out  (make-hash-table :test #'equal)))
    (puthash "name"
             (if (and (hash-table-p cmp)
                      (member (gethash "status" cmp) '("BEHIND" "IDENTICAL")))
                 (gethash "name" ref)
               :null)
             out)
    out))

(octocat-sync-define-resource commit-branch (repo sha)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (let ((parts (split-string repo "/")))
             (octocat--run-gh
              "commit-branch"
              (list "api" "graphql"
                    "-f" (concat "query=" octocat-model--commit-branch-query)
                    "-f" (concat "owner=" (car parts))
                    "-f" (concat "name=" (cadr parts))
                    "-f" (concat "sha=" sha))
              #'octocat-model--commit-parse-branch
              done))))

(defun octocat-model-compare-sha-p (ref)
  "Return non-nil when REF is a commit SHA, as a commit link's is.
Unlike a branch or tag, it names the same commit for good."
  (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" ref))

(octocat-sync-define-resource compare (repo base head)
  ;; Comparing two commits never changes, as a commit doesn't; refs move.
  :max-age (and (octocat-model-compare-sha-p base)
                (octocat-model-compare-sha-p head)
                (* 30 24 60 60))
  :fetch (lambda (done)
           (octocat--run-gh
            "compare"
            (list "api" (format "repos/%s/compare/%s...%s" repo base head))
            (lambda (output) (json-parse-string (string-trim output)))
            done)))

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
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "commits"
     (append (list "api" "graphql"
                   "-f" (concat "query=" octocat-model--repo-history-query)
                   "-f" (concat "owner=" (car parts))
                   "-f" (concat "name=" (cadr parts))
                   "-f" (concat "ref=" (or ref "HEAD"))
                   "-F" (format "limit=%d" octocat-repo-commits-page-size))
             (and after (list "-f" (concat "after=" after)))
             (and path (list "-f" (concat "path=" path))))
     #'octocat-model--repo-parse-history
     callback)))

(defun octocat-model--repo-history-commit (node)
  "Return the commit NODE of a GraphQL history shaped as REST has it.
That is what the rows read: \"sha\"; \"commit\", with the \"message\"
\(its headline only), the git \"author\" (name, email, date) and the
\"committer\" (date); \"author\", the GitHub user or :null; and, when
NODE has them, the SHAs of its \"parents\", for the graph beside it."
  (let* ((a      (gethash "author" node))
         (user   (and (hash-table-p a) (gethash "user" a)))
         (git    (make-hash-table :test #'equal))
         (by     (make-hash-table :test #'equal))
         (c      (make-hash-table :test #'equal))
         (commit (make-hash-table :test #'equal)))
    (when (hash-table-p a)
      (puthash "name" (gethash "name" a) git)
      (puthash "email" (gethash "email" a) git))
    (puthash "date" (gethash "authoredDate" node) git)
    (puthash "date" (gethash "committedDate" node) by)
    (puthash "message" (gethash "messageHeadline" node) c)
    (puthash "author" git c)
    (puthash "committer" by c)
    (puthash "sha" (gethash "oid" node) commit)
    (puthash "commit" c commit)
    (puthash "author" (if (hash-table-p user) user :null) commit)
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
  "GraphQL query behind `octocat-model--repo-fetch-head'.")

(defun octocat-model--repo-parse-head (json-string ref path)
  "Parse the response JSON-STRING of `octocat-model--repo-head-query'.
It is for PATH, nil for the root, at REF.  Return the last commit that
touched PATH, as `octocat-model--repo-history-commit' shapes it, with
\"tree\", the SHA of PATH's tree, or its blob's when \"kind\" is
\"blob\", and \"total\", the commits that touched PATH.  Of a blob,
\"size\" is its bytes and \"binary\" t when it is not text."
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
    (let ((commit (octocat-model--repo-history-commit node)))
      (puthash "tree" (gethash "oid" dir) commit)
      (puthash "kind" (if (equal (gethash "__typename" dir) "Blob") "blob" "tree") commit)
      (puthash "total" (gethash "totalCount" hist) commit)
      (puthash "size" (gethash "byteSize" dir) commit)
      (puthash "binary" (eq (gethash "isBinary" dir) t) commit)
      commit)))

(defun octocat-model--repo-fetch-head (repo ref path callback)
  "Fetch the last commit and the tree of PATH of REPO at REF.
REF is a branch, tag or SHA, as on github.com, nil for the default
branch; PATH nil is the root.  Calls CALLBACK with the commit from
`octocat-model--repo-parse-head', or a cons \\=(error . MSG)."
  (let ((parts (split-string repo "/"))
        (rev   (or ref "HEAD")))
    (octocat--run-gh
     "repo-head"
     (append (list "api" "graphql"
                   "-f" (concat "query=" octocat-model--repo-head-query)
                   "-f" (concat "owner=" (car parts))
                   "-f" (concat "name=" (cadr parts))
                   ;; Peels an annotated tag to its commit.
                   "-f" (concat "expr=" rev "^{commit}")
                   "-f" (concat "dir=" rev ":" path))
             (and path (list "-f" (concat "path=" path))))
     (lambda (json) (octocat-model--repo-parse-head json ref path))
     callback)))

(octocat-sync-define-resource repo-head (repo ref path)
  :fetch (lambda (done) (octocat-model--repo-fetch-head repo ref path done)))

(defconst octocat-model--repo-blame-query
  (concat "query($owner:String!,$name:String!,$expr:String!,$path:String!){"
          "repository(owner:$owner,name:$name){object(expression:$expr){...on Commit{"
          "blame(path:$path){ranges{startingLine endingLine commit{oid messageHeadline "
          "authoredDate committedDate author{name email user{login}}}}}}}}}")
  "GraphQL query behind `octocat-model--repo-fetch-blame'.")

(defun octocat-model--repo-parse-blame (json-string)
  "Parse the response JSON-STRING of `octocat-model--repo-blame-query'.
Return its ranges, a vector of hash-tables of \"start\" and \"end\",
the first and last line, and \"commit\", the commit that last changed
them, as `octocat-model--repo-history-commit' shapes it."
  (let* ((repo  (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (obj   (and (hash-table-p repo) (gethash "object" repo)))
         (blame (and (hash-table-p obj) (gethash "blame" obj))))
    (unless (hash-table-p blame)
      (error "No such commit"))
    (vconcat
     (mapcar (lambda (r)
               (let ((h (make-hash-table :test #'equal)))
                 (puthash "start" (gethash "startingLine" r) h)
                 (puthash "end" (gethash "endingLine" r) h)
                 (puthash "commit" (octocat-model--repo-history-commit (gethash "commit" r)) h)
                 h))
             (gethash "ranges" blame)))))

(defun octocat-model--repo-fetch-blame (repo commit path callback)
  "Fetch the blame of file PATH of REPO at COMMIT.
Calls CALLBACK with the ranges of `octocat-model--repo-parse-blame', or a
cons \\=(error . MSG)."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "blame"
     (list "api" "graphql"
           "-f" (concat "query=" octocat-model--repo-blame-query)
           "-f" (concat "owner=" (car parts))
           "-f" (concat "name=" (cadr parts))
           "-f" (concat "expr=" commit)
           "-f" (concat "path=" path))
     #'octocat-model--repo-parse-blame
     callback)))

(octocat-sync-define-resource blame (repo commit path)
  ;; COMMIT names the history, so what it says never changes.
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done) (octocat-model--repo-fetch-blame repo commit path done)))

;; Directory listings and file contents are named by tree and blob SHA,
;; which name fixed contents, so they are kept for
;; `octocat-model--fixed-max-age'.  The tree of a directory at a ref comes
;; with its last commit, the repo page's `repo-head' resource.

(defun octocat-model--tree-fetch-dir (repo sha callback)
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
  (let* ((parts  (split-string repo "/"))
         (chunks (seq-partition paths octocat-model--tree-last-commits-chunk))
         (left   (length chunks))
         (out    (make-hash-table :test #'equal))
         failed)
    (if (null chunks)
        (funcall callback out)
      (dolist (chunk chunks)
        (octocat--run-gh
         "tree-commits"
         (append (list "api" "graphql"
                       "-f" (concat "query="
                                    (octocat-model--tree-last-commits-query (length chunk)))
                       "-f" (concat "owner=" (car parts))
                       "-f" (concat "name=" (cadr parts))
                       "-f" (concat "expr=" commit))
                 (seq-mapcat (lambda (i) (list "-f" (format "p%d=%s" i (nth i chunk))))
                             (number-sequence 0 (1- (length chunk)))))
         (lambda (json) (octocat-model--tree-parse-last-commits json chunk))
         (lambda (r)
           (if (eq (car-safe r) 'error)
               (setq failed r)
             (maphash (lambda (k v) (puthash k v out)) r))
           (when (zerop (cl-decf left))
             (funcall callback (or failed out)))))))))

(octocat-sync-define-resource tree-dir (repo sha)
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done) (octocat-model--tree-fetch-dir repo sha done)))

(octocat-sync-define-resource tree-commits (repo commit dir sha)
  ;; COMMIT names the history, so what it says never changes.
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done)
           ;; No COMMIT yet: the page asks before it knows it.
           (if (null commit)
               (funcall done (make-hash-table :test #'equal))
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

(octocat-sync-define-resource tree-files (repo sha)
  :max-age octocat-model--fixed-max-age
  :fetch (lambda (done)
           (octocat-model--tree-fetch-all-files
            repo sha
            (lambda (r)
              (funcall done
                       (if (eq (car-safe r) 'error)
                           r
                         (let ((h (make-hash-table :test #'equal :size (length r))))
                           (pcase-dolist (`(,path . ,blob) r)
                             (puthash path blob h))
                           h)))))))

(defun octocat-model-tree-join (dir name)
  "Return the path of NAME inside directory path DIR (\"\" for the root)."
  (if (string-empty-p dir) name (concat dir "/" name)))

(octocat-sync-define-resource commits (repo ref path)
  :fetch (lambda (done)
           (octocat-model-repo-list-commits
            repo ref path
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

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

(defun octocat--fetch-job (repo run-id job-id callback)
  "Fetch job detail, log, annotations, and artifacts for JOB-ID in REPO.
RUN-ID is the numeric workflow run ID (used for the artifacts request).
Calls CALLBACK asynchronously with a hash-table, which the sync store
can store as JSON, of:
- \"job\", a hash-table from the GitHub REST API.
- \"log\", the raw `gh run view --log' text (see `octocat--job-parse-log'),
  or \"log_error\", the message when the log is unavailable.
- \"annotations\", a vector of annotation hash-tables from the Checks API
  (GET /check-runs/JOB-ID/annotations), \\=[] when unavailable.
- \"artifacts\", a vector of artifact hash-tables from the Actions API
  (GET /actions/runs/RUN-ID/artifacts), \\=[] when unavailable.
A job-metadata failure is fatal and CALLBACK receives \\=(error . MSG)."
  (let ((job-result 'pending)
        (log-result 'pending)
        (ann-result 'pending)
        (art-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq job-result 'pending)
                       (eq log-result 'pending)
                       (eq ann-result 'pending)
                       (eq art-result 'pending))
             ;; Metadata failure aborts the whole view; log/annotation/
             ;; artifact failures are passed through and rendered gracefully.
             (if (eq (car-safe job-result) 'error)
                 (funcall callback job-result)
               (let ((h (make-hash-table :test #'equal)))
                 (puthash "job" job-result h)
                 (if (eq (car-safe log-result) 'error)
                     (puthash "log_error" (cdr log-result) h)
                   (puthash "log" log-result h))
                 (puthash "annotations" ann-result h)
                 (puthash "artifacts" art-result h)
                 (funcall callback h))))))
      (octocat--run-gh
       "job-detail"
       (list "api" (format "repos/%s/actions/jobs/%s" repo
                           (number-to-string job-id)))
       (lambda (output) (json-parse-string (string-trim output)))
       (lambda (result) (setq job-result result) (maybe-done)))
      (octocat--run-gh
       "job-log"
       (list "run" "view"
             "--log"
             "--job" (number-to-string job-id)
             "--repo" repo)
       #'identity
       (lambda (result) (setq log-result result) (maybe-done)))
      (octocat--run-gh
       "job-annotations"
       (list "api"
             (format "repos/%s/check-runs/%s/annotations?per_page=100"
                     repo (number-to-string job-id)))
       (lambda (output)
         (condition-case nil
             (let ((parsed (json-parse-string (string-trim output))))
               (if (vectorp parsed) parsed []))
           (error [])))
       (lambda (result)
         (setq ann-result (if (eq (car-safe result) 'error) [] result))
         (maybe-done)))
      (if (not run-id)
          (progn (setq art-result []) (maybe-done))
        (octocat--run-gh
         "job-artifacts"
         (list "api"
               (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                       repo (number-to-string run-id)))
         (lambda (output)
           (condition-case nil
               (let ((parsed (json-parse-string (string-trim output))))
                 (or (and (hash-table-p parsed)
                          (gethash "artifacts" parsed))
                     []))
             (error [])))
         (lambda (result)
           (setq art-result (if (eq (car-safe result) 'error) [] result))
           (maybe-done)))))))

(octocat-sync-define-resource job (repo run-id job-id)
  :poll (lambda (data) (octocat-sync-poll-status (octocat--get data "job" "status")))
  :fetch (lambda (done) (octocat--fetch-job repo run-id job-id done)))

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
           (lambda (output)
             (condition-case nil
                 (let ((parsed (json-parse-string (string-trim output))))
                   (if (vectorp parsed) parsed []))
               (error [])))
           (lambda (ann-result)
             (let ((anns (if (eq (car-safe ann-result) 'error) [] ann-result)))
               (push (list job-id job-name anns) results))
             (cl-decf pending)
             ;; In the jobs' order, not the order their answers came in.
             (when (zerop pending)
               (funcall callback
                        (mapcar (lambda (job) (assq (gethash "databaseId" job) results))
                                job-list))))))))))

(defun octocat--fetch-run-artifacts (repo run-id callback)
  "Fetch artifacts for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a vector of artifact hash-tables, or \\=[] on failure."
  (octocat--run-gh
   "run-artifacts"
   (list "api"
         (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                 repo (number-to-string run-id)))
   (lambda (output)
     (condition-case nil
         (let ((parsed (json-parse-string (string-trim output))))
           (or (and (hash-table-p parsed)
                    (gethash "artifacts" parsed))
               []))
       (error [])))
   (lambda (result)
     (funcall callback (if (eq (car-safe result) 'error) [] result)))))

(defun octocat-model--run-annotation-entries (results)
  "Return the RESULTS of `octocat--fetch-run-annotations' as a vector.
Each entry is a hash-table of \"job\", its name, and \"annotations\", a
vector: a shape the store can hold as JSON."
  (vconcat
   (mapcar (lambda (r)
             (let ((h (make-hash-table :test #'equal)))
               (puthash "job" (nth 1 r) h)
               (puthash "annotations" (nth 2 r) h)
               h))
           results)))

(octocat-sync-define-resource run (repo run-id)
  :entity (format "run:%s/%s" (downcase repo) run-id)
  ;; Annotations come as the run's jobs finish.
  :invalidates (lambda () `((runs ,repo _ _) (workflow ,repo _ _)
                            (run-annotations ,repo ,run-id)))
  :poll (lambda (data) (octocat-sync-poll-status (octocat--get data "item" "status")))
  :fetch (lambda (done)
           (octocat--fetch-run
            repo run-id
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (octocat-model-detail r '("jobs")
                                                    (lambda (f) (octocat-model-run repo f)))))))))

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

(octocat-sync-define-resource run-artifacts (repo run-id)
  :fetch (lambda (done) (octocat--fetch-run-artifacts repo run-id done)))

(defun octocat-model--run-list-runs (repo limit callback &optional args)
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
          "--json"  (concat "databaseId,number,displayTitle,status,conclusion,createdAt,"
                            "headBranch,workflowName,workflowDatabaseId"))
    args)
   #'octocat--parse-json-list
   callback))

(octocat-sync-define-resource runs (repo limit args)
  ;; ARGS are `gh run list' options filtering the runs.
  :fetch (lambda (done)
           (octocat-model--run-list-runs
            repo limit
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (let ((tree (make-hash-table :test #'equal)))
                                (puthash "nodes"
                                         (vconcat (mapcar (lambda (run)
                                                            (octocat-model-run repo run))
                                                          r))
                                         tree)
                                tree))))
            args)))

(defun octocat--fetch-workflow (repo id callback)
  "Fetch workflow ID of REPO asynchronously.
Calls CALLBACK with a hash-table of it, or a cons \\=(error . MSG)."
  (octocat--run-gh
   "workflow-detail"
   (list "api" (format "repos/%s/actions/workflows/%s" repo id))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))

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

(octocat-sync-define-resource workflow-jobs (repo path sha)
  ;; A file at a commit never changes.
  :max-age (* 30 24 60 60)
  :fetch (lambda (done)
           (octocat--run-gh
            "workflow-file"
            (list "api" "-X" "GET"
                  (format "repos/%s/contents/%s" repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
                  "-f" (concat "ref=" sha)
                  "-H" "Accept: application/vnd.github.raw")
            #'octocat-model--workflow-yaml-jobs
            done)))

(octocat-sync-define-resource workflow-dispatch (repo path ref)
  :max-age 300
  :poll 300
  :fetch (lambda (done)
           (octocat--run-gh
            "workflow-file"
            (list "api" "-X" "GET"
                  (format "repos/%s/contents/%s" repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
                  "-f" (concat "ref=" ref)
                  "-H" "Accept: application/vnd.github.raw")
            #'octocat-model--workflow-dispatch-spec
            done)))

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
  :resources (lambda () `((workflow ,repo ,id)))
  :send (lambda (done)
          (octocat--run-gh "workflow-dispatch"
                           (append (list "api" "--method" "POST"
                                         (format "repos/%s/actions/workflows/%s/dispatches"
                                                 repo id)
                                         "-f" (concat "ref=" ref)
                                         "-F" "return_run_details=true")
                                   (mapcan (pcase-lambda (`(,name . ,value))
                                             (list "-f" (format "inputs[%s]=%s" name value)))
                                           inputs))
                           #'octocat-model--workflow-parse-dispatched done))
  :invalidates (lambda () `((runs ,repo _ _))))

(octocat-sync-define-resource workflow (repo id)
  :fetch (lambda (done) (octocat--fetch-workflow repo id done)))

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
  :fetch (lambda (done)
           (octocat-model--workflow-list
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(defun octocat--fetch-checks (repo sha callback)
  "Fetch all check-runs for SHA in REPO asynchronously.
Calls CALLBACK with a list of check-run hash-tables (snake_case keys from
the GitHub Checks REST API), or a cons \\=(error . MSG) on failure.
Requests up to 100 check-runs; pagination is not yet supported."
  (octocat--run-gh
   "checks"
   (list "api"
         (format "repos/%s/commits/%s/check-runs?per_page=100" repo sha))
   (lambda (output)
     (let* ((parsed (json-parse-string (string-trim output)))
            (runs   (and (hash-table-p parsed)
                         (gethash "check_runs" parsed))))
       (cond
        ((null runs)    '())
        ((vectorp runs) (cl-coerce runs 'list))
        (t              '()))))
   callback))

(octocat-sync-define-resource checks (repo sha)
  ;; None yet: they may still start.
  :poll (lambda (data)
          (if (seq-empty-p data)
              octocat-sync-poll-interval
            (apply #'octocat-sync-poll-status
                   (mapcar (lambda (c) (gethash "status" c)) data))))
  :fetch (lambda (done)
           (octocat--fetch-checks
            repo sha
            (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

;;;; Dashboard

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
                 (puthash "item" (octocat-model-item type repo item) node)
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

(octocat-sync-define-resource dashboard-repos ()
  :fetch (lambda (done)
           (octocat--fetch-recent-repos
            (lambda (r)
              (funcall done (if (eq (car-safe r) 'error)
                                r
                              (cl-map 'vector #'octocat-model-repo-rest r)))))))

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

;;;; Users

(defun octocat-model--user-table (&rest pairs)
  "Return a hash table of PAIRS, alternating keys and values."
  (let ((h (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) h))
    h))

(defun octocat-model--user-parse-profile (json-string)
  "Parse the `users/LOGIN' response JSON-STRING into the profile resource.
The user is an entity; the counts belong to this resource."
  (let ((p (json-parse-string json-string :null-object nil)))
    (octocat-model--user-table
     "user" (octocat-sync-entity
             'user (concat "user:" (downcase (gethash "login" p)))
             (octocat-model--user-table
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
     "publicRepos" (gethash "public_repos" p))))

(defun octocat-model--user-parse-repos (json-string)
  "Parse the `users/LOGIN/repos' response JSON-STRING into a list resource."
  (octocat-model--user-table
   "nodes" (cl-map 'vector #'octocat-model-repo-rest
                   (json-parse-string json-string :null-object nil))))

(defconst octocat-model--user-pinned-query
  (concat "query($login:String!){repositoryOwner(login:$login){... on ProfileOwner{"
          "pinnedItems(first:6,types:REPOSITORY){nodes{... on Repository{nameWithOwner "
          "description stargazerCount primaryLanguage{name} pushedAt isFork "
          "isArchived}}}}}}")
  "GraphQL query behind the `user-pinned' resource.
The REST API does not expose pinned repositories.")

(defun octocat-model--user-parse-pinned (json-string)
  "Parse the GraphQL response JSON-STRING into a list resource.
Pinned gists, which come back as empty nodes, are left out."
  (let* ((data  (gethash "data" (json-parse-string json-string :null-object nil)))
         (owner (and data (gethash "repositoryOwner" data)))
         (items (and owner (gethash "pinnedItems" owner)))
         (nodes (and items (gethash "nodes" items))))
    (octocat-model--user-table
     "nodes" (vconcat (delq nil (mapcar (lambda (node)
                                          (and node (gethash "nameWithOwner" node)
                                               (octocat-model-repo node)))
                                        nodes))))))

(octocat-sync-define-resource user-profile (login)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--run-gh "user-profile" (list "api" (format "users/%s" login))
                            #'octocat-model--user-parse-profile done)))

(octocat-sync-define-resource user-repos (login limit)
  :poll octocat-sync-poll-slow
  ;; The limit is in the URL so that `gh api' issues a GET.
  :fetch (lambda (done)
           (octocat--run-gh "user-repos"
                            (list "api" (format "users/%s/repos?sort=pushed&per_page=%d"
                                                login limit))
                            #'octocat-model--user-parse-repos done)))

(octocat-sync-define-resource user-pinned (login)
  :poll octocat-sync-poll-slow
  :fetch (lambda (done)
           (octocat--run-gh "user-pinned"
                            (list "api" "graphql"
                                  "-f" (concat "query=" octocat-model--user-pinned-query)
                                  "-F" (concat "login=" login))
                            #'octocat-model--user-parse-pinned done)))

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
  :fetch (lambda (done)
           (octocat--run-gh
            "search-objects"
            (list "search" type (format "--repo=%s" repo)
                  "--json" (alist-get type octocat-model--search-fields nil nil #'equal)
                  "--limit" "30" query)
            (lambda (output) (vconcat (octocat--parse-json-list output)))
            done)))

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
              repo "HEAD"
              (lambda (r)
                (funcall done
                         (if (eq (car-safe r) 'error)
                             r
                           (let ((h (make-hash-table :test #'equal :size (length r))))
                             (pcase-dolist (`(,path . ,blob) r)
                               (puthash path blob h))
                             h))))))))

(provide 'octocat-model)
;;; octocat-model.el ends here
