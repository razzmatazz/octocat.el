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

(defun octocat-pr-test--field-lines (fields &optional width)
  "Return the lines `octocat-vui--field-lines' makes of FIELDS within WIDTH."
  (with-temp-buffer
    (vui-render (apply #'vui-vstack (octocat-vui--field-lines fields nil width)))
    (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t)))

(ert-deftest octocat-pr-test-merge-message ()
  "Default messages follow GitHub's."
  (let ((pr (octocat-pr-test--pr
             "{\"number\":7,\"title\":\"Fix\",\"headRefName\":\"fix\",
               \"headRepositoryOwner\":{\"login\":\"me\"},
               \"commits\":{\"nodes\":[{\"commit\":{\"messageHeadline\":\"a\"}},
                                       {\"commit\":{\"messageHeadline\":\"b\"}}]}}")))
    (should (equal (octocat-pr--merge-message 'merge pr)
                   "Merge pull request #7 from me/fix\n\nFix"))
    (should (equal (octocat-pr--merge-message 'squash pr) "Fix (#7)\n\n* a\n* b"))
    (should (equal (octocat-pr--merge-message 'rebase pr) ""))))

(defun octocat-pr-test--stack (&rest prs)
  "Return a stack of PRS, bottom first.
It is as `octocat-pr--use-stack' gives it.  Each PR is a list of
NUMBER, STATE, DRAFT and MERGEABLE."
  (octocat-sync--parse
   (json-serialize
    `((number . 17) (baseRefName . "main")
      (entries
       (nodes
        . ,(vconcat
            (seq-map-indexed
             (pcase-lambda (`(,n ,state ,draft ,mergeable) i)
               `((position . ,(1+ i))
                 (pullRequest (number . ,n) (title . ,(format "Layer %d" n))
                              (state . ,state) (isDraft . ,draft)
                              (mergeable . ,mergeable))))
             prs))))))))

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
                   '("≡ Stack #17  into main  ✓ Ready to merge as stack"
                     "  #16  (draft) Layer 16"
                     "  #15  Layer 15"
                     "  #14  Layer 14")))
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
                 '("≡ Stack #17  into main  ✗ Unable to merge as stack"
                   "  #16  Layer 16"
                   "  #15  Layer 15  ✗ has conflicts"
                   "  #14  (draft) Layer 14  ✗ is a draft")))
  ;; A pull request in no stack shows none.
  (should-not (octocat-pr--stack-section "o/r" (json-parse-string "{\"number\":15}") nil 80)))

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
  "Commits are listed oldest first, as the commit rows read them."
  (let* ((pr (octocat-pr-test--pr
              "{\"commits\":{\"nodes\":[
                 {\"commit\":{\"oid\":\"aaa\",\"messageHeadline\":\"a\",
                  \"committedDate\":\"2026-10-03T12:00:00Z\",
                  \"author\":{\"name\":\"Me\",\"user\":{\"login\":\"me\"}}}},
                 {\"commit\":{\"oid\":\"bbb\",\"messageHeadline\":\"b\",
                  \"committedDate\":\"2026-10-03T12:30:00Z\",
                  \"author\":{\"name\":\"Anon\",\"user\":null}}},
                 {\"commit\":{\"oid\":\"ccc\",\"messageHeadline\":\"c\",
                  \"committedDate\":\"2026-10-05T12:00:00Z\"}}]}}"))
         (commits (octocat-pr--commits pr)))
    (should (equal (mapcar (lambda (c) (gethash "oid" c)) commits) '("aaa" "bbb" "ccc")))
    (should (equal (mapcar #'octocat--commit-author (butlast commits)) '("@me" "Anon")))
    ;; Short subjects get the minimum column; long ones what the page leaves.
    (should (= (octocat-vui--subject-width commits 112 3)
               octocat-vui--subject-min-width))
    (puthash "messageHeadline" (make-string 200 ?x) (car commits))
    (should (= (+ (octocat-vui--subject-width commits 112 3) 2 7 2 2 3 2
                  (apply #'max (mapcar (lambda (c) (string-width (octocat-vui--date c)))
                                       commits)))
               112))))

(ert-deftest octocat-pr-test-merge-allowed ()
  "Only the methods the repo allows are offered, in GitHub's order."
  (should (equal (octocat-model-pr-merge-allowed
                  (json-parse-string "{\"mergeCommitAllowed\":false,
                                       \"squashMergeAllowed\":true,
                                       \"rebaseMergeAllowed\":true}"))
                 '(squash rebase))))

(ert-deftest octocat-pr-test-merge-with-options ()
  "As the repo's options land, a method it forbids is unpicked."
  (let ((all '(merge squash rebase))
        (defaults '((merge . "m") (squash . "s") (rebase . ""))))
    ;; Allowed: kept.
    (should (eq (plist-get (octocat-pr--merge-with-options
                            (octocat-pr--merge-data 'squash all defaults nil)
                            (json-parse-string
                             "{\"squashMergeAllowed\":true,\"rebaseMergeAllowed\":true}"))
                           :method)
                'squash))
    ;; Forbidden, with several left: none picked.
    (let ((data (octocat-pr--merge-with-options
                 (octocat-pr--merge-data 'merge all defaults nil)
                 (json-parse-string
                  "{\"squashMergeAllowed\":true,\"rebaseMergeAllowed\":true}"))))
      (should-not (plist-get data :method))
      (should (equal (plist-get data :methods) '(squash rebase)))
      (should (equal (plist-get data :defaults) defaults)))
    ;; The only one left: picked.
    (should (eq (plist-get (octocat-pr--merge-with-options
                            (octocat-pr--merge-data nil all defaults nil)
                            (json-parse-string "{\"squashMergeAllowed\":true}"))
                           :method)
                'squash))))

(ert-deftest octocat-pr-test-merge-with-options-delete ()
  "Deleting the branch follows the repo, unless the user chose."
  (let ((options (json-parse-string
                  "{\"mergeCommitAllowed\":true,\"deleteBranchOnMerge\":true}")))
    (should (plist-get (octocat-pr--merge-with-options
                        (octocat-pr--merge-data 'merge '(merge) nil nil)
                        options)
                       :delete))
    (should-not (plist-get (octocat-pr--merge-with-options
                            (octocat-pr--merge-data 'merge '(merge) nil nil t)
                            options)
                           :delete))))

(ert-deftest octocat-pr-test-merge-switch ()
  "Switching method replaces the default message, not one typed."
  (let ((defaults '((merge . "Merge it") (squash . "Squash it"))))
    (with-temp-buffer
      (setq-local octocat-edit-title "Merge PR #1")
      (setq-local octocat-edit-user-data (octocat-pr--merge-data nil '(merge squash) defaults nil))
      (octocat-pr--merge-switch (octocat-pr--merge-data 'squash '(squash) defaults nil))
      (should (equal (buffer-string) "Squash it"))
      (erase-buffer)
      (insert "Mine")
      (octocat-pr--merge-switch (octocat-pr--merge-data 'merge '(merge) defaults nil))
      (should (equal (buffer-string) "Mine"))
      (should (eq (plist-get octocat-edit-user-data :method) 'merge)))))

(ert-deftest octocat-pr-test-merge-initial-method ()
  "The last method is kept while allowed; a lone method is always picked."
  (should (eq (octocat-pr--merge-initial-method '(merge squash) 'squash) 'squash))
  (should-not (octocat-pr--merge-initial-method '(merge squash) 'rebase))
  (should-not (octocat-pr--merge-initial-method '(merge squash) nil))
  (should (eq (octocat-pr--merge-initial-method '(rebase) 'squash) 'rebase)))

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
                     \"latestReviews\":{\"nodes\":[{\"state\":\"APPROVED\"}]},
                     \"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{
                       \"contexts\":{\"nodes\":[{\"conclusion\":\"SUCCESS\"},
                                              {\"conclusion\":\"SKIPPED\"},
                                              {\"status\":\"IN_PROGRESS\"}]}}}}]},
                     \"mergeable\":\"MERGEABLE\"}"))
                 '((ok "Changes approved" "1 approving review")
                   (wait "Some checks haven't completed yet"
                         "1 in progress, 1 skipped, 1 successful checks" checks)
                   (ok "No conflicts with base branch"
                       "Merging can be performed automatically.")))))

(ert-deftest octocat-pr-test-merge-rows-blocked ()
  "A blocked PR without conflicts gets a row saying so, and no promise of merging."
  (should (equal (octocat-pr--merge-rows
                  (octocat-pr-test--pr "{\"mergeable\":\"MERGEABLE\",
                                         \"mergeStateStatus\":\"BLOCKED\"}"))
                 '((ok "No conflicts with base branch" nil)
                   (fail "Merging is blocked"))))
  (should (equal (octocat-pr--merge-rows
                  (octocat-pr-test--pr "{\"mergeable\":\"CONFLICTING\",
                                         \"mergeStateStatus\":\"BLOCKED\"}"))
                 '((fail "This branch has conflicts that must be resolved"
                         "Use the web editor or the command line to resolve conflicts.")))))

(ert-deftest octocat-pr-test-merge-rows-awaiting ()
  "Workflow runs awaiting approval get a row of their own after the checks."
  (let ((pr (octocat-pr-test--pr "{\"mergeable\":\"MERGEABLE\"}"))
        (run (octocat-pr-test--pr "{\"id\":1}")))
    (should (equal (octocat-pr--merge-rows pr (list run))
                   '((wait "1 workflow awaiting approval"
                           "This workflow requires approval from a maintainer." approval)
                     (ok "No conflicts with base branch"
                         "Merging can be performed automatically."))))
    (should (equal (cadr (car (octocat-pr--merge-rows pr (list run run))))
                   "2 workflows awaiting approval"))))

(ert-deftest octocat-pr-test-reviewers-line ()
  "Several assignees or reviewers go on a line of their own, after the others.
One stays on the line of the other fields; the lines follow it in order."
  (let* ((pr (json-parse-string
              (concat "{\"latestReviews\":{\"nodes\":[{\"author\":{\"login\":\"ann\"},"
                      "\"state\":\"APPROVED\"}]},"
                      "\"reviewRequests\":{\"nodes\":[{\"requestedReviewer\":{\"login\":\"bob\"}}]},"
                      "\"assignees\":{\"nodes\":[{\"login\":\"cy\"},{\"login\":\"di\"}]}}")))
         (lines (octocat-pr-test--field-lines
                 (list (cons (cons "Assignees" #'ignore)
                             (cl-list* :line ", " (octocat-vui--login-items
                                                   (octocat--nodes pr "assignees"))))
                       (cons (cons "Reviewers" #'ignore)
                             (cl-list* :line ", " (octocat-pr--reviewers pr)))
                       (cons "Milestone" "v1")))))
    (should (equal (mapcar #'string-trim lines)
                   '("Milestone v1" "Assignees @cy, @di"
                     "Reviewers @ann (approved), @bob (pending)")))
    (should (equal (mapcar #'string-trim
                           (octocat-pr-test--field-lines
                            (list (cons (cons "Reviewers" #'ignore)
                                        (list :line ", " (list (vui-text "@ann"))))
                                  (cons "Milestone" "v1"))))
                   '("Reviewers @ann · Milestone v1")))))

(ert-deftest octocat-pr-test-field-lines-wrap ()
  "A field's line of its own wraps within the width, lined up under its first item.
Fields that would take the first line past the width get one too."
  (let ((lines (octocat-pr-test--field-lines
                (list (cons "Labels" (list :line " " "alpha" "beta" "gamma")))
                30)))
    (should (equal (mapcar #'string-trim lines) '("Labels alpha beta" "gamma")))
    (should (= (string-search "alpha" (nth 0 lines)) (string-search "gamma" (nth 1 lines)))))
  (should (equal (mapcar #'string-trim
                         (octocat-pr-test--field-lines
                          (list (cons "Milestone" "v1")
                                (cons "Labels" (list :line " " "a-rather-long-label")))
                          30))
                 '("Milestone v1" "Labels a-rather-long-label"))))

(ert-deftest octocat-pr-diff-test-review-data ()
  "Only an approval may be submitted without text, or a comment with drafts."
  (should (plist-get (octocat-pr-diff--review-data 'approve) :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data 'comment) :allow-empty))
  (should (plist-get (octocat-pr-diff--review-data 'comment "R" 2) :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data 'request-changes "R" 2) :allow-empty)))

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
    (let ((data (octocat--table "reviewThreads" (octocat--table "nodes" threads)
                                "reviews" (octocat--table "nodes" (vector (octocat--table))))))
      (should (= (octocat-pr-diff--pending-count data) 1))
      (setq data (octocat-model--review-drop-drafts data))
      (should (= (octocat-pr-diff--pending-count data) 0))
      (should-not (octocat-model-pending-review data))
      (should (= (length (octocat--get (aref (octocat--nodes data "reviewThreads") 0)
                                       "comments" "nodes"))
                 1)))))

;;;; M-x octocat-pr

(defun octocat-pr-tests--branch-pr (result)
  "Run `octocat-pr' on branch \"topic\" with `gh' answering RESULT.
Return the (REPO NUMBER) it opened, or the message it showed."
  (let (opened shown)
    (cl-letf (((symbol-function 'octocat--current-branch) (lambda () "topic"))
              ((symbol-function 'octocat-clone-current-repo) (lambda () "acme/rocket"))
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

(ert-deftest octocat-pr-test-jump-ref ()
  "`C-c C-j' on a PR's page finds files at the PR's head commit."
  (let ((pr (json-parse-string
             "{\"commits\":{\"nodes\":[{\"commit\":{\"oid\":\"abc1234\"}}]}}")))
    (with-temp-buffer
      (setq-local octocat--pr-diff-repo "o/r"
                  octocat--pr-diff-number 5
                  octocat--ref-function #'octocat-pr--current-head)
      (cl-letf (((symbol-function 'octocat-model-detail-read)
                 (lambda (spec) (and (equal spec '(pr "o/r" 5)) pr)))
                ((symbol-function 'octocat-tree--file-ref) (lambda (_repo _ref) "main")))
        (should (equal (octocat--search-current-ref "o/r") "abc1234"))
        (setq pr nil)
        (should-not (octocat--search-current-ref "o/r"))))))

(ert-deftest octocat-pr-test-timeline-urls ()
  "A review carries its URL, a commit its place in the PR."
  (let* ((pr (json-parse-string
              (concat "{\"number\":5,\"url\":\"https://github.com/o/r/pull/5\","
                      "\"reviews\":{\"nodes\":[{\"state\":\"APPROVED\",\"body\":\"\","
                      "\"url\":\"https://github.com/o/r/pull/5#pullrequestreview-8\"}]},"
                      "\"commits\":{\"nodes\":[{\"commit\":{\"oid\":\"abc1234\"}}]}}"))))
    (should (equal (plist-get (car (octocat-pr--review-items pr)) :url)
                   "https://github.com/o/r/pull/5#pullrequestreview-8"))
    (should (equal (plist-get (car (octocat-pr--commit-items "o/r" pr)) :url)
                   "https://github.com/o/r/pull/5/commits/abc1234"))))

(ert-deftest octocat-pr-test-review-comment-url ()
  "A review comment on the diff carries its URL; a draft does not."
  (let* ((thread (lambda (state)
                   (json-parse-string
                    (format (concat "[{\"id\":\"T\",\"path\":\"a\",\"line\":1,"
                                    "\"comments\":{\"nodes\":[{\"id\":\"C\",\"state\":\"%s\","
                                    "\"url\":\"https://github.com/o/r/pull/5#discussion_r9\"}]}}]")
                            state))))
         (url (lambda (state)
                (get-text-property 0 'octocat-url
                                   (octocat-diff--tag
                                    "x" (aref (octocat-pr-diff--thread-comments (funcall thread state)) 0))))))
    (should (equal (funcall url "SUBMITTED") "https://github.com/o/r/pull/5#discussion_r9"))
    (should-not (funcall url "PENDING"))))

(provide 'octocat-pr-tests)
;;; octocat-pr-tests.el ends here
