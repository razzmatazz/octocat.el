;;; octocat-async-tests.el --- ERT tests for octocat-async.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-async-tests.el
;;
;; Each test starts a real worker; `octocat-async-jobs-run' makes it
;; fail in each way the parent must survive.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(defconst octocat-async-tests--jobs
  (expand-file-name "octocat-async-jobs.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The file defining the tests' jobs.")

(defmacro octocat-async-tests--fresh (&rest body)
  "Run BODY with the worker's state fresh, every job sent to the worker,
and the worker stopped after."
  (declare (indent 0))
  `(let ((octocat-async--deadline 2.0)
         (octocat-async--startup-time 10.0)
         (octocat-async--off nil)
         (octocat-async--failures 0)
         (octocat-async--worker nil)
         (octocat-async--worker-info nil)
         (octocat-async--queue nil)
         (octocat-async--current nil)
         (octocat-async--idle-timer nil)
         (octocat-async--log nil))
     (unwind-protect (progn ,@body)
       (when octocat-async--idle-timer (cancel-timer octocat-async--idle-timer))
       (octocat-async--stop))))

(defun octocat-async-tests--wait (pred &optional seconds)
  "Wait until PRED returns non-nil, at most SECONDS (10); return its value."
  (let ((end (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.01))
    (funcall pred)))

(defun octocat-async-tests--run (what &optional value size)
  "Run job WHAT with VALUE on SIZE bytes, wait for it; return the callback's value."
  (let (got)
    (octocat-async-call 'test octocat-async-tests--jobs
                        'octocat-async-jobs-run (list what value)
                        (lambda (v) (setq got (list v)))
                        :size (or size 1))
    (car (octocat-async-tests--wait (lambda () got)))))

(defun octocat-async-tests--outcomes ()
  "The outcomes of the jobs logged, oldest first."
  (mapcar (lambda (e) (aref e 4)) (reverse octocat-async--log)))

(ert-deftest octocat-async-test-small-runs-here ()
  "A job its caller says to run here runs here, before the call returns."
  (octocat-async-tests--fresh
    (let (got)
      (should-not (octocat-async-call 'test octocat-async-tests--jobs
                                      'octocat-async-jobs-run '(echo 1)
                                      (lambda (v) (setq got v))
                                      :here t))
      (should (equal got '(here . 1)))
      (should-not octocat-async--worker)
      (should (equal (octocat-async-tests--outcomes) '(in-thread))))))

(ert-deftest octocat-async-test-round-trip ()
  "The worker runs a job; text with newlines, non-ASCII and faces survives."
  (octocat-async-tests--fresh
    (let ((text (concat (propertize "défini\n" 'face 'bold) "─│\t\"x\"\\ \0")))
      (let ((got (octocat-async-tests--run 'echo text)))
        (should (eq (car got) 'worker))
        (should (equal-including-properties (cdr got) text)))
      (should (equal (octocat-async-tests--outcomes) '(ok)))
      (should (numberp (aref (car octocat-async--log) 6))))))

(ert-deftest octocat-async-test-long-job-through-file ()
  "A job longer than the pipe's limit goes through a file, deleted after."
  (octocat-async-tests--fresh
    (let* ((text (make-string 50000 ?é))
           got
           (job (octocat-async-call 'test octocat-async-tests--jobs
                                    'octocat-async-jobs-run (list 'echo text)
                                    (lambda (v) (setq got v)))))
      (octocat-async-tests--wait (lambda () got))
      (should (equal got (cons 'worker text)))
      (should (octocat-async--job-file job))
      (should-not (file-exists-p (octocat-async--job-file job))))))

(ert-deftest octocat-async-test-jobs-run-in-order ()
  "Jobs queue for the one worker and each gets its own answer."
  (octocat-async-tests--fresh
    (let (got)
      (dotimes (i 5)
        (octocat-async-call 'test octocat-async-tests--jobs
                            'octocat-async-jobs-run (list 'echo i)
                            (lambda (v) (push v got))))
      (octocat-async-tests--wait (lambda () (= (length got) 5)))
      (should (equal (reverse got) (mapcar (lambda (i) (cons 'worker i)) '(0 1 2 3 4))))
      (should (= (plist-get octocat-async--worker-info :jobs) 5)))))

(ert-deftest octocat-async-test-error-falls-back ()
  "A job signalling in the worker runs here instead."
  (octocat-async-tests--fresh
    (should (equal (octocat-async-tests--run 'error 7) '(here . 7)))
    (should (equal (octocat-async-tests--outcomes) '(error in-thread)))
    (should (string-match-p "on purpose" (aref (cadr octocat-async--log) 7)))
    (should (= octocat-async--failures 1))
    ;; The worker survives a job's error.
    (should (process-live-p octocat-async--worker))))

(ert-deftest octocat-async-test-timeout-kills-worker ()
  "A job past its deadline kills the worker, runs here, and the next
job gets a new worker."
  (octocat-async-tests--fresh
    (should (equal (octocat-async-tests--run 'echo 1) '(worker . 1)))
    (let ((pid (process-id octocat-async--worker)) got)
      (octocat-async-call 'test octocat-async-tests--jobs 'octocat-async-jobs-run '(sleep 2)
                          (lambda (v) (setq got v))
                          :deadline 0.3)
      (should (equal (octocat-async-tests--wait (lambda () got)) '(here . 2)))
      (should (equal (octocat-async-tests--outcomes) '(ok timeout in-thread)))
      (should (equal (octocat-async-tests--run 'echo 3) '(worker . 3)))
      (should-not (= pid (process-id octocat-async--worker))))))

(ert-deftest octocat-async-test-crash-falls-back ()
  "A worker exiting mid-job fails the job, which runs here."
  (octocat-async-tests--fresh
    (should (equal (octocat-async-tests--run 'crash 1) '(here . 1)))
    (should (equal (octocat-async-tests--outcomes) '(crash in-thread)))
    (should (string-match-p "status 3" (aref (cadr octocat-async--log) 7)))
    (should (equal (octocat-async-tests--run 'echo 2) '(worker . 2)))))

(ert-deftest octocat-async-test-unreadable-falls-back ()
  "A result that cannot be read back fails the job, which runs here."
  (octocat-async-tests--fresh
    (should (equal (octocat-async-tests--run 'unreadable 1) '(here . 1)))
    (should (equal (car (octocat-async-tests--outcomes)) 'unreadable))))

(ert-deftest octocat-async-test-noise-and-stderr ()
  "A job printing to stdout or stderr doesn't confuse the parent."
  (octocat-async-tests--fresh
    (should (equal (octocat-async-tests--run 'noise 1) '(worker . 1)))
    (should (equal (octocat-async-tests--run 'message 2) '(worker . 2)))
    (should (equal (octocat-async-tests--outcomes) '(ok ok)))
    (should (string-match-p "unexpected message: noise"
                            (plist-get (octocat-async-status) :stderr)))
    (should (octocat-async-tests--wait
             (lambda () (string-match-p "to stderr" (plist-get (octocat-async-status) :stderr)))))
    ;; What it printed outlives it, without a note of its end.
    (octocat-async--stop)
    (octocat-async-tests--wait (lambda () nil) 0.2)
    (let ((stderr (plist-get (octocat-async-status) :stderr)))
      (should (string-match-p "to stderr" stderr))
      (should-not (string-match-p "finished" stderr)))))

(ert-deftest octocat-async-test-no-start-falls-back ()
  "A worker that cannot start fails the job, which runs here."
  (octocat-async-tests--fresh
    (let ((invocation-name "no-such-emacs"))
      (should (equal (octocat-async-tests--run 'echo 1) '(here . 1))))
    (should (equal (octocat-async-tests--outcomes) '(no-start in-thread)))))

(ert-deftest octocat-async-test-failures-turn-off ()
  "Failures in a row turn the worker off; jobs then run here at once."
  (octocat-async-tests--fresh
    (dotimes (_ octocat-async--max-failures)
      (octocat-async-tests--run 'error))
    (should octocat-async--off)
    (should (string-match-p "error" (cdr octocat-async--off)))
    (should-not octocat-async--worker)
    (let (got)
      (octocat-async-call 'test octocat-async-tests--jobs 'octocat-async-jobs-run '(echo 1)
                          (lambda (v) (setq got v)))
      (should (equal got '(here . 1))))
    (octocat-async-turn-on)
    (should (equal (octocat-async-tests--run 'echo 2) '(worker . 2)))))

(ert-deftest octocat-async-test-success-resets-failures ()
  "A success between failures keeps the worker on."
  (octocat-async-tests--fresh
    (dotimes (_ (* 2 octocat-async--max-failures))
      (octocat-async-tests--run 'error)
      (octocat-async-tests--run 'echo))
    (should-not octocat-async--off)
    (should (= octocat-async--failures 0))))

(ert-deftest octocat-async-test-cancel ()
  "A cancelled job's callback never runs, queued or running."
  (octocat-async-tests--fresh
    (let (got)
      (let ((running (octocat-async-call 'test octocat-async-tests--jobs
                                         'octocat-async-jobs-run '(echo 1)
                                         (lambda (v) (push v got))))
            (queued (octocat-async-call 'test octocat-async-tests--jobs
                                        'octocat-async-jobs-run '(echo 2)
                                        (lambda (v) (push v got)))))
        (octocat-async-cancel running)
        (octocat-async-cancel queued)
        (should (equal (octocat-async-tests--run 'echo 3) '(worker . 3)))
        (should-not got)
        (should (equal (sort (mapcar #'symbol-name (octocat-async-tests--outcomes)) #'string<)
                       '("dropped" "dropped" "ok")))))))

(ert-deftest octocat-async-test-cancel-during-fallback ()
  "A job cancelled before its fallback runs here never calls back."
  (octocat-async-tests--fresh
    (let* (got
           (job (octocat-async--job-create
                 :id 1 :kind 'test :size 1 :feature octocat-async-tests--jobs
                 :fn 'octocat-async-jobs-run :args '(echo 1)
                 :callback (lambda (v) (push v got)))))
      (octocat-async--fall-back job)
      (octocat-async-cancel job)
      (octocat-async-tests--wait (lambda () nil) 0.2)
      (should-not got))))

(ert-deftest octocat-async-test-stale-code-restarts ()
  "A worker whose code changed on disk is replaced before the next job."
  (octocat-async-tests--fresh
    (octocat-async-tests--run 'echo)
    (let ((pid (process-id octocat-async--worker)))
      (setf (cdr (car (plist-get octocat-async--worker-info :files))) '(0 0 0 0))
      (should (equal (octocat-async-tests--run 'echo 1) '(worker . 1)))
      (should-not (= pid (process-id octocat-async--worker))))))

(ert-deftest octocat-async-test-idle-stops ()
  "The worker stops after `octocat-async--idle-time' without a job."
  (octocat-async-tests--fresh
    (let ((octocat-async--idle-time 0.2))
      (octocat-async-tests--run 'echo)
      (should octocat-async--worker)
      (should (octocat-async-tests--wait (lambda () (null octocat-async--worker)) 3))
      ;; Stopping it is not a failure: the next job starts a new one.
      (should (equal (octocat-async-tests--run 'echo 1) '(worker . 1)))
      (should (= octocat-async--failures 0)))))

(ert-deftest octocat-async-test-status ()
  "The status names the worker's pid and process attributes."
  (octocat-async-tests--fresh
    (octocat-async-tests--run 'echo)
    (let ((status (octocat-async-status)))
      (should (integerp (plist-get (plist-get status :worker) :pid)))
      (should (assq 'rss (plist-get status :attributes)))
      (should (= (plist-get status :failures) 0)))))

(ert-deftest octocat-async-test-init-message-readable ()
  "The worker's first message prints readably, mode autoloads included."
  (let ((auto-mode-alist (list (cons "\\.foo\\'" 'octocat-async-tests--foo-mode)
                               (cons "\\.bar\\'" (lambda () nil)))))
    (cl-letf (((symbol-function 'octocat-async-tests--foo-mode)
               (list 'autoload "foo-mode" nil t nil)))
      (let ((m (octocat-async--init-message)))
        (should (equal (octocat-async--readable m) m))
        (should (member '(octocat-async-tests--foo-mode "foo-mode") (nth 2 m)))))))

(provide 'octocat-async-tests)
;;; octocat-async-tests.el ends here
