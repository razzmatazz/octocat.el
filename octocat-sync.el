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
;; A mutation changes the entities it will change at once, in memory,
;; and writes them once GitHub accepts it; see "Mutations" below.
;;
;; Still to come, from the plan: retry delays and collection.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'octocat-core)

;; Emacs built without SQLite lacks these; `octocat-sync--db' checks
;; `sqlite-available-p' first.  `sqlite-open' gained arguments in 31.
(declare-function sqlite-open        "ext:sqlite.c" t)
(declare-function sqlite-execute     "ext:sqlite.c" (db query &optional values))
(declare-function sqlite-select      "ext:sqlite.c" (db query &optional values return-type))
(declare-function sqlite-pragma      "ext:sqlite.c" (db pragma))
(declare-function sqlite-transaction "ext:sqlite.c" (db))
(declare-function sqlite-commit      "ext:sqlite.c" (db))
(declare-function sqlite-rollback    "ext:sqlite.c" (db))

(declare-function octocat-vui--on-sync-change     "octocat-vui" (keys))
(declare-function octocat-vui--on-sync-loading    "octocat-vui" (key loading))
(declare-function octocat-vui--on-sync-invalidate "octocat-vui" (keys))

(defcustom octocat-sync-directory (locate-user-emacs-file "octocat/")
  "Directory of the sync store, one SQLite file per GitHub host.
The file is named after the host, such as \"sync-github.com.sqlite\"."
  :type 'directory
  :group 'octocat)

(defcustom octocat-sync-fresh-for 30
  "Seconds after a fetch during which opening a resource doesn't refetch it."
  :type 'number
  :group 'octocat)

(defcustom octocat-sync-prefetch t
  "Whether to fetch what a list row opens while point rests on it."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-sync-prefetch-delay 0.3
  "Seconds point must rest on a list row before its page is prefetched."
  :type 'number
  :group 'octocat)

(defcustom octocat-sync-stuck-after 10
  "Seconds after which `g' gives up on a fetch still running and starts anew.
Before, the fetch running is the refresh: pressing `g' again neither
kills it nor asks GitHub again.  A fetch that hangs is stopped anyway
after `octocat-gh-timeout'."
  :type 'number
  :group 'octocat)

(defcustom octocat-sync-max-requests 4
  "Most fetches that run at once."
  :type 'integer
  :group 'octocat)

(defvar octocat-sync-change-functions (list #'octocat-vui--on-sync-change)
  "Functions called with the keys of resources whose snapshot changed.
Called once per write, after it is committed.")

(defvar octocat-sync-loading-functions (list #'octocat-vui--on-sync-loading)
  "Functions called with a resource's key and whether it is now loading.
Starting or ending a fetch changes no snapshot a page draws from data,
so it is reported here rather than as a change: a page keeps its
spinner from it, and a refetch that finds nothing new renders nothing.")

(defvar octocat-sync-invalidate-functions (list #'octocat-vui--on-sync-invalidate)
  "Functions called with the keys of resources found outdated.
Their data stays; a page showing one should refetch it.")

(defconst octocat-sync--schema 4
  "Version of the store's tables, kept in SQLite's `user_version'.
Bump it also when the shape of a resource's body changes: the store is
then recreated, rather than read in the old shape.")


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
  key TEXT PRIMARY KEY, body TEXT, hash TEXT, fetched_at REAL,
  invalidated_at REAL, error TEXT, error_kind TEXT, retry_at REAL)")
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
          (setq octocat-sync--db (octocat-sync--create db))
          ;; Once a session, when Emacs is idle.
          (run-with-idle-timer 30 nil #'octocat-sync-collect)
          octocat-sync--db))))

(defmacro octocat-sync--transaction (db &rest body)
  "Run BODY in a transaction on DB, rolled back if BODY signals."
  (declare (indent 1))
  (let ((d (make-symbol "db")) (ok (make-symbol "ok")))
    `(let ((,d ,db) (,ok nil))
       (sqlite-transaction ,d)
       (unwind-protect
           (prog1 (progn ,@body) (setq ,ok t))
         (if ,ok (sqlite-commit ,d) (sqlite-rollback ,d))))))

(defcustom octocat-sync-keep-for (* 30 24 60 60)
  "Seconds a resource is kept in the store after its last fetch."
  :type 'number
  :group 'octocat)

(defun octocat-sync--collect (db now)
  "Delete from DB, as of NOW, what nothing needs any more.
That is the resources not fetched for `octocat-sync-keep-for', and
records of failures with no data past their retry time; then the
entities no resource links to.  Return how many resources went."
  (let ((cutoff (- now octocat-sync-keep-for)))
    (octocat-sync--transaction db
      (let ((old (mapcar #'car (sqlite-select
                                db "SELECT key FROM resource
                                    WHERE fetched_at < ?1
                                       OR (body IS NULL AND COALESCE(retry_at, 0) < ?2)"
                                (list cutoff now)))))
        (dolist (key old)
          (sqlite-execute db "DELETE FROM link WHERE resource = ?" (list key))
          (sqlite-execute db "DELETE FROM resource WHERE key = ?" (list key)))
        (sqlite-execute db "DELETE FROM entity
                            WHERE key NOT IN (SELECT entity FROM link)")
        (length old)))))

(defun octocat-sync-collect ()
  "Delete from the store what nothing needs any more.
See `octocat-sync--collect'.  It runs once a session, when idle."
  (interactive)
  (let ((n (condition-case err
               (octocat-sync--collect (octocat-sync--db) (float-time))
             (error (octocat--debug-log "sync collect failed" (error-message-string err))
                    nil))))
    (when (called-interactively-p 'interactive)
      (message "Octocat: Collected %s resources" (or n 0)))))


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
by field.  A `:null', as `json-parse-string' gives by default, becomes
nil, so the store has one null."
  (cond
   ((eq value :null) nil)
   ((octocat-sync--entity-p value)
      (let* ((key    (octocat-sync--entity-key value))
             (fields (octocat-sync--split (octocat-sync--entity-fields value) entities))
             (seen   (gethash key entities)))
        (if seen
            (maphash (lambda (k v) (puthash k v (cdr seen))) fields)
          (puthash key (cons (octocat-sync--entity-type value) fields) entities))
        (octocat-sync--ref key)))
   (t (octocat-sync--map-tree (lambda (v) (octocat-sync--split v entities)) value))))

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
        (sqlite-execute db "INSERT INTO resource (key, body, hash, fetched_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT (key) DO UPDATE
                            SET body = excluded.body, hash = excluded.hash,
                                fetched_at = excluded.fetched_at, invalidated_at = NULL,
                                error = NULL, error_kind = NULL, retry_at = NULL"
                        (list key json hash now))
        (unless (and same (null changed))
          (sqlite-execute db "DELETE FROM link WHERE resource = ?" (list key))
          (dolist (entity (octocat-sync--reachable db body))
            (sqlite-execute db "INSERT INTO link (resource, entity) VALUES (?, ?)"
                            (list key entity))))
        (delete-dups (append (unless same (list key))
                             (octocat-sync--linked db changed)))))))

(defconst octocat-sync--retry-after '((transient . 60) (permanent . 86400))
  "Seconds after a failure of each kind before its resource is refetched.
An offline failure is retried on the next open.  `g' retries at once.")

(defun octocat-sync--error-kind (message)
  "Return the kind of the failure `gh' reported in MESSAGE.
That is `offline' when GitHub could not be reached, or did not answer
in `octocat-gh-timeout', `permanent' when
the resource is missing or out of reach (404, 410, 401, 403), and
`transient' otherwise, such as a 5xx or a rate limit.  `gh' commands
other than `gh api' report no HTTP status, so this reads their words."
  (cond ((string-match-p (concat "error connecting to\\|no such host\\|dial tcp"
                                 "\\|connection refused\\|network is unreachable"
                                 "\\|i/o timeout\\|TLS handshake timeout"
                                 "\\|(timed out)")
                         message)
         'offline)
        ((string-match-p "rate limit" message) 'transient)
        ((string-match-p (concat "HTTP 4\\(?:01\\|03\\|04\\|10\\)\\|Could not resolve to"
                                 "\\|Not Found")
                         message)
         'permanent)
        (t 'transient)))

(defun octocat-sync--write-error (db key message kind now)
  "Record in DB that the fetch of resource KEY failed at NOW with MESSAGE.
KIND is as `octocat-sync--error-kind' returns; it sets when the
resource is fetched again.  The resource keeps its data."
  (let ((delay (alist-get kind octocat-sync--retry-after)))
    (sqlite-execute db "INSERT INTO resource (key, error, error_kind, retry_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT (key) DO UPDATE
                        SET error = excluded.error, error_kind = excluded.error_kind,
                            retry_at = excluded.retry_at"
                    (list key message (symbol-name kind) (and delay (+ now delay))))))

(defun octocat-sync--overlay (fields key overlays)
  "Return FIELDS of entity KEY with OVERLAYS applied, or nil without either.
OVERLAYS is a list of (KEY . FIELDS), applied in order.  FIELDS may be
changed."
  (dolist (overlay overlays)
    (when (equal (car overlay) key)
      (unless fields (setq fields (make-hash-table :test #'equal)))
      (maphash (lambda (k v) (puthash k v fields)) (cdr overlay))))
  fields)

(defun octocat-sync--resolve (value entities db seen overlays)
  "Return VALUE with each ref replaced by its entity's fields, recursively.
ENTITIES maps keys to parsed fields, OVERLAYS applied; a key missing
from it is read from DB.  SEEN lists the entities being resolved, so a
cycle ends in nil."
  (if-let* ((key (octocat-sync--ref-key value)))
      (unless (member key seen)
        (octocat-sync--resolve (or (gethash key entities)
                                   (octocat-sync--overlay
                                    (octocat-sync--stored-fields db key) key overlays))
                               entities db (cons key seen) overlays))
    (octocat-sync--map-tree (lambda (v) (octocat-sync--resolve v entities db seen overlays))
                            value)))

(defun octocat-sync--read (db key &optional overlays)
  "Return resource KEY of DB as (DATA FETCHED-AT ERROR KIND OUTDATED), or nil.
KIND is the error's, a symbol; OUTDATED is when it was marked outdated.
OVERLAYS, as for `octocat-sync--overlay', change entities' fields as read."
  (when-let* ((row (car (sqlite-select
                         db "SELECT body, fetched_at, error, error_kind, invalidated_at
                             FROM resource WHERE key = ?"
                         (list key)))))
    (let ((entities (make-hash-table :test #'equal)))
      (pcase-dolist (`(,k ,fields)
                     (sqlite-select db "SELECT e.key, e.fields FROM link l
                                        JOIN entity e ON e.key = l.entity
                                        WHERE l.resource = ?"
                                    (list key)))
        (puthash k (octocat-sync--overlay (octocat-sync--parse fields) k overlays) entities))
      (list (and (nth 0 row)
                 (octocat-sync--resolve (octocat-sync--parse (nth 0 row))
                                        entities db nil overlays))
            (nth 1 row)
            (nth 2 row)
            (and (nth 3 row) (intern (nth 3 row)))
            (nth 4 row)))))

(defun octocat-sync--linked (db entities)
  "Return the keys of the resources in DB linked to any of ENTITIES."
  (and entities
       (mapcar #'car
               (sqlite-select
                db (format "SELECT DISTINCT resource FROM link WHERE entity IN (%s)"
                           (mapconcat (lambda (_) "?") entities ", "))
                entities))))

(defun octocat-sync--invalidate (db patterns)
  "Mark the resources of DB matching PATTERNS outdated, and say so.
`octocat-sync-invalidate-functions' get their keys: a page showing one
refetches it; the rest are refetched when next opened."
  (when-let* ((keys (and patterns (octocat-sync--outdate db patterns (float-time)))))
    (octocat-sync--notify keys)
    (run-hook-with-args 'octocat-sync-invalidate-functions keys)))

(defun octocat-sync--spec-match-p (pattern spec)
  "Return non-nil if SPEC matches PATTERN, where `_' matches anything."
  (and (= (length pattern) (length spec))
       (cl-every (lambda (p v) (or (eq p '_) (equal p v))) pattern spec)))

(defun octocat-sync--outdate (db patterns now)
  "Mark the resources of DB matching any of PATTERNS outdated as of NOW.
Return their keys.  Their data stays, but the next open refetches them."
  (let (keys)
    (pcase-dolist (`(,key) (sqlite-select db "SELECT key FROM resource"))
      (let ((spec (car (read-from-string key))))
        (when (and (consp spec)
                   (seq-some (lambda (p) (octocat-sync--spec-match-p p spec)) patterns))
          (push key keys))))
    (dolist (key keys)
      (sqlite-execute db "UPDATE resource SET invalidated_at = ? WHERE key = ?" (list now key)))
    keys))


;;;; Resources

(defvar octocat-sync--resources (make-hash-table :test #'eq)
  "Resource name to a function of the spec's arguments returning its plist.")

(defmacro octocat-sync-define-resource (name args &rest props)
  "Define the resource NAME, whose spec is (NAME . ARGS).
PROPS are evaluated with ARGS bound.  :fetch is a function of DONE that
fetches the resource and calls DONE with the parsed tree, its shared
records wrapped in `octocat-sync-entity', or with (error . MESSAGE).
:entity, optional, is the key of the resource's main entity: until the
resource is first fetched, a snapshot carries that entity's fields, as
another resource stored them, in :partial.  :invalidates, optional, is
a function returning the specs, `_' matching anything, of the lists
that a change to that entity may move it in or out of: a fetch that
changes it outdates them.  :max-age, optional, is how
many seconds a fetch stays good for data that rarely changes, such as a
commit's: within it, opening doesn't refetch, but `g' does."
  (declare (indent 2))
  `(puthash ',name (lambda ,args (list ,@props)) octocat-sync--resources))

(defun octocat-sync--props (spec)
  "Return the plist of resource SPEC, as `octocat-sync-define-resource' gave."
  (apply (or (gethash (car spec) octocat-sync--resources)
             (error "Octocat: Unknown resource `%s'" (car spec)))
         (cdr spec)))

(defun octocat-sync-spec-key (spec)
  "Return the store key of SPEC, such as \"(user-profile \\\"octocat\\\")\"."
  (prin1-to-string spec))

(defvar octocat-sync--loading (make-hash-table :test #'equal)
  "Keys of the resources being fetched or queued.  Kept in memory only.")

(defvar octocat-sync--queue nil
  "Queued fetches, oldest first, as (KEY . SPEC).")

(defvar octocat-sync--running 0
  "How many fetches are running.")

(defvar octocat-sync--fetches (make-hash-table :test #'equal)
  "The fetch running of each resource key, a token (KEY COUNTED STARTED).
COUNTED is whether it counts in `octocat-sync--running', and STARTED
when it started.  Only the answer of the current token is taken: a
forced request takes over a fetch running past `octocat-sync-stuck-after',
killing its `gh' calls (see `octocat--gh-owner'), so `g' unsticks a
hung fetch, which could otherwise hang until `octocat-gh-timeout'.")

(defvar octocat-sync--offline nil
  "Non-nil when the last request found GitHub out of reach.
Kept in memory only, and cleared by the next success.")

(defvar octocat-sync--waiters nil
  "Callbacks of `octocat-sync-get' awaiting a fetch, as (KEY . FUNCTION).")

(defvar octocat-sync--prefetches nil
  "Queued prefetches, as (KEY . SPEC), run after the page requests.")

(defvar octocat-sync--prefetching nil
  "The key of the prefetch running, or nil.")

(defun octocat-sync--notify (keys)
  "Tell `octocat-sync-change-functions' that the resources KEYS changed."
  (when keys
    (run-hook-with-args 'octocat-sync-change-functions keys)))

(defun octocat-sync-read (spec)
  "Return a snapshot of SPEC, a plist.
Its keys are :data :partial :loading :error :kind :offline :outdated
:fetched-at and :mutating.  :kind is that of :error, see
`octocat-sync--error-kind'; :offline is whether the last request found
GitHub out of reach; :outdated is when the data was found out of date,
see `octocat-sync--invalidate'.
It reads only the store, never the network, with the changes of pending
mutations applied.  :partial is set only when :data is nil; see
`octocat-sync-define-resource'.  :mutating is an alist (SLOT . LABEL)
of the pending mutations of SPEC, see `octocat-sync-define-mutation'."
  (let ((key (octocat-sync-spec-key spec))
        (db  (octocat-sync--db)))
    (pcase-let ((`(,data ,fetched-at ,error ,kind ,outdated)
                 (octocat-sync--read db key (octocat-sync--overlays))))
      (list :data data
            :partial (and (null data)
                          (when-let* ((entity (plist-get (octocat-sync--props spec) :entity)))
                            (octocat-sync--resolve (octocat-sync--ref entity)
                                                   (make-hash-table :test #'equal) db nil
                                                   (octocat-sync--overlays))))
            :loading (gethash key octocat-sync--loading)
            :error error
            :kind kind
            :offline octocat-sync--offline
            :outdated outdated
            :fetched-at fetched-at
            :mutating (octocat-sync--mutating key)))))

(defun octocat-sync-entities (type)
  "Return the stored entities of TYPE, a symbol, as (KEY FIELDS FETCHED-AT).
FIELDS have their refs resolved, as `octocat-sync-read' gives them."
  (let ((db       (octocat-sync--db))
        (entities (make-hash-table :test #'equal))
        (overlays (octocat-sync--overlays)))
    (mapcar (pcase-lambda (`(,key ,fields ,at))
              (list key
                    (octocat-sync--resolve
                     (octocat-sync--overlay (octocat-sync--parse fields) key overlays)
                     entities db (list key) overlays)
                    at))
            (sqlite-select db "SELECT key, fields, fetched_at FROM entity WHERE type = ?"
                           (list (symbol-name type))))))

(defun octocat-sync-stored (name)
  "Return the stored data of every resource NAME, as (SPEC DATA FETCHED-AT).
Only for resources whose data holds no entities: refs are left unresolved."
  (let ((prefix (format "(%s " name)))
    (mapcar (pcase-lambda (`(,key ,body ,at)) (list (read key) (octocat-sync--parse body) at))
            (sqlite-select (octocat-sync--db)
                           "SELECT key, body, fetched_at FROM resource
                            WHERE substr(key, 1, ?1) = ?2 AND body IS NOT NULL"
                           (list (length prefix) prefix)))))

(defun octocat-sync--wanted-p (spec force)
  "Return non-nil if SPEC should be fetched, or FORCE.
It is not when fetched just now, within `octocat-sync-fresh-for' or the
resource's :max-age, unless a mutation made it outdated since; nor
before the retry time of a failure."
  (or force
      (pcase-let ((`(,fetched ,retry-at ,outdated)
                   (car (sqlite-select (octocat-sync--db)
                                       "SELECT fetched_at, retry_at, invalidated_at
                                        FROM resource WHERE key = ?"
                                       (list (octocat-sync-spec-key spec))))))
        (let ((now (float-time)))
          (and (not (and retry-at (< now retry-at)))
               (or (null fetched) outdated
                   (>= (- now fetched)
                       (max octocat-sync-fresh-for
                            (or (plist-get (octocat-sync--props spec) :max-age) 0)))))))))

(defun octocat-sync-request (spec &optional force)
  "Queue a fetch of SPEC unless it is running or was fetched just now.
See `octocat-sync--wanted-p' for FORCE.  A queued prefetch of SPEC is
raised to a page request.  Return immediately; the store reports the
result."
  (let ((key (octocat-sync-spec-key spec)))
    (cond
     ;; Forced while running a while: take over, see `octocat-sync--fetches'.
     ((and force
           (when-let* ((token (gethash key octocat-sync--fetches)))
             (>= (- (float-time) (nth 2 token)) octocat-sync-stuck-after)))
      (octocat-sync--drop-fetch key)
      (setq octocat-sync--queue (append octocat-sync--queue (list (cons key spec))))
      (octocat-sync--pump))
     ((assoc key octocat-sync--prefetches)
      (setq octocat-sync--prefetches (assoc-delete-all key octocat-sync--prefetches))
      (setq octocat-sync--queue (append octocat-sync--queue (list (cons key spec))))
      (octocat-sync--pump))
     ((and (not (gethash key octocat-sync--loading))
           (octocat-sync--wanted-p spec force))
      (octocat-sync--set-loading key t)
      (setq octocat-sync--queue (append octocat-sync--queue (list (cons key spec))))
      (octocat-sync--pump)))))

(defun octocat-sync--drop-fetch (key)
  "Forget the fetch running of resource KEY, freeing its slot.
Its `gh' calls still running are killed, and their answers dropped."
  (when-let* ((token (gethash key octocat-sync--fetches)))
    (remhash key octocat-sync--fetches)
    (octocat--gh-stop token)
    (when (nth 1 token) (cl-decf octocat-sync--running))
    (when (equal key octocat-sync--prefetching)
      (setq octocat-sync--prefetching nil))))

(defun octocat-sync--set-loading (key loading)
  "Record whether resource KEY is LOADING, and report it.
Starting to load a resource with no data yet, or with outdated data, is
also notified as a change: its page draws grey bars, or says it is
refreshing outdated data."
  (if loading
      (puthash key t octocat-sync--loading)
    (remhash key octocat-sync--loading))
  (run-hook-with-args 'octocat-sync-loading-functions key loading)
  (when (and loading
             (not (eql 1 (caar (sqlite-select
                                (octocat-sync--db)
                                "SELECT body IS NOT NULL AND invalidated_at IS NULL
                                 FROM resource WHERE key = ?"
                                (list key))))))
    (octocat-sync--notify (list key))))

(defun octocat-sync-get (spec callback)
  "Call CALLBACK with the data of SPEC, or (error . MESSAGE).
For code outside a vui page.  It is called at once when the store holds
data fetched just now, or within the resource's :max-age; else once
a fetch lands.  Stored data waiting out a failure's retry time is given
at once too, since no fetch will land."
  (let ((key    (octocat-sync-spec-key spec))
        (data   (plist-get (octocat-sync-read spec) :data))
        (waiter (cons nil callback)))
    (if (and data (not (octocat-sync--wanted-p spec nil)))
        (funcall callback data)
      (setcar waiter key)
      (push waiter octocat-sync--waiters)
      (octocat-sync-request spec (null data))
      (when (and (memq waiter octocat-sync--waiters)
                 (not (gethash key octocat-sync--loading)))
        (setq octocat-sync--waiters (delq waiter octocat-sync--waiters))
        (funcall callback data)))))

(defun octocat-sync-cancel (spec)
  "Drop the fetch of SPEC, and the `octocat-sync-get' callbacks awaiting it.
Only a fetch still queued is dropped: one running finishes and is
stored, but calls back no one."
  (let ((key (octocat-sync-spec-key spec)))
    (setq octocat-sync--waiters
          (seq-remove (lambda (w) (equal (car w) key)) octocat-sync--waiters))
    (when (assoc key octocat-sync--queue)
      (setq octocat-sync--queue (assoc-delete-all key octocat-sync--queue))
      (octocat-sync--set-loading key nil))))

(defun octocat-sync-more (spec more &optional on-done)
  "Fetch the page after the stored data of SPEC, a list resource, and append it.
The data is a table of \"nodes\" and the \"cursor\" after the last.
MORE is a function of that CURSOR and DONE: it fetches the next page
and calls DONE with a tree of the same shape, or (error . MESSAGE).
ON-DONE, if given, is called with nil, or (error . MESSAGE).  Nothing is
fetched while SPEC is: the next fetch of it replaces the pages with the
first again."
  (let* ((key  (octocat-sync-spec-key spec))
         (db   (octocat-sync--db))
         (body (caar (sqlite-select db "SELECT body FROM resource WHERE key = ?" (list key))))
         (tree (and body (octocat-sync--parse body)))
         (cursor (and tree (gethash "cursor" tree))))
    (if (or (null cursor) (gethash key octocat-sync--loading))
        (when on-done (funcall on-done '(error . "Nothing more to load yet")))
      (octocat-sync--set-loading key t)
      (let ((token (list key nil (float-time))))
        (puthash key token octocat-sync--fetches)
        (let ((octocat--gh-owner token))
          (funcall more cursor
                   (lambda (result)
                     (if (not (eq (gethash key octocat-sync--fetches) token))
                         ;; Taken over by a forced request: a fetch of the
                         ;; first pages again, which answers instead.
                         (when on-done (funcall on-done nil))
                       (remhash key octocat-sync--fetches)
                       (octocat-sync--set-loading key nil)
                       (unless (eq (car-safe result) 'error)
                         ;; The stored nodes are refs already; the new ones
                         ;; are split out as any fetch's.
                         (puthash "nodes" (vconcat (gethash "nodes" tree) (gethash "nodes" result)) tree)
                         (puthash "cursor" (gethash "cursor" result) tree)
                         (octocat-sync--notify (cl-adjoin key (octocat-sync--write db key tree (float-time))
                                                          :test #'equal)))
                       (when on-done
                         (funcall on-done (and (eq (car-safe result) 'error) result)))))))))))

(defun octocat-sync-prefetch (specs)
  "Fetch SPECS at low priority, in place of the prefetches still queued.
A prefetch runs only while no page request is queued, one at a time,
and is skipped if its resource was fetched just now, or while offline.
It only writes the store."
  (when (and octocat-sync-prefetch (not octocat-sync--offline))
    (pcase-dolist (`(,key . ,_) octocat-sync--prefetches)
      (octocat-sync--set-loading key nil))
    (setq octocat-sync--prefetches
          (delq nil (mapcar (lambda (spec)
                              (let ((key (octocat-sync-spec-key spec)))
                                (unless (or (gethash key octocat-sync--loading)
                                            (not (octocat-sync--wanted-p spec nil)))
                                  (octocat-sync--set-loading key t)
                                  (cons key spec))))
                            specs)))
    (octocat-sync--pump)))

(defun octocat-sync--start (key spec)
  "Start fetching SPEC, whose key is KEY.
A fetch that signals as it starts fails like any other, so it can't
leave KEY loading for good."
  (cl-incf octocat-sync--running)
  (let ((answered nil)
        (token (list key t (float-time))))
    (puthash key token octocat-sync--fetches)
    (condition-case err
        (let ((octocat--gh-owner token))
          (funcall (plist-get (octocat-sync--props spec) :fetch)
                   (lambda (result)
                     (setq answered t)
                     (when (eq (gethash key octocat-sync--fetches) token)
                       (octocat-sync--done key result)))))
      (error (cond (answered (signal (car err) (cdr err)))
                   ((eq (gethash key octocat-sync--fetches) token)
                    (octocat-sync--done key (cons 'error (error-message-string err)))))))))

(defun octocat-sync--pump ()
  "Start queued fetches while fewer than `octocat-sync-max-requests' run.
Page requests go first; a prefetch only when none is queued, and only
when no other prefetch runs."
  (while (and octocat-sync--queue
              (< octocat-sync--running octocat-sync-max-requests))
    (pcase-let ((`(,key . ,spec) (pop octocat-sync--queue)))
      (octocat-sync--start key spec)))
  (when (and octocat-sync--prefetches
             (null octocat-sync--prefetching)
             (< octocat-sync--running octocat-sync-max-requests))
    (pcase-let ((`(,key . ,spec) (pop octocat-sync--prefetches)))
      (setq octocat-sync--prefetching key)
      (octocat-sync--start key spec))))

(defun octocat-sync--done (key result)
  "Store RESULT, the outcome of fetching resource KEY, and notify."
  (octocat-sync--drop-fetch key)
  (let* ((db      (octocat-sync--db))
         (spec    (car (read-from-string key)))
         (props   (octocat-sync--props spec))
         (entity  (plist-get props :entity))
         (fields  (lambda ()
                    (and entity (caar (sqlite-select db "SELECT fields FROM entity WHERE key = ?"
                                                     (list entity))))))
         (before  (funcall fields))
         (status  (car (sqlite-select
                        db "SELECT body IS NOT NULL, error IS NOT NULL, invalidated_at IS NOT NULL
                            FROM resource WHERE key = ?"
                        (list key))))
         (fetched (car status))
         ;; Its page draws no data, an error and an outdated mark, so
         ;; a change to any of them changes the snapshot.
         (shown   (or (not (eql fetched 1)) (eql (nth 1 status) 1) (eql (nth 2 status) 1)
                      (eq (car-safe result) 'error)))
         (touched (condition-case err
                      (if (eq (car-safe result) 'error)
                          (let ((kind (octocat-sync--error-kind (cdr result))))
                            (setq octocat-sync--offline (eq kind 'offline))
                            (octocat-sync--write-error db key (cdr result) kind (float-time))
                            nil)
                        (setq octocat-sync--offline nil)
                        (octocat-sync--write db key result (float-time)))
                    ;; Say a second Emacs held the lock past the timeout: drop the write.
                    (error (octocat--debug-log (format "sync write %s failed" key)
                                               (error-message-string err))
                           nil))))
    (octocat-sync--set-loading key nil)
    (octocat-sync--notify (if shown (cl-adjoin key touched :test #'equal) touched))
    ;; The main entity changed, so the lists filtered on it may have
    ;; gained or lost it.  A first fetch has nothing to compare.
    (when (and entity (eql fetched 1) (not (eq (car-safe result) 'error))
               (not (equal before (funcall fields))))
      (octocat-sync--invalidate
       db (and (plist-get props :invalidates) (funcall (plist-get props :invalidates))))))
  (let ((waiting (seq-filter (lambda (w) (equal (car w) key)) octocat-sync--waiters)))
    (when waiting
      (setq octocat-sync--waiters (seq-difference octocat-sync--waiters waiting #'eq))
      (let ((data (if (eq (car-safe result) 'error)
                      result
                    (plist-get (octocat-sync-read (car (read-from-string key))) :data))))
        (dolist (w waiting) (funcall (cdr w) data)))))
  (octocat-sync--pump))

;;;; Mutations
;;
;; A mutation's optimistic change is an overlay in memory that reads
;; apply over the stored fields, so every page showing the entity shows
;; it at once.  It is never written to SQLite before GitHub accepts it.

(defvar octocat-sync--mutations (make-hash-table :test #'eq)
  "Mutation name to a function of the spec's arguments returning its plist.")

(defvar octocat-sync--pending nil
  "Mutations sent and not yet answered, oldest first.
Each is a plist (:changes ALIST :resources KEYS :label LABEL :slot SLOT),
where ALIST holds (ENTITY-KEY . FIELDS).")

(defmacro octocat-sync-define-mutation (name args &rest props)
  "Define the mutation NAME, whose spec is (NAME . ARGS).
PROPS are evaluated with ARGS bound:
:label        what it is doing, such as \"Closing issue…\";
:slot         where a page shows that, such as `action' (the default)
              for under a timeline or `merge' for the merge box;
:resources    a function returning the specs of the resources it acts
              on: their snapshots' :mutating has (SLOT . LABEL) while
              it runs;
:optimistic   optional, a function returning a list of (ENTITY-KEY .
              FIELDS), FIELDS an alist of the values it will set;
:send         a function of DONE that sends it and calls DONE with nil,
              or with (error . MESSAGE);
:invalidates  optional, a function returning the specs, `_' matching
              anything, of resources it makes outdated."
  (declare (indent 2))
  `(puthash ',name (lambda ,args (list ,@props)) octocat-sync--mutations))

(defun octocat-sync--overlays ()
  "Return the optimistic overlays of the pending mutations, in order."
  (mapcan (lambda (m) (copy-sequence (plist-get m :changes))) octocat-sync--pending))

(defun octocat-sync--mutating (key)
  "Return the pending mutations of resource KEY as an alist (SLOT . LABEL).
The newest of a slot comes first."
  (mapcar (lambda (m) (cons (plist-get m :slot) (plist-get m :label)))
          (seq-filter (lambda (m) (member key (plist-get m :resources)))
                      (reverse octocat-sync--pending))))

(defun octocat-sync--touched (db mutation)
  "Return the keys of the resources in DB that MUTATION is visible on."
  (delete-dups (append (plist-get mutation :resources)
                       (octocat-sync--linked db (mapcar #'car (plist-get mutation :changes))))))

(defun octocat-sync-submit (spec &optional on-done)
  "Send the mutation SPEC, applying its optimistic change at once.
ON-DONE, if given, is called with nil on success, or (error . MESSAGE).
On failure the change is dropped and the error shown in the echo area."
  (let* ((props (apply (or (gethash (car spec) octocat-sync--mutations)
                           (error "Octocat: Unknown mutation `%s'" (car spec)))
                       (cdr spec)))
         (db    (octocat-sync--db))
         (mutation
          (list :changes (mapcar (lambda (change)
                                   (let ((fields (make-hash-table :test #'equal)))
                                     (pcase-dolist (`(,k . ,v) (cdr change))
                                       (puthash k v fields))
                                     (cons (car change) fields)))
                                 (and (plist-get props :optimistic)
                                      (funcall (plist-get props :optimistic))))
                :resources (mapcar #'octocat-sync-spec-key
                                   (and (plist-get props :resources)
                                        (funcall (plist-get props :resources))))
                :label (plist-get props :label)
                :slot (or (plist-get props :slot) 'action))))
    (setq octocat-sync--pending (append octocat-sync--pending (list mutation)))
    (octocat-sync--notify (octocat-sync--touched db mutation))
    (funcall (plist-get props :send)
             (lambda (result)
               (octocat-sync--answered
                mutation result
                (and (plist-get props :invalidates)
                     (funcall (plist-get props :invalidates))))
               (when on-done (funcall on-done result))))))

(defun octocat-sync--answered (mutation result patterns)
  "Settle MUTATION once GitHub answered RESULT; outdate PATTERNS on success.
On success its changes are written to the store, as GitHub now has
them."
  (let ((db (octocat-sync--db)))
    (setq octocat-sync--pending (delq mutation octocat-sync--pending))
    (if (eq (car-safe result) 'error)
        (message "Octocat: %s failed: %s"
                 (string-remove-suffix "…" (plist-get mutation :label)) (cdr result))
      (condition-case err
          (octocat-sync--transaction db
            (pcase-dolist (`(,key . ,fields) (plist-get mutation :changes))
              (when-let* ((type (caar (sqlite-select db "SELECT type FROM entity WHERE key = ?"
                                                     (list key)))))
                (octocat-sync--merge db key (intern type) fields (float-time)))))
        (error (octocat--debug-log "sync mutation write failed" (error-message-string err)))))
    (octocat-sync--notify (octocat-sync--touched db mutation))
    (unless (eq (car-safe result) 'error)
      (octocat-sync--invalidate db patterns))))


;;;; GitHub entities
;;
;; Builders for the entities several pages share.  Fields keep the names
;; of GitHub's GraphQL API, which `gh ... --json' also uses.

(defun octocat-sync-item-key (type repo number)
  "Return the key of issue or PR (TYPE `issue' or `pr') NUMBER of REPO."
  (format "%s:%s#%d" type (downcase repo) number))

(defun octocat-sync-user (user)
  "Return the `user' entity of USER, a table with a \"login\", or USER.
Only the login is kept: the fields beside it vary with the source."
  (let ((login (and (hash-table-p user) (gethash "login" user))))
    (if (not (stringp login))
        user
      (let ((fields (make-hash-table :test #'equal)))
        (puthash "login" login fields)
        (octocat-sync-entity 'user (concat "user:" (downcase login)) fields)))))

(defun octocat-sync-label (repo label)
  "Return the `label' entity of LABEL of REPO, a table with name and colour."
  (let ((fields (make-hash-table :test #'equal)))
    (puthash "name" (gethash "name" label) fields)
    (puthash "color" (gethash "color" label) fields)
    (octocat-sync-entity 'label (format "label:%s/%s" (downcase repo) (gethash "name" label))
                         fields)))

(defun octocat-sync--item-ref (ref)
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

(defun octocat-sync-item (type repo item)
  "Return the entity of the issue or PR ITEM of REPO; TYPE is `issue' or `pr'.
ITEM is a table of its fields.  Its author, assignees and labels become
entities too.  Labels must be the whole set: an entity's list fields
are never a page of it."
  (let ((fields (copy-hash-table item)))
    (when-let* ((author (gethash "author" item)))
      (puthash "author" (octocat-sync-user author) fields))
    (when-let* ((assignees (gethash "assignees" item)))
      (puthash "assignees" (cl-map 'vector #'octocat-sync-user assignees) fields))
    (when-let* ((labels (gethash "labels" item)))
      (when (sequencep labels)
        (puthash "labels" (cl-map 'vector (lambda (l) (octocat-sync-label repo l)) labels)
                 fields)))
    ;; The lists and the page fetch these with different fields; keep
    ;; those both have, so the entity reads the same from either.
    (dolist (key '("closedByPullRequestsReferences" "closingIssuesReferences"))
      (when-let* ((refs (gethash key item)))
        (when (sequencep refs)
          (puthash key (cl-map 'vector #'octocat-sync--item-ref refs) fields))))
    (octocat-sync-entity type (octocat-sync-item-key type repo (gethash "number" item))
                         fields)))

(defun octocat-sync-repo (fields)
  "Return the `repo' entity of FIELDS, a table in GraphQL's names."
  (octocat-sync-entity 'repo (concat "repo:" (downcase (gethash "nameWithOwner" fields)))
                       fields))

(defun octocat-sync-repo-rest (repo)
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
    (octocat-sync-repo fields)))

(defun octocat-sync-run (repo run)
  "Return the `run' entity of RUN, a workflow run of REPO, by `gh run' names."
  (octocat-sync-entity 'run (format "run:%s/%s" (downcase repo) (gethash "databaseId" run))
                       (copy-hash-table run)))

(defun octocat-sync-detail (item parts make)
  "Return ITEM, such as an issue, as the tree of its page's resource.
MAKE returns the entity of a table of fields, such as
`octocat-sync-item' does; the entity goes under \"item\", shared with
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

(defun octocat-sync-detail-item (data)
  "Return the item of DATA, read from an `octocat-sync-detail' tree.
Its parts are put back in it, so it has the shape `gh ... view' gives."
  (let ((item (copy-hash-table (gethash "item" data))))
    (maphash (lambda (k v) (unless (equal k "item") (puthash k v item))) data)
    item))

(defun octocat-sync-detail-read (spec)
  "Return the item of the detail resource SPEC as the store has it, or nil."
  (let ((data (plist-get (octocat-sync-read spec) :data)))
    (and data (octocat-sync-detail-item data))))

(provide 'octocat-sync)
;;; octocat-sync.el ends here
