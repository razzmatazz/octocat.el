;;; octocat-sync-tests.el --- ERT tests for octocat-sync.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-sync-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-sync-tests--db ()
  "Return a fresh in-memory store."
  (octocat-sync--create (sqlite-open nil)))

(defun octocat-sync-tests--table (&rest pairs)
  "Return a hash table of PAIRS, alternating keys and values."
  (let ((h (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) h))
    h))

(defun octocat-sync-tests--issue (title &optional author)
  "Return issue o/r#12 titled TITLE, by the user AUTHOR when given."
  (octocat-sync-entity
   'issue "issue:o/r#12"
   (apply #'octocat-sync-tests--table "title" title
          (and author (list "author" (octocat-sync-entity
                                      'user (concat "user:" author)
                                      (octocat-sync-tests--table "login" author)))))))

(ert-deftest octocat-sync-test-round-trip ()
  "A write splits out entities, links them transitively and reads back the tree."
  (let ((db (octocat-sync-tests--db)))
    (should (equal (octocat-sync--write
                    db "list"
                    (octocat-sync-tests--table
                     "nodes" (vector (octocat-sync-tests--issue "Crash" "alice"))
                     "totalCount" 1)
                    1.0)
                   '("list")))
    (should (equal (sort (mapcar #'car (sqlite-select db "SELECT entity FROM link")) #'string<)
                   '("issue:o/r#12" "user:alice")))
    (pcase-let ((`(,data ,fetched-at ,error) (octocat-sync--read db "list")))
      (should (= fetched-at 1.0))
      (should-not error)
      (should (= (gethash "totalCount" data) 1))
      (let ((issue (aref (gethash "nodes" data) 0)))
        (should (equal (gethash "title" issue) "Crash"))
        (should (equal (gethash "login" (gethash "author" issue)) "alice"))))))

(ert-deftest octocat-sync-test-unchanged-notifies-nothing ()
  "A refetch with the same body and entities touches nothing."
  (let ((db (octocat-sync-tests--db))
        (tree (lambda () (octocat-sync-tests--table
                          "nodes" (vector (octocat-sync-tests--issue "Crash"))))))
    (octocat-sync--write db "list" (funcall tree) 1.0)
    (should-not (octocat-sync--write db "list" (funcall tree) 2.0))
    (should (= (nth 1 (octocat-sync--read db "list")) 2.0))))

(ert-deftest octocat-sync-test-entity-change-notifies-linked ()
  "Renaming an entity notifies every resource linked to it, and no other."
  (let ((db (octocat-sync-tests--db)))
    (octocat-sync--write db "list"
                         (octocat-sync-tests--table "nodes" (vector (octocat-sync-tests--issue "Crash")))
                         1.0)
    (octocat-sync--write db "other" (octocat-sync-tests--table "n" 1) 1.0)
    (should (equal (sort (octocat-sync--write db "issue" (octocat-sync-tests--issue "Boom") 2.0)
                         #'string<)
                   '("issue" "list")))
    (should (equal (gethash "title" (aref (gethash "nodes" (car (octocat-sync--read db "list"))) 0))
                   "Boom"))))

(ert-deftest octocat-sync-test-merge-keeps-missing-fields ()
  "A merge keeps fields the fetch lacked, and stores a null."
  (let ((db (octocat-sync-tests--db)))
    (octocat-sync--merge db "user:a" 'user (octocat-sync-tests--table "login" "a" "name" "A") 1.0)
    (should (octocat-sync--merge db "user:a" 'user (octocat-sync-tests--table "bio" nil) 2.0))
    (should-not (octocat-sync--merge db "user:a" 'user (octocat-sync-tests--table "bio" nil) 3.0))
    (let ((fields (octocat-sync--stored-fields db "user:a")))
      (should (equal (gethash "name" fields) "A"))
      (should (eq (gethash "bio" fields 'absent) nil)))))

(ert-deftest octocat-sync-test-error-keeps-data ()
  "A failed fetch is recorded beside the data, and a success clears it."
  (let ((db (octocat-sync-tests--db)))
    (octocat-sync--write db "r" (octocat-sync-tests--table "n" 1) 1.0)
    (octocat-sync--write-error db "r" "boom" 'transient 1.0)
    (pcase-let ((`(,data ,_ ,error) (octocat-sync--read db "r")))
      (should (= (gethash "n" data) 1))
      (should (equal error "boom")))
    (octocat-sync--write db "r" (octocat-sync-tests--table "n" 1) 2.0)
    (should-not (nth 2 (octocat-sync--read db "r")))))

(ert-deftest octocat-sync-test-collect ()
  "Collection deletes old resources and failed fetches, then unlinked entities only."
  (let ((db (octocat-sync-tests--db))
        (octocat-sync-keep-for 100))
    (octocat-sync--write db "old" (octocat-sync-tests--table
                                   "user" (octocat-sync-user
                                           (octocat-sync-tests--table "login" "carol")))
                         1.0)
    (octocat-sync--write db "new" (octocat-sync-tests--table
                                   "nodes" (vector (octocat-sync-tests--issue "A")))
                         500.0)
    (octocat-sync--write-error db "failed" "boom" 'transient 400.0)
    (should (= (octocat-sync--collect db 550.0) 2))
    (should (equal (mapcar #'car (sqlite-select db "SELECT key FROM resource")) '("new")))
    ;; The issue is still linked; carol was linked only from the old resource.
    (should (equal (mapcar #'car (sqlite-select db "SELECT key FROM entity"))
                   '("issue:o/r#12")))))

(ert-deftest octocat-sync-test-schema ()
  "An older schema is recreated; a newer one signals."
  (let ((db (sqlite-open nil)))
    (sqlite-execute db "CREATE TABLE resource (key TEXT)")
    (octocat-sync--create db)
    (sqlite-select db "SELECT hash FROM resource")
    (should (= (caar (sqlite-select db "PRAGMA user_version")) octocat-sync--schema))
    (sqlite-execute db "PRAGMA user_version = 99")
    (should-error (octocat-sync--create db) :type 'user-error)))

(ert-deftest octocat-sync-test-null-becomes-nil ()
  "A `:null' from `json-parse-string' is stored and read back as nil."
  (let ((db (octocat-sync-tests--db)))
    (octocat-sync--write db "r" (json-parse-string "{\"a\":null,\"b\":[null]}") 1.0)
    (let ((data (car (octocat-sync--read db "r"))))
      (should (eq (gethash "a" data 'absent) nil))
      (should (equal (gethash "b" data) [nil])))))

(ert-deftest octocat-sync-test-partial ()
  "An unfetched resource whose entity a list stored reads as :partial."
  (let* ((octocat-sync--db (octocat-sync-tests--db))
         (octocat-sync--resources (make-hash-table :test #'eq))
         (octocat-sync--loading (make-hash-table :test #'equal)))
    (octocat-sync-define-resource issue (repo number)
      :entity (octocat-sync-item-key 'issue repo number))
    (octocat-sync--write octocat-sync--db "list"
                         (octocat-sync-tests--table
                          "nodes" (vector (octocat-sync-item
                                           'issue "O/R"
                                           (json-parse-string
                                            "{\"number\":12,\"title\":\"Crash\",\"author\":{\"login\":\"Alice\"},\"labels\":[{\"name\":\"bug\",\"color\":\"f00\"}]}"))))
                         1.0)
    (should (equal (sort (mapcar #'car (sqlite-select octocat-sync--db "SELECT key FROM entity"))
                         #'string<)
                   '("issue:o/r#12" "label:o/r/bug" "user:alice")))
    (let ((snap (octocat-sync-read '(issue "o/r" 12))))
      (should-not (plist-get snap :data))
      (should (equal (gethash "title" (plist-get snap :partial)) "Crash"))
      (should (equal (gethash "login" (gethash "author" (plist-get snap :partial))) "Alice"))
      (should (equal (gethash "color" (aref (gethash "labels" (plist-get snap :partial)) 0))
                     "f00")))
    (should-not (plist-get (octocat-sync-read '(issue "o/r" 13)) :partial))))

(defmacro octocat-sync-tests--with-sync (&rest body)
  "Run BODY against a fresh in-memory store and empty queues.
Resource `thing' (N) is defined; its fetches are pushed to `pending' as
(N . DONE), and every notification to `notified'."
  (declare (indent 0))
  `(let* ((octocat-sync--db (octocat-sync-tests--db))
          (octocat-sync--loading (make-hash-table :test #'equal))
          (octocat-sync--fetches (make-hash-table :test #'equal))
          (octocat-sync--queue nil)
          (octocat-sync--prefetches nil)
          (octocat-sync--prefetching nil)
          (octocat-sync--polls nil)
          (octocat-sync--quiet (make-hash-table :test #'equal))
          (octocat-sync--poll-intervals (make-hash-table :test #'equal))
          (octocat-sync--pending nil)
          (octocat-sync--running 0)
          (octocat-sync--resources (make-hash-table :test #'eq))
          (octocat-sync--mutations (make-hash-table :test #'eq))
          (octocat-sync-change-functions nil)
          (octocat-sync-invalidate-functions nil)
          (octocat-sync-prefetch t)
          (pending nil)
          (notified nil))
     (octocat-sync-define-resource thing (n)
       :fetch (lambda (done) (push (cons n done) pending)))
     (add-hook 'octocat-sync-change-functions (lambda (keys) (push keys notified)))
     ,@body))

(ert-deftest octocat-sync-test-queue ()
  "One fetch runs per key, at most the cap at once, and each result notifies."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-max-requests 2))
      (dolist (n '(1 1 2 3))
        (octocat-sync-request (list 'thing n)))
      (should (= (length pending) 2))
      (should (plist-get (octocat-sync-read '(thing 3)) :loading))
      (funcall (cdr (assq 1 pending)) (octocat-sync-tests--table "n" 1))
      (should (equal (car notified) '("(thing 1)")))
      (should (= (length pending) 3))
      (should (= (gethash "n" (plist-get (octocat-sync-read '(thing 1)) :data)) 1))
      ;; Fresh, so not fetched again unless forced.
      (octocat-sync-request '(thing 1))
      (should (= (length pending) 3))
      (octocat-sync-request '(thing 1) t)
      (should (= octocat-sync--running 2))
      (should (equal octocat-sync--queue '(("(thing 1)" thing 1)))))))

(ert-deftest octocat-sync-test-get-and-cancel ()
  "A get calls back once its fetch lands, at once while a failure waits to
retry, and never once cancelled."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync--waiters nil)
          got)
      (octocat-sync-get '(thing 1) (lambda (r) (setq got r)))
      (funcall (cdr (pop pending)) (octocat-sync-tests--table "n" 1))
      (should (= (gethash "n" got) 1))
      ;; Old data, then a failed refetch: the next get gives the old data.
      (sqlite-execute octocat-sync--db "UPDATE resource SET fetched_at = 0")
      (octocat-sync-request '(thing 1))
      (funcall (cdr (pop pending)) '(error . "HTTP 502: Bad Gateway"))
      (setq got nil)
      (octocat-sync-get '(thing 1) (lambda (r) (setq got r)))
      (should (= (gethash "n" got) 1))
      (should-not octocat-sync--waiters)
      ;; Cancelled while queued: dropped, and no one is called back.
      (let ((octocat-sync-max-requests 1))
        (octocat-sync-request '(thing 2))
        (setq got nil)
        (octocat-sync-get '(thing 3) (lambda (r) (setq got r)))
        (should (assoc "(thing 3)" octocat-sync--queue))
        (octocat-sync-cancel '(thing 3))
        (should-not octocat-sync--queue)
        (should-not octocat-sync--waiters)
        (should-not (plist-get (octocat-sync-read '(thing 3)) :loading))
        (funcall (cdr (pop pending)) (octocat-sync-tests--table "n" 2))
        (should-not pending)
        (should-not got)))))

(ert-deftest octocat-sync-test-error-kinds ()
  "A failure waits by its kind before a refetch, unless forced; offline is noted."
  (should (eq (octocat-sync--error-kind "HTTP 502: Bad Gateway") 'transient))
  (should (eq (octocat-sync--error-kind "API rate limit exceeded") 'transient))
  (should (eq (octocat-sync--error-kind "HTTP 404: Not Found (https://x)") 'permanent))
  (should (eq (octocat-sync--error-kind
               "GraphQL: Could not resolve to an Issue with the number of 9.")
              'permanent))
  (should (eq (octocat-sync--error-kind "error connecting to api.github.com") 'offline))
  (octocat-sync-tests--with-sync
    (octocat-sync-request '(thing 1))
    (funcall (cdr (pop pending)) '(error . "HTTP 502: Bad Gateway"))
    (octocat-sync-request '(thing 1))
    (should-not pending)
    (octocat-sync-request '(thing 1) t)
    (funcall (cdr (pop pending)) '(error . "error connecting to api.github.com"))
    (let ((snap (octocat-sync-read '(thing 1))))
      (should (eq (plist-get snap :kind) 'offline))
      (should (plist-get snap :offline)))
    ;; Offline waits for nothing, and the next success clears it.
    (octocat-sync-request '(thing 1))
    (funcall (cdr (pop pending)) (octocat-sync-tests--table "n" 1))
    (let ((snap (octocat-sync-read '(thing 1))))
      (should-not (plist-get snap :error))
      (should-not (plist-get snap :offline)))))

(ert-deftest octocat-sync-test-entity-change-outdates-lists ()
  "A fetch changing a resource's entity outdates its lists, unless it is the first."
  (octocat-sync-tests--with-sync
    (let ((title "A") outdated)
      (add-hook 'octocat-sync-invalidate-functions (lambda (keys) (setq outdated keys)))
      (octocat-sync-define-resource item ()
        :entity "issue:o/r#12"
        :invalidates (lambda () '((thing _)))
        :fetch (lambda (done) (funcall done (octocat-sync-tests--issue title))))
      (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1) 1.0)
      (octocat-sync-request '(item) t)
      (should-not outdated)
      (octocat-sync-request '(item) t)
      (should-not outdated)
      (setq title "B")
      (octocat-sync-request '(item) t)
      (should (equal outdated '("(thing 1)")))
      (should (plist-get (octocat-sync-read '(thing 1)) :outdated)))))

(ert-deftest octocat-sync-test-more ()
  "A further page is appended to a list resource, its items stored as entities."
  (octocat-sync-tests--with-sync
    (let ((thirteen (octocat-sync-entity
                     'issue "issue:o/r#13" (octocat-sync-tests--table "title" "Typo")))
          after result)
      (octocat-sync--write octocat-sync--db "(thing 1)"
                           (octocat-sync-tests--table
                            "nodes" (vector (octocat-sync-tests--issue "Crash"))
                            "cursor" "c1")
                           1.0)
      (octocat-sync-more '(thing 1)
                         (lambda (cursor done)
                           (setq after cursor)
                           (funcall done (octocat-sync-tests--table
                                          "nodes" (vector thirteen) "cursor" nil)))
                         (lambda (r) (setq result (or r 'ok))))
      (should (equal after "c1"))
      (should (eq result 'ok))
      (let ((data (plist-get (octocat-sync-read '(thing 1)) :data)))
        (should (equal (mapcar (lambda (n) (gethash "title" n)) (gethash "nodes" data))
                       '("Crash" "Typo")))
        (should-not (gethash "cursor" data)))
      (should (sqlite-select octocat-sync--db
                             "SELECT 1 FROM link WHERE resource = ? AND entity = ?"
                             '("(thing 1)" "issue:o/r#13")))
      ;; No cursor left: nothing to fetch.
      (octocat-sync-more '(thing 1) (lambda (&rest _) (error "Unexpected fetch"))
                         (lambda (r) (setq result r)))
      (should (eq (car-safe result) 'error)))))

(ert-deftest octocat-sync-test-locked-write-dropped ()
  "A write blocked by a second connection is dropped quietly."
  (let ((file (make-temp-file "octocat-sync" nil ".sqlite")))
    (unwind-protect
        (octocat-sync-tests--with-sync
          (let ((octocat-sync--db (octocat-sync--create (sqlite-open file)))
                (other (sqlite-open file))
                (inhibit-message t))
            (sqlite-execute other "BEGIN EXCLUSIVE")
            (octocat-sync-request '(thing 1))
            (funcall (cdr (pop pending)) (octocat-sync-tests--table "n" 1))
            (should (= octocat-sync--running 0))
            (should-not (gethash "(thing 1)" octocat-sync--loading))
            (sqlite-execute other "ROLLBACK")
            (should-not (plist-get (octocat-sync-read '(thing 1)) :data))))
      (delete-file file))))

(ert-deftest octocat-sync-test-fetch-signals ()
  "A fetch that signals as it starts fails like any other, freeing its slot."
  (octocat-sync-tests--with-sync
    (octocat-sync-define-resource broken ()
      :fetch (lambda (_done) (error "Boom")))
    (octocat-sync-request '(broken))
    (should (= octocat-sync--running 0))
    (let ((snap (octocat-sync-read '(broken))))
      (should-not (plist-get snap :loading))
      (should (equal (plist-get snap :error) "Boom")))))

(ert-deftest octocat-sync-test-prefetch ()
  "Prefetches wait for page requests, run one at a time, and replace queued ones."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-max-requests 4))
      (octocat-sync-prefetch '((thing 1) (thing 2)))
      (should (equal (mapcar #'car pending) '(1)))
      ;; A new rest of point replaces the queued (thing 2), not the running one.
      (octocat-sync-prefetch '((thing 3)))
      (should-not (plist-get (octocat-sync-read '(thing 2)) :loading))
      (should (equal (mapcar #'car octocat-sync--prefetches) '("(thing 3)")))
      ;; Opening a queued prefetch makes it a page request, at once.
      (octocat-sync-request '(thing 3))
      (should (equal (mapcar #'car pending) '(3 1)))
      (should-not octocat-sync--prefetches)
      (funcall (cdr (assq 1 pending)) (octocat-sync-tests--table "n" 1))
      (should-not octocat-sync--prefetching)
      ;; Fresh: nothing to prefetch.
      (octocat-sync-prefetch '((thing 1)))
      (should-not octocat-sync--prefetches))))

(ert-deftest octocat-sync-test-mutation ()
  "An optimistic change shows on linked resources at once, and is written on success."
  (octocat-sync-tests--with-sync
    (let ((sent nil) (invalidated nil))
      (add-hook 'octocat-sync-invalidate-functions (lambda (keys) (setq invalidated keys)))
      (octocat-sync-define-mutation rename (title)
        :label "Renaming…"
        :resources (lambda () '((thing 1)))
        :optimistic (lambda () `(("issue:o/r#12" ("title" . ,title))))
        :send (lambda (done) (push done sent))
        :invalidates (lambda () '((thing _))))
      (octocat-sync--write octocat-sync--db "(list)"
                           (octocat-sync-tests--table
                            "nodes" (vector (octocat-sync-tests--issue "Crash")))
                           1.0)
      (octocat-sync--write octocat-sync--db "(thing 2)" (octocat-sync-tests--table "n" 2) 1.0)
      (cl-flet ((title () (gethash "title" (aref (gethash "nodes" (plist-get (octocat-sync-read '(list)) :data)) 0))))
        (octocat-sync-submit '(rename "Boom"))
        (should (equal (title) "Boom"))
        (should (member "(list)" (car notified)))
        (should (equal (plist-get (octocat-sync-read '(thing 1)) :mutating) '((action . "Renaming…"))))
        (should (equal (gethash "title" (octocat-sync--stored-fields octocat-sync--db "issue:o/r#12"))
                       "Crash"))
        (funcall (car sent) nil)
        (should (equal (title) "Boom"))
        (should (equal (gethash "title" (octocat-sync--stored-fields octocat-sync--db "issue:o/r#12"))
                       "Boom"))
        (should-not (plist-get (octocat-sync-read '(thing 1)) :mutating))
        (should (equal invalidated '("(thing 2)")))
        ;; Outdated: kept, but refetched however recently fetched.
        (should (gethash "n" (car (octocat-sync--read octocat-sync--db "(thing 2)"))))
        (should (octocat-sync--wanted-p '(thing 2) nil))))))

(ert-deftest octocat-sync-test-mutation-failure ()
  "A failed mutation drops only its own change; one sent after it stays."
  (octocat-sync-tests--with-sync
    (let ((sent nil))
      (octocat-sync-define-mutation rename (title)
        :label "Renaming…"
        :optimistic (lambda () `(("issue:o/r#12" ("title" . ,title))))
        :send (lambda (done) (push done sent)))
      (octocat-sync--write octocat-sync--db "(list)"
                           (octocat-sync-tests--table
                            "nodes" (vector (octocat-sync-tests--issue "Crash")))
                           1.0)
      (cl-flet ((title () (gethash "title" (aref (gethash "nodes" (plist-get (octocat-sync-read '(list)) :data)) 0))))
        (let ((inhibit-message t))
          (octocat-sync-submit '(rename "One"))
          (octocat-sync-submit '(rename "Two"))
          (should (equal (title) "Two"))
          ;; The first fails; the second, sent after it, stays.
          (funcall (nth 1 sent) '(error . "nope"))
          (should (equal (title) "Two"))
          (funcall (nth 0 sent) nil)
          (should (equal (title) "Two")))))))

(defmacro octocat-sync-tests--with-edit (&rest body)
  "Run BODY with resource (thing 1) stored and mutation `add' defined.
`add' appends \"N?\" to its \"items\" while it runs, and what GitHub
answers once it is accepted.  Its sends are pushed to `sent', and the
keys invalidated set `invalidated'; `items' and `stored' read the
items as pages see them and as stored."
  (declare (indent 0))
  `(octocat-sync-tests--with-sync
     (let ((sent nil) (invalidated nil))
       (add-hook 'octocat-sync-invalidate-functions (lambda (keys) (setq invalidated keys)))
       (octocat-sync-define-mutation add (n)
         :label "Adding…"
         :resources (lambda () '((thing 1)))
         :edits (lambda (answered answer)
                  (list (cons '(thing 1)
                              (lambda (data)
                                (puthash "items"
                                         (vconcat (gethash "items" data)
                                                  (vector (if answered answer (format "%s?" n))))
                                         data)
                                data))))
         :send (lambda (done) (push done sent)))
       (octocat-sync--write octocat-sync--db "(thing 1)"
                            (octocat-sync-tests--table "items" ["a"]) (float-time))
       (cl-flet ((items () (gethash "items" (plist-get (octocat-sync-read '(thing 1)) :data)))
                 (stored () (gethash "items" (car (octocat-sync--read octocat-sync--db
                                                                       "(thing 1)")))))
         ,@body))))

(ert-deftest octocat-sync-test-mutation-edits ()
  "A resource edit shows at once, unstored; on success GitHub's answer is stored."
  (octocat-sync-tests--with-edit
    (octocat-sync-submit '(add "b"))
    (should (equal (items) ["a" "b?"]))
    (should (member "(thing 1)" (car notified)))
    (should (equal (stored) ["a"]))
    (funcall (car sent) "b")
    (should (equal (items) ["a" "b"]))
    (should (equal (stored) ["a" "b"]))
    (should-not invalidated)))

(ert-deftest octocat-sync-test-mutation-failure-refetches ()
  "A failed mutation drops its edit and outdates what it acts on.
GitHub may have made the change anyway, so the page refetches it."
  (octocat-sync-tests--with-edit
    (octocat-sync-submit '(add "b"))
    (should-not (octocat-sync--wanted-p '(thing 1) nil))
    (let ((inhibit-message t))
      (funcall (car sent) '(error . "nope")))
    (should (equal (items) ["a"]))
    (should (equal (stored) ["a"]))
    (should (equal invalidated '("(thing 1)")))
    (should (octocat-sync--wanted-p '(thing 1) nil))))

(ert-deftest octocat-sync-test-failed-gh-stops-loading ()
  "A `gh' that hangs past the timeout, or is missing, ends the loading.
The resource keeps the error, and the fetch's slot is free again."
  (octocat-sync-tests--with-sync
    (let ((octocat-gh-timeout 0.1)
          (gh "sleep"))
      (octocat-sync-define-resource hung (n)
        :fetch (lambda (done) (octocat--run-gh "test" (list "5" (format "%s" n)) #'identity done)))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) gh)))
        (octocat-sync-request '(hung 1))
        (should (plist-get (octocat-sync-read '(hung 1)) :loading))
        (let ((n 0))
          (while (and (plist-get (octocat-sync-read '(hung 1)) :loading) (< n 100))
            (accept-process-output nil 0.05)
            (cl-incf n)))
        (let ((snap (octocat-sync-read '(hung 1))))
          (should-not (plist-get snap :loading))
          (should (string-search "(timed out)" (plist-get snap :error)))
          (should (eq (plist-get snap :kind) 'offline)))
        ;; Forced while hanging: the hung `gh' is killed, a new one runs.
        (let ((octocat-gh-timeout nil)
              (octocat-sync-stuck-after 0)
              (live (lambda () (seq-filter (lambda (p) (and (eq (process-type p) 'real)
                                                            (process-live-p p)
                                                            (string-prefix-p "octocat-gh-test"
                                                                             (process-name p))))
                                           (process-list)))))
          (octocat-sync-request '(hung 3))
          (let ((old (funcall live)))
            (should (= (length old) 1))
            (octocat-sync-request '(hung 3) t)
            (accept-process-output nil 0.1)
            (should-not (process-live-p (car old)))
            (should (= (length (funcall live)) 1))
            (should (plist-get (octocat-sync-read '(hung 3)) :loading))
            (should (= octocat-sync--running 1))
            (octocat-sync-request '(hung 3) t)
            (mapc #'kill-process (funcall live))
            (accept-process-output nil 0.1)))
        (setq gh nil)
        (octocat-sync-request '(hung 2))
        (let ((snap (octocat-sync-read '(hung 2))))
          (should-not (plist-get snap :loading))
          (should (string-search "not found" (plist-get snap :error))))
        (should (= octocat-sync--running 0))))))

(ert-deftest octocat-sync-test-force-takes-over ()
  "A forced request fetches anew once the fetch running seems stuck.
The new fetch takes the old one's slot; the old answer, coming late, is
dropped."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-max-requests 1))
      (octocat-sync-request '(thing 1))
      (should (= (length pending) 1))
      (let ((stale (cdar pending)))
        (octocat-sync-request '(thing 1))   ; unforced: already loading
        (should (= (length pending) 1))
        ;; Forced, but just started: the fetch running is the refresh.
        (octocat-sync-request '(thing 1) t)
        (should (= (length pending) 1))
        (let ((octocat-sync-stuck-after 0))
          (octocat-sync-request '(thing 1) t))
        (should (= (length pending) 2))
        (should (= octocat-sync--running 1))
        (funcall stale (octocat-sync-tests--table "n" "old"))
        (should (plist-get (octocat-sync-read '(thing 1)) :loading))
        (should-not (plist-get (octocat-sync-read '(thing 1)) :data))
        (funcall (cdar pending) (octocat-sync-tests--table "n" "new"))
        (let ((snap (octocat-sync-read '(thing 1))))
          (should-not (plist-get snap :loading))
          (should (equal (gethash "n" (plist-get snap :data)) "new")))
        (should (= octocat-sync--running 0))))))

;;;; Timed refetches

(ert-deftest octocat-sync-test-poll-slowdown ()
  "Refetches slow while away, unfocused or on battery, and stop past a long pause."
  (let ((octocat-sync-poll-idle-after 300))
    (should (eql (octocat-sync-poll-slowdown 10 t 'mains nil) 1))
    (should (eql (octocat-sync-poll-slowdown 400 t 'mains nil) 4))
    (should (eql (octocat-sync-poll-slowdown 10 nil 'mains nil) 4))
    ;; The slowest state wins; they don't compound.
    (should (eql (octocat-sync-poll-slowdown 400 nil 'battery nil) 4))
    (should-not (octocat-sync-poll-slowdown 1800 t 'mains nil))
    (should-not (octocat-sync-poll-slowdown 10 t 'low nil))
    (should-not (octocat-sync-poll-slowdown 10 t 'mains t))))

(ert-deftest octocat-sync-test-poll-status ()
  "Runs, jobs and checks under way refetch fast, and never once completed."
  (should (eql (octocat-sync-poll-status "in_progress") octocat-sync-poll-active))
  (should (eql (octocat-sync-poll-status "completed" "QUEUED") octocat-sync-poll-active))
  (should-not (octocat-sync-poll-status "completed" "COMPLETED"))
  (should-not (octocat-sync-poll-status nil)))

(ert-deftest octocat-sync-test-poll-quiet ()
  "A due resource refetches quietly, after prefetches; a page request shows it."
  (octocat-sync-tests--with-sync
    (let* ((octocat-sync-poll-interval 60)
           (loading nil)
           (octocat-sync-loading-functions
            (list (lambda (key on) (push (cons key on) loading))))
           (now (float-time)))
      (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1)
                           (- now 100))
      (octocat-sync--write octocat-sync--db "(thing 2)" (octocat-sync-tests--table "n" 2)
                           (- now 10))
      (octocat-sync-poll '((thing 1) (thing 2)) 1 t)
      ;; Only the one fetched over a minute ago, and not reported as loading.
      (should (equal (mapcar #'car pending) '(1)))
      (should (gethash "(thing 1)" octocat-sync--quiet))
      (should-not loading)
      ;; Four times slower: not due.
      (funcall (cdr (assq 1 pending)) (octocat-sync-tests--table "n" 1))
      (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1)
                           (- now 100))
      (setq pending nil loading nil)
      (octocat-sync-poll '((thing 1)) 4 t)
      (should-not pending)
      ;; Behind a prefetch, then shown as loading once a page asks for it.
      (octocat-sync-prefetch '((thing 3)))
      (setq loading nil)
      (octocat-sync-poll '((thing 1)) 1 t)
      (should (equal (mapcar #'car octocat-sync--polls) '("(thing 1)")))
      (should-not loading)
      (octocat-sync-request '(thing 1))
      (should (equal (car loading) '("(thing 1)" . t)))
      (should-not octocat-sync--polls)
      (should (equal (mapcar #'car pending) '(1 3))))))

(ert-deftest octocat-sync-test-poll-drops-buried ()
  "A queued timed refetch of a page no longer on screen is dropped."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-poll-interval 60))
      (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1)
                           (- (float-time) 100))
      (octocat-sync-prefetch '((thing 2)))
      (octocat-sync-poll '((thing 1)) 1 t)
      (should (assoc "(thing 1)" octocat-sync--polls))
      (octocat-sync-poll nil 1 t)
      (should-not octocat-sync--polls)
      (should-not (plist-get (octocat-sync-read '(thing 1)) :loading))
      (should-not (gethash "(thing 1)" octocat-sync--quiet)))))

(ert-deftest octocat-sync-test-poll-catch-up ()
  "A catch-up is a page request; a resource of no :poll, or off, never refetches."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-poll-interval 60)
          (old (- (float-time) 100)))
      (octocat-sync-define-resource fixed (n)
        :poll nil
        :fetch (lambda (done) (push (cons n done) pending)))
      (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1) old)
      (octocat-sync--write octocat-sync--db "(fixed 2)" (octocat-sync-tests--table "n" 2) old)
      (octocat-sync-poll '((thing 1) (fixed 2)) 1 nil)
      (should (equal (mapcar #'car pending) '(1)))
      (should-not (gethash "(thing 1)" octocat-sync--quiet))
      (let ((octocat-sync-poll-interval nil))
        (funcall (cdr (assq 1 pending)) (octocat-sync-tests--table "n" 1))
        (octocat-sync--write octocat-sync--db "(thing 1)" (octocat-sync-tests--table "n" 1) old)
        (setq pending nil)
        (octocat-sync-poll '((thing 1)) 1 nil)
        (should-not pending)))))

(ert-deftest octocat-sync-test-poll-interval ()
  "A :poll function sees the data, once per fetch; :max-age is the least."
  (octocat-sync-tests--with-sync
    (let ((octocat-sync-poll-interval 60)
          (calls 0))
      (octocat-sync-define-resource run (n)
        :poll (lambda (data) (cl-incf calls) (octocat-sync-poll-status (gethash "status" data)))
        :fetch (lambda (done) (push (cons n done) pending)))
      (octocat-sync-define-resource old (n)
        :max-age 3600
        :fetch (lambda (done) (push (cons n done) pending)))
      (octocat-sync--write octocat-sync--db "(run 1)"
                           (octocat-sync-tests--table "status" "in_progress") 1.0)
      (should (eql (octocat-sync--poll-interval '(run 1) "(run 1)" 1.0) octocat-sync-poll-active))
      (should (eql (octocat-sync--poll-interval '(run 1) "(run 1)" 1.0) octocat-sync-poll-active))
      (should (= calls 1))
      (octocat-sync--write octocat-sync--db "(run 1)"
                           (octocat-sync-tests--table "status" "completed") 2.0)
      (should-not (octocat-sync--poll-interval '(run 1) "(run 1)" 2.0))
      (should (= (octocat-sync--poll-interval '(old 1) "(old 1)" 1.0) 3600)))))

(provide 'octocat-sync-tests)
;;; octocat-sync-tests.el ends here
