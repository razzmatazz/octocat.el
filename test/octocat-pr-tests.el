;;; octocat-pr-tests.el --- ERT tests for octocat-pr.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-pr-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-pr-test--pr (json)
  "Return the PR hash-table parsed from JSON."
  (json-parse-string json))

(ert-deftest octocat-pr-test-merge-message ()
  "Default messages follow GitHub's."
  (let ((pr (octocat-pr-test--pr
             "{\"number\":7,\"title\":\"Fix\",\"headRefName\":\"fix\",
               \"headRepositoryOwner\":{\"login\":\"me\"},
               \"commits\":[{\"messageHeadline\":\"a\"},{\"messageHeadline\":\"b\"}]}")))
    (should (equal (octocat-pr--merge-message "Merge" pr)
                   "Merge pull request #7 from me/fix\n\nFix"))
    (should (equal (octocat-pr--merge-message "Squash" pr) "Fix (#7)\n\n* a\n* b"))
    (should (equal (octocat-pr--merge-message "Rebase" pr) ""))))

(defun octocat-pr-test--stack (&rest prs)
  "Return a stack of PRS, bottom first.
It is as `octocat-model--pr-parse-stack' gives it.  Each PR is a list
of NUMBER, STATE, DRAFT and MERGEABLE."
  (gethash "stack"
           (octocat-model--pr-parse-stack
            (json-serialize
             `((data
                (repository
                 (pullRequest
                  (stack
                   (number . 17) (baseRefName . "main")
                   (entries
                    (nodes
                     . ,(vconcat
                         (seq-map-indexed
                          (pcase-lambda (`(,n ,state ,draft ,mergeable) i)
                            `((position . ,(1+ i))
                              (pullRequest (number . ,n) (title . ,(format "Layer %d" n))
                                           (state . ,state) (isDraft . ,draft)
                                           (mergeable . ,mergeable))))
                          prs)))))))))))))

(defun octocat-pr-test--text (nodes)
  "Return NODES rendered, each line trimmed on the right."
  (with-temp-buffer
    (vui-render (apply #'vui-vstack nodes))
    (mapcar #'string-trim-right
            (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n"))))

(ert-deftest octocat-pr-test-stack ()
  "A stack lists its pull requests top first, this one in bold and not a link."
  (let* ((stack (octocat-pr-test--stack '(14 "MERGED" :false "UNKNOWN")
                                        '(15 "OPEN" :false "MERGEABLE")
                                        '(16 "OPEN" t "MERGEABLE")))
         (pr    (json-parse-string "{\"number\":15,\"state\":\"OPEN\"}")))
    (should (equal (octocat-pr-test--text (octocat-pr--stack-section "o/r" pr stack 80))
                   '("" "  ≡ Stack #17 · into main · ✓ Ready to merge as stack"
                     "    It merges into main."
                     "    #16  (draft) Layer 16"
                     "    #15  Layer 15"
                     "    #14  Layer 14")))
    (should (equal (octocat-pr--stack-label stack 15) "≡ 2/3"))
    (should-not (octocat-pr--stack-label stack 99))
    (should (equal (octocat-pr--stack-choices stack 15)
                   '(("3/3 #16 Layer 16" . 16) ("2/3 #15 Layer 15 (this)" . 15)
                     ("1/3 #14 Layer 14" . 14))))
    (with-temp-buffer
      (vui-render (apply #'vui-vstack (octocat-pr--stack-section "o/r" pr stack 80)))
      (goto-char (point-min))
      (search-forward "Layer 15")
      (should (eq (get-text-property (1- (point)) 'face) 'bold))
      (should-not (get-text-property (1- (point)) 'keymap))
      (search-forward "Layer 14")
      (should (get-text-property (1- (point)) 'keymap))))
  ;; Merging #16 merges #15 too, which can stop it.
  (should (equal (octocat-pr--stack-merge-row
                  16 (octocat-pr-test--stack '(14 "OPEN" :false "MERGEABLE")
                                             '(15 "OPEN" :false "MERGEABLE")
                                             '(16 "OPEN" :false "MERGEABLE")))
                 '(ok "Ready to merge as stack" "Merging this merges #14, #15, #16 into main.")))
  ;; Each PR that stops it says why on its row; one above it stops nothing.
  (should (equal (octocat-pr-test--text
                  (octocat-pr--stack-section
                   "o/r" (json-parse-string "{\"number\":15,\"state\":\"OPEN\"}")
                   (octocat-pr-test--stack '(14 "OPEN" t "MERGEABLE")
                                           '(15 "OPEN" :false "CONFLICTING")
                                           '(16 "OPEN" :false "CONFLICTING"))
                   80))
                 '("" "  ≡ Stack #17 · into main · ✗ Unable to merge as stack"
                   "    #16  Layer 16"
                   "    #15  Layer 15  ✗ has conflicts"
                   "    #14  (draft) Layer 14  ✗ is a draft")))
  ;; A pull request in no stack shows none.
  (let ((none (octocat-model--pr-parse-stack
               "{\"data\":{\"repository\":{\"pullRequest\":{\"stack\":null}}}}")))
    (should (eq (gethash "stack" none) :null))
    (should-not (octocat-pr--stack-section "o/r" (json-parse-string "{\"number\":15}")
                                           (octocat--get none "stack") 80))))

(ert-deftest octocat-pr-test-repo-stacks ()
  "The PR list marks each PR of a stack with its place, counted from the bottom."
  (let ((index (octocat-pr--stacks-index
                (json-parse-string
                 "[{\"number\":17,\"pull_requests\":[{\"number\":14},{\"number\":15}]},
                   {\"number\":9,\"pull_requests\":[{\"number\":8},{\"number\":6},
                                                      {\"number\":7}]}]"))))
    (should (equal (octocat-pr--stacks-label index 15) "≡ 2/2"))
    (should (equal (octocat-pr--stacks-label index 6) "≡ 2/3"))
    (should-not (octocat-pr--stacks-label index 3))
    (should-not (octocat-pr--stacks-label nil 15))))

(ert-deftest octocat-pr-test-commits ()
  "Commits are listed oldest first and read as REST commits."
  (let* ((pr (octocat-pr-test--pr
              "{\"commits\":[
                 {\"oid\":\"aaa\",\"messageHeadline\":\"a\",
                  \"committedDate\":\"2026-10-03T12:00:00Z\",
                  \"authors\":[{\"login\":\"me\",\"name\":\"Me\"}]},
                 {\"oid\":\"bbb\",\"messageHeadline\":\"b\",
                  \"committedDate\":\"2026-10-03T12:30:00Z\",
                  \"authors\":[{\"login\":\"\",\"name\":\"Anon\"}]},
                 {\"oid\":\"ccc\",\"messageHeadline\":\"c\",
                  \"committedDate\":\"2026-10-05T12:00:00Z\"}]}"))
         (commits (octocat-pr--commits pr)))
    (should (equal (mapcar (lambda (c) (gethash "sha" c)) commits) '("aaa" "bbb" "ccc")))
    (should (equal (mapcar #'octocat--commit-author (butlast commits)) '("@me" "Anon")))
    ;; Short subjects get the minimum column; long ones what the page leaves.
    (should (= (octocat-vui--subject-width commits 112 3)
               octocat-vui--subject-min-width))
    (puthash "message" (make-string 200 ?x) (gethash "commit" (car commits)))
    (should (= (+ (octocat-vui--subject-width commits 112 3) 2 7 2 2 3 2
                  (apply #'max (mapcar (lambda (c) (string-width (octocat-vui--date c)))
                                       commits)))
               112))))

(ert-deftest octocat-pr-test-merge-allowed ()
  "Only the methods the repo allows are offered, in GitHub's order."
  (should (equal (octocat-pr--merge-allowed
                  (json-parse-string "{\"mergeCommitAllowed\":false,
                                       \"squashMergeAllowed\":true,
                                       \"rebaseMergeAllowed\":true}"))
                 '("Squash" "Rebase"))))

(ert-deftest octocat-pr-test-merge-initial-method ()
  "The last method is kept while allowed; a lone method is always picked."
  (should (equal (octocat-pr--merge-initial-method '("Merge" "Squash") "Squash") "Squash"))
  (should-not (octocat-pr--merge-initial-method '("Merge" "Squash") "Rebase"))
  (should-not (octocat-pr--merge-initial-method '("Merge" "Squash") nil))
  (should (equal (octocat-pr--merge-initial-method '("Rebase") "Squash") "Rebase")))

(ert-deftest octocat-pr-test-merge-refusal ()
  "Drafts and conflicts cannot be merged; a blocked PR is left to GitHub."
  (should (octocat-pr--merge-refusal (octocat-pr-test--pr "{\"isDraft\":true}")))
  (should (octocat-pr--merge-refusal
           (octocat-pr-test--pr "{\"mergeable\":\"CONFLICTING\"}")))
  (should-not (octocat-pr--merge-refusal
               (octocat-pr-test--pr "{\"mergeStateStatus\":\"BLOCKED\"}"))))

(ert-deftest octocat-pr-test-merge-rows ()
  "The merge box rows read as GitHub's."
  (should (equal (octocat-pr--merge-rows
                  (octocat-pr-test--pr
                   "{\"reviewDecision\":\"APPROVED\",
                     \"latestReviews\":[{\"state\":\"APPROVED\"}],
                     \"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"},
                                            {\"conclusion\":\"SKIPPED\"},
                                            {\"status\":\"IN_PROGRESS\"}],
                     \"mergeable\":\"MERGEABLE\"}"))
                 '((ok "Changes approved" "1 approving review")
                   (wait "Some checks haven't completed yet"
                         "1 in progress, 1 skipped, 1 successful checks" checks)
                   (ok "No conflicts with base branch")))))

(ert-deftest octocat-pr-test-merge-rows-awaiting ()
  "Workflow runs awaiting approval get a row of their own after the checks."
  (let ((pr (octocat-pr-test--pr "{\"mergeable\":\"MERGEABLE\"}"))
        (run (octocat-pr-test--pr "{\"id\":1}")))
    (should (equal (octocat-pr--merge-rows pr (list run))
                   '((wait "1 workflow awaiting approval"
                           "This workflow requires approval from a maintainer." approval)
                     (ok "No conflicts with base branch"))))
    (should (equal (cadr (car (octocat-pr--merge-rows pr (list run run))))
                   "2 workflows awaiting approval"))))

(ert-deftest octocat-pr-test-reviewers-stack ()
  "Several assignees or reviewers stack under their label, lined up after it.
One stays on the line of the other fields; the stacks follow it in order."
  (let* ((pr (json-parse-string
              (concat "{\"latestReviews\":[{\"author\":{\"login\":\"ann\"},\"state\":\"APPROVED\"}],"
                      "\"reviewRequests\":[{\"login\":\"bob\"}],"
                      "\"assignees\":[{\"login\":\"cy\"},{\"login\":\"di\"}]}")))
         (render (lambda (fields)
                   (with-temp-buffer
                     (vui-render (apply #'vui-vstack (octocat-vui--field-lines fields)))
                     (split-string (buffer-substring-no-properties (point-min) (point-max))
                                   "\n" t))))
         (lines (funcall render
                         (list (cons (cons "Assignees" #'ignore)
                                     (cons :stack (octocat-vui--login-items
                                                   (gethash "assignees" pr))))
                               (cons (cons "Reviewers" #'ignore)
                                     (cons :stack (octocat-pr--reviewers pr)))
                               (cons "Milestone" "v1")))))
    (should (equal (mapcar #'string-trim lines)
                   '("Milestone v1" "Assignees @cy" "@di"
                     "Reviewers @ann (approved)" "@bob (pending)")))
    (should (= (string-search "@cy" (nth 1 lines)) (string-search "@di" (nth 2 lines))))
    (should (= (string-search "@ann" (nth 3 lines)) (string-search "@bob" (nth 4 lines))))
    (should (equal (mapcar #'string-trim
                           (funcall render
                                    (list (cons (cons "Reviewers" #'ignore)
                                                (cons :stack (list (list (vui-text "@ann")))))
                                          (cons "Milestone" "v1"))))
                   '("Reviewers @ann · Milestone v1")))))

(ert-deftest octocat-pr-diff-test-review-data ()
  "Only an approval may be submitted without text, or a comment with drafts."
  (should (plist-get (octocat-pr-diff--review-data "Approve") :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data "Comment") :allow-empty))
  (should (plist-get (octocat-pr-diff--review-data "Comment" "R" 2) :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data "Request changes" "R" 2) :allow-empty))
  (should (equal (plist-get (octocat-pr-diff--review-data "Request changes") :flag)
                 "--request-changes")))

(ert-deftest octocat-pr-diff-test-thread-comments ()
  "GraphQL's threads become REST-shaped comments, replies pointing at the first.
The thread's own fields go on its first comment; a draft is pending."
  (let* ((threads (json-parse-string
                   (concat "[{\"id\":\"T1\",\"isResolved\":true,\"path\":\"a.el\","
                           "\"line\":9,\"startLine\":7,\"diffSide\":\"RIGHT\","
                           "\"startDiffSide\":\"LEFT\",\"subjectType\":\"LINE\","
                           "\"viewerCanResolve\":false,\"viewerCanUnresolve\":true,"
                           "\"resolvedBy\":{\"login\":\"b\"},\"comments\":{\"nodes\":["
                           "{\"id\":\"C1\",\"databaseId\":11,\"body\":\"x\\r\\ny\","
                           "\"state\":\"SUBMITTED\",\"author\":{\"login\":\"a\"}},"
                           "{\"id\":\"C2\",\"databaseId\":12,\"body\":\"z\","
                           "\"state\":\"PENDING\",\"viewerCanUpdate\":true,"
                           "\"author\":{\"login\":\"me\"}}]}}]")
                   :null-object :null))
         (cs (append (octocat-pr-diff--thread-comments threads) nil))
         (root (car cs)) (reply (cadr cs)))
    (should (equal (mapcar (lambda (k) (gethash k root))
                           '("id" "node_id" "thread_id" "path" "line" "start_line"
                             "side" "start_side" "subject_type" "body" "resolved"
                             "resolved_by" "can_unresolve" "pending"))
                   '(11 "C1" "T1" "a.el" 9 7 "RIGHT" "LEFT" "line" "x\ny" t "b" t nil)))
    (should (equal (octocat--get root "user" "login") "a"))
    (should (equal (gethash "in_reply_to_id" reply) 11))
    (should (eq (gethash "pending" reply) t))
    (should (eq (gethash "can_edit" reply) t))
    (should (equal (octocat-diff--threads cs) (list cs)))
    (let ((data (make-hash-table :test #'equal)))
      (puthash "threads" threads data)
      (puthash "pending" (make-hash-table) data)
      (should (= (octocat-pr-diff--pending-count data) 1))
      (setq data (octocat-model--review-drop-drafts data))
      (should (= (octocat-pr-diff--pending-count data) 0))
      (should-not (gethash "pending" data))
      (should (= (length (octocat--get (aref (gethash "threads" data) 0) "comments" "nodes"))
                 1)))))

;;;; M-x octocat-pr

(defun octocat-pr-tests--branch-pr (result)
  "Run `octocat-pr' on branch \"topic\" with `gh' answering RESULT.
Return the (REPO NUMBER) it opened, or the message it showed."
  (let (opened shown)
    (cl-letf (((symbol-function 'octocat--current-branch) (lambda () "topic"))
              ((symbol-function 'octocat-repo--current-repo) (lambda () "acme/rocket"))
              ((symbol-function 'octocat--run-gh)
               (lambda (_name args parse callback)
                 (should (equal args '("pr" "view" "--json" "url")))
                 (funcall callback (if (stringp result) (funcall parse result) result))))
              ((symbol-function 'octocat-pr-open)
               (lambda (repo number) (setq opened (list repo number))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (and fmt (setq shown (apply #'format fmt args))))))
      (octocat-pr))
    (or opened shown)))

(ert-deftest octocat-pr-test-open-branch-pr ()
  "`octocat-pr' opens the PR of the branch checked out, if it has one."
  (should (equal (octocat-pr-tests--branch-pr
                  "{\"url\":\"https://github.com/acme/rocket/pull/42\"}")
                 '("acme/rocket" 42)))
  (should (equal (octocat-pr-tests--branch-pr
                  '(error . "no pull requests found for branch \"topic\""))
                 "Octocat: topic has no pull request"))
  (should (equal (octocat-pr-tests--branch-pr '(error . "HTTP 502"))
                 "Octocat: Could not look up the pull request: HTTP 502")))

(ert-deftest octocat-pr-test-open-branch-pr-detached ()
  "`octocat-pr' with no branch checked out says so."
  (cl-letf (((symbol-function 'octocat--current-branch) #'ignore))
    (should-error (octocat-pr) :type 'user-error)))

(provide 'octocat-pr-tests)
;;; octocat-pr-tests.el ends here
