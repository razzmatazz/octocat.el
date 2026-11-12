;;; octocat-model-tests.el --- ERT tests for octocat-model.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-model-tests.el

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'octocat)

(defun octocat-model-tests--data (json)
  "Return the \"data\" of JSON, a GraphQL answer, as a resource's :parse gets it."
  (gethash "data" (octocat-sync--parse json)))

;;;; Issues

(ert-deftest octocat-model-test-issue-shares-entity-with-list ()
  "The issue page and the list store one entity; the comments stay with the page."
  (let ((db (octocat-sync--create (sqlite-open nil)))
        (issue (json-parse-string
                (concat "{\"number\":12,\"title\":\"Crash\",\"state\":\"OPEN\","
                        "\"author\":{\"login\":\"alice\",\"is_bot\":false},"
                        "\"labels\":{\"nodes\":[]},"
                        "\"comments\":{\"totalCount\":1,\"nodes\":[{\"body\":\"me too\"}]}}"))))
    (octocat-sync--write db "list"
                         (octocat-model--list-tree
                          'issues "o/r"
                          (list :items (list (json-parse-string
                                              (concat "{\"number\":12,\"title\":\"Old\","
                                                      "\"comments\":{\"totalCount\":0}}")))))
                         1.0)
    (should (member "list"
                    (octocat-sync--write
                     db "issue"
                     (octocat-model-detail issue '("comments")
                                           (lambda (f) (octocat-model-item 'issue "o/r" f)))
                     2.0)))
    (let ((row (aref (gethash "nodes" (car (octocat-sync--read db "list"))) 0)))
      (should (equal (gethash "title" row) "Crash"))
      (should (= (octocat--get row "comments" "totalCount") 1))
      (should-not (octocat--get row "comments" "nodes")))
    (let ((page (octocat-model-detail-item (car (octocat-sync--read db "issue")))))
      (should (equal (gethash "login" (gethash "author" page)) "alice"))
      (should (equal (gethash "body" (aref (octocat--nodes page "comments") 0)) "me too")))))

(ert-deftest octocat-model-test-parse-file-blob ()
  "A file's text is kept but for a binary, cut short or too large one."
  (let ((parse (lambda (json)
                 (octocat-model--parse-file-blob
                  (json-parse-string (format "{\"repository\":{\"object\":%s}}" json)
                                     :null-object nil :false-object :false)))))
    (should (equal (gethash "text" (funcall parse "{\"oid\":\"b\",\"byteSize\":3,\"isBinary\":false,\"isTruncated\":false,\"text\":\"hi\\n\"}"))
                   "hi\n"))
    (should (equal (gethash "oid" (funcall parse "{\"oid\":\"b\",\"isBinary\":true,\"text\":null}"))
                   "b"))
    (should-not (gethash "text" (funcall parse "{\"oid\":\"b\",\"isBinary\":true,\"text\":null}")))
    (should-not (gethash "text" (funcall parse "{\"oid\":\"b\",\"isTruncated\":true,\"text\":\"h\"}")))
    (should-not (gethash "text" (funcall parse (format "{\"oid\":\"b\",\"byteSize\":%d,\"text\":\"h\"}"
                                                       (1+ octocat--max-file-size)))))
    (should-error (funcall parse "null"))))

(ert-deftest octocat-model-test-tree-path ()
  "Each tree on the way to a path is asked for in one query, the root's first."
  (let ((props (octocat-sync--props '(tree-path "o/r" "main" "a/b"))))
    (should (equal (plist-get props :vars)
                   '(("e0" . "main:") ("e1" . "main:a") ("e2" . "main:a/b"))))
    (should (equal (octocat-model-tree-shas
                    (octocat-sync--parse
                     "{\"repository\":{\"t0\":{\"oid\":\"r\"},\"t1\":{\"oid\":\"a\"},\"t2\":{}}}"))
                   ["r" "a" nil]))
    (should-error (funcall (plist-get props :parse) (octocat-sync--parse "{\"repository\":null}")))
    ;; Nothing revealed, nothing asked.
    (should (plist-get (octocat-sync--props '(tree-path "o/r" "main" nil)) :fetch))))

(ert-deftest octocat-model-test-ref-split ()
  "The most leading segments GitHub resolves are the ref, else the first."
  (let ((props (octocat-sync--props '(ref-split "o/r" "feat/x/a.el"))))
    (should (equal (mapcar #'car (plist-get props :vars)) '("e1" "e2" "e3")))
    (should (equal (cdr (assoc "e2" (plist-get props :vars))) "feat/x^{commit}"))
    (should (eql (octocat-model-ref-count
                  (octocat-sync--parse
                   "{\"repository\":{\"p1\":{\"oid\":\"1\"},\"p2\":{\"oid\":\"2\"},\"p3\":null}}"))
                 2))
    (should (eql (octocat-model-ref-count (octocat-sync--parse "{\"repository\":null}")) 1))
    (should (eql (octocat-model-ref-count nil) 1))))

(ert-deftest octocat-model-test-issue-parse-created ()
  "The number is read from the URL `gh issue create' prints."
  (should (= (octocat-model--issue-parse-created
              "https://github.com/o/r/issues/42\n")
             42))
  (should-error (octocat-model--issue-parse-created "oops")))

;;;; Shared resources

(ert-deftest octocat-model-test-counts-query ()
  "Pull requests also count merged."
  (should (string-match-p "merged:pullRequests(states:MERGED)"
                          (octocat-model--counts-query 'pulls)))
  (should-not (string-match-p "merged" (octocat-model--counts-query 'issues))))

(ert-deftest octocat-model-test-default-branch ()
  "A summary gives its default branch, nil for an empty repository."
  (should (equal (octocat-model-default-branch
                  (octocat-model-tests--data
                   "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"}}}}"))
                 "main"))
  (should-not (octocat-model-default-branch
               (octocat-model-tests--data
                "{\"data\":{\"repository\":{\"defaultBranchRef\":null}}}"))))

(ert-deftest octocat-model-test-search-query ()
  "The query is scoped to the repo and kind; nil means open items."
  (should (equal (octocat-model--search-query "o/r" 'pulls nil)
                 "( is:open ) repo:o/r type:pr"))
  (should (equal (octocat-model--search-query "o/r" 'issues "is:closed OR label:x")
                 "( is:closed OR label:x ) repo:o/r type:issue"))
  (should (equal (octocat-model--search-query "o/r" 'issues "  ")
                 "repo:o/r type:issue")))

(ert-deftest octocat-model-test-parse-list-items ()
  "The rows read GraphQL's connections; the cursor ends with the pages."
  (let* ((json "{\"data\":{\"search\":{\"nodes\":[{\"number\":5,\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},\"comments\":{\"totalCount\":3},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"state\":\"FAILURE\",\"contexts\":{\"checkRunCountsByState\":[{\"state\":\"SUCCESS\",\"count\":3},{\"state\":\"FAILURE\",\"count\":1}],\"statusContextCountsByState\":[{\"state\":\"SUCCESS\",\"count\":1}]}}}}]}},{\"number\":6,\"labels\":{\"nodes\":[]},\"comments\":{\"totalCount\":0},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"Y3I\"}}}}")
         (page  (octocat-model--parse-list-items json))
         (pr    (car (plist-get page :items)))
         (bare  (cadr (plist-get page :items))))
    (should (equal (plist-get page :cursor) "Y3I"))
    (should (equal (gethash "name" (aref (octocat--nodes pr "labels") 0)) "bug"))
    (should (= (octocat--get pr "comments" "totalCount") 3))
    (should (equal (substring-no-properties (octocat--ci-status pr)) "✗"))
    (should (equal (substring-no-properties (octocat--ci-count-label pr)) "✗ 4/5"))
    (should-not (octocat--rollup bare)))
  (should-not (plist-get (octocat-model--parse-list-items
                          "{\"data\":{\"search\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}")
                         :cursor)))

(ert-deftest octocat-model-test-list-item-assignees ()
  "A list row's assignees are the nodes of their connection, as its labels are."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,
                                   \"assignees\":{\"nodes\":[{\"login\":\"a\"}]}}]}}}")
                    :items))))
    (should (equal (mapcar (lambda (u) (gethash "login" u)) (octocat--nodes item "assignees"))
                   '("a")))))

(ert-deftest octocat-model-test-list-item-requested-reviewers ()
  "A PR row's requested reviewers are the users and teams asked."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,\"requestedReviewers\":{\"nodes\":[
                         {\"requestedReviewer\":{\"login\":\"a\"}},
                         {\"requestedReviewer\":{\"name\":\"core\"}}]}}]}}}")
                    :items))))
    (should (equal (mapcar (lambda (r) (or (octocat--get r "requestedReviewer" "login")
                                           (octocat--get r "requestedReviewer" "name")))
                           (octocat--nodes item "requestedReviewers"))
                   '("a" "core")))
    ;; The team has no login to toggle.
    (should (equal (octocat-vui-list--value-counts (list item) "requestedReviewers"
                                                   '("requestedReviewer" "login"))
                   '(("a" . 1))))))

(ert-deftest octocat-model-test-list-item-without-commits ()
  "A PR that comes with no commits parses, without a CI state."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,\"commits\":{\"nodes\":[]}}]}}}")
                    :items))))
    (should (= (gethash "number" item) 3))
    (should-not (octocat--rollup item))))

(ert-deftest octocat-model-test-pr-tree ()
  "A PR page keeps its connections; its entity, their counts and its labels."
  (let* ((tree (funcall (plist-get (octocat-sync--props '(pr "o/r" 7)) :parse)
                        (octocat-model-tests--data
                         "{\"data\":{\"repository\":{\"pullRequest\":{
                           \"number\":7,
                           \"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},
                           \"comments\":{\"totalCount\":2,\"nodes\":[{\"body\":\"hi\"}]},
                           \"commits\":{\"totalCount\":1,\"nodes\":[
                             {\"commit\":{\"oid\":\"b2\",
                               \"statusCheckRollup\":{\"state\":\"SUCCESS\"}}}]}}}}}")))
         (item (octocat-sync--entity-fields (gethash "item" tree))))
    (should (equal (octocat--get item "comments" "totalCount") 2))
    (should-not (gethash "commits" item))
    (should (= (length (octocat--nodes item "labels")) 1))
    (should (equal (gethash "body" (aref (octocat--nodes tree "comments") 0)) "hi"))
    (should (equal (octocat-pr--head-sha tree) "b2"))
    (should (equal (substring-no-properties (octocat--ci-status tree)) "✓")))
  (should-error (funcall (plist-get (octocat-sync--props '(pr "o/r" 7)) :parse)
                         (octocat-model-tests--data
                          "{\"data\":{\"repository\":{\"pullRequest\":null}}}"))))

(ert-deftest octocat-model-test-list-more ()
  "The page after a cursor is asked for by the list's query and page size."
  (let (asked got)
    (cl-letf (((symbol-function 'octocat-model--list-items)
               (lambda (kind repo callback query after limit)
                 (setq asked (list kind repo query after limit))
                 (funcall callback (list :items (list (octocat--table "number" 7))
                                         :cursor "c2")))))
      (funcall (octocat-model-list-more 'issues "o/r" "is:open" 15)
               "c1" (lambda (tree) (setq got tree))))
    (should (equal asked '(issues "o/r" "is:open" "c1" 15)))
    (should (equal (gethash "cursor" got) "c2"))
    (should (equal (octocat-sync--entity-key (aref (gethash "nodes" got) 0))
                   "issue:o/r#7"))))

;;;; Comments

(defun octocat-model-tests--page (&rest comments)
  "Return a page resource's body holding COMMENTS, JSON strings."
  (octocat--table "comments" (octocat--table "totalCount" (length comments)
                                             "nodes" (vconcat (mapcar #'json-parse-string
                                                                      comments)))))

(ert-deftest octocat-model-test-toggle-reaction ()
  "A reaction is counted up, down to nothing, or added; the old groups stay."
  (let* ((old (json-parse-string
               "[{\"content\":\"HEART\",\"users\":{\"totalCount\":1}}]"))
         (counts (lambda (groups)
                   (let ((h (make-hash-table :test #'equal)))
                     (puthash "reactionGroups" groups h)
                     (octocat--reaction-counts h)))))
    (should (equal (funcall counts (octocat-model--toggle-reaction old "HEART" t)) '(("❤️" . 2))))
    (should-not (funcall counts (octocat-model--toggle-reaction old "HEART" nil)))
    (should (equal (funcall counts (octocat-model--toggle-reaction old "EYES" t))
                   '(("❤️" . 1) ("👀" . 1))))
    (should (equal (funcall counts (octocat-model--toggle-reaction nil "EYES" t)) '(("👀" . 1))))
    (should (equal (funcall counts old) '(("❤️" . 1))))))

(ert-deftest octocat-model-test-put-comment ()
  "A comment is added at the end, or takes the place of one of its id."
  (let ((data (octocat-model-tests--page "{\"id\":\"C1\",\"body\":\"a\"}")))
    (octocat-model--put-comment data (json-parse-string "{\"id\":\"C2\",\"body\":\"b\"}"))
    (octocat-model--put-comment data (json-parse-string "{\"id\":\"C1\",\"body\":\"a2\"}"))
    (should (equal (mapcar (lambda (c) (gethash "body" c)) (octocat--nodes data "comments"))
                   '("a2" "b")))
    (should (= (octocat--get data "comments" "totalCount") 1))))

(ert-deftest octocat-model-test-set-comment-body ()
  "Only the comment of that REST id changes, and as a copy."
  (let* ((data (octocat-model-tests--page
                "{\"url\":\"https://x/1#issuecomment-11\",\"body\":\"a\"}"
                "{\"url\":\"https://x/1#issuecomment-22\",\"body\":\"b\"}"))
         (old  (aref (octocat--nodes data "comments") 0))
         (new  (octocat--nodes (octocat-model--set-comment-body data "11" "a2" "saving")
                               "comments")))
    (should (equal (gethash "body" (aref new 0)) "a2"))
    (should (equal (gethash octocat-model-pending (aref new 0)) "saving"))
    (should (equal (gethash "body" (aref new 1)) "b"))
    (should (equal (gethash "body" old) "a"))))

(ert-deftest octocat-model-test-react-comment ()
  "A reaction is counted on the comment of that node id only."
  (let* ((data (octocat-model-tests--page
                "{\"id\":\"C1\",\"reactionGroups\":[]}"
                "{\"id\":\"C2\",\"reactionGroups\":[]}"))
         (new  (octocat--nodes (octocat-model--react-comment data "C2" "HEART" t)
                               "comments")))
    (should (seq-empty-p (gethash "reactionGroups" (aref new 0))))
    (should (= (octocat--get (aref (gethash "reactionGroups" (aref new 1)) 0)
                             "users" "totalCount")
               1))))

;;;; Actions

(ert-deftest octocat-model-test-poll-status ()
  "Runs, jobs and checks under way refetch fast, and never once completed."
  (should (eql (octocat-model--poll-status "in_progress") octocat-sync-poll-active))
  (should (eql (octocat-model--poll-status "completed" "QUEUED") octocat-sync-poll-active))
  (should-not (octocat-model--poll-status "completed" "COMPLETED"))
  (should-not (octocat-model--poll-status nil)))

(ert-deftest octocat-model-test-job-tree ()
  "A job's annotations and artifacts may fail; the job itself may not."
  (let ((tree (octocat-model--job-tree (json-parse-string "{\"id\":1}") '(error . "no") [])))
    (should (equal (octocat--get tree "job" "id") 1))
    (should (equal (gethash "annotations" tree) []))
    (should (equal (gethash "artifacts" tree) [])))
  (should (equal (octocat-model--job-tree '(error . "no job") [] [])
                 '(error . "no job"))))

(ert-deftest octocat-model-test-parse-annotations-artifacts ()
  "Annotations and artifacts read as vectors, [] when unreadable."
  (should (= (length (octocat-model--parse-annotations "[{\"message\":\"m\"}]")) 1))
  (should (equal (octocat-model--parse-annotations "{}") []))
  (should (equal (octocat-model--parse-annotations "oops") []))
  (should (= (length (octocat-model--parse-artifacts "{\"artifacts\":[{\"id\":1}]}")) 1))
  (should (equal (octocat-model--parse-artifacts "[]") []))
  (should (equal (octocat-model--parse-artifacts "oops") [])))

;;;; Pull requests and reviews

(ert-deftest octocat-model-test-pr-merge-args ()
  "Merge and squash pass the message split into subject and body; rebase none."
  (should (equal (octocat-model--pr-merge-args "o/r" 7 'squash "Fix (#7)\n\n* a\n* b" t)
                 '("pr" "merge" "7" "--repo" "o/r" "--squash"
                   "--subject" "Fix (#7)" "--body" "* a\n* b" "--delete-branch")))
  (should (equal (octocat-model--pr-merge-args "o/r" 7 'merge "Merge it" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--merge"
                   "--subject" "Merge it" "--body" "")))
  (should (equal (octocat-model--pr-merge-args "o/r" 7 'rebase "ignored" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--rebase"))))

(ert-deftest octocat-model-test-review-review-args ()
  "A review passes its event's flag, and its body only when there is one."
  (should (equal (octocat-model--review-args "o/r" 7 'approve "")
                 '("pr" "review" "7" "--repo" "o/r" "--approve")))
  (should (equal (octocat-model--review-args "o/r" 7 'comment "LGTM")
                 '("pr" "review" "7" "--repo" "o/r" "--comment" "--body" "LGTM"))))

(defun octocat-model-tests--threads (&rest comments)
  "Return `pr-review-threads' data, one thread of COMMENTS, a pending review."
  (octocat--table "reviewThreads"
                  (octocat--table "nodes" (vector (octocat--table
                                                   "id" "T1"
                                                   "comments" (octocat--table
                                                               "nodes" (vconcat comments)))))
                  "reviews" (octocat--table "nodes" (vector (octocat--table "id" "R1")))))

(defun octocat-model-tests--comments (data key)
  "Return KEY of each comment of DATA's first thread."
  (mapcar (lambda (c) (gethash key c))
          (octocat--get (aref (octocat--nodes data "reviewThreads") 0) "comments" "nodes")))

(ert-deftest octocat-model-test-review-submit-drafts ()
  "Submitting a review submits its drafts and leaves none pending."
  (let ((data (octocat-model--review-submit-drafts
               (octocat-model-tests--threads
                (octocat--table "id" "C1" "state" "SUBMITTED")
                (octocat--table "id" "C2" "state" "PENDING")))))
    (should (equal (octocat-model-tests--comments data "state") '("SUBMITTED" "SUBMITTED")))
    (should-not (octocat-model-pending-review data))))

(ert-deftest octocat-model-test-review-set-body ()
  "Only the comment edited gets the new body."
  (let ((data (octocat-model--review-set-body
               (octocat-model-tests--threads
                (octocat--table "id" "C1" "body" "a")
                (octocat--table "id" "C2" "body" "b"))
               "C2" "new")))
    (should (equal (octocat-model-tests--comments data "body") '("a" "new")))))

(ert-deftest octocat-model-test-review-draft-send ()
  "A draft goes to the review given, or to one started first, with its id."
  (let (calls answer)
    (cl-letf (((symbol-function 'octocat-model--review-graphql)
               (lambda (name _query vars parse done)
                 (push (cons name vars) calls)
                 (funcall done
                          (funcall parse
                                   (if (equal name "review-start")
                                       (octocat--table "addPullRequestReview"
                                                       (octocat--table "pullRequestReview"
                                                                       (octocat--table "id" "R9")))
                                     (octocat--table "add" (octocat--table "node" "N"))))))))
      (octocat-model--review-draft-send "PR" "R1" "abc" "draft" "q" '(("body" . "x"))
                                        '("add" "node") (lambda (a) (setq answer a)))
      (should (equal answer '("R1" . "N")))
      (should (equal (car calls) '("draft" ("review" . "R1") ("body" . "x"))))
      (setq calls nil)
      (octocat-model--review-draft-send "PR" nil "abc" "draft" "q" nil
                                        '("add" "node") (lambda (a) (setq answer a)))
      (should (equal answer '("R9" . "N")))
      (should (equal (mapcar #'car calls) '("draft" "review-start"))))))

(ert-deftest octocat-model-test-review-parse-threads ()
  "The pages' threads join; with no pending review, there is none."
  (let* ((page (lambda (reviews threads)
                 (format (concat "{\"data\":{\"repository\":{\"pullRequest\":{"
                                 "\"id\":\"PR1\",\"headRefOid\":\"abc\","
                                 "\"reviews\":{\"nodes\":[%s]},"
                                 "\"reviewThreads\":{\"nodes\":[%s]}}}}}")
                         reviews threads)))
         (none (octocat-model--review-parse-threads
                (format "[%s,%s]" (funcall page "" "{\"id\":\"T1\"}")
                        (funcall page "" "{\"id\":\"T2\"}"))))
         (some (octocat-model--review-parse-threads
                (format "[%s]" (funcall page "{\"id\":\"R1\",\"commit\":{\"oid\":\"def\"}}"
                                        "")))))
    (should (equal (gethash "id" none) "PR1"))
    (should-not (octocat-model-pending-review none))
    (should (equal (mapcar (lambda (th) (gethash "id" th)) (octocat--nodes none "reviewThreads"))
                   '("T1" "T2")))
    (should (equal (octocat--get (octocat-model-pending-review some) "id") "R1"))
    (should (equal (octocat--get (octocat-model-pending-review some) "commit" "oid") "def"))))

;;;; Commits

(ert-deftest octocat-model-test-commit-holder ()
  "The default branch holds a commit behind its head or at it, not one ahead."
  (dolist (case '(("BEHIND" . "main") ("IDENTICAL" . "main") ("AHEAD") ("DIVERGED")))
    (should (equal (octocat-model-commit-holder
                    (octocat-model-tests--data
                     (format "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\",\"compare\":{\"status\":\"%s\"}}}}}"
                             (car case))))
                   (cdr case)))))

(ert-deftest octocat-model-test-set-given ()
  "A reaction given is yours, even of a group not listed; taken back, it is not."
  (let ((data (octocat-sync--parse
               "{\"node\":{\"reactionGroups\":[{\"content\":\"HEART\",\"viewerHasReacted\":true}]}}")))
    (octocat-model--set-given data "ROCKET" t)
    (should (equal (octocat-model-reactions-given data) '("HEART" "ROCKET")))
    (octocat-model--set-given data "HEART" nil)
    (should (equal (octocat-model-reactions-given data) '("ROCKET")))))

;;;; Repository code

(ert-deftest octocat-model-test-commits-tree ()
  "A page of history keeps its commits, their count and the cursor after it."
  (let ((tree (octocat-model--commits-tree
               (octocat-model-tests--data
                (concat "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":7,"
                        "\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\","
                        "\"author\":{\"name\":\"Ann\",\"user\":{\"login\":\"ann\"}}},"
                        "{\"oid\":\"def\",\"author\":{\"name\":\"Bo\",\"user\":null}}],"
                        "\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c1\"}}}}}}")))))
    (should (equal (mapcar (lambda (c) (gethash "oid" c)) (gethash "nodes" tree)) '("abc" "def")))
    (should (equal (mapcar #'octocat--commit-author (gethash "nodes" tree)) '("@ann" "Bo")))
    (should (= (gethash "totalCount" tree) 7))
    (should (equal (gethash "cursor" tree) "c1")))
  (should-not (gethash "cursor"
                       (octocat-model--commits-tree
                        (octocat-model-tests--data
                         (concat "{\"data\":{\"repository\":{\"object\":{\"history\":{"
                                 "\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,"
                                 "\"endCursor\":\"c1\"}}}}}}")))))
  (should-error (octocat-model--commits-tree
                 (octocat-model-tests--data "{\"data\":{\"repository\":{\"object\":null}}}"))))

(ert-deftest octocat-model-test-file-args ()
  "A file is asked for raw at its ref, each part of its path encoded."
  (should (equal (octocat-model--file-args "o/r" "docs/a b.md" "main")
                 '("api" "-X" "GET" "repos/o/r/contents/docs/a%20b.md" "-f" "ref=main"
                   "-H" "Accept: application/vnd.github.raw"))))

(ert-deftest octocat-model-test-repo-check-head ()
  "A directory at a ref has its last commit and its tree; a missing one errs."
  (let ((head (octocat-model--repo-check-head
               (octocat-model-tests--data "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":42,\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}]}},\"dir\":{\"__typename\":\"Tree\",\"oid\":\"t1\",\"entries\":[{\"path\":\"README.md\",\"type\":\"blob\",\"sha\":\"b1\"}]}}}}")
               "main" "src")))
    (should (equal (octocat--commit-author (octocat-model-head-commit head)) "@ann"))
    (should (equal (gethash "oid" (octocat-model-head-dir head)) "t1")))
  (should-error (octocat-model--repo-check-head
                 (octocat-model-tests--data "{\"data\":{\"repository\":{\"object\":null,\"dir\":null}}}")
                 "nope" nil))
  (should-error (octocat-model--repo-check-head
                 (octocat-model-tests--data
                  "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":0,\"nodes\":[]}},\"dir\":null}}}")
                 "main" "missing")))

(ert-deftest octocat-model-test-tree-parse-last-commits ()
  "Each path gets the commit of its alias; one with no history is left out."
  (let ((got (octocat-model--tree-parse-last-commits
              (concat "{\"data\":{\"repository\":{\"object\":{"
                      "\"e0\":{\"nodes\":[{\"oid\":\"a1\",\"messageHeadline\":\"One\"}]},"
                      "\"e1\":{\"nodes\":[]}}}}}")
              '("README.md" "gone"))))
    (should (equal (gethash "oid" (gethash "README.md" got)) "a1"))
    (should-not (gethash "gone" got))))

;;;; Actions

(ert-deftest octocat-model-test-job-run-annotations-order ()
  "A run's annotations come in its jobs' order, not their answers'."
  (let (calls result)
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name _args _parse callback) (push callback calls))))
      (octocat-model--fetch-run-annotations
       "o/r"
       (vector (let ((j (make-hash-table :test #'equal)))
                 (puthash "databaseId" 1 j) (puthash "name" "a" j) j)
               (let ((j (make-hash-table :test #'equal)))
                 (puthash "databaseId" 2 j) (puthash "name" "b" j) j))
       (lambda (r) (setq result r)))
      ;; CALLS is newest first, so job 2 answers first.
      (dolist (cb calls) (funcall cb [])))
    (should (equal (mapcar #'car result) '(1 2)))))

(ert-deftest octocat-model-test-run-yaml-jobs ()
  "A job's needs are read in each form, and nothing else of the file."
  (let ((jobs (octocat-model--workflow-yaml-jobs "name: CI
on: push
jobs:
  lint:   # first
    runs-on: ubuntu-latest
    steps:
      - run: |
          needs: not-a-job
  test:
    name: Test ${{ matrix.rust }}
    needs: lint
  build:
    needs: [lint]

  docs:
    needs:
      - test
      - build
env:
  needs: nope
")))
    (should (equal (mapcar (lambda (j) (list (gethash "id" j) (gethash "name" j) (gethash "needs" j)))
                           jobs)
                   '(("lint" nil []) ("test" "Test ${{ matrix.rust }}" ["lint"])
                     ("build" nil ["lint"]) ("docs" nil ["test" "build"]))))
    (should (equal (octocat-model--workflow-yaml-jobs "on: push\n") []))))

(ert-deftest octocat-model-test-workflow-yaml-on ()
  "The triggers are read in each way a workflow may write them."
  (should (equal (octocat-model--workflow-yaml-on "on: workflow_dispatch\n") "workflow_dispatch"))
  (should (equal (octocat-model--workflow-yaml-on "on: [push, workflow_dispatch]\n")
                 ["push" "workflow_dispatch"]))
  (should (equal (octocat-model--workflow-yaml-on "\"on\":\n  - push\n  - workflow_dispatch\n")
                 ["push" "workflow_dispatch"]))
  (should (equal (octocat-model--workflow-yaml-on
                  "name: CI\non:\n  workflow_dispatch:  # by hand\n  push: {branches: [main]}\njobs:\n  a:\n")
                 '(("workflow_dispatch") ("push" ("branches" . ["main"])))))
  (should-not (octocat-model--workflow-yaml-on "name: CI\njobs:\n")))

(ert-deftest octocat-model-test-workflow-parse-dispatched ()
  "The run's ID is read from the answer; an empty answer gives none."
  (should (= (octocat-model--workflow-parse-dispatched
              "{\"workflow_run_id\":42,\"run_url\":\"u\",\"html_url\":\"h\"}")
             42))
  (should-not (octocat-model--workflow-parse-dispatched "\n")))

;;;; Dashboard

(ert-deftest octocat-model-test-dashboard-items-query ()
  "The dashboard searches the user's open items of a kind, with their repo."
  (should (equal (octocat-model--dashboard-search-query 'pulls)
                 "is:open archived:false involves:@me sort:updated-desc type:pr"))
  (should (string-match-p "type:issue\\'" (octocat-model--dashboard-search-query 'issues)))
  (let ((q (octocat-model--dashboard-items-query 'issues)))
    (should (string-search "...on Issue{repository{nameWithOwner}}" q))
    (should (string-search (octocat--graphql (alist-get 'issues octocat-model--list-item-fields))
                           q))))

(ert-deftest octocat-model-test-dashboard-items-tree ()
  "Each dashboard item keeps its repo beside its entity."
  (let* ((page (octocat-model--parse-list-items
                "{\"data\":{\"search\":{\"nodes\":[{\"repository\":{\"nameWithOwner\":\"O/R\"},\"number\":5,\"title\":\"T\",\"state\":\"OPEN\",\"comments\":{\"totalCount\":4}}],\"pageInfo\":{\"hasNextPage\":false}}}}"))
         (tree (octocat-model--dashboard-items-tree 'pulls page))
         (node (aref tree 0))
         (item (gethash "item" node)))
    (should (equal (gethash "repo" node) "O/R"))
    (should (octocat-sync--entity-p item))
    (should (equal (octocat-sync--entity-key item) "pr:o/r#5"))
    (should-not (gethash "repository" (octocat-sync--entity-fields item)))
    (should (equal (octocat--get (octocat-sync--entity-fields item) "comments" "totalCount")
                   4))))

;;;; Users

(ert-deftest octocat-model-test-user-parse-pinned ()
  "Pinned repositories become repo entities; gists and unknown owners drop out."
  (let* ((tree (octocat-model--user-parse-pinned
                (octocat-model-tests--data
                 (concat "{\"data\":{\"repositoryOwner\":{\"pinnedItems\":{\"nodes\":["
                         "{\"nameWithOwner\":\"bob/App\",\"description\":null,"
                         "\"stargazerCount\":7,\"primaryLanguage\":{\"name\":\"Go\"},"
                         "\"pushedAt\":\"2026-01-01T10:00:00Z\",\"isFork\":false,\"isArchived\":true},"
                         "{}]}}}}"))))
         (nodes (gethash "nodes" tree)))
    (should (= (length nodes) 1))
    (should (equal (octocat-sync--entity-key (aref nodes 0)) "repo:bob/app"))
    (should (eq (gethash "isArchived" (octocat-sync--entity-fields (aref nodes 0))) t))
    (should (equal (gethash "nodes" (octocat-model--user-parse-pinned
                                     (octocat-model-tests--data
                                      "{\"data\":{\"repositoryOwner\":null}}")))
                   []))))

(ert-deftest octocat-model-test-user-repos-share-entities ()
  "The repositories list and the pinned list write one entity per repository."
  (let ((db (octocat-sync--create (sqlite-open nil))))
    (octocat-sync--write
     db "pinned"
     (octocat-model--user-parse-pinned
      (octocat-model-tests--data
       "{\"data\":{\"repositoryOwner\":{\"pinnedItems\":{\"nodes\":[{\"nameWithOwner\":\"bob/app\",\"description\":\"old\",\"isFork\":false}]}}}}"))
     1.0)
    (should (equal (sort (octocat-sync--write
                          db "repos"
                          (octocat-model--user-parse-repos
                           (octocat-model-tests--data
                            (concat "{\"data\":{\"repositoryOwner\":{\"repositories\":{\"nodes\":["
                                    "{\"nameWithOwner\":\"bob/app\",\"description\":\"new\","
                                    "\"primaryLanguage\":{\"name\":\"Go\"},\"isFork\":false}]}}}}")))
                          2.0)
                         #'string<)
                   '("pinned" "repos")))
    (let ((repo (aref (gethash "nodes" (car (octocat-sync--read db "pinned"))) 0)))
      (should (equal (gethash "description" repo) "new"))
      (should (equal (gethash "name" (gethash "primaryLanguage" repo)) "Go")))))

;;;; Search

(ert-deftest octocat-model-test-search-repo-search-args ()
  "Forks are searched; \"owner/name\" searches the repos of owner."
  (should (equal (octocat-model--repo-search-args "razzmatazz/open")
                 '("search" "repos" "--limit" "30" "--json" "fullName"
                   "--include-forks=true" "--owner=razzmatazz" "open")))
  (should (equal (last (octocat-model--repo-search-args "razzmatazz/"))
                 '("--owner=razzmatazz")))
  (should (equal (last (octocat-model--repo-search-args "openra")) '("openra"))))

(provide 'octocat-model-tests)
;;; octocat-model-tests.el ends here
