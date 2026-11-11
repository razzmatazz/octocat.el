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
                        "\"labels\":[],\"comments\":[{\"body\":\"me too\"}]}"))))
    (octocat-sync--write db "list"
                         (octocat-model-list-tree
                          'issues "o/r"
                          (list :items (list (json-parse-string
                                              "{\"number\":12,\"title\":\"Old\",\"commentCount\":0}"))))
                         1.0)
    (should (member "list"
                    (octocat-sync--write
                     db "issue"
                     (octocat-model-detail issue '("comments")
                                           (lambda (f) (octocat-model-item 'issue "o/r" f)))
                     2.0)))
    (let ((row (aref (gethash "nodes" (car (octocat-sync--read db "list"))) 0)))
      (should (equal (gethash "title" row) "Crash"))
      (should (= (gethash "commentCount" row) 1))
      (should-not (gethash "comments" row)))
    (let ((page (octocat-model-detail-item (car (octocat-sync--read db "issue")))))
      (should (equal (gethash "login" (gethash "author" page)) "alice"))
      (should (equal (gethash "body" (aref (gethash "comments" page) 0)) "me too")))))

(ert-deftest octocat-model-test-issue-parse-created ()
  "The number is read from the URL `gh issue create' prints."
  (should (= (octocat-model--issue-parse-created
              "https://github.com/o/r/issues/42\n")
             42))
  (should-error (octocat-model--issue-parse-created "oops")))

;;;; Shared resources

(ert-deftest octocat-model-test-counts-query-and-parse ()
  "Pull requests also count merged; the answer parses to a table."
  (should (string-match-p "merged:pullRequests(states:MERGED)"
                          (octocat-model--counts-query 'pulls)))
  (should-not (string-match-p "merged" (octocat-model--counts-query 'issues)))
  (let ((counts (octocat-model--parse-counts
                 (octocat-model-tests--data
                  "{\"data\":{\"repository\":{\"open\":{\"totalCount\":2},\"closed\":{\"totalCount\":5}}}}"))))
    (should (= (hash-table-count counts) 2))
    (should (= (gethash "open" counts) 2))
    (should (= (gethash "closed" counts) 5))))

(ert-deftest octocat-model-test-parse-repo-summary-fork ()
  "A fork's summary carries its parent, default branch and counts."
  (let ((summary (octocat-model--parse-repo-summary
                  (octocat-model-tests--data
                   "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"parent\":{\"nameWithOwner\":\"up/stream\"},\"issues\":{\"totalCount\":3},\"pullRequests\":{\"totalCount\":2}}}}"))))
    (should (equal (gethash "default-branch" summary) "main"))
    (should (equal (gethash "fork-parent" summary) "up/stream"))
    (should (= (gethash "open-issues" summary) 3))
    (should (= (gethash "open-prs" summary) 2))))

(ert-deftest octocat-model-test-parse-repo-summary-empty-repo ()
  "A non-fork with no default branch yields nils, not errors."
  (let ((summary (octocat-model--parse-repo-summary
                  (octocat-model-tests--data
                   "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"parent\":null,\"issues\":{\"totalCount\":0},\"pullRequests\":{\"totalCount\":0}}}}"))))
    (should-not (gethash "default-branch" summary))
    (should-not (gethash "fork-parent" summary))
    (should (= (gethash "open-issues" summary) 0))))

(ert-deftest octocat-model-test-parse-list-items ()
  "Connections flatten to what the rows read; the cursor ends with the pages."
  (let* ((json "{\"data\":{\"search\":{\"nodes\":[{\"number\":5,\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},\"comments\":{\"totalCount\":3},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"state\":\"FAILURE\",\"contexts\":{\"checkRunCountsByState\":[{\"state\":\"SUCCESS\",\"count\":3},{\"state\":\"FAILURE\",\"count\":1}],\"statusContextCountsByState\":[{\"state\":\"SUCCESS\",\"count\":1}]}}}}]}},{\"number\":6,\"labels\":{\"nodes\":[]},\"comments\":{\"totalCount\":0},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"Y3I\"}}}}")
         (page  (octocat-model--parse-list-items json))
         (pr    (car (plist-get page :items)))
         (bare  (cadr (plist-get page :items))))
    (should (equal (plist-get page :cursor) "Y3I"))
    (should (equal (gethash "name" (aref (gethash "labels" pr) 0)) "bug"))
    (should (= (gethash "commentCount" pr) 3))
    (should (equal (gethash "ciState" pr) "FAILURE"))
    (should (equal (substring-no-properties (octocat--ci-status pr)) "✗"))
    (should (equal (substring-no-properties (octocat--ci-count-label pr)) "✗ 4/5"))
    (should-not (gethash "ciState" bare))
    (should-not (gethash "commits" bare)))
  (should-not (plist-get (octocat-model--parse-list-items
                          "{\"data\":{\"search\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}")
                         :cursor)))

(ert-deftest octocat-model-test-list-item-assignees ()
  "A list row's assignees become a vector of their nodes, as its labels do."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,
                                   \"assignees\":{\"nodes\":[{\"login\":\"a\"}]}}]}}}")
                    :items))))
    (should (equal (mapcar (lambda (u) (gethash "login" u)) (gethash "assignees" item))
                   '("a")))))

(ert-deftest octocat-model-test-list-item-requested-reviewers ()
  "A PR row's requested reviewers become the users and teams asked."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,\"requestedReviewers\":{\"nodes\":[
                         {\"requestedReviewer\":{\"login\":\"a\"}},
                         {\"requestedReviewer\":{\"name\":\"core\"}}]}}]}}}")
                    :items))))
    (should (equal (mapcar (lambda (r) (or (gethash "login" r) (gethash "name" r)))
                           (gethash "requestedReviewers" item))
                   '("a" "core")))
    ;; The team has no login to toggle.
    (should (equal (octocat-vui-list--value-counts (list item) "requestedReviewers" "login")
                   '(("a" . 1))))))

(ert-deftest octocat-model-test-list-item-without-commits ()
  "A PR that comes with no commits parses, without a CI state."
  (let ((item (car (plist-get
                    (octocat-model--parse-list-items
                     "{\"data\":{\"search\":{\"pageInfo\":{\"hasNextPage\":false},
                       \"nodes\":[{\"number\":3,\"commits\":{\"nodes\":[]}}]}}}")
                    :items))))
    (should (= (gethash "number" item) 3))
    (should-not (gethash "ciState" item))))

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
  (let ((data (make-hash-table :test #'equal)))
    (puthash "comments" (vconcat (mapcar #'json-parse-string comments)) data)
    data))

(ert-deftest octocat-model-test-put-comment ()
  "A comment is added at the end, or takes the place of one of its id."
  (let ((data (octocat-model-tests--page "{\"id\":\"C1\",\"body\":\"a\"}")))
    (octocat-model--put-comment data (json-parse-string "{\"id\":\"C2\",\"body\":\"b\"}"))
    (octocat-model--put-comment data (json-parse-string "{\"id\":\"C1\",\"body\":\"a2\"}"))
    (should (equal (mapcar (lambda (c) (gethash "body" c)) (gethash "comments" data))
                   '("a2" "b")))))

(ert-deftest octocat-model-test-set-comment-body ()
  "Only the comment of that REST id changes, and as a copy."
  (let* ((data (octocat-model-tests--page
                "{\"url\":\"https://x/1#issuecomment-11\",\"body\":\"a\"}"
                "{\"url\":\"https://x/1#issuecomment-22\",\"body\":\"b\"}"))
         (old  (aref (gethash "comments" data) 0))
         (new  (gethash "comments"
                        (octocat-model--set-comment-body data "11" "a2" "saving…"))))
    (should (equal (gethash "body" (aref new 0)) "a2"))
    (should (equal (gethash octocat-model-pending (aref new 0)) "saving…"))
    (should (equal (gethash "body" (aref new 1)) "b"))
    (should (equal (gethash "body" old) "a"))))

(ert-deftest octocat-model-test-react-comment ()
  "A reaction is counted on the comment of that node id only."
  (let* ((data (octocat-model-tests--page
                "{\"id\":\"C1\",\"reactionGroups\":[]}"
                "{\"id\":\"C2\",\"reactionGroups\":[]}"))
         (new  (gethash "comments" (octocat-model--react-comment data "C2" "HEART" t))))
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
  (should (equal (octocat-model--pr-merge-args "o/r" 7 "Squash" "Fix (#7)\n\n* a\n* b" t)
                 '("pr" "merge" "7" "--repo" "o/r" "--squash"
                   "--subject" "Fix (#7)" "--body" "* a\n* b" "--delete-branch")))
  (should (equal (octocat-model--pr-merge-args "o/r" 7 "Merge" "Merge it" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--merge"
                   "--subject" "Merge it" "--body" "")))
  (should (equal (octocat-model--pr-merge-args "o/r" 7 "Rebase" "ignored" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--rebase"))))

(ert-deftest octocat-model-test-review-review-args ()
  "A review passes its flag, and its body only when there is one."
  (should (equal (octocat-model--review-args "o/r" 7 "--approve" "")
                 '("pr" "review" "7" "--repo" "o/r" "--approve")))
  (should (equal (octocat-model--review-args "o/r" 7 "--comment" "LGTM")
                 '("pr" "review" "7" "--repo" "o/r" "--comment" "--body" "LGTM"))))

(ert-deftest octocat-model-test-review-parse-threads ()
  "The pages' threads join; with no pending review, \"pending\" is nil."
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
    (should (equal (gethash "head" none) "abc"))
    (should-not (gethash "pending" none))
    (should (equal (mapcar (lambda (th) (gethash "id" th)) (gethash "threads" none))
                   '("T1" "T2")))
    (should (equal (octocat--get some "pending" "id") "R1"))
    (should (equal (octocat--get some "pending" "commit") "def"))))

;;;; Commits

(ert-deftest octocat-model-test-commit-parse-branch ()
  "The default branch holds a commit behind its head or at it, not one ahead."
  (dolist (case '(("BEHIND" . "main") ("IDENTICAL" . "main") ("AHEAD" . :null) ("DIVERGED" . :null)))
    (should (equal (gethash "name"
                            (octocat-model--commit-parse-branch
                             (octocat-model-tests--data
                              (format "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\",\"compare\":{\"status\":\"%s\"}}}}}"
                                      (car case)))))
                   (cdr case)))))

;;;; Repository code

(ert-deftest octocat-model-test-repo-parse-history ()
  "History edges become REST-shaped commits that keep their cursor."
  (let* ((json "{\"data\":{\"repository\":{\"object\":{\"history\":{\"edges\":[{\"cursor\":\"abc 0\",\"node\":{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}},{\"cursor\":\"abc 1\",\"node\":{\"oid\":\"def\",\"messageHeadline\":\"Old\",\"authoredDate\":\"2026-10-13T00:00:00Z\",\"author\":{\"name\":\"Bo\",\"email\":\"b@x\",\"user\":null}}}]}}}}}")
         (commits (octocat-model--repo-parse-history json))
         (first   (car commits)))
    (should (equal (gethash "sha" first) "abc"))
    (should (equal (gethash "message" (gethash "commit" first)) "Fix it"))
    (should (equal (octocat--commit-author first) "@ann"))
    (should (equal (octocat--commit-author (cadr commits)) "Bo"))
    (should (equal (gethash "cursor" (cadr commits)) "abc 1"))
    (should-not (gethash "total" first)))
  (should (equal (gethash "total" (car (octocat-model--repo-parse-history
                                        "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":7,\"edges\":[{\"cursor\":\"c\",\"node\":{\"oid\":\"abc\"}}]}}}}}")))
                 7))
  (should-error (octocat-model--repo-parse-history
                 "{\"data\":{\"repository\":{\"object\":null}}}")))

(ert-deftest octocat-model-test-file-args ()
  "A file is asked for raw at its ref, each part of its path encoded."
  (should (equal (octocat-model--file-args "o/r" "docs/a b.md" "main")
                 '("api" "-X" "GET" "repos/o/r/contents/docs/a%20b.md" "-f" "ref=main"
                   "-H" "Accept: application/vnd.github.raw"))))

(ert-deftest octocat-model-test-commits-tree ()
  "A full page has the last commit's cursor; a short one, at the end, none."
  (let ((commits (octocat-model--repo-parse-history
                  "{\"data\":{\"repository\":{\"object\":{\"history\":{\"edges\":[{\"cursor\":\"c 0\",\"node\":{\"oid\":\"abc\"}},{\"cursor\":\"c 1\",\"node\":{\"oid\":\"def\"}}]}}}}}")))
    (should (equal (gethash "cursor" (octocat-model--commits-tree commits 2)) "c 1"))
    (should (= (length (gethash "nodes" (octocat-model--commits-tree commits 2))) 2))
    (should-not (gethash "cursor" (octocat-model--commits-tree commits 3)))
    (should-not (gethash "cursor" (octocat-model--commits-tree nil 2)))))

(ert-deftest octocat-model-test-repo-parse-head ()
  "A directory at a ref has its last commit, its tree and its history count."
  (let ((head (octocat-model--repo-parse-head
               (octocat-model-tests--data "{\"data\":{\"repository\":{\"object\":{\"history\":{\"totalCount\":42,\"nodes\":[{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}]}},\"dir\":{\"__typename\":\"Tree\",\"oid\":\"t1\"}}}}")
               "main" "src")))
    (should (equal (gethash "sha" head) "abc"))
    (should (equal (octocat--commit-author head) "@ann"))
    (should (equal (gethash "tree" head) "t1"))
    (should (equal (gethash "kind" head) "tree"))
    (should (equal (gethash "total" head) 42)))
  (should-error (octocat-model--repo-parse-head
                 (octocat-model-tests--data "{\"data\":{\"repository\":{\"object\":null,\"dir\":null}}}")
                 "nope" nil))
  (should-error (octocat-model--repo-parse-head
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
    (should (equal (gethash "sha" (gethash "README.md" got)) "a1"))
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
    (should (string-search (alist-get 'issues octocat-model--list-item-fields) q))))

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
    (should (equal (gethash "commentCount" (octocat-sync--entity-fields item)) 4))))

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
  "The REST list and the pinned list write one entity per repository."
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
                           (octocat-sync--parse
                            "[{\"full_name\":\"bob/app\",\"description\":\"new\",\"language\":\"Go\",\"fork\":false}]"))
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
