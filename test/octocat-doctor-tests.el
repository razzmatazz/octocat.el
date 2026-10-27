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
        (octocat-sync--loading (make-hash-table :test #'equal))
        (octocat-sync--quiet (make-hash-table :test #'equal)))
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
      (should (string-match-p " 0.6 requests/min, 60 kB received, 200 B/s" text))
      (should (string-match-p " 0.1 requests/min, 1.3 MB received, 350 B/s" text))
      (should (string-match-p "Running        1" text))
      (should (string-match-p "1.5 s       0 B  poll      failed checks" text))
      (should (string-match-p "0.5 s     60 kB  poll      ok     checks" text))))
  ;; An entry logged before BYTES was added counts as none.
  (should (string-match-p "0 B received"
                          (octocat-doctor--requests
                           (list (vector 990.0 991.0 "checks" t 'poll)) 1000.0))))

(ert-deftest octocat-doctor-test-rate ()
  "The rate says why it is slowed or stopped."
  (should (equal (octocat-doctor--rate '(0 1 10 t mains) nil 300) "full rate"))
  (should (equal (octocat-doctor--rate '(0 4 10 nil battery) nil 300)
                 "4 times slower (on battery, no Emacs frame focused)"))
  (should (equal (octocat-doctor--rate '(0 nil 2000 t mains) nil 300)
                 "stopped (idle 33 min)")))

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
