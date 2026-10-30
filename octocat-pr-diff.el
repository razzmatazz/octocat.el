;;; octocat-pr-diff.el --- PR diff view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
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

;; Full-diff view for a GitHub Pull Request, opened by pressing RET on the
;; "Changes" line of the PR page (`octocat-pr-mode').  Fetches per-file
;; patches from the REST API and the review threads from GraphQL, and
;; renders one collapsible section per file.
;;
;; Rendered with vui.el (https://github.com/d12frosted/vui.el), like the PR
;; page itself.  The two fetches are independent resources, so the diff
;; shows as soon as the files arrive and the review comments appear in it
;; when theirs do.  Each file is a component of its own, whose patch text
;; is only rebuilt when that file or its comments change.
;;
;; A review is written here as on GitHub's "Files changed": comments on
;; lines are drafts in your pending review, which GitHub keeps, until the
;; review is submitted or discarded.
;;
;; The files themselves are rendered by octocat-diff.el, shared with the
;; commit page.  Must not depend on octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-diff)
(require 'octocat-edit)
(require 'octocat-sync)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-pr--use-data "octocat-pr" (repo number tick))
(declare-function octocat-pr--header "octocat-pr" (repo pr bg width &optional tab stack))
(declare-function octocat-pr--use-stack "octocat-pr" (repo number tick))
(declare-function octocat-pr--current "octocat-pr" ())
(declare-function octocat-pr--busy "octocat-pr" (repo number slot))
(declare-function octocat-pr-merge "octocat-pr" ())
(declare-function octocat-pr--tabs "octocat-pr" (current repo number width &optional files commits))


;;;; Buffer-local declarations

(defvar-local octocat--pr-diff-repo nil
  "The \"owner/repo\" this PR diff buffer belongs to.")

(defvar-local octocat--pr-diff-number nil
  "The PR number this buffer is displaying a diff for.")


;;;; Data fetching

(defun octocat--fetch-pr-diff (repo number callback)
  "Fetch the per-file diff for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a vector of file hash-tables (same shape as the
GitHub commits API \\='files\\=' array — each entry has \\='filename\\=',
\\='status\\=', \\='additions\\=', \\='deletions\\=', and \\='patch\\='),
or a cons \\=(error . MSG) on failure.
Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "pr-diff"
   (list "api"
         (format "repos/%s/pulls/%d/files" repo number))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))

(octocat-sync-define-resource pr-files (repo number)
  :fetch (lambda (done) (octocat--fetch-pr-diff repo number done)))

;; The review comments are read as GitHub's threads, from GraphQL: REST
;; has no thread, whose id replying and resolving need, and no drafts.
;; Your drafts are the comments of your pending review, which only you
;; see; they come with the threads.

(defconst octocat-pr-diff--comment-fields
  (concat "id databaseId body createdAt state viewerDidAuthor viewerCanUpdate "
          "viewerCanDelete author{login} replyTo{databaseId} "
          "reactionGroups{content users{totalCount}}")
  "The fields of a review comment read from GraphQL.")

(defconst octocat-pr-diff--thread-fields
  (concat "id isResolved isOutdated path line startLine diffSide startDiffSide "
          "subjectType viewerCanReply viewerCanResolve viewerCanUnresolve "
          "resolvedBy{login} comments(first:100){nodes{"
          octocat-pr-diff--comment-fields "}}")
  "The fields of a review thread read from GraphQL.")

(defconst octocat-pr-diff--threads-query
  (concat "query($owner:String!,$name:String!,$number:Int!,$endCursor:String){"
          "repository(owner:$owner,name:$name){pullRequest(number:$number){"
          "id headRefOid reviews(states:PENDING,first:1){nodes{id commit{oid}}} "
          "reviewThreads(first:50,after:$endCursor){nodes{"
          octocat-pr-diff--thread-fields
          "} pageInfo{hasNextPage endCursor}}}}}")
  "GraphQL query for a PR's review threads and your pending review.")

(defun octocat-pr-diff--parse-threads (output)
  "Return the review threads of OUTPUT, `gh api --paginate --slurp's pages.
That is a table of the PR's \"id\", its \"head\" commit, the
\"threads\" of all pages, and \"pending\", your pending review, a table
of its \"id\" and \"commit\", or nil."
  (let* ((pages (append (json-parse-string output) nil))
         (pr    (octocat--get (car pages) "data" "repository" "pullRequest"))
         (review (seq-first (octocat--get pr "reviews" "nodes")))
         (tree  (make-hash-table :test #'equal)))
    (puthash "id" (gethash "id" pr) tree)
    (puthash "head" (gethash "headRefOid" pr) tree)
    (puthash "pending" (and review (octocat-pr-diff--review review)) tree)
    (puthash "threads"
             (apply #'vconcat
                    (mapcar (lambda (p)
                              (octocat--get p "data" "repository" "pullRequest"
                                            "reviewThreads" "nodes"))
                            pages))
             tree)
    tree))

(defun octocat-pr-diff--review (node)
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
                    "-f" (concat "query=" octocat-pr-diff--threads-query)
                    "-f" (concat "owner=" owner) "-f" (concat "name=" name)
                    "-F" (format "number=%d" number))
              #'octocat-pr-diff--parse-threads
              done))))

(defun octocat-pr-diff--null (v)
  "Return V, or nil for JSON's null."
  (unless (eq v :null) v))

(defun octocat-pr-diff--thread-comments (threads)
  "Return the comments of review THREADS, from GraphQL, as `octocat-diff' takes.
That is a vector in the REST shape (\"id\", \"path\", \"line\",
\"side\", \"user\", \"in_reply_to_id\" the first comment's id...), each
also carrying its \"node_id\" and \"thread_id\", \"pending\" for a
draft and \"can_edit\" for one you may edit.  The first comment of a
thread also has its \"resolved\", \"resolved_by\", \"can_resolve\" and
\"can_unresolve\"."
  (let (out)
    (seq-doseq (thread threads)
      (let ((root-id nil))
        (seq-doseq (c (octocat--get thread "comments" "nodes"))
          (let ((h    (make-hash-table :test #'equal))
                (user (make-hash-table :test #'equal))
                (line  (octocat-pr-diff--null (gethash "line" thread)))
                (start (octocat-pr-diff--null (gethash "startLine" thread))))
            (puthash "login" (octocat--get c "author" "login") user)
            (puthash "id" (octocat-pr-diff--null (gethash "databaseId" c)) h)
            (puthash "node_id" (gethash "id" c) h)
            (puthash "thread_id" (gethash "id" thread) h)
            (puthash "path" (gethash "path" thread) h)
            (puthash "line" line h)
            (puthash "side" (octocat-pr-diff--null (gethash "diffSide" thread)) h)
            (when (and start (not (eql start line)))
              (puthash "start_line" start h)
              (puthash "start_side" (octocat-pr-diff--null (gethash "startDiffSide" thread)) h))
            (puthash "subject_type"
                     (downcase (or (octocat-pr-diff--null (gethash "subjectType" thread)) "line"))
                     h)
            (puthash "body" (string-replace "\r\n" "\n" (or (gethash "body" c) "")) h)
            (puthash "created_at" (gethash "createdAt" c) h)
            (puthash "user" user h)
            (puthash "reactionGroups" (gethash "reactionGroups" c) h)
            (puthash "pending" (equal (gethash "state" c) "PENDING") h)
            (puthash "can_edit" (eq (gethash "viewerCanUpdate" c) t) h)
            (if root-id
                (puthash "in_reply_to_id" root-id h)
              (setq root-id (or (gethash "id" h) 0))
              (puthash "resolved" (eq (gethash "isResolved" thread) t) h)
              (puthash "resolved_by" (octocat--get thread "resolvedBy" "login") h)
              ;; A draft's thread is not one yet.
              (puthash "can_resolve" (and (eq (gethash "viewerCanResolve" thread) t)
                                          (not (gethash "pending" h)))
                       h)
              (puthash "can_unresolve" (eq (gethash "viewerCanUnresolve" thread) t) h))
            (push h out)))))
    (vconcat (nreverse out))))

(defun octocat-pr-diff--pending-count (data)
  "Return the count of draft comments in DATA, the `pr-review-threads'."
  (let ((n 0))
    (seq-doseq (thread (and data (gethash "threads" data)))
      (seq-doseq (c (octocat--get thread "comments" "nodes"))
        (when (equal (gethash "state" c) "PENDING") (cl-incf n))))
    n))


;;;; Changing the threads
;;
;; Each change to a comment is a mutation whose edits of the
;; `pr-review-threads' show it at once, and write GitHub's answer.  The
;; threads are not refetched after a deletion: GitHub may still return
;; what was deleted for a moment.

(defun octocat-pr-diff--graphql (name query vars parse done)
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

(defun octocat-pr-diff--with-review (pr-id review-id commit k)
  "Call K with REVIEW-ID, or the id of a pending review started at COMMIT.
PR-ID is the PR's node id.  K is called with (error . MESSAGE) instead
when the review cannot be started."
  (if review-id
      (funcall k review-id)
    (octocat-pr-diff--graphql
     "review-start"
     (concat "mutation($pr:ID!,$commit:GitObjectID){addPullRequestReview("
             "input:{pullRequestId:$pr,commitOID:$commit}){pullRequestReview{id commit{oid}}}}")
     `(("pr" . ,pr-id) ("commit" . ,commit))
     (lambda (data) (octocat--get data "addPullRequestReview" "pullRequestReview"))
     (lambda (review)
       (funcall k (if (eq (car-safe review) 'error) review (gethash "id" review)))))))

(defun octocat-pr-diff--draft (body login)
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

(defun octocat-pr-diff--map-threads (data fn)
  "Return DATA, the `pr-review-threads', its threads replaced by FN's.
FN gets each thread and returns it, changed, or nil to drop it."
  (when data
    (puthash "threads" (vconcat (delq nil (mapcar fn (append (gethash "threads" data) nil))))
             data))
  data)

(defun octocat-pr-diff--map-comments (data fn)
  "Return DATA, the `pr-review-threads', each comment replaced by FN's.
FN gets each comment and returns it, changed, or nil to drop it; a
thread left with no comment is dropped."
  (octocat-pr-diff--map-threads
   data
   (lambda (thread)
     (let* ((thread (copy-hash-table thread))
            (conn   (copy-hash-table (gethash "comments" thread)))
            (nodes  (delq nil (mapcar fn (append (gethash "nodes" conn) nil)))))
       (puthash "nodes" (vconcat nodes) conn)
       (puthash "comments" conn thread)
       (and nodes thread)))))

(defun octocat-pr-diff--set-pending (data review)
  "Return DATA, the `pr-review-threads', with REVIEW as the pending one."
  (when data (puthash "pending" review data))
  data)

(defun octocat-pr-diff--new-thread (range comment)
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

(defun octocat-pr-diff--threads-spec (repo number)
  "Return the spec of the review threads of PR NUMBER of REPO."
  `(pr-review-threads ,repo ,number))

(octocat-sync-define-mutation review-draft-add (repo number pr-id review-id commit range body login)
  :label "Saving draft…"
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  ;; GitHub answers with the pending review's id and the new thread.
  :edits (lambda (answered answer)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       (lambda (data)
                         (when answered
                           (unless review-id
                             (let ((r (make-hash-table :test #'equal)))
                               (puthash "id" (car answer) r)
                               (puthash "commit" commit r)
                               (octocat-pr-diff--set-pending data r))))
                         (let ((thread (if answered
                                           (cdr answer)
                                         (octocat-pr-diff--new-thread
                                          range (octocat-pr-diff--draft body login)))))
                           (when data
                             (puthash "threads"
                                      (vconcat (gethash "threads" data) (vector thread))
                                      data)))
                         data))))
  :send (lambda (done)
          (octocat-pr-diff--with-review
           pr-id review-id commit
           (lambda (review)
             (if (eq (car-safe review) 'error)
                 (funcall done review)
               (octocat-pr-diff--graphql
                "review-draft-add"
                (concat "mutation($review:ID!,$path:String!,$body:String!,$line:Int,"
                        "$side:DiffSide,$startLine:Int,$startSide:DiffSide,"
                        "$subject:PullRequestReviewThreadSubjectType){"
                        "addPullRequestReviewThread(input:{pullRequestReviewId:$review,"
                        "path:$path,body:$body,line:$line,side:$side,startLine:$startLine,"
                        "startSide:$startSide,subjectType:$subject}){thread{"
                        octocat-pr-diff--thread-fields "}}}")
                `(("review" . ,review) ("path" . ,(plist-get range :path)) ("body" . ,body)
                  ("line" . ,(plist-get range :line)) ("side" . ,(plist-get range :side))
                  ("startLine" . ,(plist-get range :start-line))
                  ("startSide" . ,(plist-get range :start-side))
                  ("subject" . ,(if (plist-get range :file) "FILE" "LINE")))
                (lambda (data)
                  (cons review (octocat--get data "addPullRequestReviewThread" "thread")))
                done))))))

(defun octocat-pr-diff--add-reply (data thread-id comment)
  "Return DATA, the `pr-review-threads', with COMMENT ending thread THREAD-ID."
  (octocat-pr-diff--map-threads
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
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (answered answer)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       (lambda (data)
                         (when (and answered (not review-id))
                           (let ((r (make-hash-table :test #'equal)))
                             (puthash "id" (car answer) r)
                             (puthash "commit" commit r)
                             (octocat-pr-diff--set-pending data r)))
                         (octocat-pr-diff--add-reply
                          data thread-id
                          (if answered (cdr answer) (octocat-pr-diff--draft body login)))))))
  :send (lambda (done)
          (octocat-pr-diff--with-review
           pr-id review-id commit
           (lambda (review)
             (if (eq (car-safe review) 'error)
                 (funcall done review)
               (octocat-pr-diff--graphql
                "review-draft-reply"
                (concat "mutation($review:ID!,$thread:ID!,$body:String!){"
                        "addPullRequestReviewThreadReply(input:{pullRequestReviewId:$review,"
                        "pullRequestReviewThreadId:$thread,body:$body}){comment{"
                        octocat-pr-diff--comment-fields "}}}")
                `(("review" . ,review) ("thread" . ,thread-id) ("body" . ,body))
                (lambda (data)
                  (cons review (octocat--get data "addPullRequestReviewThreadReply" "comment")))
                done))))))

(octocat-sync-define-mutation review-reply-now (repo number thread-id comment-id body login)
  :label "Posting reply…"
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (answered _)
           (unless answered
             (let ((c (octocat-pr-diff--draft body login)))
               (puthash "state" "SUBMITTED" c)
               (list (cons (octocat-pr-diff--threads-spec repo number)
                           (lambda (data) (octocat-pr-diff--add-reply data thread-id c)))))))
  :send (lambda (done)
          (octocat--run-gh "review-reply"
                           (list "api" (format "repos/%s/pulls/%d/comments/%d/replies"
                                               repo number comment-id)
                                 "-f" (concat "body=" body))
                           #'ignore done))
  :invalidates (lambda () (list (octocat-pr-diff--threads-spec repo number))))

(octocat-sync-define-mutation review-comment-edit (repo number node-id body)
  :label "Saving comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       (lambda (data)
                         (octocat-pr-diff--map-comments
                          data (lambda (c)
                                 (if (not (equal (gethash "id" c) node-id))
                                     c
                                   (let ((c (copy-hash-table c)))
                                     (puthash "body" body c)
                                     c))))))))
  :send (lambda (done)
          (octocat-pr-diff--graphql
           "review-comment-edit"
           (concat "mutation($id:ID!,$body:String!){updatePullRequestReviewComment("
                   "input:{pullRequestReviewCommentId:$id,body:$body}){"
                   "pullRequestReviewComment{id}}}")
           `(("id" . ,node-id) ("body" . ,body))
           #'ignore done)))

(octocat-sync-define-mutation review-comment-delete (repo number node-id)
  :label "Deleting comment…"
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       (lambda (data)
                         (octocat-pr-diff--map-comments
                          data (lambda (c) (unless (equal (gethash "id" c) node-id) c)))))))
  :send (lambda (done)
          (octocat-pr-diff--graphql
           "review-comment-delete"
           (concat "mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){"
                   "clientMutationId}}")
           `(("id" . ,node-id))
           #'ignore done)))

(octocat-sync-define-mutation review-thread-resolve (repo number thread-id resolve)
  :label (if resolve "Resolving…" "Unresolving…")
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (answered answer)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       (lambda (data)
                         (octocat-pr-diff--map-threads
                          data (lambda (thread)
                                 (cond ((not (equal (gethash "id" thread) thread-id)) thread)
                                       (answered answer)
                                       (t (let ((thread (copy-hash-table thread)))
                                            (puthash "isResolved" (and resolve t) thread)
                                            thread)))))))))
  :send (lambda (done)
          (let ((field (if resolve "resolveReviewThread" "unresolveReviewThread")))
            (octocat-pr-diff--graphql
             "review-thread-resolve"
             (format "mutation($id:ID!){%s(input:{threadId:$id}){thread{%s}}}"
                     field octocat-pr-diff--thread-fields)
             `(("id" . ,thread-id))
             (lambda (data) (octocat--get data field "thread"))
             done))))

(defun octocat-pr-diff--drop-drafts (data)
  "Return DATA, the `pr-review-threads', without drafts or a pending review."
  (octocat-pr-diff--set-pending
   (octocat-pr-diff--map-comments
    data (lambda (c) (unless (equal (gethash "state" c) "PENDING") c)))
   nil))

(octocat-sync-define-mutation review-discard (repo number review-id)
  :label "Discarding review…"
  :slot 'inline
  :resources (lambda () (list (octocat-pr-diff--threads-spec repo number)))
  :edits (lambda (_answered _)
           (list (cons (octocat-pr-diff--threads-spec repo number)
                       #'octocat-pr-diff--drop-drafts)))
  :send (lambda (done)
          (octocat-pr-diff--graphql
           "review-discard"
           (concat "mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){"
                   "clientMutationId}}")
           `(("id" . ,review-id))
           #'ignore done)))


;;;; The page's comment backend
;;
;; The diff's commands (`octocat-diff-add-comment' and the others) call
;; these through `octocat-diff--comment-backend'.

(defun octocat-pr-diff--threads ()
  "Return the stored `pr-review-threads' of this page's PR, or signal."
  (pcase-let ((`(,repo . ,number) (octocat-pr--current)))
    (or (plist-get (octocat-sync-read (octocat-pr-diff--threads-spec repo number)) :data)
        (user-error "Octocat: The review comments are still loading"))))

(defun octocat-pr-diff--login ()
  "Return your login, as the store has it, or nil."
  (octocat--get (plist-get (octocat-sync-read '(viewer)) :data) "login"))

(defun octocat-pr-diff--submitter (make-spec)
  "Return an edit buffer's submit function sending (MAKE-SPEC BODY)."
  (lambda (body source on-success _on-error)
    (with-current-buffer source
      (octocat-sync-submit (funcall make-spec body)))
    (funcall on-success)))

(defun octocat-pr-diff--add (range)
  "Open the edit buffer of a draft comment on RANGE; return its window."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (data   (octocat-pr-diff--threads))
               (review (gethash "pending" data)))
    (octocat-timeline-prepare-comment)
    (octocat--open-edit-buffer
     (format "Comment on %s" (octocat-diff-range-label range))
     (octocat-pr-diff--submitter
      (lambda (body)
        `(review-draft-add ,repo ,number ,(gethash "id" data)
                           ,(and review (gethash "id" review))
                           ,(if review (gethash "commit" review) (gethash "head" data))
                           ,range ,body ,(octocat-pr-diff--login))))
     #'ignore)))

(defun octocat-pr-diff--reply (comment)
  "Open the edit buffer of a reply to the thread of COMMENT.
With a pending review the reply is a draft in it; without one, you
pick between replying now and starting a review."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (data   (octocat-pr-diff--threads))
               (review (gethash "pending" data))
               (thread (gethash "thread_id" comment))
               (draft  (or review
                           (eq (car (read-multiple-choice
                                     "Reply: " '((?n "now" "post the reply at once")
                                                 (?r "review" "start a review with it"))))
                               ?r))))
    (octocat-timeline-prepare-comment)
    (octocat--open-edit-buffer
     (format "Reply on %s" (octocat-diff-range-label
                            (list :path (gethash "path" comment)
                                  :line (or (gethash "line" comment) 0)
                                  :side (gethash "side" comment))))
     (octocat-pr-diff--submitter
      (lambda (body)
        (if draft
            `(review-draft-reply ,repo ,number ,(gethash "id" data)
                                 ,(and review (gethash "id" review))
                                 ,(if review (gethash "commit" review) (gethash "head" data))
                                 ,thread ,body ,(octocat-pr-diff--login))
          `(review-reply-now ,repo ,number ,thread
                             ,(or (gethash "in_reply_to_id" comment) (gethash "id" comment))
                             ,body ,(octocat-pr-diff--login)))))
     #'ignore)))

(defvar octocat-pr-diff-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d") #'octocat-pr-diff-delete-comment)
    map)
  "Keymap for `octocat-pr-diff-comment-mode'.")

(define-minor-mode octocat-pr-diff-comment-mode
  "Delete the review comment being edited in its edit buffer."
  :keymap octocat-pr-diff-comment-mode-map)

(defun octocat-pr-diff--delete (source node-id)
  "Delete review comment NODE-ID of the PR of SOURCE, after asking."
  (when (y-or-n-p "Delete this comment? ")
    (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
      (octocat-sync-submit `(review-comment-delete ,repo ,number ,node-id)))
    t))

(defun octocat-pr-diff-delete-comment ()
  "Delete the review comment this buffer edits, after asking."
  (interactive)
  (when (octocat-pr-diff--delete octocat-edit--source-buffer
                                 (plist-get octocat-edit--user-data :node-id))
    (set-buffer-modified-p nil)
    (quit-window t octocat-edit--window)))

(defun octocat-pr-diff--edit (comment)
  "Open the edit buffer of your review COMMENT."
  (pcase-let* ((`(,repo . ,number) (octocat-pr--current))
               (node-id (gethash "node_id" comment))
               (title   (format "Edit comment on %s"
                                (octocat-diff-range-label
                                 (list :path (gethash "path" comment)
                                       :line (or (gethash "line" comment) 0)
                                       :side (gethash "side" comment)))))
               (win (octocat--open-edit-buffer
                     title
                     (lambda (body source on-success on-error)
                       (cond ((not (string-empty-p body))
                              (octocat-sync-submit
                               `(review-comment-edit ,repo ,number ,node-id ,body))
                              (funcall on-success))
                             ((octocat-pr-diff--delete source node-id)
                              (funcall on-success))
                             (t (funcall on-error "Nothing to save"))))
                     #'ignore
                     (gethash "body" comment)
                     (list :node-id node-id :allow-empty t))))
    (with-current-buffer (window-buffer win)
      (octocat-pr-diff-comment-mode 1)
      (setq header-line-format
            (concat (octocat-edit--header-line title) "   "
                    (propertize "C-c C-d" 'face 'help-key-binding) "  delete")))
    win))

(defun octocat-pr-diff--resolve (root)
  "Resolve the thread of ROOT, its first comment, or unresolve it."
  (pcase-let ((`(,repo . ,number) (octocat-pr--current)))
    (octocat-sync-submit `(review-thread-resolve ,repo ,number ,(gethash "thread_id" root)
                                                 ,(not (eq (gethash "resolved" root) t))))))

(defconst octocat-pr-diff--comment-backend
  (list :add #'octocat-pr-diff--add
        :reply #'octocat-pr-diff--reply
        :edit #'octocat-pr-diff--edit
        :resolve #'octocat-pr-diff--resolve)
  "The PR diff's comments, drafts in your pending review, see `octocat-diff'.")


;;;; Review submission

(defconst octocat-pr-diff--review-events
  '(("Comment"         "--comment"         "COMMENT")
    ("Approve"         "--approve"         "APPROVE")
    ("Request changes" "--request-changes" "REQUEST_CHANGES"))
  "Review events offered on submit: their `gh pr review' flag and GraphQL event.")

(defun octocat-pr-diff--review-args (repo number flag body)
  "Return the `gh' arguments submitting a FLAG review of PR NUMBER of REPO.
An empty BODY is left out, as `gh' rejects an empty --body."
  (append (list "pr" "review" (number-to-string number) "--repo" repo flag)
          (unless (string-empty-p body) (list "--body" body))))

(defun octocat-pr-diff--review-data (event &optional review-id pending)
  "Return the edit buffer's user data for an EVENT review.
REVIEW-ID is your pending review's, holding PENDING drafts.  Only an
approval may be submitted without text, or a comment with drafts."
  (let ((flag (cadr (assoc event octocat-pr-diff--review-events))))
    (list :event event :flag flag :review-id review-id :pending pending
          :allow-empty (or (equal flag "--approve")
                           (and (equal flag "--comment") (natnump pending) (> pending 0))))))

(defun octocat-pr-diff--review-header (title event &optional pending)
  "Return the review dialog's header line for TITLE with EVENT chosen.
PENDING is how many drafts the review holds."
  (concat "  " title
          (if (and pending (> pending 0))
              (propertize (format "  %d pending comment%s" pending (if (= pending 1) "" "s"))
                          'face 'octocat-review-pending)
            "")
          "    "
          (mapconcat (lambda (e)
                       (if (equal (car e) event)
                           (propertize (format "(•) %s" (car e)) 'face 'bold)
                         (propertize (format "( ) %s" (car e)) 'face 'octocat-dimmed)))
                     octocat-pr-diff--review-events "  ")
          "    "
          (propertize "C-c C-t" 'face 'help-key-binding) " decision   "
          (propertize "C-c C-c" 'face 'help-key-binding) " submit   "
          (propertize "C-c C-k" 'face 'help-key-binding) " close"
          (if pending
              (concat "   " (propertize "C-c C-d" 'face 'help-key-binding) " discard review")
            "")))

(octocat-sync-define-mutation review-pr (repo number flag body &optional review-id)
  :label "Submitting review…"
  :slot 'review
  :resources (lambda () `((pr ,repo ,number) ,(octocat-pr-diff--threads-spec repo number)))
  ;; The drafts are no longer drafts.
  :edits (lambda (_answered _)
           (when review-id
             (list (cons (octocat-pr-diff--threads-spec repo number)
                         (lambda (data)
                           (octocat-pr-diff--set-pending
                            (octocat-pr-diff--map-comments
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
              (octocat-pr-diff--graphql
               "review"
               (concat "mutation($id:ID!,$event:PullRequestReviewEvent!,$body:String){"
                       "submitPullRequestReview(input:{pullRequestReviewId:$id,event:$event,"
                       "body:$body}){clientMutationId}}")
               `(("id" . ,review-id)
                 ("event" . ,(nth 2 (seq-find (lambda (e) (equal (cadr e) flag))
                                              octocat-pr-diff--review-events)))
                 ("body" . ,(and (not (string-empty-p body)) body)))
               #'ignore done)
            (octocat--run-gh "review" (octocat-pr-diff--review-args repo number flag body)
                             #'ignore done)))
  ;; The review joins the timeline, may add review comments and may
  ;; change the merge box.
  :invalidates (lambda () `((pr ,repo ,number) (timeline-events ,repo ,number)
                            ,(octocat-pr-diff--threads-spec repo number))))

(defun octocat-pr-diff--submit-review (body source on-success on-error)
  "Submit BODY as a review of the PR in SOURCE buffer.
The review flag is read from the edit buffer's :flag user data; there
is none until the user picks a decision.  The dialog closes at once,
through ON-SUCCESS, and the PR's pages show the review under way until
it is sent, so a slow GitHub does not block; ON-ERROR is called only
for a missing decision."
  (let ((flag (plist-get octocat-edit--user-data :flag))
        (review-id (plist-get octocat-edit--user-data :review-id)))
    (cond
     ((not flag)
      (funcall on-error "Pick a decision with C-c C-t first"))
     ((and (string-empty-p body) (not (plist-get octocat-edit--user-data :allow-empty)))
      (funcall on-error "Write the review's text first"))
     (t
      (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
        (octocat-sync-submit `(review-pr ,repo ,number ,flag ,body ,review-id)
                             (lambda (result)
                               (unless (eq (car-safe result) 'error)
                                 (message "Octocat: Reviewed PR #%d" number)))))
      (funcall on-success)))))

(defun octocat-pr-diff-review-cycle ()
  "Switch the review dialog to the next decision."
  (interactive)
  (let* ((events  (mapcar #'car octocat-pr-diff--review-events))
         (next    (or (cadr (member (plist-get octocat-edit--user-data :event) events))
                      (car events)))
         (pending (plist-get octocat-edit--user-data :pending)))
    (setq octocat-edit--user-data
          (octocat-pr-diff--review-data
           next (plist-get octocat-edit--user-data :review-id) pending))
    (setq header-line-format
          (octocat-pr-diff--review-header octocat-edit--title next pending))
    (force-mode-line-update)))

(defun octocat-pr-diff--discard (source review-id pending)
  "Discard pending review REVIEW-ID of the PR of SOURCE, after asking.
PENDING is how many drafts it holds.  Return non-nil when discarded."
  (when (y-or-n-p (format "Discard your review and its %d draft%s? "
                          pending (if (= pending 1) "" "s")))
    (pcase-let ((`(,repo . ,number) (with-current-buffer source (octocat-pr--current))))
      (octocat-sync-submit `(review-discard ,repo ,number ,review-id)))
    t))

(defun octocat-pr-diff-review-discard ()
  "Discard your pending review, its drafts with it, after asking."
  (interactive)
  (let ((review-id (or (plist-get octocat-edit--user-data :review-id)
                       (user-error "Octocat: No review to discard"))))
    (when (octocat-pr-diff--discard octocat-edit--source-buffer review-id
                                    (plist-get octocat-edit--user-data :pending))
      (set-buffer-modified-p nil)
      (quit-window t octocat-edit--window))))

(defvar octocat-pr-diff-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'octocat-pr-diff-review-cycle)
    (define-key map (kbd "C-c C-d") #'octocat-pr-diff-review-discard)
    map)
  "Keymap for `octocat-pr-diff-review-mode'.")

;; A minor mode so the decision key lives only in review dialogs, not in
;; every `octocat-edit-mode' buffer.
(define-minor-mode octocat-pr-diff-review-mode
  "Pick the decision of a PR review in its edit buffer."
  :keymap octocat-pr-diff-review-mode-map)

(defun octocat-pr-diff--pending-review (repo number)
  "Return your pending review of PR NUMBER of REPO and its drafts, or nil.
That is (ID . COUNT), from the store."
  (let* ((data   (plist-get (octocat-sync-read (octocat-pr-diff--threads-spec repo number))
                            :data))
         (review (and data (gethash "pending" data))))
    (and review (cons (gethash "id" review) (octocat-pr-diff--pending-count data)))))

(defun octocat-pr-diff-review ()
  "Open the dialog to submit a review of this PR, from any of its pages.
Write the review text, pick Comment, Approve or Request changes with
\\<octocat-pr-diff-review-mode-map>\\[octocat-pr-diff-review-cycle], then submit.
Your draft comments are submitted with it, or discarded with
\\[octocat-pr-diff-review-discard]."
  (interactive)
  (let* ((current (or (octocat-pr--current)
                      (user-error "Octocat: Buffer is not associated with a pull request")))
         (number  (cdr current))
         (_       (when (octocat-pr--busy (car current) number 'review)
                    (user-error "Octocat: A review of PR #%d is being submitted" number)))
         (pending (octocat-pr-diff--pending-review (car current) number))
         (title (format "Review PR #%d" number))
         (win   (octocat--open-edit-buffer
                 title
                 #'octocat-pr-diff--submit-review
                 #'ignore
                 nil
                 ;; No default decision: it must be a deliberate choice.
                 (octocat-pr-diff--review-data nil (car pending) (cdr pending)))))
    (with-current-buffer (window-buffer win)
      (octocat-pr-diff-review-mode 1)
      (setq header-line-format (octocat-pr-diff--review-header title nil (cdr pending))))))

(defun octocat-pr-diff--buttons (pending)
  "Return the buttons under the PR diff: submit, and discard with PENDING drafts.
PENDING is (REVIEW-ID . COUNT), your pending review, or nil."
  (apply #'vui-vstack
         (octocat-timeline-buttons
          (cons (list (if pending
                          (format "Submit review (%d pending)" (cdr pending))
                        "Submit review")
                      "RET: comment on, approve or request changes"
                      #'octocat-pr-diff-review)
                (and pending
                     (list (list "Discard review" "RET: delete your drafts"
                                 (lambda ()
                                   (octocat-pr-diff--discard (current-buffer) (car pending)
                                                             (cdr pending))))))))))


;;;; Components

(vui-defcomponent octocat-pr-diff--page (repo number hide-comments raw tick)
  "The diff of pull request NUMBER of REPO, under the PR page's header.
HIDE-COMMENTS leaves the review comments out of the diff, and RAW shows
their markdown verbatim.  A review being
submitted shows in place of the submit button.  A new TICK fetches
everything again."
  :render
  (let* ((pr       (octocat-pr--use-data repo number tick))
         (stack    (octocat-pr--use-stack repo number tick))
         (tab-w    (octocat--markdown-width))
         (files    (octocat-vui-use-resource (list 'pr-files repo number) tick))
         (threads  (octocat-vui-use-resource (octocat-pr-diff--threads-spec repo number) tick))
         (data     (plist-get threads :data))
         (comments (vui-use-memo (data)
                     (and data (octocat-pr-diff--thread-comments (gethash "threads" data)))))
         (by-path  (vui-use-memo (comments) (octocat-diff-by-path comments)))
         (review   (and data (gethash "pending" data)))
         (pending  (and review (cons (gethash "id" review)
                                     (octocat-pr-diff--pending-count data)))))
    (vui-vstack
     ;; The same header as the conversation, so the pages read as tabs.
     (cond
      ((or (plist-get pr :data) (plist-get pr :partial))
       (apply #'vui-vstack
              (delq nil (octocat-pr--header
                         repo (or (plist-get pr :data) (plist-get pr :partial))
                         (octocat--label-background) tab-w 'files stack))))
      ((and (plist-get pr :error) (not (plist-get pr :loading)))
       (vui-vstack
        (vui-text (octocat-vui-error-text pr) :face 'error)
        (octocat-pr--tabs 'files repo number tab-w)))
      (t (vui-vstack
          (vui-text (format "%s#%d  diff" repo number)
            :face 'octocat-dimmed)
          (octocat-pr--tabs 'files repo number tab-w))))
     (pcase (octocat-vui-snapshot-status files)
       ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28) ("  " 34)))))
       ('error   (vui-text (concat "  " (octocat-vui-error-text files)) :face 'error))
       (_ (octocat-diff-files-section repo (plist-get files :data) by-path
                                      hide-comments raw (octocat--markdown-width))))
     (vui-newline)
     (octocat-diff-comments-section "Review Comments" (plist-put (copy-sequence threads)
                                                                 :data comments)
                                    raw (octocat--markdown-width))
     (if-let* ((reviewing (alist-get 'review (plist-get pr :mutating))))
         (vui-text (concat "  " (octocat-vui-spinner) " " reviewing) :face 'bold)
       (octocat-pr-diff--buttons pending)))))


;;;; Major mode

(defun octocat-pr-diff--page-url ()
  "Return the URL of the files changed of this pull request."
  (and octocat--pr-diff-repo octocat--pr-diff-number
       (octocat--web-url "%s/pull/%d/files" octocat--pr-diff-repo octocat--pr-diff-number)))

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-a") #'octocat-diff-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-diff-edit-comment)
    (define-key map (kbd "C-c C-r") #'octocat-pr-diff-review)
    (define-key map (kbd "C-c C-m") #'octocat-pr-merge)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-v") #'octocat-diff-toggle-comments)
    map)
  "Keymap for `octocat-pr-diff-mode'.")

(define-derived-mode octocat-pr-diff-mode vui-mode "Octocat-PR-Diff"
  "Major mode for viewing the complete diff of a GitHub Pull Request.

\\{octocat-pr-diff-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh)
  (setq-local octocat--refresh-fn #'octocat-pr-diff-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup)
  (setq-local octocat--url-function #'octocat-pr-diff--page-url)
  (setq-local octocat-diff--comment-backend octocat-pr-diff--comment-backend))


;;;; Refresh

(defun octocat-pr-diff-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR diff buffer.
The page fetches the file diffs and the review threads independently,
in place."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (octocat-vui-refresh-page 'octocat-pr-diff--page
                            (cons octocat--pr-diff-repo octocat--pr-diff-number)
                            (list :repo octocat--pr-diff-repo
                                  :number octocat--pr-diff-number
                                  :hide-comments octocat-diff--hide-comments
                                  :raw octocat--markdown-raw)))

(defun octocat-pr-diff-open (repo number)
  "Show the diff of pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d diff*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-diff-mode)
      (octocat-pr-diff-mode))
    (setq octocat--pr-diff-repo   repo
          octocat--pr-diff-number number
          octocat-diff--hide-comments nil)
    (octocat-pr-diff-refresh)))

(provide 'octocat-pr-diff)
;;; octocat-pr-diff.el ends here
