;;; octocat-async.el --- Run work in a child Emacs, off the UI  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Work too slow for the UI, such as highlighting a large file, runs in
;; a worker: one child Emacs, started on first use, which runs jobs one
;; at a time and stops after `octocat-async--idle-time' without one.  It
;; requires no other module.
;;
;; `octocat-async-call' is the whole interface.  Its caller gets the
;; result either way: a small job, or any job while the worker is off,
;; runs in this Emacs at once; a job the worker fails (an error, a
;; crash, an unreadable result, or past its deadline) runs in this Emacs
;; after.  Three failures in a row turn the worker off until restart.
;;
;; Messages are one line each, printed with every newline and non-ASCII
;; character escaped, so a newline always ends one.  To the worker:
;;
;;   (init VARS AUTOLOADS)  then  (job ID FEATURE FN ARGS)
;;
;; and back: (ready PID), then (ok ID VALUE MS) or (error ID MESSAGE MS),
;; MS the time the job took the worker.
;;
;; `octocat-async--log' keeps the last hour's jobs for `octocat-doctor'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst octocat-async--file
  (or load-file-name buffer-file-name (locate-library "octocat-async"))
  "This file, which the worker loads.")

(defvar octocat-async--pipe-limit 4096
  "Longest job, in characters, sent through the pipe.
A longer one goes through a file.")

(defvar octocat-async--deadline 10.0
  "Seconds the worker may take on a job whose caller gave no deadline.")

(defvar octocat-async--startup-time 5.0
  "Seconds more for a job a just-started worker runs.
They load Emacs and the job's libraries.")

(defvar octocat-async--idle-time 300
  "Seconds without a job after which the worker stops.")

(defvar octocat-async--max-failures 3
  "Failures in a row that turn the worker off for the session.")

(defvar octocat-async--vars
  '(load-path auto-mode-alist interpreter-mode-alist magic-mode-alist
              magic-fallback-mode-alist major-mode-remap-alist major-mode-remap-defaults)
  "Variables the worker gets from this Emacs, to pick a file's mode as it would.")

(defvar octocat-async-in-worker nil
  "Non-nil in the worker.")

(defvar octocat-async--off nil
  "Nil, or (TIME . REASON) since the worker is off for the session.")

(defvar octocat-async--failures 0
  "Failures in a row; a success resets it.")

(defvar octocat-async--worker nil
  "The worker's process, or nil.")

(defvar octocat-async--worker-info nil
  "The worker's (:pid :started :jobs :busy :files), or nil.
BUSY is the ms its jobs took it; FILES its code's, each (FILE .
MODIFIED) as it loaded them.")

(defvar octocat-async--queue nil
  "Jobs waiting for the worker, oldest first.")

(defvar octocat-async--current nil
  "The job the worker runs, or nil.")

(defvar octocat-async--idle-timer nil
  "Timer stopping the idle worker.")

(defvar octocat-async--next-id 0
  "The last job's id.")

(defvar octocat-async--log nil
  "The jobs of the last hour, newest first, for `octocat-doctor'.
Each is a vector [START END KIND SIZE OUTCOME PARENT-MS WORKER-MS
ERROR]: END is nil until done; OUTCOME `ok', `in-thread', `timeout',
`error', `crash', `unreadable', `no-start' or `dropped'; PARENT-MS the
time this Emacs spent on it, sending it and reading its result, or
running it; WORKER-MS the worker's.")

(cl-defstruct (octocat-async--job (:constructor octocat-async--job-create))
  "A call `octocat-async-call' handed the worker."
  id kind size deadline feature fn args callback entry timer file cancelled)


;;;; Messages

(defun octocat-async--print (message)
  "Return MESSAGE as a line, every newline and non-ASCII character escaped."
  (let ((print-escape-newlines t)
        (print-escape-control-characters t)
        (print-escape-multibyte t)
        (print-escape-nonascii t)
        (print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-symbols-bare t))
    (concat (prin1-to-string message) "\n")))

(defun octocat-async--readable (value)
  "Return VALUE as printing and reading it back gives it, or nil."
  (condition-case nil
      (car (read-from-string (octocat-async--print value)))
    (error nil)))

(defun octocat-async--init-message ()
  "Return the worker's first message.
It holds `octocat-async--vars', and the autoloads of the modes and
functions they name, as this Emacs has them: a `magic-mode-alist'
function void in the worker fails `set-auto-mode' for every file."
  (let* ((vars (delq nil (mapcar (lambda (v)
                                   (and (boundp v)
                                        (cons v (seq-filter #'octocat-async--readable
                                                            (symbol-value v)))))
                                 octocat-async--vars)))
         (modes (seq-uniq (cl-loop for (_ . value) in vars
                                   append (cl-loop for e in value
                                                   for m = (if (consp e) (cdr e) e)
                                                   for m1 = (if (consp m) (car m) m)
                                                   when (and m1 (symbolp m1)) collect m1
                                                   when (and (consp e) (car e) (symbolp (car e)))
                                                   collect (car e)))))
         (autoloads (cl-loop for m in modes
                             for f = (and (fboundp m) (symbol-function m))
                             when (autoloadp f) collect (list m (cadr f))
                             ;; Not `subrp', which a native-compiled one is too.
                             else when (and f (not (subr-primitive-p f)))
                             collect (let ((file (symbol-file m 'defun)))
                                       (and file (list m file))))))
    (list 'init vars (delq nil autoloads))))


;;;; The log

(defun octocat-async--log-start (kind size)
  "Record a job of KIND on SIZE bytes starting now, and return its entry.
Entries over an hour old are dropped."
  (let* ((now (float-time))
         (entry (vector now nil kind size nil 0.0 nil nil)))
    (setq octocat-async--log
          (cons entry (seq-take-while (lambda (e) (> (aref e 0) (- now 3600)))
                                      octocat-async--log)))
    entry))

(defun octocat-async--log-end (entry outcome &optional worker-ms error)
  "Record ENTRY's job done with OUTCOME, WORKER-MS and ERROR."
  (aset entry 1 (float-time))
  (aset entry 4 outcome)
  (aset entry 6 worker-ms)
  (aset entry 7 error))

(defmacro octocat-async--timed (entry &rest body)
  "Run BODY, adding its time to ENTRY's PARENT-MS."
  (declare (indent 1))
  (let ((t0 (make-symbol "t0")))
    `(let ((,t0 (float-time)))
       (unwind-protect (progn ,@body)
         (aset ,entry 5 (+ (aref ,entry 5) (* 1000 (- (float-time) ,t0))))))))


;;;; Running in this Emacs

(defun octocat-async--run-here (feature fn args)
  "Return FN applied to ARGS here, FEATURE first loaded, or nil if it signals."
  (condition-case err
      (progn (when feature (octocat-async--load feature))
             (apply fn args))
    (error (message "Octocat: %s failed: %s" fn (error-message-string err))
           nil)))

(defun octocat-async--in-thread (kind size feature fn args callback)
  "Run FN on ARGS here, FEATURE loaded, and call CALLBACK with its value.
KIND and SIZE are for the log."
  (let* ((entry (octocat-async--log-start kind size))
         (value (octocat-async--timed entry
                  (octocat-async--run-here feature fn args))))
    (octocat-async--log-end entry 'in-thread)
    (funcall callback value)))

(defun octocat-async--fall-back (job)
  "Run JOB here, after the current command, as the worker could not."
  (run-at-time 0 nil
               (lambda ()
                 (unless (octocat-async--job-cancelled job)
                   (octocat-async--in-thread
                    (octocat-async--job-kind job) (octocat-async--job-size job)
                    (octocat-async--job-feature job) (octocat-async--job-fn job)
                    (octocat-async--job-args job) (octocat-async--job-callback job))))))


;;;; The interface

(cl-defun octocat-async-call (kind feature fn args callback &key here deadline size)
  "Call CALLBACK with FN applied to ARGS, in the worker unless HERE.
The worker runs the job, and CALLBACK runs once it is done; should the
worker fail, the job runs here instead, so CALLBACK always runs, unless
the job is cancelled, see `octocat-async-cancel'.  With HERE, the
caller's guess that the job is too small to be worth the worker, or
while the worker is off, the job runs here at once, and CALLBACK runs
before this returns.

DEADLINE is the seconds the worker may take, `octocat-async--deadline'
if nil: past it, the job fails.  SIZE, about how many bytes ARGS hold,
and KIND, a symbol such as `fontify', name the job in the log.

FEATURE, a feature to `require' or a file to `load', defines FN, which
is a symbol.  ARGS and FN's value must print readably: no buffer,
marker, process or the like.  Should FN signal even here, CALLBACK gets
nil.

Return the job, or nil when it ran here."
  (if (or here octocat-async--off)
      (progn (octocat-async--in-thread kind size feature fn args callback) nil)
    (let ((job (octocat-async--job-create
                :id (cl-incf octocat-async--next-id) :kind kind :size size
                :deadline (or deadline octocat-async--deadline)
                :feature feature :fn fn :args args :callback callback)))
      (setq octocat-async--queue (nconc octocat-async--queue (list job)))
      (octocat-async--pump)
      job)))

(defun octocat-async-cancel (job)
  "Drop JOB, as from `octocat-async-call': its callback won't run.
A job the worker runs finishes there, its result unread."
  (when (and job (not (octocat-async--job-cancelled job)))
    (setf (octocat-async--job-cancelled job) t)
    (when (memq job octocat-async--queue)
      (setq octocat-async--queue (delq job octocat-async--queue))
      (octocat-async--log-end (octocat-async--log-start (octocat-async--job-kind job)
                                                        (octocat-async--job-size job))
                              'dropped))))

(defun octocat-async-status ()
  "Return the worker's state, for `octocat-doctor': a plist.
:off is nil or (TIME . REASON), :failures the failures in a row,
:queued and :running the jobs waiting and running, :worker nil or the
worker's (:pid :started :jobs :busy), :attributes its
`process-attributes', :stderr the end of what workers printed there."
  (let ((proc octocat-async--worker))
    (list :off octocat-async--off
          :failures octocat-async--failures
          :queued (length octocat-async--queue)
          :running (if octocat-async--current 1 0)
          :worker (and (process-live-p proc) octocat-async--worker-info)
          :attributes (and (process-live-p proc) (process-attributes (process-id proc)))
          :stderr (let ((buf (get-buffer " *octocat-async stderr*")))
                    (and buf (with-current-buffer buf
                               (string-trim (buffer-substring
                                             (max (point-min) (- (point-max) 300))
                                             (point-max)))))))))

(defun octocat-async-turn-on ()
  "Turn the worker back on, if failures turned it off."
  (setq octocat-async--off nil
        octocat-async--failures 0))


;;;; The worker, from this Emacs

(defun octocat-async--load (feature)
  "Load FEATURE: `require' a symbol, `load' a file."
  (if (symbolp feature) (require feature) (load feature nil t)))

(defun octocat-async--feature-file (feature)
  "Return the file to load FEATURE from, or nil."
  (if (stringp feature) feature (locate-library (symbol-name feature))))

(defun octocat-async--modified (file)
  "Return FILE's modification time, or nil."
  (file-attribute-modification-time (file-attributes file)))

(defun octocat-async--stale-p ()
  "Return non-nil if code the worker loaded changed on disk since."
  (cl-loop for (file . time) in (plist-get octocat-async--worker-info :files)
           thereis (not (equal (octocat-async--modified file) time))))

(defun octocat-async--note-file (feature)
  "Record FEATURE's file in the worker's info, as the worker will load it."
  (when-let* ((file (and feature (octocat-async--feature-file feature))))
    (unless (assoc file (plist-get octocat-async--worker-info :files))
      (setq octocat-async--worker-info
            (plist-put octocat-async--worker-info :files
                       (cons (cons file (octocat-async--modified file))
                             (plist-get octocat-async--worker-info :files)))))))

(defun octocat-async--start ()
  "Start the worker and return it, or nil if it cannot start."
  (condition-case err
      (let* ((stderr (make-pipe-process
                      :name "octocat-async stderr"
                      :buffer (octocat-async--stderr-buffer)
                      :noquery t
                      ;; Not the default, which notes its end in the buffer.
                      :sentinel #'ignore))
             (proc (make-process
                    :name "octocat-async"
                    :buffer (generate-new-buffer " *octocat-async*")
                    :command (list (expand-file-name invocation-name invocation-directory)
                                   "-Q" "--batch" "-l" octocat-async--file
                                   "-f" "octocat-async-worker-main")
                    :connection-type 'pipe
                    :coding 'utf-8-emacs-unix
                    :noquery t
                    :stderr stderr
                    :filter #'octocat-async--filter
                    :sentinel #'octocat-async--sentinel)))
        (setq octocat-async--worker proc
              octocat-async--worker-info
              (list :pid (process-id proc) :started (float-time) :jobs 0 :busy 0.0 :fresh t
                    :files (list (cons octocat-async--file
                                       (octocat-async--modified octocat-async--file)))))
        (process-send-string proc (octocat-async--print (octocat-async--init-message)))
        proc)
    (error (setq octocat-async--worker nil)
           (cons 'error (error-message-string err)))))

(defun octocat-async--stop (&optional _reason)
  "Stop the worker, if running; its job is not failed by this."
  (when-let* ((proc octocat-async--worker))
    (setq octocat-async--worker nil)
    (process-put proc 'octocat-async-stopped t)
    (when (process-live-p proc) (delete-process proc))
    (when (buffer-live-p (process-buffer proc)) (kill-buffer (process-buffer proc)))))

(defun octocat-async--arm-idle ()
  "Stop the worker after `octocat-async--idle-time' without a job."
  (when octocat-async--idle-timer (cancel-timer octocat-async--idle-timer))
  (setq octocat-async--idle-timer
        (and octocat-async--worker
             (run-at-time octocat-async--idle-time nil
                          (lambda ()
                            (setq octocat-async--idle-timer nil)
                            (unless (or octocat-async--current octocat-async--queue)
                              (octocat-async--stop 'idle)))))))

(defun octocat-async--pump ()
  "Hand the worker the next queued job, if it is free."
  (while (and (null octocat-async--current) octocat-async--queue)
    (let ((job (pop octocat-async--queue)))
      (if octocat-async--off
          (octocat-async--fall-back job)
        (when (and octocat-async--worker (octocat-async--stale-p))
          (octocat-async--stop 'stale))
        (let ((proc (or (and (process-live-p octocat-async--worker) octocat-async--worker)
                        (octocat-async--start))))
          (if (processp proc)
              (octocat-async--send job proc)
            (octocat-async--fail job 'no-start (cdr proc)
                                 (octocat-async--log-start (octocat-async--job-kind job)
                                                           (octocat-async--job-size job))))))))
  (octocat-async--arm-idle))

(defun octocat-async--send (job proc)
  "Send JOB to the worker PROC, and start its deadline."
  (let* ((entry (octocat-async--log-start (octocat-async--job-kind job)
                                          (octocat-async--job-size job)))
         (fresh (plist-get octocat-async--worker-info :fresh))
         (deadline (+ (octocat-async--job-deadline job)
                      (if fresh octocat-async--startup-time 0))))
    (setf (octocat-async--job-entry job) entry)
    (setq octocat-async--current job
          octocat-async--worker-info (plist-put octocat-async--worker-info :fresh nil))
    (octocat-async--note-file (octocat-async--job-feature job))
    (setf (octocat-async--job-timer job)
          (run-at-time deadline nil #'octocat-async--timeout job))
    (condition-case err
        (octocat-async--timed entry
          (let ((line (octocat-async--print
                       (list 'job (octocat-async--job-id job) (octocat-async--job-feature job)
                             (octocat-async--job-fn job) (octocat-async--job-args job)))))
            ;; Through a file when long: the worker reads stdin slowly, and
            ;; this Emacs waits until it has read all that was sent.
            (when (> (length line) octocat-async--pipe-limit)
              (let ((file (make-temp-file "octocat-async-")))
                (setf (octocat-async--job-file job) file)
                (let ((coding-system-for-write 'us-ascii-unix))
                  (write-region line nil file nil 'silent))
                (setq line (octocat-async--print (list 'job-file file)))))
            (process-send-string proc line)))
      (error (octocat-async--finish job)
             (octocat-async--stop 'send)
             (octocat-async--fail job 'crash (error-message-string err) entry)))))

(defun octocat-async--finish (job)
  "Clear JOB as the worker's current one, and delete its file."
  (when (octocat-async--job-timer job) (cancel-timer (octocat-async--job-timer job)))
  (when-let* ((file (octocat-async--job-file job)))
    (when (file-exists-p file) (delete-file file)))
  (when (eq octocat-async--current job) (setq octocat-async--current nil)))

(defun octocat-async--fail (job outcome error entry)
  "Record JOB failed with OUTCOME and ERROR, logged in ENTRY; run it here.
Turn the worker off once `octocat-async--max-failures' are in a row."
  (octocat-async--log-end entry outcome nil error)
  (cl-incf octocat-async--failures)
  (when (and (not octocat-async--off)
             (>= octocat-async--failures octocat-async--max-failures))
    (setq octocat-async--off (cons (float-time) (format "%s: %s" outcome error)))
    (octocat-async--stop 'off)
    (message "Octocat: background work failed %d times (%s); running it in Emacs until restart"
             octocat-async--failures outcome))
  (if (octocat-async--job-cancelled job)
      (aset entry 4 'dropped)
    (octocat-async--fall-back job)))

(defun octocat-async--timeout (job)
  "Fail JOB, which the worker took too long on, and stop the worker."
  (when (eq octocat-async--current job)
    (octocat-async--finish job)
    (octocat-async--stop 'timeout)
    (octocat-async--fail job 'timeout
                         (format "no answer in %.1f s"
                                 (- (float-time) (aref (octocat-async--job-entry job) 0)))
                         (octocat-async--job-entry job))
    (octocat-async--pump)))

(defun octocat-async--sentinel (proc _event)
  "Fail the job of the worker PROC, which exited unasked."
  (unless (or (process-live-p proc) (process-get proc 'octocat-async-stopped))
    (when (eq proc octocat-async--worker) (setq octocat-async--worker nil))
    (when (buffer-live-p (process-buffer proc)) (kill-buffer (process-buffer proc)))
    (when-let* ((job octocat-async--current))
      (octocat-async--finish job)
      (octocat-async--fail job 'crash
                           (format "exited with status %d" (process-exit-status proc))
                           (octocat-async--job-entry job)))
    (octocat-async--pump)))

(defun octocat-async--filter (proc string)
  "Read the worker PROC's messages, a line each, as STRING completes them."
  (when (buffer-live-p (process-buffer proc))
    (let ((job octocat-async--current) messages)
      (with-current-buffer (process-buffer proc)
        (let ((t0 (float-time)))
          (goto-char (point-max))
          (let ((from (point)))
            (insert string)
            ;; Only the new text: a long result comes in many pieces.
            (goto-char from))
          (while (search-forward "\n" nil t)
            (let ((end (point)))
              (goto-char (point-min))
              (push (condition-case err (read (current-buffer))
                      (error (list 'unreadable (error-message-string err))))
                    messages)
              (delete-region (point-min) end)))
          (when job
            (aset (octocat-async--job-entry job) 5
                  (+ (aref (octocat-async--job-entry job) 5) (* 1000 (- (float-time) t0)))))))
      (dolist (m (nreverse messages))
        (octocat-async--handle proc m)))))

(defun octocat-async--handle (proc message)
  "Act on MESSAGE from the worker PROC."
  (pcase message
    (`(ready ,_pid) nil)
    (`(,(and kind (or 'ok 'error)) ,id ,value ,ms)
     (let ((job octocat-async--current))
       (when (and job (eql id (octocat-async--job-id job)))
         (octocat-async--finish job)
         (setq octocat-async--worker-info
               (plist-put (plist-put octocat-async--worker-info :jobs
                                     (1+ (plist-get octocat-async--worker-info :jobs)))
                          :busy (+ (or (plist-get octocat-async--worker-info :busy) 0) ms)))
         (if (eq kind 'error)
             (octocat-async--fail job 'error value (octocat-async--job-entry job))
           (setq octocat-async--failures 0)
           (if (octocat-async--job-cancelled job)
               (octocat-async--log-end (octocat-async--job-entry job) 'dropped ms)
             (octocat-async--log-end (octocat-async--job-entry job) 'ok ms)
             (funcall (octocat-async--job-callback job) value)))
         (octocat-async--pump))))
    (`(unreadable ,error)
     (when-let* ((job octocat-async--current))
       (octocat-async--finish job)
       (octocat-async--fail job 'unreadable error (octocat-async--job-entry job))
       (octocat-async--pump)))
    (_ (when (eq proc octocat-async--worker)
         (octocat-async--debug "unexpected message" message)))))

(defun octocat-async--stderr-buffer ()
  "Return the buffer of what workers printed on stderr, trimmed to its end.
It outlives each worker, so the doctor shows what a crashed one said."
  (with-current-buffer (get-buffer-create " *octocat-async stderr*")
    (when (> (buffer-size) 4000)
      (delete-region (point-min) (- (point-max) 2000)))
    (current-buffer)))

(defun octocat-async--debug (what value)
  "Note WHAT, VALUE, in the worker's stderr buffer, for the doctor."
  (with-current-buffer (octocat-async--stderr-buffer)
    (goto-char (point-max))
    (insert (format "%s: %.200S\n" what value))))


;;;; The worker

(defun octocat-async--worker-send (message)
  "Print MESSAGE to the parent, on stdout."
  (princ (octocat-async--print message)))

(defun octocat-async--worker-init (vars autoloads)
  "Set VARS, an alist, and define AUTOLOADS, a list of (FUNCTION FILE)."
  (dolist (v vars) (set-default (car v) (cdr v)))
  (dolist (a autoloads)
    (unless (fboundp (car a)) (autoload (car a) (cadr a) nil t))))

(defun octocat-async--worker-job (id feature fn args)
  "Run job ID, FN on ARGS with FEATURE loaded, and print its answer."
  (let* ((t0 (float-time))
         (answer (condition-case err
                     (progn (when feature (octocat-async--load feature))
                            (list 'ok id (apply fn args)))
                   (error (list 'error id (error-message-string err))))))
    (octocat-async--worker-send
     (append answer (list (* 1000 (- (float-time) t0)))))))

(defun octocat-async-worker-main ()
  "Run as the worker: answer the parent's messages on stdin until it closes."
  (setq octocat-async-in-worker t)
  (octocat-async--worker-send (list 'ready (emacs-pid)))
  (while t
    (let ((line (condition-case nil (read-from-minibuffer "")
                  (error (kill-emacs 0)))))
      (pcase (car (read-from-string line))
        (`(init ,vars ,autoloads) (octocat-async--worker-init vars autoloads))
        (`(job ,id ,feature ,fn ,args)
         (octocat-async--worker-job id feature fn args))
        (`(job-file ,file)
         (pcase (with-temp-buffer
                  (insert-file-contents-literally file)
                  (read (current-buffer)))
           (`(job ,id ,feature ,fn ,args)
            (octocat-async--worker-job id feature fn args))))))))

(provide 'octocat-async)
;;; octocat-async.el ends here
