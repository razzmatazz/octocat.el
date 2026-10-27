;;; octocat-doctor.el --- Report on octocat's code, store and requests  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; `octocat-doctor' writes a plain-text report to paste into a bug
;; report: the sync store's size and its largest resources; which pages
;; on screen refresh on their own, how often and why; the `gh' calls of
;; the last hour; and which files are loaded, and whether a compiled
;; one is older than its source.  It names the host and resources,
;; never a token.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'octocat-core)
(require 'octocat-sync)
(require 'octocat-vui)

(declare-function sqlite-select "ext:sqlite.c" (db query &optional values return-type))


;;;; Code

(defun octocat-doctor--duration (seconds)
  "Return SECONDS as a short duration, such as \"40 s\" or \"12 min\"."
  (cond ((< seconds 90)   (format "%d s" (round seconds)))
        ((< seconds 5400) (format "%d min" (round seconds 60)))
        ((< seconds 172800) (format "%.1f h" (/ seconds 3600.0)))
        (t                (format "%d days" (round seconds 86400)))))

(defun octocat-doctor--loaded-file (feature)
  "Return the file FEATURE was loaded from, or nil."
  (car (seq-find (lambda (entry) (member (cons 'provide feature) (cdr entry)))
                 load-history)))

(defun octocat-doctor--stale-p (file)
  "Return non-nil if FILE, a compiled file, is older than its source."
  (let ((source (concat (file-name-sans-extension file) ".el")))
    (and (not (equal file source))
         (file-exists-p source)
         (file-newer-than-file-p source file))))

(defun octocat-doctor--features ()
  "Return the features of octocat loaded, sorted."
  (sort (seq-filter (lambda (f)
                      (let ((name (symbol-name f)))
                        (and (string-prefix-p "octocat" name)
                             (not (string-suffix-p "-tests" name)))))
                    features)
        (lambda (a b) (string< (symbol-name a) (symbol-name b)))))

(defun octocat-doctor--gh-version (gh)
  "Return the first line `GH --version' prints, or why there is none."
  (if (not gh)
      "not found"
    (condition-case err
        (car (process-lines gh "--version"))
      (error (error-message-string err)))))

(defun octocat-doctor--code ()
  "Return the report's lines on Emacs, `gh' and the files loaded."
  (let ((gh (octocat--gh-executable)))
    (concat
     "Code\n"
     (format "  Emacs %s, %s, native-comp %s, SQLite %s\n"
             emacs-version system-configuration
             (if (and (fboundp 'native-comp-available-p) (native-comp-available-p)) "yes" "no")
             (if (and (fboundp 'sqlite-available-p) (sqlite-available-p)) "yes" "no"))
     (format "  GC          threshold %s, percentage %s; %d so far, %.1f s in all\n"
             (file-size-human-readable gc-cons-threshold) gc-cons-percentage
             gcs-done gc-elapsed)
     (format "  gh          %s, %s\n" (or gh octocat-gh-program)
             (octocat-doctor--gh-version gh))
     (mapconcat (lambda (feature)
                  (let ((file (octocat-doctor--loaded-file feature)))
                    ;; No file: evaluated from a buffer.
                    (format "  %-18s %s%s\n" feature (or file "evaluated, not from a file")
                            (if (and file (octocat-doctor--stale-p file))
                                "  STALE: older than its .el"
                              ""))))
                (octocat-doctor--features) ""))))


;;;; Store

(defun octocat-doctor--file-size (file)
  "Return the size of FILE, readable, or \"none\" if there is no FILE."
  (if-let* ((attributes (file-attributes file)))
      (file-size-human-readable (file-attribute-size attributes))
    "none"))

(defun octocat-doctor--store (db file now)
  "Return the report's lines on DB, the store in FILE, at NOW."
  (pcase-let ((`(,count ,chars ,errors ,outdated)
               (car (sqlite-select db "SELECT count(*), coalesce(sum(length(body)), 0),
                                              count(error), count(invalidated_at)
                                       FROM resource"))))
    (concat
     "Store\n"
     (format "  File        %s  %s, WAL %s\n" file (octocat-doctor--file-size file)
             (octocat-doctor--file-size (concat file "-wal")))
     (format "  Free        %s, which VACUUM gives back\n"
             (file-size-human-readable
              (* (caar (sqlite-select db "PRAGMA freelist_count"))
                 (caar (sqlite-select db "PRAGMA page_size")))))
     (format "  Schema      %s (this code's: %d)\n"
             (caar (sqlite-select db "PRAGMA user_version")) octocat-sync--schema)
     (format "  Resources   %d, %s of data, %d failed, %d outdated\n"
             count (file-size-human-readable chars) errors outdated)
     (format "  Entities    %d\n" (caar (sqlite-select db "SELECT count(*) FROM entity")))
     (format "  Loading     %d, of which %d timed refetches\n"
             (hash-table-count octocat-sync--loading) (hash-table-count octocat-sync--quiet))
     (format "  Queued      %d page requests, %d prefetches, %d timed refetches\n"
             (length octocat-sync--queue) (length octocat-sync--prefetches)
             (length octocat-sync--polls))
     (format "  Running     %d of at most %d\n" octocat-sync--running octocat-sync-max-requests)
     (format "  Offline     %s\n" (if octocat-sync--offline "yes" "no"))
     (format "  Fresh for   %s s\n" octocat-sync-fresh-for)
     "\nLargest resources\n"
     (mapconcat (pcase-lambda (`(,key ,size ,fetched ,error))
                  (format "  %9s  %12s  %s%s\n" (file-size-human-readable size)
                          (if fetched
                              (format "%s ago" (octocat-doctor--duration (- now fetched)))
                            "never fetched")
                          key (if error (concat "  failed: " error) "")))
                (sqlite-select db "SELECT key, coalesce(length(body), 0), fetched_at, error
                                   FROM resource ORDER BY 2 DESC LIMIT 10")
                ""))))


;;;; Refreshes

(defun octocat-doctor--rate (state offline idle-after)
  "Return how timed refetches run, from STATE, `octocat-vui--poll-state'.
OFFLINE is whether GitHub was out of reach, and IDLE-AFTER
`octocat-sync-poll-idle-after'."
  (pcase-let* ((`(,_ ,slowdown ,idle ,focused ,power) state)
               (why (delq nil (list (and offline "offline")
                                    (pcase power ('low "low battery") ('battery "on battery"))
                                    (and (>= idle idle-after)
                                         (format "idle %s" (octocat-doctor--duration idle)))
                                    (and (not focused) "no Emacs frame focused")))))
    (concat (pcase slowdown
              ('nil "stopped")
              (1    "full rate")
              (n    (format "%d times slower" n)))
            (and why (format " (%s)" (string-join why ", "))))))

(defun octocat-doctor--resource (spec slowdown now)
  "Return a line on how SPEC is refetched, SLOWDOWN times slower, as of NOW."
  (pcase-let ((`(,fetched ,interval ,state) (octocat-sync-poll-info spec)))
    (format "    %-16s %-22s %s%s\n"
            (cond ((null interval) "never")
                  ((null slowdown) "stopped")
                  (t (format "every %s" (octocat-doctor--duration (* slowdown interval)))))
            (if fetched
                (format "fetched %s ago" (octocat-doctor--duration (- now fetched)))
              "not fetched")
            (prin1-to-string spec)
            (pcase state
              ('queued  "  [refetch queued]")
              ('quiet   "  [refetching]")
              ('loading "  [loading]")
              (_        "")))))

(defun octocat-doctor--refreshes (now)
  "Return the report's lines on the pages refreshing on their own, at NOW."
  (let* ((state    octocat-vui--poll-state)
         (slowdown (nth 1 state))
         (shown    (octocat-vui--shown-pages))
         (pages    (seq-uniq (mapcar #'car (apply #'append
                                                  (hash-table-values
                                                   octocat-vui--subscriptions)))))
         (hidden   (seq-count #'buffer-live-p (seq-difference pages shown #'eq))))
    (concat
     "Refreshing pages on screen\n"
     (format "  Default     %s\n"
             (if octocat-sync-poll-interval
                 (format "every %s, slower after %s idle"
                         (octocat-doctor--duration octocat-sync-poll-interval)
                         (octocat-doctor--duration octocat-sync-poll-idle-after))
               "off: `octocat-sync-poll-interval' is nil"))
     (format "  Now         %s\n"
             (if state
                 (octocat-doctor--rate state octocat-sync--offline octocat-sync-poll-idle-after)
               "not checked yet"))
     (format "  Checked     %s\n"
             (if (timerp octocat-vui--poll-timer)
                 (format "every %d s, last %s ago" octocat-vui--poll-tick
                         (if state (octocat-doctor--duration (- now (car state))) "never"))
               "not running: no page on screen"))
     (format "  Power       %s\n" (octocat-power))
     (format "  Pages       %d on screen, %d not, which don't refresh\n" (length shown) hidden)
     (mapconcat (lambda (buf)
                  (concat (format "  %s\n" (buffer-name buf))
                          (mapconcat (lambda (spec) (octocat-doctor--resource spec slowdown now))
                                     (octocat-vui--page-specs (list buf)) "")))
                shown ""))))


;;;; Requests

(defun octocat-doctor--more-p (a b)
  "Return non-nil if A, a (REASON . COUNT), comes before B: more, then by name."
  (or (> (cdr a) (cdr b))
      (and (= (cdr a) (cdr b)) (string< (car a) (car b)))))

(defun octocat-doctor--requests (log now)
  "Return the report's lines on LOG, the `gh' log `octocat--gh-log', at NOW."
  (let ((sum (lambda (seconds label)
               (let* ((calls  (seq-filter (lambda (e) (> (aref e 0) (- now seconds))) log))
                      (failed (seq-count (lambda (e) (and (aref e 1) (not (aref e 3)))) calls))
                      (counts nil))
                 (dolist (e calls)
                   (let ((reason (or (aref e 4) 'other)))
                     (setf (alist-get reason counts) (1+ (alist-get reason counts 0)))))
                 (format "  %-11s %4d%s, %d failed\n" label (length calls)
                         (if counts
                             (format " (%s)"
                                     (mapconcat (pcase-lambda (`(,r . ,n)) (format "%s %d" r n))
                                                (sort counts #'octocat-doctor--more-p)
                                                ", "))
                           "")
                         failed)))))
    (concat
     "Requests to GitHub through gh, last hour\n"
     (funcall sum 300 "Last 5 min")
     (funcall sum 3600 "Last hour")
     (format "  %-11s %4d\n" "Running" (seq-count (lambda (e) (null (aref e 1))) log))
     "\nMost recent requests\n"
     (mapconcat (lambda (e)
                  (format "  %s  %7s  %-9s %-6s %s\n"
                          (format-time-string "%H:%M:%S" (aref e 0))
                          (if (aref e 1) (format "%.1f s" (- (aref e 1) (aref e 0))) "…")
                          (or (aref e 4) 'other)
                          (cond ((null (aref e 1)) "")
                                ((aref e 3) "ok")
                                (t "failed"))
                          (aref e 2)))
                (seq-take log 20) ""))))


;;;; Report

(defun octocat-doctor-report ()
  "Return, as a string, the report of `octocat-doctor'."
  (let ((now (float-time)))
    (concat (format "octocat-doctor at %s, host %s\n\n"
                    (format-time-string "%F %T") (octocat-sync--host))
            (octocat-doctor--store (octocat-sync--db) (octocat-sync--file) now)
            "\n"
            (octocat-doctor--refreshes now)
            "\n"
            (octocat-doctor--requests octocat--gh-log now)
            "\n"
            (octocat-doctor--code))))

(defvar octocat-doctor-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap of `octocat-doctor-mode'; `g' redoes the report.")

(define-derived-mode octocat-doctor-mode special-mode "Octocat-Doctor"
  "Major mode of the `octocat-doctor' report."
  (setq-local revert-buffer-function (lambda (&rest _) (octocat-doctor-show))))

(defun octocat-doctor-show ()
  "Show the report of `octocat-doctor-report', which `g' redoes."
  (let ((buf (get-buffer-create "*octocat-doctor*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'octocat-doctor-mode)
        (octocat-doctor-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (octocat-doctor-report)))
      (goto-char (point-min)))
    (octocat-display-buffer buf)))

(provide 'octocat-doctor)
;;; octocat-doctor.el ends here
