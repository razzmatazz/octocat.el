;;; octocat-timeline-tests.el --- ERT tests for octocat-timeline.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-timeline-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defconst octocat-timeline-tests--issue-json
  (concat "{\"number\":7,\"state\":\"CLOSED\",\"body\":\"opening\","
          "\"createdAt\":\"2026-01-01T10:00:00Z\",\"closedAt\":\"2026-01-03T10:00:00Z\","
          "\"author\":{\"login\":\"ann\"},\"labels\":[],"
          "\"comments\":[{\"author\":{\"login\":\"bob\"},\"body\":\"later\","
          "\"createdAt\":\"2026-01-04T10:00:00Z\"},"
          "{\"author\":{\"login\":\"cy\"},\"body\":\"first\","
          "\"createdAt\":\"2026-01-02T10:00:00Z\"}]}")
  "A closed issue with two comments, the later one listed first.")

(ert-deftest octocat-timeline-test-issue-orders-by-time ()
  "Post, comments and events interleave by timestamp."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (events (json-parse-string
                  (concat "[{\"event\":\"labeled\",\"created_at\":\"2026-01-02T12:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"label\":{\"name\":\"bug\",\"color\":\"d73a4a\"}},"
                          "{\"event\":\"commented\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"closed\",\"created_at\":\"2026-01-03T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"state_reason\":\"completed\"}]")))
         (items (octocat-timeline-items issue "opened this issue" events nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event event comment)))
    (should (equal (plist-get (nth 1 items) :actor) "@cy"))
    (should (equal (plist-get (nth 3 items) :text) "closed this as completed"))
    (should (eq (plist-get (car items) :target) 'body))
    (should (hash-table-p (plist-get (nth 1 items) :target)))))

(ert-deftest octocat-timeline-test-merges-label-events ()
  "One actor's label events within a minute become a single entry."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (ev (lambda (kind actor time name)
               (format "{\"event\":\"%s\",\"created_at\":\"%s\",\"actor\":{\"login\":\"%s\"},\"label\":{\"name\":\"%s\",\"color\":\"d73a4a\"}}"
                       kind time actor name)))
         (events (json-parse-string
                  (concat "["
                          (string-join
                           (list (funcall ev "labeled" "ann" "2026-01-02T12:00:00Z" "bug")
                                 (funcall ev "labeled" "ann" "2026-01-02T12:00:01Z" "docs")
                                 (funcall ev "unlabeled" "ann" "2026-01-02T12:00:02Z" "wip")
                                 (funcall ev "labeled" "bob" "2026-01-02T12:00:03Z" "x")
                                 (funcall ev "labeled" "ann" "2026-01-02T13:00:00Z" "y"))
                           ",")
                          "]")))
         (texts (mapcar (lambda (i) (substring-no-properties (plist-get i :text)))
                        (seq-filter (lambda (i) (eq (plist-get i :kind) 'event))
                                    (octocat-timeline-items issue "opened this issue" events nil)))))
    (should (equal (seq-take texts 3)
                   '("added the  bug   docs  labels and removed the  wip  label"
                     "added the  x  label"
                     "added the  y  label")))))

(ert-deftest octocat-timeline-test-merges-renames ()
  "Consecutive title changes by one actor become one entry."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (ev (lambda (time from to)
               (format "{\"event\":\"renamed\",\"created_at\":\"%s\",\"actor\":{\"login\":\"ann\"},\"rename\":{\"from\":\"%s\",\"to\":\"%s\"}}"
                       time from to)))
         (events (json-parse-string
                  (concat "[" (string-join
                               (list (funcall ev "2026-01-02T12:00:00Z" "a" "b")
                                     (funcall ev "2026-01-02T12:05:00Z" "b" "c"))
                               ",")
                          "]")))
         (renames (seq-filter (lambda (i) (plist-get i :rename))
                              (octocat-timeline-items issue "opened this issue" events nil))))
    (should (= (length renames) 1))
    (should (equal (plist-get (car renames) :rename) '("a" . "c")))
    (should (equal (substring-no-properties (plist-get (car renames) :text))
                   "changed the title a → c"))))

(ert-deftest octocat-timeline-test-issue-close-without-events ()
  "Before the events load, a close still shows, from `closedAt'."
  (let ((items (octocat-timeline-items (json-parse-string octocat-timeline-tests--issue-json)
                                       "opened this issue" nil nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event comment)))
    (should (equal (plist-get (nth 2 items) :actor) ""))))

(ert-deftest octocat-timeline-test-issue-event-text ()
  "Events render as short phrases; unknown ones are skipped."
  (let ((text (lambda (json) (octocat-timeline--event-text (json-parse-string json) nil))))
    (should (equal (funcall text "{\"event\":\"assigned\",\"actor\":{\"login\":\"a\"},\"assignee\":{\"login\":\"a\"}}")
                   "self-assigned this"))
    (should (equal (funcall text "{\"event\":\"assigned\",\"actor\":{\"login\":\"a\"},\"assignee\":{\"login\":\"b\"}}")
                   "assigned @b"))
    (should (equal (substring-no-properties
                    (funcall text "{\"event\":\"renamed\",\"rename\":{\"from\":\"x\",\"to\":\"y\"}}"))
                   "changed the title x → y"))
    (should (equal (funcall text "{\"event\":\"reopened\"}") "reopened this"))
    (should-not (funcall text "{\"event\":\"subscribed\"}"))
    (should-not (funcall text "{\"event\":\"labeled\",\"label\":null}"))))

(ert-deftest octocat-timeline-test-issue-entry-string ()
  "A comment entry carries its target, a quote rail and its body."
  (let* ((comment (json-parse-string
                   "{\"author\":{\"login\":\"bob\"},\"body\":\"hi\\nthere\",\"createdAt\":\"2026-01-04T10:00:00Z\"}"))
         (entry (octocat-timeline--entry-string
                 (list :time "2026-01-04T10:00:00Z" :kind 'comment :actor "@bob"
                       :verb "commented" :body "hi\nthere" :target comment)
                 t 80)))
    (should (string-match-p "@bob commented" entry))
    (should (string-match-p "\n│ hi\n│ there\\'" (substring-no-properties entry)))
    (should (eq (get-text-property (1- (length entry)) 'octocat-timeline-target entry)
                comment))))

(ert-deftest octocat-timeline-test-reactions ()
  "The post, comments and a PR's reviews show their reactions after the date."
  (let* ((rg (lambda (content n)
               (format "\"reactionGroups\":[{\"content\":\"%s\",\"users\":{\"totalCount\":%d}}]"
                       content n)))
         (pr (json-parse-string
              (concat "{\"body\":\"b\",\"createdAt\":\"2026-01-01T10:00:00Z\","
                      "\"author\":{\"login\":\"ann\"}," (funcall rg "HOORAY" 2) ","
                      "\"comments\":[{\"author\":{\"login\":\"bob\"},\"body\":\"c\","
                      "\"createdAt\":\"2026-01-02T10:00:00Z\"," (funcall rg "EYES" 1) "}],"
                      "\"reviews\":[{\"author\":{\"login\":\"cy\"},\"body\":\"r\","
                      "\"state\":\"APPROVED\",\"submittedAt\":\"2026-01-03T10:00:00Z\","
                      (funcall rg "ROCKET" 4) "}]}")))
         (items (octocat-pr--items "o/r" pr nil nil)))
    (should (equal (mapcar (lambda (i) (substring-no-properties (plist-get i :reactions)))
                           items)
                   '("🎉 2" "👀 1" "🚀 4")))
    (let ((heading (car (split-string (substring-no-properties
                                       (octocat-timeline--entry-string (car items) t 80))
                                      "\n"))))
      (should (string-match-p "opened this pull request  .*  🎉 2\\'" heading))))
  ;; None: the heading ends at the date.
  (should-not (string-match-p
               "[[:space:]]\n" (substring-no-properties
                                 (octocat-timeline--entry-string
                                  (list :time "2026-01-04T10:00:00Z" :kind 'comment
                                        :actor "@bob" :verb "commented" :body "hi")
                                  t 80)))))

(ert-deftest octocat-timeline-test-event-line-wraps ()
  "An event line wider than WIDTH breaks, hung under its actor on the rail."
  (let ((entry (substring-no-properties
                (octocat-timeline--entry-string
                 (list :time "" :kind 'event :actor "@bob"
                       :text "changed the title aaa bbb → ccc ddd")
                 nil 20))))
    (should (string-prefix-p "○ @bob changed the\n│ title" entry))
    (should (cl-every (lambda (l) (<= (string-width l) 20))
                      (split-string entry "\n")))))

(ert-deftest octocat-timeline-test-merged-pr ()
  "A merged PR shows its merge, not the close GitHub logs beside it."
  (let* ((pr (json-parse-string
              (concat "{\"body\":\"\",\"createdAt\":\"2026-01-01T10:00:00Z\","
                      "\"mergedAt\":\"2026-01-02T10:00:00Z\",\"closedAt\":\"2026-01-02T10:00:00Z\","
                      "\"author\":{\"login\":\"ann\"},\"comments\":[]}")))
         (events (json-parse-string
                  (concat "[{\"event\":\"closed\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"merged\",\"created_at\":\"2026-01-02T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"}}]")))
         (kinds (lambda (evs)
                  (mapcar (lambda (i) (plist-get i :text))
                          (cdr (octocat-timeline-items pr "opened this pull request" evs nil))))))
    (should (equal (funcall kinds events) '("merged this")))
    ;; Without events the merge still shows, from `mergedAt'.
    (should (equal (funcall kinds nil) '("merged this")))))

(ert-deftest octocat-timeline-test-joins-actions ()
  "One actor's approval, merge and branch deletion read as one line."
  (let* ((item  (lambda (kind actor time &rest props)
                  (append (list :kind kind :actor actor
                                :time (format "2026-01-02T10:%s:00Z" time))
                          props)))
         (items (octocat-timeline--join-actions
                 (list (funcall item 'review "@ann" "00" :verb "approved these changes"
                                :body "" :state "approved")
                       (funcall item 'event "@ann" "05" :text "merged this" :state "merged")
                       (funcall item 'event "@ann" "05" :text "deleted the head branch"
                                :state "head_ref_deleted")
                       (funcall item 'event "@bob" "06" :text "restored the head branch")
                       (funcall item 'review "@bob" "07" :verb "approved these changes"
                                :body "looks good")
                       (funcall item 'event "@bob" "59" :text "reopened this")))))
    (should (equal (mapcar (lambda (i) (plist-get i :text)) items)
                   '("approved these changes, merged this and deleted the head branch"
                     "restored the head branch" nil "reopened this")))
    (should (equal (plist-get (car items) :state) "merged"))
    (should (equal (plist-get (car items) :time) "2026-01-02T10:05:00Z"))
    ;; Logged in the same second, the deletion may come first.
    (should (equal (plist-get (car (octocat-timeline--join-actions
                                    (list (funcall item 'event "@ann" "05"
                                                   :text "deleted the head branch"
                                                   :state "head_ref_deleted")
                                          (funcall item 'event "@ann" "05"
                                                   :text "merged this" :state "merged"))))
                              :text)
                   "merged this and deleted the head branch"))))

(ert-deftest octocat-timeline-test-post-leads ()
  "The opening post comes first even if an extra item predates it."
  (let* ((pr (json-parse-string
              "{\"body\":\"x\",\"createdAt\":\"2026-01-02T10:00:00Z\",\"author\":{\"login\":\"ann\"},\"comments\":[]}"))
         (items (octocat-timeline-items
                 pr "opened this pull request" nil nil
                 (list (list :time "2026-01-01T10:00:00Z" :kind 'commit :actor "" :text "c")))))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items) '(post commit)))))

(ert-deftest octocat-timeline-test-review-events ()
  "Review requests name a user or a team."
  (let ((text (lambda (json) (octocat-timeline--event-text (json-parse-string json) nil))))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_reviewer\":{\"login\":\"zed\"}}")
                   "requested a review from @zed"))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_team\":{\"name\":\"core\"}}")
                   "requested a review from core"))))

(defun octocat-timeline-tests--submit (result)
  "Submit text from an edit dialog, the mutation answering RESULT.
Return (MUTATING-WHILE-RUNNING MUTATING-AFTER REOPENED CLOSED)."
  (let* ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
         (octocat-sync--pending nil)
         (octocat-sync--mutations (make-hash-table :test #'eq))
         (octocat-sync-change-functions nil)
         (inhibit-message t)
         (source (generate-new-buffer " source"))
         running reopened closed)
    (octocat-sync-define-mutation post ()
      :label "Posting comment…"
      :resources (lambda () '((issue "o/r" 1)))
      :send (lambda (done)
              (setq running (plist-get (octocat-sync-read '(issue "o/r" 1)) :mutating))
              (funcall done result)))
    (unwind-protect
        (cl-letf (((symbol-function 'octocat-sync--props) (lambda (_) nil))
                  ((symbol-function 'octocat--open-edit-buffer)
                   (lambda (&rest args) (setq reopened args))))
          (with-temp-buffer
            (setq octocat-edit--title "New comment"
                  octocat-edit--submit-fn #'ignore)
            (octocat-timeline-submit '(post) "hello" source (lambda () (setq closed t))))
          (list running (plist-get (octocat-sync-read '(issue "o/r" 1)) :mutating)
                reopened closed))
      (kill-buffer source))))

(ert-deftest octocat-timeline-test-submit-success ()
  "A submitted dialog closes at once and shows its change under way."
  (pcase-let ((`(,running ,after ,reopened ,closed)
               (octocat-timeline-tests--submit nil)))
    (should (equal running '((action . "Posting comment…"))))
    (should-not after)
    (should-not reopened)
    (should closed)))

(ert-deftest octocat-timeline-test-submit-failure-reopens ()
  "A failed submission reopens the dialog with the typed text."
  (pcase-let ((`(,_running ,after ,reopened ,_closed)
               (octocat-timeline-tests--submit '(error . "boom"))))
    (should-not after)
    (should (equal (nth 0 reopened) "New comment"))
    (should (equal (nth 3 reopened) "hello"))))

(ert-deftest octocat-timeline-test-edit-values-send ()
  "Editing labels adds and removes them in one `gh ... edit'."
  (let (args)
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name a &rest _) (setq args a))))
      (funcall (plist-get (funcall (gethash 'edit-values octocat-sync--mutations)
                                   "pr" "o/r" 5 "label" '("bug" "ui") '("wip"))
                          :send)
               #'ignore))
    (should (equal args '("pr" "edit" "5" "--repo" "o/r"
                          "--add-label" "bug,ui" "--remove-label" "wip")))))

(ert-deftest octocat-timeline-test-edit-values-diff ()
  "Picking assignees submits only who was added or removed, without the @."
  (let ((item (make-hash-table :test #'equal)) submitted)
    (puthash "assignees"
             (vector (let ((u (make-hash-table :test #'equal))) (puthash "login" "ann" u) u)
                     (let ((u (make-hash-table :test #'equal))) (puthash "login" "bob" u) u))
             item)
    (cl-letf (((symbol-function 'octocat-sync-detail-read) (lambda (_) item))
              ((symbol-function 'octocat-vui-list--stored)
               (lambda (&rest _) (lambda (_repo cb) (funcall cb '("ann" "bob" "cy")))))
              ((symbol-function 'run-at-time) (lambda (_ _ f) (funcall f)))
              ((symbol-function 'octocat--still-selected-p) (lambda (_) t))
              ((symbol-function 'octocat-vui-list--read-multiple)
               (lambda (_prompt candidates selected)
                 (should (equal candidates '("@ann" "@bob" "@cy")))
                 (should (equal selected '("@ann" "@bob")))
                 '("@bob" "cy")))
              ((symbol-function 'octocat-sync-submit)
               (lambda (spec &rest _) (setq submitted spec))))
      (octocat-timeline-edit-values "issue" "o/r" 3 "assignee"))
    (should (equal submitted '(edit-values "issue" "o/r" 3 "assignee" ("cy") ("ann"))))))

(defconst octocat-timeline-tests--mine-json
  (concat "{\"id\":\"I_7\",\"number\":7,\"state\":\"OPEN\",\"body\":\"opening\","
          "\"createdAt\":\"2026-01-01T10:00:00Z\",\"author\":{\"login\":\"me\"},\"labels\":[],"
          "\"comments\":[{\"id\":\"IC_5\",\"author\":{\"login\":\"me\"},\"body\":\"mine\","
          "\"createdAt\":\"2026-01-02T10:00:00Z\",\"viewerDidAuthor\":true,"
          "\"reactionGroups\":[{\"content\":\"HEART\",\"users\":{\"totalCount\":1}}],"
          "\"url\":\"https://github.com/o/r/issues/7#issuecomment-5\"}]}")
  "An open issue by \"me\", with one comment of mine, given a ❤️.")

(defmacro octocat-timeline-tests--with-issue (&rest body)
  "Run BODY with issue o/r#7 of `octocat-timeline-tests--mine-json' stored.
The viewer is \"me\".  `gh' is not run: each call is pushed to `calls'
as (ARGS PARSE CALLBACK).  `issue' reads the issue as its page does."
  (declare (indent 0))
  `(let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
         (octocat-sync--pending nil)
         (octocat-sync-change-functions nil)
         (octocat-sync-invalidate-functions nil)
         (calls nil))
     (octocat-sync--write octocat-sync--db (octocat-sync-spec-key '(issue "o/r" 7))
                          (octocat-sync-detail
                           (json-parse-string octocat-timeline-tests--mine-json) '("comments")
                           (lambda (f) (octocat-sync-item 'issue "o/r" f)))
                          (float-time))
     (octocat-sync--write octocat-sync--db (octocat-sync-spec-key '(viewer))
                          (let ((h (make-hash-table :test #'equal))) (puthash "login" "me" h) h)
                          (float-time))
     (cl-letf (((symbol-function 'octocat--run-gh)
                (lambda (_name args parse callback) (push (list args parse callback) calls))))
       (cl-flet ((issue () (octocat-sync-detail-read '(issue "o/r" 7))))
         ,@body))))

(defun octocat-timeline-tests--answer (call output)
  "Answer the `gh' CALL with OUTPUT, what it printed or (error . MESSAGE).
CALL is as `octocat-timeline-tests--with-issue' pushes it."
  (funcall (nth 2 call) (if (stringp output) (funcall (nth 1 call) output) output)))

(ert-deftest octocat-timeline-test-post-comment ()
  "A comment shows at once, behind a spinner, and GitHub's takes its place."
  (octocat-timeline-tests--with-issue
    (octocat-sync-submit '(comment "issue" "o/r" 7 "new"))
    (should (equal (car (car calls))
                   '("api" "repos/o/r/issues/7/comments" "-f" "body=new")))
    (let* ((items (octocat-timeline-items (issue) "opened this issue" nil nil))
           (new   (car (last items))))
      (should (= (length items) 3))
      (should (equal (plist-get new :actor) "@me"))
      (should (equal (plist-get new :body) "new"))
      (should (equal (plist-get new :pending) "posting…"))
      (with-temp-buffer
        (let ((entry (octocat-timeline--entry-string new nil 80)))
          (should (string-match-p "@me commented  . posting…" (substring-no-properties entry)))
          (should (text-property-any 0 (length entry) 'octocat-vui-spinner t entry)))))
    ;; Not stored before GitHub accepts it.
    (should (= (length (gethash "comments"
                                (car (octocat-sync--read octocat-sync--db
                                                         "(issue \"o/r\" 7)"))))
               1))
    (octocat-timeline-tests--answer
     (car calls)
     (concat "{\"id\":9,\"node_id\":\"IC_9\",\"user\":{\"login\":\"me\"},\"body\":\"new\","
             "\"created_at\":\"2026-01-05T10:00:00Z\",\"author_association\":\"OWNER\","
             "\"html_url\":\"https://github.com/o/r/issues/7#issuecomment-9\"}"))
    (let ((comments (gethash "comments" (issue))))
      (should (= (length comments) 2))
      (should (equal (octocat--comment-numeric-id (aref comments 1)) "9"))
      (should (equal (gethash "createdAt" (aref comments 1)) "2026-01-05T10:00:00Z"))
      (should-not (gethash octocat-timeline--pending (aref comments 1))))
    ;; Stored as GitHub has it, so the refetch finds no gap to fill.
    (should (= (length (gethash "comments"
                                (car (octocat-sync--read octocat-sync--db
                                                         "(issue \"o/r\" 7)"))))
               2))))

(ert-deftest octocat-timeline-test-post-comment-failure ()
  "A comment GitHub refused is gone again, and the page refetched."
  (octocat-timeline-tests--with-issue
    (octocat-sync-submit '(comment "issue" "o/r" 7 "new"))
    (should (= (length (gethash "comments" (issue))) 2))
    (let ((inhibit-message t))
      (octocat-timeline-tests--answer (car calls) '(error . "boom")))
    (should (= (length (gethash "comments" (issue))) 1))
    (should-not (plist-get (octocat-sync-read '(issue "o/r" 7)) :mutating))
    (should (plist-get (octocat-sync-read '(issue "o/r" 7)) :outdated))))

(ert-deftest octocat-timeline-test-edit-comment ()
  "An edited comment shows its new body at once, behind a spinner."
  (octocat-timeline-tests--with-issue
    (octocat-sync-submit '(edit-comment "issue" "o/r" 7 "5" "changed"))
    (let ((comment (aref (gethash "comments" (issue)) 0)))
      (should (equal (gethash "body" comment) "changed"))
      (should (equal (gethash octocat-timeline--pending comment) "saving…")))
    (octocat-timeline-tests--answer (car calls) "{}")
    (let ((comment (aref (gethash "comments" (issue)) 0)))
      (should (equal (gethash "body" comment) "changed"))
      (should-not (gethash octocat-timeline--pending comment)))))

(ert-deftest octocat-timeline-test-edit-body ()
  "An edited opening post shows its new body at once, behind a spinner."
  (octocat-timeline-tests--with-issue
    (octocat-sync-submit '(edit-body "issue" "o/r" 7 "new body"))
    (let ((post (car (octocat-timeline-items (issue) "opened this issue" nil nil))))
      (should (equal (plist-get post :body) "new body"))
      (should (equal (plist-get post :pending) "saving…")))
    (octocat-timeline-tests--answer (car calls) "")
    (let ((post (car (octocat-timeline-items (issue) "opened this issue" nil nil))))
      (should (equal (plist-get post :body) "new body"))
      (should-not (plist-get post :pending)))))

(ert-deftest octocat-timeline-test-react ()
  "A reaction given or taken back shows at once, and stays once GitHub has it."
  (octocat-timeline-tests--with-issue
    (octocat-sync--write octocat-sync--db (octocat-sync-spec-key '(viewer-reactions "IC_5"))
                         (json-parse-string "{\"given\":[\"HEART\"]}")
                         (float-time))
    (cl-flet ((reactions ()
                (mapcar (lambda (i) (and (plist-get i :reactions)
                                         (substring-no-properties (plist-get i :reactions))))
                        (octocat-timeline-items (issue) "opened this issue" nil nil)))
              (given ()
                (octocat--get (plist-get (octocat-sync-read '(viewer-reactions "IC_5")) :data)
                              "given")))
      (octocat-sync-submit '(react "issue" "o/r" 7 "I_7" "HOORAY" t))
      (octocat-sync-submit '(react "issue" "o/r" 7 "IC_5" "HEART" nil))
      (should (equal (reactions) '("🎉 1" nil)))
      (should (equal (given) []))
      (let ((args (car (nth 1 calls))))
        (should (string-match-p "addReaction" (nth 3 args)))
        (should (equal (nthcdr 4 args) '("-f" "id=I_7" "-f" "content=HOORAY"))))
      (should (string-match-p "removeReaction" (nth 3 (car (car calls)))))
      (octocat-timeline-tests--answer (nth 1 calls) "{}")
      (octocat-timeline-tests--answer (car calls) "{}")
      (should-not octocat-sync--pending)
      (should (equal (reactions) '("🎉 1" nil)))
      (should (equal (given) [])))))

(ert-deftest octocat-timeline-test-react-picks ()
  "Picking a reaction you gave takes it back; the picker ticks it."
  (let (prompted submitted)
    (cl-letf (((symbol-function 'octocat-timeline-target) (lambda () 'body))
              ((symbol-function 'octocat-sync-detail-read)
               (lambda (_) (json-parse-string "{\"id\":\"I_7\"}")))
              ((symbol-function 'octocat-sync-get)
               (lambda (spec cb)
                 (should (equal spec '(viewer-reactions "I_7")))
                 (funcall cb (json-parse-string "{\"given\":[\"THUMBS_UP\"]}"))))
              ((symbol-function 'run-at-time) (lambda (_ _ f) (funcall f)))
              ((symbol-function 'octocat--still-selected-p) (lambda (_) t))
              ((symbol-function 'read-multiple-choice)
               (lambda (_prompt choices) (setq prompted choices) (assq ?+ choices)))
              ((symbol-function 'octocat-sync-submit)
               (lambda (spec &rest _) (setq submitted spec))))
      (octocat-timeline-react "issue" "o/r" 7))
    (should (equal (car prompted) '(?+ "👍 +1 ✓")))
    (should (equal (nth 1 prompted) '(?- "👎 -1")))
    (should (equal submitted '(react "issue" "o/r" 7 "I_7" "THUMBS_UP" nil)))))

(provide 'octocat-timeline-tests)
;;; octocat-timeline-tests.el ends here
