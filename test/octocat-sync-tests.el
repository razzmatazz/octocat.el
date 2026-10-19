;;; octocat-sync-tests.el --- ERT tests for octocat-sync.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-sync-tests.el

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
    (octocat-sync--write-error db "r" "boom")
    (pcase-let ((`(,data ,_ ,error) (octocat-sync--read db "r")))
      (should (= (gethash "n" data) 1))
      (should (equal error "boom")))
    (octocat-sync--write db "r" (octocat-sync-tests--table "n" 1) 2.0)
    (should-not (nth 2 (octocat-sync--read db "r")))))

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

(ert-deftest octocat-sync-test-queue ()
  "One fetch runs per key, at most the cap at once, and each result notifies."
  (let* ((octocat-sync--db (octocat-sync-tests--db))
         (octocat-sync--loading (make-hash-table :test #'equal))
         (octocat-sync--queue nil)
         (octocat-sync--running 0)
         (octocat-sync--resources (make-hash-table :test #'eq))
         (octocat-sync-max-requests 2)
         (octocat-sync-change-functions nil)
         (pending nil)
         (notified nil))
    (octocat-sync-define-resource thing (n)
      :fetch (lambda (done) (push (cons n done) pending)))
    (add-hook 'octocat-sync-change-functions (lambda (keys) (push keys notified)))
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
    (should (equal octocat-sync--queue '(("(thing 1)" thing 1))))))

(provide 'octocat-sync-tests)
;;; octocat-sync-tests.el ends here
