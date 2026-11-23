;;; octocat-doctor-tests.el --- ERT tests for octocat-doctor.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-doctor-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-doctor-test-store ()
  "The store's lines count its resources and name the largest."
  (let ((db (octocat-sync--create (sqlite-open nil)))
        (octocat-sync--queue nil)
        (octocat-sync--fetches (make-hash-table :test #'equal)))
    (octocat-sync--write db "(thing 1)" (let ((h (make-hash-table :test #'equal)))
                                          (puthash "n" 1 h)
                                          h)
                         10.0)
    (let ((text (octocat-doctor--store db "/nonexistent" 70.0)))
      (should (string-match-p "Resources   1, " text))
      (should (string-match-p "60 s ago  (thing 1)" text))
      (should (string-match-p "WAL none" text)))))

(ert-deftest octocat-doctor-test-requests ()
  "Requests are summed by reason, failures counted, the newest listed first."
  (let ((log (list (vector 990.0 nil "pr-view" nil 'page nil)
                   (vector 900.0 901.5 "checks" nil 'poll 0)
                   (vector 800.0 800.5 "checks" t 'poll 60000)
                   (vector 100.0 100.5 "user" t nil 1200000))))
    (let ((text (octocat-doctor--requests log 1000.0)))
      (should (string-match-p "Last 5 min     3 (poll 2, page 1), 1 failed" text))
      (should (string-match-p "Last hour      4 (poll 2, other 1, page 1), 1 failed" text))
      ;; The speed is over the 2 s and 2.5 s the finished requests ran.
      (should (string-match-p " 0.6 requests/min, 60 kB received in 2.0 s, 30 kB/s" text))
      (should (string-match-p " 0.1 requests/min, 1.3 MB received in 2.5 s, 504 kB/s" text))
      (should (string-match-p "Running        1" text))
      (should (string-match-p "1.5 s       0 B  poll      failed checks" text))
      (should (string-match-p "0.5 s     60 kB  poll      ok     checks" text))))
  ;; An entry logged before BYTES was added counts as none.
  (should (string-match-p "0 B received"
                          (octocat-doctor--requests
                           (list (vector 990.0 991.0 "checks" t 'poll)) 1000.0))))

(ert-deftest octocat-doctor-test-async ()
  "Background jobs are summed by kind and outcome, the worker described."
  (let* ((log (list (vector 990.0 nil 'fontify 200000 nil 1.0 nil nil)
                    (vector 950.0 950.1 'fontify 200000 'ok 8.0 70.0 nil)
                    (vector 900.0 902.0 'fontify 50000 'timeout 2.0 nil "no answer in 2.0 s")
                    (vector 900.0 900.05 'fontify 10000 'in-thread 50.0 nil nil)
                    (vector 100.0 100.3 'markdown 1000 'ok 4.0 250.0 nil)))
         (status (list :off nil :failures 1 :queued 2 :running 1
                       :worker '(:pid 42 :started 700.0 :jobs 9 :busy 812.4)
                       :attributes '((rss . 40960))
                       :stderr "Loading foo...\nOctocat: oops"))
         (text (octocat-doctor--async status log 1000.0)))
    (should (string-match-p "Worker      pid 42, up 5 min, 9 jobs done in 812 ms, RSS 42 MB" text))
    (should (string-match-p "Jobs        1 running, 2 queued; 1 failed in a row" text))
    (should (string-match-p
             "Last 5 min  fontify 4 (in-thread 1, ok 1, timeout 1), in the worker 100 ms median, 100 ms slowest; this Emacs 60 ms, worker 70 ms"
             text))
    (should (string-match-p "Last hour   markdown 1 (ok 1)" text))
    (should (string-match-p "    Octocat: oops" text))
    (should (string-match-p "fontify      50 kB   2000 ms  this Emacs    2.0 ms  worker +timeout: no answer"
                            text)))
  (let ((text (octocat-doctor--async (list :off '(400.0 . "crash: exited") :failures 3
                                           :queued 0 :running 0)
                                     nil 1000.0)))
    (should (string-match-p "Worker      off for 10 min: crash: exited; turn it back on" text))
    (should (string-match-p "Last 5 min  none" text))))

(ert-deftest octocat-doctor-test-busy ()
  "Requests running at once count once; running ones not at all."
  (should (= (octocat-doctor--busy
              (list (vector 10.0 14.0) (vector 12.0 13.0) (vector 13.0 16.0)
                    (vector 20.0 21.0) (vector 30.0 nil)))
             7.0))
  (should (= (octocat-doctor--busy nil) 0)))

(ert-deftest octocat-doctor-test-rate ()
  "The rate says why it is slowed or stopped."
  (should (equal (octocat-doctor--rate '(0 1 10 t mains) nil 300) "full rate"))
  (should (equal (octocat-doctor--rate '(0 4 10 nil battery) nil 300)
                 "4 times slower (on battery, no Emacs frame focused)"))
  (should (equal (octocat-doctor--rate '(0 nil 2000 t mains) nil 300)
                 "stopped (idle 33 min)")))

(ert-deftest octocat-doctor-test-renders ()
  "A page's renders read as their count and time."
  (should (equal (octocat-doctor--renders nil) "no render counted"))
  (should (equal (octocat-doctor--renders '(1 0.0123 0.0123))
                 "1 render, 12 ms in all, slowest 12 ms"))
  (should (equal (octocat-doctor--renders '(3 0.2 0.15))
                 "3 renders, 200 ms in all, slowest 150 ms")))

(ert-deftest octocat-doctor-test-stale-p ()
  "A compiled file older than its source is stale."
  (let* ((dir (make-temp-file "octocat-doctor" t))
         (source (expand-file-name "x.el" dir))
         (compiled (expand-file-name "x.elc" dir)))
    (unwind-protect
        (progn
          (write-region "" nil compiled)
          (write-region "" nil source)
          (set-file-times compiled (time-subtract nil 60))
          (should (octocat-doctor--stale-p compiled))
          (should-not (octocat-doctor--stale-p source)))
      (delete-directory dir t))))

(provide 'octocat-doctor-tests)
;;; octocat-doctor-tests.el ends here
