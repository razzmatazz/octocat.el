;;; octocat-vui-tests.el --- ERT tests for octocat-vui.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-vui-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-vui-tests--parts (vnode)
  "Return VNODE's text as a list: a link's as (link TEXT), else a string."
  (cond ((vui-vnode-fragment-p vnode)
         (mapcan #'octocat-vui-tests--parts (vui-vnode-fragment-children vnode)))
        ((vui-vnode-button-p vnode) (list (list 'link (vui-vnode-button-label vnode))))
        ((vui-vnode-text-p vnode) (list (vui-vnode-text-content vnode)))))

(ert-deftest octocat-vui-test-repo-heading-links-owner-and-repo ()
  "The owner and repo link to their pages; on the repo page its name is plain."
  (should (equal (octocat-vui-tests--parts (octocat-vui-repo-heading "o/r"))
                 '((link "o") "/" (link "r"))))
  (should (equal (octocat-vui-tests--parts (octocat-vui-repo-heading "o/r" nil t))
                 '((link "o") "/" "r"))))

(ert-deftest octocat-vui-test-filter-active-p ()
  "Only a query other than the default counts as an active filter."
  (should-not (octocat-vui-list-filter-active-p nil))
  (should-not (octocat-vui-list-filter-active-p " is:open "))
  (should (octocat-vui-list-filter-active-p "is:closed"))
  (should (octocat-vui-list-filter-active-p "")))

(ert-deftest octocat-vui-test-run-args ()
  "A runs query becomes gh run list options; the last of a qualifier wins."
  (should (equal (octocat-actions--run-args "") '(nil)))
  (should (equal (octocat-actions--run-args
                  "branch:main status:failure workflow:\"CI build\" actor:me branch:dev foo")
                 '(("--branch" "dev" "--status" "failure" "--workflow" "CI build"
                    "--user" "me")
                   "foo")))
  (should (equal (octocat-actions--run-args "branch:") '(nil "branch:"))))

(ert-deftest octocat-vui-test-filter-default-query-local ()
  "A list page with its own default query counts only other queries as filters."
  (with-temp-buffer
    (setq-local octocat-vui-list--default-query "")
    (should-not (octocat-vui-list-filter-active-p nil))
    (should-not (octocat-vui-list-filter-active-p " "))
    (should (octocat-vui-list-filter-active-p "is:open"))))

(ert-deftest octocat-vui-test-filter-tokenize-keeps-quotes ()
  "Quoted values stay in one token."
  (should (equal (octocat-vui-list--tokenize "is:open label:\"good first issue\" bob")
                 '("is:open" "label:\"good first issue\"" "bob"))))

(ert-deftest octocat-vui-test-filter-values-unquotes ()
  "Qualifier values are returned unquoted, negated qualifiers excluded."
  (should (equal (octocat-vui-list--values
                  "label:bug label:\"good first issue\" -label:wip" "label:")
                 '("bug" "good first issue"))))

(ert-deftest octocat-vui-test-filter-with-values ()
  "Setting a qualifier replaces its tokens and quotes values with spaces."
  (should (equal (octocat-vui-list--with-values
                  "is:open label:old -label:wip" "label:" '("a b" "c"))
                 "is:open -label:wip label:\"a b\" label:c"))
  (should (equal (octocat-vui-list--with-values "is:open author:x" "author:" nil)
                 "is:open")))

(ert-deftest octocat-vui-test-filter-state ()
  "The state token is read, replaced and removed (\"all\")."
  (should (equal (octocat-vui-list--state "label:x is:closed") "closed"))
  (should (equal (octocat-vui-list--state "label:x") "all"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "merged")
                 "is:merged label:x"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "all")
                 "label:x")))

(ert-deftest octocat-vui-test-detail-skeleton ()
  "The skeleton names the item and keeps its grey bars within WIDTH."
  (let ((text (octocat-vui-detail-skeleton "o/r" 7 30)))
    (should (string-search "o/r#7" (cadr (split-string text "\n"))))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 30)))))

(ert-deftest octocat-vui-test-detail-skeleton-tabs ()
  "TABS adds a header line and the tab strip, still within WIDTH."
  (let ((plain (split-string (octocat-vui-detail-skeleton "o/r" 7 40) "\n"))
        (tabs  (split-string (octocat-vui-detail-skeleton "o/r" 7 40 '("A" "B")) "\n")))
    (should (= (length tabs) (+ 2 (length plain))))
    (should (seq-some (lambda (l) (string-prefix-p "A  B" l)) tabs))
    (dolist (line tabs)
      (should (<= (string-width line) 40)))))

(ert-deftest octocat-vui-test-compact-list-skeleton ()
  "The compact list skeleton draws one-line rows within WIDTH."
  (let ((lines (split-string (octocat-vui-list-skeleton 30 t) "\n")))
    (should (= (length lines) 4))
    (dolist (line lines)
      (should (<= (string-width line) 30)))))

(ert-deftest octocat-vui-test-compact-list-skeleton-no-state ()
  "NO-STATE drops the state bar from the compact list skeleton."
  (let ((with    (car (split-string (octocat-vui-list-skeleton 200 t) "\n")))
        (without (car (split-string (octocat-vui-list-skeleton 200 t t) "\n"))))
    (should (= (string-width with)
               (+ (string-width without) octocat-repo-vui--state-width 2)))))

(ert-deftest octocat-vui-test-list-skeleton ()
  "The list skeleton draws two-line rows of grey bars within WIDTH."
  (let ((text (octocat-vui-list-skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (should (= (% (length (split-string text "\n")) 2) 0))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(ert-deftest octocat-vui-test-line-skeleton ()
  "The line skeleton draws one-line rows of grey bars."
  (let ((text (octocat-vui-line-skeleton)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (should (> (length (split-string text "\n")) 1))))

(ert-deftest octocat-vui-test-mode-line-loading ()
  "The mode line shows :loading while any component of the buffer loads."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (octocat-vui--add-loading buf 1)
      (octocat-vui--add-loading buf 1)
      (should (equal mode-line-process '(":loading " octocat-vui--spinner)))
      (octocat-vui--add-loading buf -1)
      (should (equal mode-line-process '(":loading " octocat-vui--spinner)))
      (octocat-vui--add-loading buf -1)
      (should (null mode-line-process)))))

(ert-deftest octocat-vui-test-mode-line-action ()
  "An action shows in the mode line ahead of :loading, which it gives back."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (octocat-vui--add-loading buf 1)
      (octocat-vui-mode-line-action buf ":saving")
      (should (equal mode-line-process '(":saving " octocat-vui--spinner)))
      (octocat-vui-mode-line-action buf nil)
      (should (equal mode-line-process '(":loading " octocat-vui--spinner))))))

(ert-deftest octocat-vui-test-page-spinner ()
  "A page spinner turns with the mode line's until the page drops it."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (octocat-vui--spinner "▝"))
      (insert "  " (octocat-vui-spinner) " Merging…")
      (should (octocat-vui--turn-page-spinners buf))
      (should (equal (get-text-property 3 'display) "▝"))
      (erase-buffer)
      (should-not (octocat-vui--turn-page-spinners buf))
      (should-not octocat-vui--page-spinner))))

(ert-deftest octocat-vui-test-header-notice ()
  "Only a failed refresh over shown data gets a notice; offline names the time."
  (let ((h (make-hash-table)))
    (should-not (octocat-vui-header-notice (list (list :data h))))
    (should-not (octocat-vui-header-notice (list (list :error "boom"))))
    (should-not (octocat-vui-header-notice (list (list :data h :error "boom" :loading t))))
    (should (equal (octocat-vui-header-notice
                    (list (list :data h) (list :data h :error "HTTP 502\nmore")))
                   "Refresh failed: HTTP 502; g to retry"))
    (should-not (octocat-vui-header-notice (list (list :data h :outdated 0.0 :loading t))))
    (should (string-prefix-p "Offline: showing data from "
                             (octocat-vui-header-notice
                              (list (list :data h :error "x" :kind 'offline :fetched-at 0.0)))))))

(ert-deftest octocat-vui-test-error-text ()
  "A failure with no data reads by its kind."
  (should (equal (octocat-vui-error-text '(:error "HTTP 404: Not Found" :kind permanent))
                 "Not found; g to retry"))
  (should (equal (octocat-vui-error-text '(:error "HTTP 403: Forbidden" :kind permanent))
                 "No access; g to retry"))
  (should (equal (octocat-vui-error-text '(:error "x" :kind offline))
                 "Offline: GitHub can't be reached; g to retry"))
  (should (equal (octocat-vui-error-text '(:error "HTTP 502\nmore" :kind transient))
                 "Error: HTTP 502; g to retry")))

(ert-deftest octocat-vui-test-prefetch-waits-for-rest ()
  "Point resting on a row prefetches its specs; moving on cancels it."
  (with-temp-buffer
    (insert (propertize "row" 'octocat-sync-prefetch '((issue "o/r" 1))) "\nplain")
    (let ((octocat-sync-prefetch t)
          (octocat-sync-prefetch-delay 10))
      (goto-char (point-min))
      (octocat-vui--prefetch-schedule)
      (let ((timer octocat-vui--prefetch-timer))
        (should (timerp timer))
        (should (equal (timer--args timer) '(((issue "o/r" 1)))))
        ;; The next command moves off the row before the timer fires.
        (goto-char (point-max))
        (octocat-vui--prefetch-schedule)
        (should-not octocat-vui--prefetch-timer)
        (should-not (memq timer timer-list))))))

(defvar octocat-vui-tests--renders 0
  "How many times `octocat-vui-tests--reader' rendered.")

(vui-defcomponent octocat-vui-tests--reader (spec tick)
  "Show the \"n\" of SPEC's data, read through `octocat-vui-use-resource'."
  :render
  (let ((data (plist-get (octocat-vui-use-resource spec tick) :data)))
    (cl-incf octocat-vui-tests--renders)
    (vui-text (format "n=%S" (and data (gethash "n" data))))))

(ert-deftest octocat-vui-test-use-resource ()
  "A page re-renders on a write to what it reads, and only then.
Opening fetches, a new tick forces a refetch, and killing the page
unsubscribes it."
  (let* ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
         (octocat-sync--loading (make-hash-table :test #'equal))
         (octocat-sync--queue nil)
         (octocat-sync--prefetches nil)
         (octocat-sync--running 0)
         (octocat-sync--resources (make-hash-table :test #'eq))
         (octocat-sync-change-functions (list #'octocat-vui--on-sync-change))
         (octocat-sync-loading-functions (list #'octocat-vui--on-sync-loading))
         (octocat-vui--subscriptions (make-hash-table :test #'equal))
         (octocat-vui-tests--renders 0)
         (vui-render-delay nil)
         (pending nil)
         (buf nil))
    (octocat-sync-define-resource thing (n)
      :fetch (lambda (done) (push (cons n done) pending)))
    (cl-flet ((answer (n)
                (let ((h (make-hash-table :test #'equal)))
                  (puthash "n" n h)
                  (funcall (cdr (assq n pending)) h)))
              (text () (with-current-buffer buf
                         (string-trim (buffer-substring-no-properties
                                       (point-min) (point-max))))))
      (unwind-protect
          (let ((root (vui-mount (vui-component 'octocat-vui-tests--reader
                                                :spec '(thing 1) :tick 1)
                                 "*octocat-vui-test*")))
            (setq buf (get-buffer "*octocat-vui-test*"))
            (should (equal (mapcar #'car pending) '(1)))
            (answer 1)
            (should (equal (text) "n=1"))
            (let ((renders octocat-vui-tests--renders))
              (octocat-sync-request '(thing 2))
              (answer 2)
              (should (= octocat-vui-tests--renders renders)))
            ;; Fresh, but a new tick is `g'.
            (vui-update-props root (list :spec '(thing 1) :tick 2))
            (should (equal (mapcar #'car pending) '(1 2 1)))
            ;; A refetch shows only in the mode line, and finding the
            ;; same data renders nothing.
            (should (buffer-local-value 'mode-line-process buf))
            (let ((renders octocat-vui-tests--renders))
              (answer 1)
              (should (= octocat-vui-tests--renders renders)))
            (should-not (buffer-local-value 'mode-line-process buf))
            (kill-buffer buf)
            (should (= (hash-table-count octocat-vui--subscriptions) 0)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest octocat-vui-test-list-stored-candidates ()
  "Stored candidates are given at once and refreshed behind; none stored waits."
  (let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
        (octocat-sync--loading (make-hash-table :test #'equal))
        (octocat-sync--queue nil)
        (octocat-sync--prefetches nil)
        (octocat-sync--prefetching nil)
        (octocat-sync--running 0)
        (octocat-sync--waiters nil)
        (fetches 0)
        deliver got)
    (cl-letf (((symbol-function 'octocat--list-people)
               (lambda (_repo callback) (cl-incf fetches) (setq deliver callback))))
      (let ((fetch (octocat-vui-list--stored 'assignees)))
        (funcall fetch "o/r" (lambda (r) (setq got r)))
        (should-not got)
        (funcall deliver '("alice" "bob"))
        (should (equal got '("alice" "bob")))
        ;; Old data: given at once, and refetched for the next prompt.
        (sqlite-execute octocat-sync--db "UPDATE resource SET fetched_at = 0")
        (setq got nil)
        (funcall fetch "o/r" (lambda (r) (setq got r)))
        (should (equal got '("alice" "bob")))
        (should (= fetches 2))))))

(ert-deftest octocat-vui-test-list-items-refetch-keeps-loaded ()
  "A list refetch asks for as many items as are stored, up to 100."
  (let ((spec '(list-items issues "o/r" nil 15)) asked)
    (dolist (stored '(0 40 130))
      (cl-letf (((symbol-function 'octocat-sync-read)
                 (lambda (_)
                   (and (> stored 0)
                        (list :data (let ((h (make-hash-table :test #'equal)))
                                      (puthash "nodes" (make-vector stored nil) h)
                                      h)))))
                ((symbol-function 'octocat--list-items)
                 (lambda (_kind _repo _cb _query _after limit) (push limit asked))))
        (funcall (plist-get (octocat-sync--props spec) :fetch) #'ignore)))
    (should (equal (nreverse asked) '(15 40 100)))))

(ert-deftest octocat-vui-test-revisit-page-fetches-unforced ()
  "Revisiting requests only this buffer's resources, without forcing."
  (let ((octocat-vui--subscriptions (make-hash-table :test #'equal))
        requests)
    (with-temp-buffer
      (puthash "(a 1)" (list (cons (current-buffer) (list 0))) octocat-vui--subscriptions)
      (puthash "(b 2)" (list (cons 'other-buffer (list 0))) octocat-vui--subscriptions)
      (cl-letf (((symbol-function 'octocat-sync-request)
                 (lambda (spec &optional force) (push (cons spec force) requests))))
        (octocat-vui-revisit-page)))
    (should (equal requests '(((a 1)))))))

(provide 'octocat-vui-tests)
;;; octocat-vui-tests.el ends here
