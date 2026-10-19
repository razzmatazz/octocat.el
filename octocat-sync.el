;;; octocat-sync.el --- Sync GitHub data into a local SQLite store  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
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

;; The sync layer between pages and GitHub: pages ask for resources, such
;; as `(user-profile "octocat")', read them from a SQLite store, and are
;; told when what they read changes.  Fetches write to the store and never
;; hand data to a page.  See plans/github-sync-mechanism.md.
;;
;; Records shared by several resources are entities, stored once: a fetch
;; wraps each in `octocat-sync-entity', and the write splits them out,
;; leaving {"__ref": KEY} in the resource's body.  Reading puts the
;; entity's fields back in place of each ref.
;;
;; This is the first slice of the plan: store, entities, resources, a
;; capped queue and change notification.  Mutations, invalidation,
;; prefetch, retry delays and collection are still to come.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'octocat-core)

(defcustom octocat-sync-directory (locate-user-emacs-file "octocat/")
  "Directory of the sync store, one SQLite file per GitHub host.
The file is named after the host, such as \"sync-github.com.sqlite\"."
  :type 'directory
  :group 'octocat)

(defcustom octocat-sync-fresh-for 30
  "Seconds after a fetch during which opening a resource doesn't refetch it."
  :type 'number
  :group 'octocat)

(defcustom octocat-sync-max-requests 4
  "Most fetches that run at once."
  :type 'integer
  :group 'octocat)

(defvar octocat-sync-change-functions nil
  "Functions called with the keys of resources whose snapshot changed.
Called once per write, after it is committed.")

(defconst octocat-sync--schema 1
  "Version of the store's tables, kept in SQLite's `user_version'.")


;;;; Store

(defvar octocat-sync--db nil
  "The open store, or nil before first use.")

(defun octocat-sync--create (db)
  "Create the tables of DB, dropping older ones.
Signal a `user-error' when DB was made by a newer octocat."
  (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
    (cond
     ((> version octocat-sync--schema)
      (user-error "Octocat: The sync store is from a newer octocat; restart Emacs"))
     ((< version octocat-sync--schema)
      ;; A cache, so there are no migrations.
      (dolist (table '("link" "resource" "entity"))
        (sqlite-execute db (format "DROP TABLE IF EXISTS %s" table)))
      (sqlite-execute db "CREATE TABLE entity (
  key TEXT PRIMARY KEY, type TEXT NOT NULL, fields TEXT NOT NULL, fetched_at REAL)")
      (sqlite-execute db "CREATE TABLE resource (
  key TEXT PRIMARY KEY, body TEXT, hash TEXT, fetched_at REAL, error TEXT)")
      (sqlite-execute db "CREATE TABLE link (
  resource TEXT, entity TEXT, PRIMARY KEY (resource, entity))")
      (sqlite-execute db "CREATE INDEX link_entity ON link (entity)")
      (sqlite-execute db (format "PRAGMA user_version = %d" octocat-sync--schema))))
    db))

(defun octocat-sync--db ()
  "Return the store of the current GitHub host, opening it on first use."
  (or octocat-sync--db
      (progn
        (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
          (user-error "Octocat: Needs an Emacs built with SQLite"))
        (make-directory octocat-sync-directory t)
        (let ((db (sqlite-open
                   (expand-file-name (concat "sync-" (or (getenv "GH_HOST") "github.com")
                                             ".sqlite")
                                     octocat-sync-directory))))
          (sqlite-pragma db "journal_mode=WAL")
          (sqlite-pragma db "busy_timeout=2000")
          (setq octocat-sync--db (octocat-sync--create db))))))

(defmacro octocat-sync--transaction (db &rest body)
  "Run BODY in a transaction on DB, rolled back if BODY signals."
  (declare (indent 1))
  (let ((d (make-symbol "db")) (ok (make-symbol "ok")))
    `(let ((,d ,db) (,ok nil))
       (sqlite-transaction ,d)
       (unwind-protect
           (prog1 (progn ,@body) (setq ,ok t))
         (if ,ok (sqlite-commit ,d) (sqlite-rollback ,d))))))


;;;; JSON trees and entities

(cl-defstruct (octocat-sync--entity (:constructor octocat-sync-entity (type key fields)))
  "A record several resources share, inside a fetch's parsed tree."
  type key fields)

(defun octocat-sync--json (value)
  "Return VALUE, a parsed JSON tree, as a JSON string."
  (json-serialize value :null-object nil :false-object :false))

(defun octocat-sync--parse (string)
  "Parse STRING as `octocat-sync--json' writes it."
  (json-parse-string string :null-object nil :false-object :false))

(defun octocat-sync--ref (key)
  "Return a ref to the entity KEY."
  (let ((h (make-hash-table :test #'equal :size 1)))
    (puthash "__ref" key h)
    h))

(defun octocat-sync--ref-key (value)
  "Return the entity key VALUE refers to, or nil when it isn't a ref."
  (and (hash-table-p value)
       (= (hash-table-count value) 1)
       (gethash "__ref" value)))

(defun octocat-sync--map-tree (fn value)
  "Return VALUE with FN applied to each hash table value and vector item."
  (cond ((hash-table-p value)
         (let ((copy (make-hash-table :test #'equal :size (hash-table-count value))))
           (maphash (lambda (k v) (puthash k (funcall fn v) copy)) value)
           copy))
        ((vectorp value) (cl-map 'vector fn value))
        (t value)))

(defun octocat-sync--split (value entities)
  "Return VALUE with each entity in it replaced by a ref.
Each entity's fields, themselves split, are merged into ENTITIES, a hash
table of key to (TYPE . FIELDS); a later copy of one entity wins field
by field."
  (if (octocat-sync--entity-p value)
      (let* ((key    (octocat-sync--entity-key value))
             (fields (octocat-sync--split (octocat-sync--entity-fields value) entities))
             (seen   (gethash key entities)))
        (if seen
            (maphash (lambda (k v) (puthash k v (cdr seen))) fields)
          (puthash key (cons (octocat-sync--entity-type value) fields) entities))
        (octocat-sync--ref key))
    (octocat-sync--map-tree (lambda (v) (octocat-sync--split v entities)) value)))

(defun octocat-sync--refs (value)
  "Return the entity keys VALUE refers to directly."
  (let (keys)
    (cl-labels ((walk (v)
                  (if-let* ((key (octocat-sync--ref-key v)))
                      (push key keys)
                    (cond ((hash-table-p v) (maphash (lambda (_ x) (walk x)) v))
                          ((vectorp v) (mapc #'walk v))))))
      (walk value))
    keys))

(defun octocat-sync--same-p (a b)
  "Return non-nil if A and B are the same JSON value."
  (string= (octocat-sync--json (vector a)) (octocat-sync--json (vector b))))

(defun octocat-sync--stored-fields (db key)
  "Return the stored fields of entity KEY in DB, or nil."
  (when-let* ((row (car (sqlite-select db "SELECT fields FROM entity WHERE key = ?"
                                       (list key)))))
    (octocat-sync--parse (car row))))

(defun octocat-sync--merge (db key type fields now)
  "Merge FIELDS into entity KEY of TYPE in DB, field by field.
A field FIELDS lacks is kept.  Return non-nil if any value changed."
  (let* ((old     (octocat-sync--stored-fields db key))
         (merged  (or old (make-hash-table :test #'equal)))
         (changed (null old)))
    (maphash (lambda (k v)
               (unless (and old
                            (not (eq (gethash k old 'octocat-sync--none) 'octocat-sync--none))
                            (octocat-sync--same-p (gethash k old) v))
                 (setq changed t)
                 (puthash k v merged)))
             fields)
    (if changed
        (sqlite-execute db "INSERT INTO entity (key, type, fields, fetched_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT (key) DO UPDATE
                            SET fields = excluded.fields, fetched_at = excluded.fetched_at"
                        (list key (symbol-name type) (octocat-sync--json merged) now))
      (sqlite-execute db "UPDATE entity SET fetched_at = ? WHERE key = ?" (list now key)))
    changed))

(defun octocat-sync--reachable (db body)
  "Return every entity key in DB that BODY reaches, directly or through entities."
  (let ((seen (make-hash-table :test #'equal))
        (todo (octocat-sync--refs body)))
    (while todo
      (let ((key (pop todo)))
        (unless (gethash key seen)
          (puthash key t seen)
          (setq todo (append (octocat-sync--refs (octocat-sync--stored-fields db key))
                             todo)))))
    (hash-table-keys seen)))

(defun octocat-sync--write (db key tree now)
  "Write TREE, the parsed result of a fetch of resource KEY, into DB at NOW.
Return the keys of the resources whose data changed: KEY if its body
did, and every resource linked to an entity whose fields did."
  (let* ((entities (make-hash-table :test #'equal))
         (body     (octocat-sync--split tree entities))
         (json     (octocat-sync--json body))
         (hash     (secure-hash 'sha1 json))
         changed)
    (octocat-sync--transaction db
      (maphash (lambda (k entity)
                 (when (octocat-sync--merge db k (car entity) (cdr entity) now)
                   (push k changed)))
               entities)
      (let ((same (equal hash (caar (sqlite-select
                                     db "SELECT hash FROM resource WHERE key = ?"
                                     (list key))))))
        (sqlite-execute db "INSERT INTO resource (key, body, hash, fetched_at, error)
                            VALUES (?, ?, ?, ?, NULL)
                            ON CONFLICT (key) DO UPDATE
                            SET body = excluded.body, hash = excluded.hash,
                                fetched_at = excluded.fetched_at, error = NULL"
                        (list key json hash now))
        (unless (and same (null changed))
          (sqlite-execute db "DELETE FROM link WHERE resource = ?" (list key))
          (dolist (entity (octocat-sync--reachable db body))
            (sqlite-execute db "INSERT INTO link (resource, entity) VALUES (?, ?)"
                            (list key entity))))
        (delete-dups
         (append (unless same (list key))
                 (and changed
                      (mapcar #'car
                              (sqlite-select
                               db (format "SELECT DISTINCT resource FROM link WHERE entity IN (%s)"
                                          (mapconcat (lambda (_) "?") changed ", "))
                               changed)))))))))

(defun octocat-sync--write-error (db key message)
  "Record in DB that the fetch of resource KEY failed with MESSAGE.
The resource keeps its data."
  (sqlite-execute db "INSERT INTO resource (key, error) VALUES (?, ?)
                      ON CONFLICT (key) DO UPDATE SET error = excluded.error"
                  (list key message)))

(defun octocat-sync--resolve (value entities db seen)
  "Return VALUE with each ref replaced by its entity's fields, recursively.
ENTITIES maps keys to parsed fields; a key missing from it is read from
DB.  SEEN lists the entities being resolved, so a cycle ends in nil."
  (if-let* ((key (octocat-sync--ref-key value)))
      (unless (member key seen)
        (octocat-sync--resolve (or (gethash key entities)
                                   (octocat-sync--stored-fields db key))
                               entities db (cons key seen)))
    (octocat-sync--map-tree (lambda (v) (octocat-sync--resolve v entities db seen))
                            value)))

(defun octocat-sync--read (db key)
  "Return resource KEY of DB as (DATA FETCHED-AT ERROR), or nil if absent."
  (when-let* ((row (car (sqlite-select
                         db "SELECT body, fetched_at, error FROM resource WHERE key = ?"
                         (list key)))))
    (let ((entities (make-hash-table :test #'equal)))
      (pcase-dolist (`(,k ,fields)
                     (sqlite-select db "SELECT e.key, e.fields FROM link l
                                        JOIN entity e ON e.key = l.entity
                                        WHERE l.resource = ?"
                                    (list key)))
        (puthash k (octocat-sync--parse fields) entities))
      (list (and (nth 0 row)
                 (octocat-sync--resolve (octocat-sync--parse (nth 0 row)) entities db nil))
            (nth 1 row)
            (nth 2 row)))))


;;;; Resources

(defvar octocat-sync--resources (make-hash-table :test #'eq)
  "Resource name to a function of the spec's arguments returning its plist.")

(defmacro octocat-sync-define-resource (name args &rest props)
  "Define the resource NAME, whose spec is (NAME . ARGS).
PROPS are evaluated with ARGS bound.  :fetch is a function of DONE that
fetches the resource and calls DONE with the parsed tree, its shared
records wrapped in `octocat-sync-entity', or with (error . MESSAGE)."
  (declare (indent 2))
  `(puthash ',name (lambda ,args (list ,@props)) octocat-sync--resources))

(defun octocat-sync-spec-key (spec)
  "Return the store key of SPEC, such as \"(user-profile \\\"octocat\\\")\"."
  (prin1-to-string spec))

(defvar octocat-sync--loading (make-hash-table :test #'equal)
  "Keys of the resources being fetched or queued.  Kept in memory only.")

(defvar octocat-sync--queue nil
  "Queued fetches, oldest first, as (KEY . SPEC).")

(defvar octocat-sync--running 0
  "How many fetches are running.")

(defun octocat-sync--notify (keys)
  "Tell `octocat-sync-change-functions' that the resources KEYS changed."
  (when keys
    (run-hook-with-args 'octocat-sync-change-functions keys)))

(defun octocat-sync-read (spec)
  "Return a snapshot of SPEC: (:data :loading :error :fetched-at).
It reads only the store, never the network."
  (let ((key (octocat-sync-spec-key spec)))
    (pcase-let ((`(,data ,fetched-at ,error) (octocat-sync--read (octocat-sync--db) key)))
      (list :data data
            :loading (gethash key octocat-sync--loading)
            :error error
            :fetched-at fetched-at))))

(defun octocat-sync-request (spec &optional force)
  "Queue a fetch of SPEC unless it is running or was fetched just now.
Within `octocat-sync-fresh-for' of the last fetch, nothing is fetched
unless FORCE.  Return immediately; the store reports the result."
  (let* ((key (octocat-sync-spec-key spec))
         (db  (octocat-sync--db))
         (fetched (caar (sqlite-select db "SELECT fetched_at FROM resource WHERE key = ?"
                                       (list key)))))
    (unless (or (gethash key octocat-sync--loading)
                (and (not force) fetched
                     (< (- (float-time) fetched) octocat-sync-fresh-for)))
      (puthash key t octocat-sync--loading)
      (setq octocat-sync--queue (append octocat-sync--queue (list (cons key spec))))
      (octocat-sync--notify (list key))
      (octocat-sync--pump))))

(defun octocat-sync--pump ()
  "Start queued fetches while fewer than `octocat-sync-max-requests' run."
  (while (and octocat-sync--queue
              (< octocat-sync--running octocat-sync-max-requests))
    (pcase-let* ((`(,key . ,spec) (pop octocat-sync--queue))
                 (make (or (gethash (car spec) octocat-sync--resources)
                           (error "Octocat: Unknown resource `%s'" (car spec))))
                 (fetch (plist-get (apply make (cdr spec)) :fetch)))
      (cl-incf octocat-sync--running)
      (funcall fetch (lambda (result) (octocat-sync--done key result))))))

(defun octocat-sync--done (key result)
  "Store RESULT, the outcome of fetching resource KEY, and notify."
  (cl-decf octocat-sync--running)
  (remhash key octocat-sync--loading)
  (let ((db (octocat-sync--db)))
    (octocat-sync--notify
     ;; KEY always changed, since it stopped loading.
     (cl-adjoin key
           (condition-case err
               (if (eq (car-safe result) 'error)
                   (progn (octocat-sync--write-error db key (cdr result)) nil)
                 (octocat-sync--write db key result (float-time)))
             ;; Say a second Emacs held the lock past the timeout: drop the write.
             (error (octocat--debug-log (format "sync write %s failed" key)
                                        (error-message-string err))
                    nil))
           :test #'equal)))
  (octocat-sync--pump))

(provide 'octocat-sync)
;;; octocat-sync.el ends here
