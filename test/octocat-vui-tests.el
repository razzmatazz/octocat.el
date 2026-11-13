;;; octocat-vui-tests.el --- ERT tests for octocat-vui.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eldev test test/octocat-vui-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-vui-tests--parts (vnode)
  "Return VNODE's text as a list: a link's as (link TEXT), else a string."
  (cond ((vui-vnode-fragment-p vnode)
         (mapcan #'octocat-vui-tests--parts (vui-vnode-fragment-children vnode)))
        ((vui-vnode-button-p vnode) (list (list 'link (vui-vnode-button-label vnode))))
        ((vui-vnode-text-p vnode) (list (vui-vnode-text-content vnode)))))

(ert-deftest octocat-vui-test-repo-heading-links-owner ()
  "The owner links to its page; the repo name is plain."
  (should (equal (octocat-vui-tests--parts (octocat-vui-repo-heading "o/r"))
                 '((link "o") "/r")))
  ;; Linked, on a page under the repo, the name opens the repo page.
  (should (equal (octocat-vui-tests--parts (octocat-vui-repo-heading "o/r" t))
                 '((link "o") "/" (link "r")))))

(ert-deftest octocat-vui-test-fit-middle-keeps-both-ends ()
  (should (equal (octocat-vui--fit-middle "CI" 24) "CI"))
  (let ((cut (octocat-vui--fit-middle "Build and publish the documentation site" 24)))
    (should (equal cut "Build and pu…tation site"))
    (should (equal (get-text-property 0 'help-echo cut)
                   "Build and publish the documentation site")))
  ;; Wide characters count by their columns.
  (should (<= (string-width (octocat-vui--fit-middle "日本語のワークフロー名前" 12)) 12)))

(ert-deftest octocat-vui-test-filter-active-p ()
  "Only a query other than the default counts as an active filter."
  (should-not (octocat-vui-list-filter-active-p nil))
  (should-not (octocat-vui-list-filter-active-p " is:open "))
  (should (octocat-vui-list-filter-active-p "is:closed"))
  (should (octocat-vui-list-filter-active-p "")))

(ert-deftest octocat-vui-test-list-page-url-query ()
  "A list's web URL carries a filter other than the default, after its scope."
  (with-temp-buffer
    (setq-local process-environment (cons "GH_HOST" process-environment))
    (setq-local octocat-vui-list--repo "acme/rocket"
                octocat-vui-list--path "pulls")
    (setq-local octocat-vui-list--query "is:closed author:@me")
    (should (equal (octocat-vui-list--page-url) "https://github.com/acme/rocket/pulls"))
    (setq-local octocat-vui-list--web-scope "is:pr")
    (should (equal (octocat-vui-list--page-url)
                   "https://github.com/acme/rocket/pulls?q=is%3Apr%20is%3Aclosed%20author%3A%40me"))
    (setq-local octocat-vui-list--query "")
    (should (equal (octocat-vui-list--page-url) "https://github.com/acme/rocket/pulls?q=is%3Apr"))
    (setq-local octocat-vui-list--query nil)
    (should (equal (octocat-vui-list--page-url) "https://github.com/acme/rocket/pulls"))))

(ert-deftest octocat-vui-test-run-args ()
  "A runs query becomes gh run list options; the last of a qualifier wins."
  (should (equal (octocat-run-list--args "") '(nil)))
  (should (equal (octocat-run-list--args
                  "branch:main status:failure workflow:\"CI build\" actor:me branch:dev foo")
                 '(("--branch" "dev" "--status" "failure" "--workflow" "CI build"
                    "--user" "me")
                   "foo")))
  (should (equal (octocat-run-list--args "branch:") '(nil "branch:"))))

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

(ert-deftest octocat-vui-test-filter-none ()
  "The none candidate stands for its token, and other values replace it."
  (should (equal (octocat-vui-list--with-values
                  "is:open assignee:x" "assignee:" (list octocat-vui-list--none)
                  "no:assignee")
                 "is:open no:assignee"))
  (should (equal (octocat-vui-list--with-values
                  "is:open no:assignee" "assignee:" '("y") "no:assignee")
                 "is:open assignee:y"))
  (should (equal (octocat-vui-list--selected
                  "is:open no:assignee" "assignee:" "no:assignee")
                 (list octocat-vui-list--none)))
  (should (equal (octocat-vui-list--selected "assignee:x" "assignee:" "no:assignee")
                 '("x"))))

(ert-deftest octocat-vui-test-filter-state ()
  "The state token is read, replaced and removed (\"all\")."
  (should (equal (octocat-vui-list--state "label:x is:closed") "closed"))
  (should (equal (octocat-vui-list--state "label:x") "all"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "merged")
                 "is:merged label:x"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "all")
                 "label:x")))

(ert-deftest octocat-vui-test-filter-reviews ()
  "A Reviews choice is read, replaces the one before, and is removed."
  (should (equal (octocat-vui-list--review "is:open reviewed-by:@me")
                 "Reviewed by you"))
  (should (equal (octocat-vui-list--review "is:open -reviewed-by:@me")
                 "Not reviewed by you"))
  (should-not (octocat-vui-list--review "is:open reviewed-by:x"))
  (should (equal (octocat-vui-list--with-review
                  "is:open review-requested:@me label:x" "Approved review")
                 "is:open label:x review:approved"))
  (should (equal (octocat-vui-list--with-review "is:open review:none" nil)
                 "is:open")))

(ert-deftest octocat-vui-test-detail-skeleton ()
  "The skeleton starts with the item and keeps its grey bars within WIDTH."
  (let ((text (octocat-vui-detail-skeleton "o/r" 7 30)))
    (should (string-prefix-p "o/r#7" text))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 30)))))

(ert-deftest octocat-vui-test-detail-skeleton-tabs ()
  "TABS adds the tab strip, still within WIDTH."
  (let ((plain (split-string (octocat-vui-detail-skeleton "o/r" 7 40) "\n"))
        (tabs  (split-string (octocat-vui-detail-skeleton "o/r" 7 40 '("A" "B")) "\n")))
    (should (= (length tabs) (1+ (length plain))))
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
               (+ (string-width without) octocat-vui--state-width 2)))))

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
      (should (equal mode-line-process '(" " octocat--spinner ":loading")))
      (octocat-vui--add-loading buf -1)
      (should (equal mode-line-process '(" " octocat--spinner ":loading")))
      (octocat-vui--add-loading buf -1)
      (should (null mode-line-process)))))

(ert-deftest octocat-vui-test-pending-mode-line ()
  "Pending writes show in every mode line, a count for several, until answered."
  (let ((global-mode-string '("" display-time-string))
        (octocat-vui--pending-mode-line nil)
        (octocat-mode-line-writes t))
    (cl-letf (((symbol-function 'octocat--spinner-start) #'ignore))
      (octocat-vui--on-sync-pending '("Merging pull request…"))
      (should (equal global-mode-string
                     '("" display-time-string octocat-vui--pending-mode-line)))
      (should (equal octocat-vui--pending-mode-line
                     '(" " octocat--spinner " " "Octocat: Merging pull request…")))
      (octocat-vui--on-sync-pending '("Merging pull request…" "Posting comment…"))
      (should (equal (car (last octocat-vui--pending-mode-line)) "Octocat: 2 changes…"))
      (should (= 1 (seq-count (lambda (x) (eq x 'octocat-vui--pending-mode-line))
                              global-mode-string)))
      (octocat-vui--on-sync-pending nil)
      (should (equal global-mode-string '("" display-time-string)))
      (should (null octocat-vui--pending-mode-line))
      (let ((octocat-mode-line-writes nil))
        (octocat-vui--on-sync-pending '("Posting comment…"))
        (should (equal global-mode-string '("" display-time-string)))))))

(ert-deftest octocat-vui-test-page-spinner ()
  "A page spinner turns with the mode line's until the page drops it."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (octocat--spinner "▝"))
      (insert "  " (octocat-spinner) " Merging…")
      (should (octocat--turn-page-spinners buf))
      (should (equal (get-text-property 3 'display) "▝"))
      (erase-buffer)
      (should-not (octocat--turn-page-spinners buf))
      (should-not octocat--page-spinner))))

(ert-deftest octocat-vui-test-page-spinner-function ()
  "Text whose spinner is a function displays what it returns for each frame."
  (with-temp-buffer
    (let ((octocat--spinner "▗"))
      (insert (propertize "[image]" 'octocat-spinner (lambda (f) (concat f " [image]"))))
      (should (octocat--turn-page-spinners (current-buffer)))
      (should (equal (get-text-property 1 'display) "▗ [image]")))))

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

(ert-deftest octocat-vui-test-pin ()
  "A pin joins its parts, leaving out nil and empty ones; crumbs as the row does."
  (should (equal (octocat-vui-pin "open" nil "" "acme/rocket#1") "open  acme/rocket#1"))
  (should (equal (octocat-vui-crumbs-pin "acme/rocket" "Actions" nil "CI")
                 "acme/rocket › Actions › CI"))
  (should (equal (octocat-vui-commit-pin "acme/rocket" "abcdef0123") "acme/rocket@abcdef0123"))
  (let ((pill (octocat-vui-segmented-pin '(("Diff" t "help" ignore) ("Patch" nil "help" ignore)))))
    (should (equal pill " Diff  Patch "))
    (should (eq (get-text-property 1 'face pill) 'octocat-segment-current))
    (should (eq (get-text-property 7 'face pill) 'octocat-segment)))
  (should-not (octocat-vui-segmented-pin nil)))

(ert-deftest octocat-vui-test-pin-line ()
  "The pinned line follows the notice, is plain text, and a click on it goes to the top."
  (let ((line (octocat-vui--pin-line
               (concat (propertize "acme/rocket" 'mouse-face 'highlight 'keymap 'x) "#1")
               "Offline" 80)))
    (should (string-prefix-p "Offline  acme/rocket#1" line))
    (should-not (get-text-property 9 'mouse-face line))
    (should-not (get-text-property 9 'keymap line))
    (should (eq (lookup-key (get-text-property 9 'local-map line) [header-line mouse-1])
                #'octocat-vui-sticky-top))
    (should (equal (get-text-property (1- (length line)) 'display line)
                   '(space :align-to 80))))
  (let* ((pill (octocat-vui-segmented-pin '(("Diff" t "help" ignore))))
         (line (octocat-vui--pin-line (octocat-vui-pin "acme/rocket@abc" pill) nil 40)))
    ;; The pill ends at the right edge, after a space aligned to it.
    (should (string-prefix-p "acme/rocket@abc" line))
    (should (memq 'octocat-segment-current
                  (ensure-list (get-text-property (string-search " Diff " line) 'face line))))
    (should (equal (get-text-property (1- (string-search " Diff " line)) 'display line)
                   '(space :align-to 34))))
  (should (string-prefix-p "acme" (octocat-vui--pin-line "acme" nil 80)))
  (should (equal (substring-no-properties (octocat-vui--pin-line "acme/rocket" nil 6))
                 "acme/… ")))

(ert-deftest octocat-vui-test-detail-pin ()
  "A detail pin cuts its title to fit, and keeps labels while half of it shows."
  (let* ((label (lambda (name) (octocat--table "name" name "color" "")))
         (item  (octocat--table "number" 7 "title" (make-string 40 ?t)
                                "labels" (octocat--table
                                          "nodes" (vector (funcall label "bug")
                                                          (funcall label "perf")))))
         (pin   (lambda (width) (substring-no-properties
                                 (octocat-vui-detail-pin item "open  " width nil)))))
    (should (equal (funcall pin 80) (concat "open  #7  " (make-string 40 ?t) "  bug perf")))
    ;; The title fits 40 columns without labels, else what is left past "open  #7  ".
    (should (equal (funcall pin 50) (concat "open  #7  " (make-string 29 ?t) "…  bug perf")))
    (should (equal (funcall pin 27) (concat "open  #7  " (make-string 8 ?t) "…  bug +1")))
    (should (equal (funcall pin 20) (concat "open  #7  " (make-string 5 ?t) "…  +2")))
    (should (equal (funcall pin 17) (concat "open  #7  " (make-string 6 ?t) "…")))
    (puthash "labels" :null item)
    (should (equal (funcall pin 80) (concat "open  #7  " (make-string 40 ?t))))))

(ert-deftest octocat-vui-test-page-pins ()
  "A page is a sticky region pinning its title, unless `octocat-sticky-title' is nil."
  (with-temp-buffer
    (let ((page (octocat-vui-page "Title" (vui-text "Title"))))
      (should (string-prefix-p "Title" (vui-vnode-region-sticky page))))
    (let ((octocat-sticky-title nil))
      (should-not (vui-vnode-region-sticky (octocat-vui-page "Title" (vui-text "Title")))))))

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
         (octocat-sync--queue nil)
         (octocat-sync--fetches (make-hash-table :test #'equal))
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

(vui-defcomponent octocat-vui-tests--counter ()
  "Counts its renders in `octocat-vui-tests--renders'."
  :render
  (progn (cl-incf octocat-vui-tests--renders)
         (vui-text "x")))

(ert-deftest octocat-vui-test-theme-change-rerenders ()
  "A theme change re-renders each page once, when `load-theme' is done."
  (let ((octocat-vui-tests--renders 0)
        (vui-render-delay nil)
        (octocat-vui--theme-timer nil)
        (buf (get-buffer-create "*octocat-vui-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (octocat-page-mode))
          (vui-mount (vui-component 'octocat-vui-tests--counter) "*octocat-vui-test*")
          (should (= octocat-vui-tests--renders 1))
          ;; `load-theme' disables the old theme, then enables the new.
          (octocat-vui--on-theme-change 'old)
          (octocat-vui--on-theme-change 'new)
          (should (= octocat-vui-tests--renders 1))
          (should (timerp octocat-vui--theme-timer))
          (timer-event-handler octocat-vui--theme-timer)
          (should (= octocat-vui-tests--renders 2))
          (should-not octocat-vui--theme-timer))
      (when (timerp octocat-vui--theme-timer)
        (cancel-timer octocat-vui--theme-timer))
      (kill-buffer buf))))

(vui-defcomponent octocat-vui-tests--form ()
  "Two fields whose RET moves on, and a button."
  :render
  (vui-vstack
   (vui-field :key 'a :value "one" :size 10
              :on-submit (lambda (_) (octocat-vui-field-next)))
   (vui-field :key 'b :value "" :size 10
              :on-submit (lambda (_) (octocat-vui-field-next)))
   (vui-button "Send" :key 'send :on-click #'ignore)))

(ert-deftest octocat-vui-test-field-next ()
  "RET in a form's field moves to the next control, past its padding."
  (let ((vui-render-delay nil)
        (left 0))
    (unwind-protect
        (progn
          (vui-mount (vui-component 'octocat-vui-tests--form) "*octocat-vui-test*")
          (with-current-buffer "*octocat-vui-test*"
            (let ((octocat-vui-field-next-hook (list (lambda () (cl-incf left)))))
              (goto-char (point-min))
              (let ((a (vui-field-at)))
                (should (= (octocat-vui-field-value-end a)
                           (+ (car (vui-element-bounds a)) 3)))
                (vui-activate)
                (should-not (eq (vui-field-at) a))
                (should (vui-field-at))
                (vui-activate)
                (should-not (vui-field-at))
                (should (looking-at-p "\\[?Send"))
                (should (= left 2))))))
      (when (get-buffer "*octocat-vui-test*")
        (kill-buffer "*octocat-vui-test*")))))

(defvar octocat-vui-tests--fail nil
  "Non-nil makes `octocat-vui-tests--failing' signal.")

(vui-defcomponent octocat-vui-tests--failing ()
  "A part that fails while `octocat-vui-tests--fail' is set."
  :render
  (if octocat-vui-tests--fail (error "Boom") (vui-text "fine")))

(vui-defcomponent octocat-vui-tests--guarded ()
  "The failing part in a boundary, with a line after it."
  :render
  (vui-vstack (octocat-vui-error-boundary (vui-component 'octocat-vui-tests--failing))
              (vui-text "after")))

(ert-deftest octocat-vui-test-error-boundary ()
  "A failing part shows as an error line until a refresh draws it again."
  (let ((vui-render-delay nil)
        (octocat-vui-tests--fail t))
    (unwind-protect
        (progn
          (vui-mount (vui-component 'octocat-vui-tests--guarded) "*octocat-vui-test*")
          (with-current-buffer "*octocat-vui-test*"
            (should (equal (buffer-string) "  Error: Boom; g to retry\nafter"))
            (setq octocat-vui-tests--fail nil)
            (vui-rerender (vui-get-instance))
            (should (string-prefix-p "  Error: Boom" (buffer-string)))
            (setq-local revert-buffer-function
                        (lambda (&rest _) (vui-rerender (vui-get-instance))))
            (octocat-vui-refresh)
            (should (equal (buffer-string) "fine\nafter"))))
      (when (get-buffer "*octocat-vui-test*")
        (kill-buffer "*octocat-vui-test*")))))

(ert-deftest octocat-vui-test-list-stored-candidates ()
  "Stored candidates are given at once and refreshed behind; none stored waits."
  (let ((octocat-sync--db (octocat-sync--create (sqlite-open nil)))
        (octocat-sync--queue nil)
        (octocat-sync--fetches (make-hash-table :test #'equal))
        (octocat-sync--waiters nil)
        (fetches 0)
        deliver got)
    (cl-letf (((symbol-function 'octocat-model--list-people)
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
                ((symbol-function 'octocat-model--list-items)
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

;;;; Page mode

(ert-deftest octocat-vui-test-pages-derive-from-page-mode ()
  "Every vui page derives from `octocat-page-mode', so none misses its setup."
  (let (modes)
    (mapatoms (lambda (sym)
                (when (and (string-prefix-p "octocat-" (symbol-name sym))
                           (get sym 'derived-mode-parent)
                           (provided-mode-derived-p sym 'vui-mode))
                  (push sym modes))))
    (should (memq 'octocat-pr-mode modes))
    (should-not (seq-remove (lambda (m) (provided-mode-derived-p m 'octocat-page-mode))
                            modes))))

(ert-deftest octocat-vui-test-page-mode-setup ()
  "A page is read-only unless it has fields, and prefetches its rows."
  (with-temp-buffer
    (octocat-user-mode)
    (should buffer-read-only)
    (should truncate-lines)
    (should (memq #'octocat-vui--prefetch-schedule post-command-hook))
    (should (memq 'octocat-markdown-details buffer-invisibility-spec)))
  (with-temp-buffer
    (octocat-pr-list-mode)
    (should-not buffer-read-only))
  (with-temp-buffer
    (octocat-pr-mode)
    (should-not truncate-lines)))

(ert-deftest octocat-vui-test-evil-page-maps ()
  "Evil's shared keys go on every page's map but the lists'."
  (require 'octocat-evil)               ; loaded only once Evil is on
  (let ((maps (octocat-evil--page-maps)))
    (dolist (map (list octocat-mode-map octocat-user-mode-map octocat-job-mode-map
                       octocat-file-mode-map octocat-tree-mode-map))
      (should (memq map maps)))
    (should-not (memq octocat-pr-list-mode-map maps))
    (should-not (memq octocat-doctor-mode-map maps))))

(ert-deftest octocat-vui-test-page-map-shared-keys ()
  "A page's map finds the shared keys through its parent's."
  (should (eq (lookup-key octocat-user-mode-map (kbd "C-c C-o")) #'octocat-browse))
  (should (eq (lookup-key octocat-file-mode-map (kbd "g")) #'octocat-vui-refresh))
  (should (eq (lookup-key octocat-pr-list-mode-map (kbd "C-c C-o")) #'octocat-browse)))

;;;; Timed refetches

(ert-deftest octocat-vui-test-poll-only-shown ()
  "Only pages on screen refetch; with none, the timer stops."
  (let* ((octocat-vui--subscriptions (make-hash-table :test #'equal))
         (octocat-vui--poll-timer nil)
         (octocat-vui--poll-shown nil)
         (shown  (generate-new-buffer " *octocat-shown*"))
         (buried (generate-new-buffer " *octocat-buried*"))
         (polled nil))
    (unwind-protect
        (cl-letf (((symbol-function 'octocat-sync-poll)
                   (lambda (specs _slowdown quiet) (push (cons quiet specs) polled))))
          (puthash "(thing 1)" (list (cons shown (list 0))) octocat-vui--subscriptions)
          (puthash "(thing 2)" (list (cons buried (list 0))) octocat-vui--subscriptions)
          (save-window-excursion
            (switch-to-buffer shown)
            (should (equal (octocat-vui--shown-pages) (list shown)))
            (should (equal (octocat-vui--page-specs (list shown)) '((thing 1))))
            ;; Newly on screen: caught up at once, and the timer runs.
            (should (equal (octocat-vui--poll-shown-changed) (list shown)))
            (should (equal (car polled) '(nil (thing 1))))
            (should (timerp octocat-vui--poll-timer))
            (let ((status (octocat-vui-refresh-status)))
              (should (equal (plist-get status :pages) (list (list shown '(thing 1)))))
              (should (= (plist-get status :hidden) 1))
              (should (= (plist-get status :tick) octocat-vui--poll-tick)))
            (switch-to-buffer buried)
            (remhash "(thing 2)" octocat-vui--subscriptions)
            (setq polled nil)
            (should-not (octocat-vui--poll-shown-changed))
            (should-not octocat-vui--poll-timer)
            ;; Stopping drops the quiet refetches still queued.
            (should (equal polled '((t))))))
      (when (timerp octocat-vui--poll-timer) (cancel-timer octocat-vui--poll-timer))
      (kill-buffer shown)
      (kill-buffer buried))))

(ert-deftest octocat-vui-test-low-battery-no-animation ()
  "On low battery an unfolding jumps to its end."
  (let ((octocat--power (cons (float-time) 'low)))
    (should (= (octocat-vui--unfold-next 0 0 100) 100)))
  (let ((octocat--power (cons (float-time) 'mains)))
    (should (< (octocat-vui--unfold-next 0 0 100) 100))))

(ert-deftest octocat-vui-test-slide-long ()
  "A column longer than `octocat-vui-slide-max-spans' shows at once."
  (let ((octocat-vui-slide-max-spans 3)
        done)
    (with-temp-buffer
      (dotimes (_ 4)
        (insert (propertize "abc" 'octocat-test t) " x\n"))
      (cl-letf (((symbol-function 'octocat-power) (lambda () 'high)))
        (octocat-vui-slide (current-buffer) 'octocat-test 'in
                           (lambda () (setq done t))))
      (should done)
      (should-not octocat-vui--slide-timer)
      (should-not (text-property-not-all (point-min) (point-max) 'display nil)))))

(ert-deftest octocat-vui-test-roll ()
  "A roll groups adjoining lines into boxes and shows each one's first lines."
  (with-temp-buffer
    (insert "a\n" (propertize "1" 'octocat-test t) "\n" (propertize "2" 'octocat-test t)
            "\nb\n" (propertize "3" 'octocat-test t) "\nc")
    (let ((boxes (octocat-vui--roll-boxes 'octocat-test)))
      (should (equal (mapcar #'length boxes) '(2 1)))
      (octocat-vui--roll-show boxes 1)
      (should (equal (apply #'string
                            (cl-loop for i from (point-min) below (point-max)
                                     unless (get-text-property i 'invisible)
                                     collect (char-after i)))
                     "a\n1\nb\n3\nc"))
      (octocat-vui--roll-show boxes nil)
      (should-not (text-property-not-all (point-min) (point-max) 'invisible nil)))))

(ert-deftest octocat-vui-test-last-run ()
  "The last run of a property whose value satisfies the predicate is found."
  (with-temp-buffer
    (insert (propertize "a" 'octocat-test 1) (propertize "bb" 'octocat-test 2)
            "-" (propertize "c" 'octocat-test 1))
    (should (equal (octocat-vui--last-run 'octocat-test (lambda (v) (eql v 1))) '(5 . 6)))
    (should (equal (octocat-vui--last-run 'octocat-test (lambda (v) (eql v 2))) '(2 . 4)))
    (should-not (octocat-vui--last-run 'octocat-test (lambda (v) (eql v 3))))))

(ert-deftest octocat-vui-test-pulse ()
  "A pulse lights up whole lines; one started stops the one running."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let ((octocat--power (cons (float-time) 'mains)))
      (octocat-vui-pulse (current-buffer) 6 7)
      (let ((first (car octocat-vui--pulse)))
        (should (equal (list (overlay-start first) (overlay-end first)) '(5 9)))
        (octocat-vui-pulse (current-buffer) 10 15)
        (should-not (overlay-buffer first)))
      (should (equal (overlay-end (car octocat-vui--pulse)) 15))
      (octocat-vui--pulse-stop)
      (should-not octocat-vui--pulse)
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest octocat-vui-test-show-lines ()
  "A window scrolls the least that shows the lines, and not when it does."
  (with-temp-buffer
    (dotimes (i 100) (insert (format "line %d\n" i)))
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (delete-other-windows)
      (let* ((win    (selected-window))
             (height (window-body-height win))
             (bol    (lambda (n) (save-excursion (goto-char (point-min))
                                                 (forward-line n) (point))))
             (top    (lambda () (1- (line-number-at-pos (window-start win))))))
        (set-window-start win (point-min))
        ;; Shown: no scroll.
        (octocat-vui--show-lines win (funcall bol 2) (funcall bol 4))
        (should (= (funcall top) 0))
        ;; Below: the last line comes to the bottom.
        (octocat-vui--show-lines win (funcall bol 50) (funcall bol 52))
        (should (= (funcall top) (- 52 height)))
        (should (= (window-point win) (funcall bol 50)))
        ;; Above: the first line comes to the top.
        (octocat-vui--show-lines win (funcall bol 10) (funcall bol 12))
        (should (= (funcall top) 10))
        ;; Taller than the window: from its first line.
        (octocat-vui--show-lines win (funcall bol 60) (funcall bol (+ 61 height)))
        (should (= (funcall top) 60))
        ;; Taller than half the window, though it fits: from its first line.
        (octocat-vui--show-lines win (funcall bol 30) (funcall bol (+ 30 (1- height))))
        (should (= (funcall top) 30))))))

(ert-deftest octocat-vui-test-blend ()
  "Colours blend; anything not a colour gives nil."
  (should (equal (octocat-vui--blend "#000000" "#ffffff" 0.5) "#7f7f7f"))
  (should (equal (octocat-vui--blend "#000000" "#ffffff" 1) "#ffffff"))
  (should-not (octocat-vui--blend "unspecified-bg" "#ffffff" 0)))

(defvar octocat-vui-tests--marks nil
  "The marks of `octocat-vui-tests--marks-buffer'.")

(defun octocat-vui-tests--marks-buffer ()
  "Insert a header, then three two-line rows, items 7, 5 and 3.
The marks are kept in a variable, as the page keeps them in its state."
  (insert "Filter  is:open\n")
  (dolist (n '(7 5 3))
    (insert (propertize (format "open    #%d\n        by @a" n) 'octocat-vui-list-item n)
            "\n"))
  (goto-char (point-min))
  (setq-local octocat-vui-tests--marks nil
              octocat-vui--page '(octocat-vui-search-list nil nil)))

(defmacro octocat-vui-tests--with-marks (&rest body)
  "Run BODY in a list of three rows, its marks in `octocat-vui-tests--marks'."
  (declare (indent 0))
  `(with-temp-buffer
     (octocat-vui-tests--marks-buffer)
     (cl-letf (((symbol-function 'octocat-vui-list-marks)
                (lambda () octocat-vui-tests--marks))
               ((symbol-function 'vui-get-instance) #'ignore)
               ((symbol-function 'vui-set-state)
                (lambda (key value _instance)
                  (should (eq key :marks))
                  (setq octocat-vui-tests--marks value)))
               ((symbol-function 'message) #'ignore))
       ,@body)))

(ert-deftest octocat-vui-test-mark-moves-to-next-item ()
  "`m' marks the item at point and moves to the next; `u' unmarks."
  (octocat-vui-tests--with-marks
    (should-error (octocat-vui-list-mark) :type 'user-error)
    (search-forward "#7")
    (octocat-vui-list-mark)
    (should (equal (octocat-vui-list-marks) '(7)))
    (should (looking-at "open    #5"))
    ;; Marking an item twice keeps one mark.
    (octocat-vui-list-mark)
    (forward-line -2)
    (octocat-vui-list-mark)
    (should (equal (octocat-vui-list-marks) '(7 5)))
    (goto-char (point-max))
    (search-backward "#3")
    (octocat-vui-list-unmark)
    (should (equal (octocat-vui-list-marks) '(7 5)))
    (search-backward "#5")
    (octocat-vui-list-unmark)
    (should (equal (octocat-vui-list-marks) '(7)))))

(ert-deftest octocat-vui-test-mark-region ()
  "With a region, `m' marks each item it touches, and point stays."
  (octocat-vui-tests--with-marks
    (transient-mark-mode 1)
    (search-forward "@a")
    (set-mark (point))
    (search-forward "#5")
    (activate-mark)
    (let ((pos (point)))
      (octocat-vui-list-mark)
      (should (equal (octocat-vui-list-marks) '(7 5)))
      (should (= (point) pos))
      (should-not (use-region-p)))))

(ert-deftest octocat-vui-test-unmark-all ()
  "`U' clears every mark."
  (octocat-vui-tests--with-marks
    (setq octocat-vui-tests--marks '(7 5))
    (octocat-vui-list-unmark-all)
    (should-not (octocat-vui-list-marks))))

(ert-deftest octocat-vui-test-with-marks ()
  "Marking adds the items not yet marked, after the others; unmarking drops them."
  (should (equal (octocat-vui-list--with-marks '(5 7) '(7 3) t) '(5 7 3)))
  (should (equal (octocat-vui-list--with-marks '(5 7) '(7 3) nil) '(5))))

(defun octocat-vui-tests--labelled (number &rest names)
  "Return an item NUMBER with labels NAMES, as a list holds it."
  (let ((item (make-hash-table :test #'equal)))
    (puthash "number" number item)
    (puthash "labels"
             (octocat--table "nodes" (vconcat (mapcar (lambda (name)
                                                        (octocat--table "name" name))
                                                      names)))
             item)
    item))

(ert-deftest octocat-vui-test-toggle-labels ()
  "A label all items have is taken off; any other is added to those without it."
  (let ((items (list (octocat-vui-tests--labelled 1 "bug" "docs")
                     (octocat-vui-tests--labelled 2 "bug"))))
    (should (equal (octocat-vui-list--value-counts items "labels" '("name"))
                   '(("bug" . 2) ("docs" . 1))))
    (should (equal (octocat-vui-list--toggle-changes items '("bug" "docs" "new") "labels" '("name"))
                   '((1 ("new") ("bug")) (2 ("docs" "new") ("bug")))))
    ;; An item with nothing to change is left out.
    (should (equal (octocat-vui-list--toggle-changes items '("docs") "labels" '("name"))
                   '((2 ("docs") nil))))
    ;; Assignees the same way, by login.
    (let ((assigned (list (octocat-vui-tests--labelled 1) (octocat-vui-tests--labelled 2))))
      (puthash "assignees" (octocat--table "nodes" (vector (octocat--table "login" "a")))
               (car assigned))
      (should (equal (octocat-vui-list--toggle-changes assigned '("a") "assignees" '("login"))
                     '((2 ("a") nil)))))))

(ert-deftest octocat-vui-test-state-changes ()
  "Marking as closed takes the open items; as open, the closed ones, never merged."
  (let ((items (mapcar (pcase-lambda (`(,number ,state))
                         (let ((item (octocat-vui-tests--labelled number)))
                           (puthash "state" state item)
                           item))
                       '((1 "OPEN") (2 "closed") (3 "MERGED") (4 "open")))))
    (should (equal (octocat-vui-list--state-changes items "close") '(1 4)))
    (should (equal (octocat-vui-list--state-changes items "reopen") '(2)))))

(ert-deftest octocat-vui-test-mark-without-page ()
  "Marking where no list page has mounted says so."
  (with-temp-buffer
    (insert (propertize "open    #7" 'octocat-vui-list-item 7))
    (goto-char (point-min))
    (should-error (octocat-vui-list-mark) :type 'user-error)))

(ert-deftest octocat-vui-test-lanes ()
  "A line runs down from a row to each of its targets, joining on its row."
  (should (equal (octocat-vui-lanes '(a b c d e) '((a b) (a c) (c d) (b e) (d e)))
                 '((" ─╮" . 0) ("  │" . 0) ("│  " . 1) ("│  " . 1) (" ─╯" . 0))))
  ;; A merge's first parent keeps its column; the branch rejoins below.
  (should (equal (octocat-vui-lanes '(h m f p b) '((h m) (m p) (m f) (f b) (p b)))
                 '(("   " . 0) (" ─╮" . 0) ("│  " . 1) ("  │" . 0) (" ─╯" . 0))))
  ;; A target not loaded yet runs off the bottom; one above is left out.
  (should (equal (octocat-vui-lanes '(x y) '((x z) (y x) (x y)))
                 '((" ─╮" . 0) ("│  " . 1))))
  ;; A line running on across a row's join hops it.
  (should (equal (octocat-vui-lanes '(a b e c) '((a e) (a c) (b e)))
                 '((" ─╮  " . 0) ("│ │  " . 2) (" ╴│╶╯" . 0) ("     " . 1))))
  (should (equal (car (octocat-vui-lane-mirror '(" ╴│╶╯" . 0))) "╰╴│╶ "))
  (should (equal (mapcar #'octocat-vui-lane-mirror '(("   " . 0) (" ─╮" . 0) ("│  " . 1)))
                 '(("   " . 1) ("╭─ " . 1) ("  │" . 0))))
  (should-not (octocat-vui-lanes (cons 'root (number-sequence 1 9))
                                 (mapcar (lambda (n) (list 'root n)) (number-sequence 1 9)))))

(ert-deftest octocat-vui-test-stage-lanes ()
  "A node sits in its stage's column; lines into a column join."
  (should (equal (octocat-vui-stage-lanes '(l s b d) '((l s) (l b) (s d) (b d)))
                 '((" ─╮  " . 0) ("   ─╮" . 1) ("   ─┤" . 1) ("     " . 2))))
  ;; A line running on down a column hops a row's line across it.
  (should (equal (octocat-vui-stage-lanes '(a x b c) '((a b) (x c) (b c)))
                 '((" ─╮  " . 0) (" ╴│╶╮" . 0) ("   ─┤" . 1) ("     " . 2))))
  ;; A target above is left out.
  (should (equal (octocat-vui-stage-lanes '(x y) '((y x))) '((" " . 0) (" " . 0))))
  (should-not (octocat-vui-stage-lanes (number-sequence 0 8)
                                       (mapcar (lambda (n) (list n (1+ n)))
                                               (number-sequence 0 7)))))

(defun octocat-vui-tests--open-settled (stored moved-on answer)
  "Open a page settled by a resource holding STORED, answered with ANSWER.
MOVED-ON switches to another buffer before the answer.  Return the
pages opened, oldest first, and whether the guess's buffer is live."
  (let (opened guess answered)
    (save-window-excursion
      (cl-letf (((symbol-function 'octocat-sync-read) (lambda (_) (list :data stored)))
                ((symbol-function 'octocat-sync-get) (lambda (_ k) (setq answered k)))
                ((symbol-function 'octocat-open)
                 (lambda (&rest args)
                   (push args opened)
                   (switch-to-buffer (generate-new-buffer "*octocat-test-page*")))))
        (octocat-vui-open-settled '(spec) (lambda (data) (list (or data 'guess))))
        (setq guess (window-buffer))
        (when answered
          (when moved-on (switch-to-buffer (generate-new-buffer "*octocat-test-other*")))
          (funcall answered answer))))
    (list (nreverse opened) (buffer-live-p guess))))

(ert-deftest octocat-vui-test-open-settled ()
  "A page opens at once; a guess gives way to what the data settles."
  ;; Stored: no guess.
  (should (equal (octocat-vui-tests--open-settled 'known nil nil) '(((known)) t)))
  ;; A wrong guess is replaced, and killed.
  (should (equal (octocat-vui-tests--open-settled nil nil 'right) '(((guess) (right)) nil)))
  ;; A right guess, or a failed fetch, stays.
  (should (equal (octocat-vui-tests--open-settled nil nil 'guess) '(((guess)) t)))
  (should (equal (octocat-vui-tests--open-settled nil nil '(error . "x")) '(((guess)) t)))
  ;; The user moved on: nothing more opens.
  (should (equal (octocat-vui-tests--open-settled nil t 'right) '(((guess)) t))))

(provide 'octocat-vui-tests)
;;; octocat-vui-tests.el ends here
