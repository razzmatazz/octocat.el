;;; octocat-core-tests.el --- ERT tests for octocat-core.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-core-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-core-test-settings ()
  "Settings survive a reload of the file; nil removes one."
  (let* ((dir (make-temp-file "octocat-settings" t))
         (octocat-settings-file (expand-file-name "sub/settings.eld" dir)))
    (unwind-protect
        (progn
          (should-not (octocat--setting '(compact "o/r" "pr-list")))
          (octocat--setting-put '(compact "o/r" "pr-list") t)
          (octocat--setting-put '(compact "o/r" "issue-list") t)
          (should (octocat--setting '(compact "o/r" "pr-list")))
          (octocat--setting-put '(compact "o/r" "pr-list") nil)
          (should-not (octocat--setting '(compact "o/r" "pr-list")))
          (should (equal (octocat--settings-load) '(((compact "o/r" "issue-list") . t)))))
      (delete-directory dir t))))

(define-derived-mode octocat-core-test-page-mode special-mode "Test")

(vui-defcomponent octocat-core-test--rows (tick)
  :render
  (vui-vstack
   (format "tick %s" tick)
   (apply #'vui-vstack
          (mapcar (lambda (i) (vui-button (format "row %d" i) :key i))
                  (number-sequence 1 60)))))

(ert-deftest octocat-core-test-quit-window-returns-to-point ()
  "`q' goes back to the row point was on, though the page re-rendered hidden."
  (let ((list (generate-new-buffer "*octocat-test-list*"))
        (page (generate-new-buffer "*octocat-test-page*"))
        (vui-render-delay nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-current-buffer list (octocat-core-test-page-mode))
          (with-current-buffer page (octocat-core-test-page-mode))
          (let ((root (vui-mount (vui-component 'octocat-core-test--rows :tick 0)
                                 (buffer-name list))))
            (goto-char (point-min))
            (search-forward "row 40")
            (beginning-of-line)
            (let ((row (point)))
              (octocat-display-buffer page)
              (vui-update-props root '(:tick 1))
              (octocat-quit-window)
              (should (eq (window-buffer) list))
              (should (= (window-point) row)))))
      (kill-buffer list)
      (kill-buffer page))))

(ert-deftest octocat-core-test-format-label-colour ()
  (let* ((label (make-hash-table :test 'equal)))
    (puthash "name" "bug" label)
    (puthash "color" "d73a4a" label)
    (let* ((s (octocat--format-label label nil))
           (face (get-text-property 1 'face s)))
      (should (equal s " bug "))
      (should (equal (plist-get face :background) "#d73a4a"))
      (should (equal (plist-get face :foreground) "white")))
    (puthash "color" "fef2c0" label)
    (should (equal (plist-get (get-text-property 1 'face (octocat--format-label label nil))
                              :foreground)
                   "black"))))

(ert-deftest octocat-core-test-format-label-dark ()
  "On a dark background a label is a tint with lightened text, as on GitHub."
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "bug" label)
    (puthash "color" "d73a4a" label)
    (let ((face (octocat--label-face label "#000000")))
      ;; 18% of the colour over black.
      (should (equal (plist-get face :background) "#270a0d"))
      ;; Lightness 0.535 raised by 0.6 - 0.363.
      (should (equal (plist-get face :foreground) "#eb9fa6"))
      (should (equal (plist-get (plist-get face :box) :color) "#473032")))
    ;; Light enough already: the text keeps the label's colour.
    (puthash "color" "fef2c0" label)
    (should (equal (plist-get (octocat--label-face label "#000000") :foreground)
                   "#fef2c0"))))

(ert-deftest octocat-core-test-format-label-fallback ()
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "x" label)
    (should (eq (get-text-property 0 'face (octocat--format-label label nil))
                'octocat-branch))
    (should (equal (octocat--format-labels nil nil) ""))
    (should (equal (octocat--format-labels :null nil) ""))
    (should (equal (octocat--format-labels [] nil) ""))))

(ert-deftest octocat-core-test-search-query ()
  "The query is scoped to the repo and kind; nil means open items."
  (should (equal (octocat--search-query "o/r" 'pulls nil)
                 "( is:open ) repo:o/r type:pr"))
  (should (equal (octocat--search-query "o/r" 'issues "is:closed OR label:x")
                 "( is:closed OR label:x ) repo:o/r type:issue"))
  (should (equal (octocat--search-query "o/r" 'issues "  ")
                 "repo:o/r type:issue")))

(ert-deftest octocat-core-test-parse-list-items ()
  "Connections flatten to what the rows read; the cursor ends with the pages."
  (let* ((json "{\"data\":{\"search\":{\"nodes\":[{\"number\":5,\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},\"comments\":{\"totalCount\":3},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"state\":\"FAILURE\",\"contexts\":{\"checkRunCountsByState\":[{\"state\":\"SUCCESS\",\"count\":3},{\"state\":\"FAILURE\",\"count\":1}],\"statusContextCountsByState\":[{\"state\":\"SUCCESS\",\"count\":1}]}}}}]}},{\"number\":6,\"labels\":{\"nodes\":[]},\"comments\":{\"totalCount\":0},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"Y3I\"}}}}")
         (page  (octocat--parse-list-items json))
         (pr    (car (plist-get page :items)))
         (bare  (cadr (plist-get page :items))))
    (should (equal (plist-get page :cursor) "Y3I"))
    (should (equal (gethash "name" (aref (gethash "labels" pr) 0)) "bug"))
    (should (= (gethash "commentCount" pr) 3))
    (should (equal (gethash "ciState" pr) "FAILURE"))
    (should (equal (substring-no-properties (octocat--ci-status pr)) "✗"))
    (should (equal (substring-no-properties (octocat--ci-count-label pr)) "✗ 4/5"))
    (should-not (gethash "ciState" bare))
    (should-not (gethash "commits" bare)))
  (should-not (plist-get (octocat--parse-list-items
                          "{\"data\":{\"search\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}")
                         :cursor)))

(ert-deftest octocat-core-test-checks-ci-status ()
  "A check's outcome is its conclusion or state, in any case."
  (cl-flet ((status (&rest checks)
              (substring-no-properties
               (octocat--checks-ci-status
                (mapcar (lambda (fields)
                          (let ((h (make-hash-table :test #'equal)))
                            (while fields (puthash (pop fields) (pop fields) h))
                            h))
                        checks)))))
    (should (equal (status '("conclusion" "SUCCESS")) "✓"))
    (should (equal (status '("conclusion" "success") '("state" "SUCCESS")) "✓"))
    (should (equal (status '("conclusion" "SUCCESS") '("conclusion" "FAILURE")) "✗"))
    (should (equal (status '("conclusion" "SUCCESS") '("status" "IN_PROGRESS")) "●"))))

(ert-deftest octocat-core-test-counts-query-and-parse ()
  "Pull requests also count merged; the response parses to a plist."
  (should (string-match-p "merged:pullRequests(states:MERGED)"
                          (octocat--counts-query 'pulls)))
  (should-not (string-match-p "merged" (octocat--counts-query 'issues)))
  (should (equal (octocat--parse-counts
                  "{\"data\":{\"repository\":{\"open\":{\"totalCount\":2},\"closed\":{\"totalCount\":5}}}}")
                 '(:open 2 :closed 5))))


(ert-deftest octocat-core-test-parse-repo-summary-fork ()
  "A fork's summary carries its parent, default branch and counts."
  (should (equal (octocat--parse-repo-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"parent\":{\"nameWithOwner\":\"up/stream\"},\"issues\":{\"totalCount\":3},\"pullRequests\":{\"totalCount\":2}}}}")
                 '(:default-branch "main" :fork-parent "up/stream"
                   :open-issues 3 :open-prs 2))))

(ert-deftest octocat-core-test-parse-repo-summary-empty-repo ()
  "A non-fork with no default branch yields nils, not errors."
  (should (equal (octocat--parse-repo-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"parent\":null,\"issues\":{\"totalCount\":0},\"pullRequests\":{\"totalCount\":0}}}}")
                 '(:default-branch nil :fork-parent nil
                   :open-issues 0 :open-prs 0))))

(ert-deftest octocat-core-test-cap-width ()
  "Only a capped page keeps to `octocat-max-width'."
  (with-temp-buffer
    (let ((octocat-max-width 100))
      (should (= (octocat--cap-width 140) 140))
      (octocat--max-width-setup)
      (should (= (octocat--cap-width 140) 100))
      (should (= (octocat--cap-width 80) 80))
      (let ((octocat-max-width nil))
        (should (= (octocat--cap-width 140) 140))))))

(ert-deftest octocat-search-test-state-face ()
  "`gh search' gives lower-case states: open is green, closed is red."
  (cl-flet ((face (fn state)
              (let ((c (funcall fn (json-parse-string
                                    (format "{\"number\":1,\"title\":\"t\",\"state\":\"%s\"}"
                                            state))
                                "o/r")))
                (get-text-property (string-search "(" c) 'face c))))
    (should (eq (face #'octocat--search-make-pr-candidate "closed") 'octocat-pr-state-closed))
    (should (eq (face #'octocat--search-make-pr-candidate "open") 'octocat-pr-state-open))
    (should (eq (face #'octocat--search-make-issue-candidate "open") 'octocat-pr-state-open))
    (should (eq (face #'octocat--search-make-issue-candidate "closed") 'octocat-pr-state-closed))))

;;; github.com links

(ert-deftest octocat-core-test-github-url-target ()
  "A github.com URL maps to the octocat view showing it, or nil for none."
  (dolist (case '(("https://github.com/octocat"                    (user "octocat"))
                  ("https://github.com/octo/cat"                   (repo "octo/cat"))
                  ("http://www.github.com/octo/cat.git/"           (repo "octo/cat"))
                  ("https://github.com/octo/cat?tab=readme-ov-file" (repo "octo/cat"))
                  ("https://github.com/octo/cat/pull/12"           (pr "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12#issuecomment-1" (pr "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/files"     (pr-diff "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/commits"   (pr-commits "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/commits/abc1234"
                   (commit "octo/cat" "abc1234"))
                  ("https://github.com/octo/cat/issues/7"          (issue "octo/cat" 7))
                  ("https://github.com/octo/cat/commit/deadbeef1"  (commit "octo/cat" "deadbeef1"))
                  ("https://github.com/octo/cat/compare/abc1234..def5678"
                   (compare "octo/cat" "abc1234" ".." "def5678"))
                  ("https://github.com/octo/cat/compare/main...feature/x?expand=1"
                   (compare "octo/cat" "main" "..." "feature/x"))
                  ("https://github.com/octo/cat/compare/v1.0...octo:cat:main#diff-1"
                   (compare "octo/cat" "v1.0" "..." "octo:cat:main"))
                  ("https://github.com/octo/cat/pulls"             (pr-list "octo/cat"))
                  ("https://github.com/octo/cat/issues"            (issue-list "octo/cat"))
                  ("https://github.com/octo/cat/actions"           (actions "octo/cat"))
                  ("https://github.com/octo/cat/tree"              (tree "octo/cat"))
                  ("https://github.com/octo/cat/tree/main"         (tree "octo/cat" "main"))
                  ("https://github.com/octo/cat/tree/feat/x/src/"  (tree "octo/cat" "feat" "x" "src"))
                  ("https://github.com/octo/cat/tree/a%23b"        (tree "octo/cat" "a#b"))
                  ("https://github.com/octo/cat/commits"           (commits "octo/cat"))
                  ("https://github.com/octo/cat/commits/v1.0"      (commits "octo/cat" "v1.0"))
                  ("https://github.com/octo/cat/blob/main/x.el"    (blob "octo/cat" "main" "x.el"))
                  ("https://github.com/octo/cat/actions/runs/42"   (run "octo/cat" 42))
                  ("https://github.com/octo/cat/actions/runs/42/attempts/2" (run "octo/cat" 42))
                  ("https://github.com/octo/cat/actions/runs/42/job/99" (job "octo/cat" 42 99))
                  ("https://github.com/octo/cat/actions/workflows/ci.yml" (workflow "octo/cat" "ci.yml"))
                  ;; Another owner's repository is opened as readily.
                  ("https://github.com/torvalds/linux/commit/0123abc4567"
                   (commit "torvalds/linux" "0123abc4567"))
                  ("https://github.com/torvalds/linux/actions/runs/5" (run "torvalds/linux" 5))
                  ;; No octocat view: left to the browser.
                  ("https://github.com/octo/cat/blob/main"         nil)
                  ("https://github.com/octo/cat/wiki"              nil)
                  ("https://github.com/octo/cat/compare/feature"   nil)
                  ("https://github.com/octo/cat/compare"           nil)
                  ("https://github.com/octo/cat/pull/abc"          nil)
                  ("https://github.com/orgs/octo/teams/t"          nil)
                  ("https://github.com/settings"                   nil)
                  ("https://github.com"                            nil)
                  ("https://gitlab.com/octo/cat"                   nil)
                  ("https://example.com/github.com/octo/cat"       nil)))
    (should (equal (list (car case) (octocat--github-url-target (car case)))
                   case))))

(ert-deftest octocat-core-test-browse-url-opens-views ()
  "`octocat-browse-url' opens the view of each kind of link."
  (let (opened)
    (cl-letf (((symbol-function 'octocat-user-open)     (lambda (&rest a) (push (cons 'user a) opened)))
              ((symbol-function 'octocat-visit-repo)    (lambda (&rest a) (push (cons 'repo a) opened)))
              ((symbol-function 'octocat-pr-open)       (lambda (&rest a) (push (cons 'pr a) opened)))
              ((symbol-function 'octocat-pr-diff-open)  (lambda (&rest a) (push (cons 'pr-diff a) opened)))
              ((symbol-function 'octocat-pr-commits-open) (lambda (&rest a) (push (cons 'pr-commits a) opened)))
              ((symbol-function 'octocat--markdown-open-ref) (lambda (&rest a) (push (cons 'ref a) opened)))
              ((symbol-function 'octocat-commit-open)   (lambda (&rest a) (push (cons 'commit a) opened)))
              ((symbol-function 'octocat-compare-open)  (lambda (&rest a) (push (cons 'compare a) opened)))
              ((symbol-function 'octocat-run-open)      (lambda (&rest a) (push (cons 'run a) opened)))
              ((symbol-function 'octocat-job-open)      (lambda (&rest a) (push (cons 'job a) opened)))
              ((symbol-function 'octocat-workflow-open) (lambda (&rest a) (push (cons 'workflow a) opened)))
              ((symbol-function 'octocat-pr-list)       (lambda (&rest a) (push (cons 'pr-list a) opened)))
              ((symbol-function 'octocat-issue-list)    (lambda (&rest a) (push (cons 'issue-list a) opened)))
              ((symbol-function 'octocat-actions)       (lambda (&rest a) (push (cons 'actions a) opened)))
              ((symbol-function 'octocat-commits-open)  (lambda (&rest a) (push (cons 'commits a) opened)))
              ((symbol-function 'octocat-tree-open)     (lambda (&rest a) (push (cons 'tree a) opened)))
              ((symbol-function 'octocat-tree--open-file-by-path)
               (lambda (&rest a) (push (cons 'file a) opened)))
              ;; Of feat/x/src/a.el, GitHub has feat and feat/x.
              ((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback)
                 (funcall callback (funcall parse "{\"data\":{\"repository\":{\"p1\":{\"oid\":\"1\"},\"p2\":{\"oid\":\"2\"},\"p3\":null,\"p4\":null}}}")))))
      (dolist (path '("octocat" "o/r" "o/r/pull/1" "o/r/pull/1/files" "o/r/pull/1/commits" "o/r/issues/2"
                      "o/r/commit/abc1234" "o/r/compare/a...b" "o/r/actions/runs/3" "o/r/actions/runs/3/job/4"
                      "o/r/actions/workflows/ci.yml"
                      "o/r/pulls" "o/r/issues" "o/r/actions" "o/r/tree/main"
                      "o/r/tree" "o/r/tree/feat/x/src/a.el" "o/r/commits/main"
                      "o/r/commits/feat/x/src/a.el" "o/r/blob/feat/x/src/a.el"))
        (octocat-browse-url (concat "https://github.com/" path))))
    (should (equal (nreverse opened)
                   '((user "octocat") (repo "o/r") (pr "o/r" 1) (pr-diff "o/r" 1) (pr-commits "o/r" 1)
                     (ref issue "o/r" 2) (commit "o/r" "abc1234")
                     (compare "o/r" "a" "..." "b") (run "o/r" 3)
                     (job "o/r" 3 4 nil)
                     (workflow "o/r" "ci.yml" "ci.yml" ".github/workflows/ci.yml")
                     (pr-list "o/r") (issue-list "o/r")
                     (actions "o/r") (repo "o/r" "main") (repo "o/r" nil)
                     (tree "o/r" "feat/x" "src/a.el") (commits "o/r" "main" nil)
                     (commits "o/r" "feat/x" "src/a.el") (file "o/r" "feat/x" "src/a.el" nil))))))

(ert-deftest octocat-core-test-split-ref-path ()
  "The most leading segments naming a ref are the ref, else the first."
  (should (equal (octocat--split-ref-path '("feat" "x" "src") '(1 2)) '("feat/x" . "src")))
  (should (equal (octocat--split-ref-path '("main" "src" "a.el") nil) '("main" . "src/a.el")))
  (should (equal (octocat--split-ref-path '("feat" "x") '(2)) '("feat/x"))))

(ert-deftest octocat-core-test-browse-url-handler ()
  "`browse-url' sends the github.com links octocat can show to it.
Other links, and an explicit request for an external browser, skip it;
`octocat-open-github-urls' turns it off."
  (should (eq (browse-url-select-handler "https://github.com/o/r/pull/1")
              #'octocat-browse-url))
  (should-not (eq (browse-url-select-handler "https://github.com/o/r/wiki")
                  #'octocat-browse-url))
  (should-not (eq (browse-url-select-handler "https://github.com/o/r/pull/1" 'external)
                  #'octocat-browse-url))
  (unwind-protect
      (progn
        (customize-set-variable 'octocat-open-github-urls nil)
        (should-not (eq (browse-url-select-handler "https://github.com/o/r/pull/1")
                        #'octocat-browse-url)))
    (customize-set-variable 'octocat-open-github-urls t))
  (should (= 1 (cl-count #'octocat-browse-url browse-url-handlers :key #'cdr))))

(ert-deftest octocat-core-test-markdown-links-open-views ()
  "RET on a github.com link in markdown opens its view, in the repo it names;
#123 and commit references still open in the buffer's own repository."
  (let ((out (octocat-markdown-render
              "https://github.com/torvalds/linux/commit/0123abc4567 and #7 and abc1234" ""))
        opened)
    (cl-letf (((symbol-function 'octocat-commit-open)
               (lambda (&rest a) (push (cons 'commit a) opened)))
              ((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback) (funcall callback (funcall parse "false"))))
              ((symbol-function 'octocat-issue-open)
               (lambda (&rest a) (push (cons 'issue a) opened)))
              ((symbol-function 'octocat--search-repo--current-repo) (lambda () "me/mine"))
              ((symbol-function 'octocat--still-selected-p) #'always))
      (with-temp-buffer
        (insert out)
        (dolist (needle '("github.com" "#7" "abc1234"))
          (goto-char (1+ (string-match (regexp-quote needle) out)))
          (octocat-markdown-follow))))
    (should (equal (nreverse opened)
                   '((commit "torvalds/linux" "0123abc4567")
                     (issue "me/mine" 7)
                     (commit "me/mine" "abc1234"))))))

(ert-deftest octocat-core-test-browse-commands-go-external ()
  "\"Open in browser\" commands ask for an external browser, not octocat."
  (let (kinds)
    (cl-letf (((symbol-function 'browse-url-with-browser-kind)
               (lambda (kind url &rest _) (push (list kind url) kinds))))
      (with-temp-buffer
        (insert (propertize "row" 'octocat-dashboard-repo "o/r"))
        (goto-char (point-min))
        (octocat-dashboard-browse)))
    (should (equal kinds '((external "https://github.com/o/r"))))))

;;;; Dashboard: open pull requests and issues

(ert-deftest octocat-core-test-dashboard-items-query ()
  "The dashboard searches the user's open items of a kind, with their repo."
  (should (equal (octocat--dashboard-search-query 'pulls)
                 "is:open archived:false involves:@me sort:updated-desc type:pr"))
  (should (string-match-p "type:issue\\'" (octocat--dashboard-search-query 'issues)))
  (let ((q (octocat--dashboard-items-query 'issues)))
    (should (string-search "...on Issue{repository{nameWithOwner}}" q))
    (should (string-search (alist-get 'issues octocat--list-item-fields) q))))

(ert-deftest octocat-core-test-dashboard-items-tree ()
  "Each dashboard item keeps its repo beside its entity."
  (let* ((page (octocat--parse-list-items
                "{\"data\":{\"search\":{\"nodes\":[{\"repository\":{\"nameWithOwner\":\"O/R\"},\"number\":5,\"title\":\"T\",\"state\":\"OPEN\",\"comments\":{\"totalCount\":4}}],\"pageInfo\":{\"hasNextPage\":false}}}}"))
         (tree (octocat--dashboard-items-tree 'pulls page))
         (node (aref tree 0))
         (item (gethash "item" node)))
    (should (equal (gethash "repo" node) "O/R"))
    (should (octocat-sync--entity-p item))
    (should (equal (octocat-sync--entity-key item) "pr:o/r#5"))
    (should-not (gethash "repository" (octocat-sync--entity-fields item)))
    (should (equal (gethash "commentCount" (octocat-sync--entity-fields item)) 4))))

(ert-deftest octocat-core-test-dashboard-browse-item ()
  "C-c C-o on a dashboard PR or issue row opens that item, not its repo."
  (let (urls)
    (cl-letf (((symbol-function 'browse-url-with-browser-kind)
               (lambda (_kind url &rest _) (push url urls))))
      (with-temp-buffer
        (insert (propertize "row" 'octocat-dashboard-url "https://github.com/o/r/pull/5"
                            'octocat-dashboard-repo "o/r"))
        (goto-char (point-min))
        (octocat-dashboard-browse)))
    (should (equal urls '("https://github.com/o/r/pull/5")))))

(ert-deftest octocat-core-test-key-help ()
  "A button's hint names its command's key, and only then shows in ElDoc."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-c C-v") #'ignore)
      (use-local-map map))
    (let ((help (octocat--key-help #'ignore "do nothing")))
      (should (equal help "RET, C-c C-v: do nothing"))
      (insert (propertize "[x]" 'help-echo help) (propertize "[y]" 'help-echo "RET: y"))
      (goto-char 2)
      (should (equal (octocat--key-help-eldoc) help))
      (goto-char 5)
      (should-not (octocat--key-help-eldoc)))
    (should (equal (octocat--key-help #'octocat-core-test-key-help "go") "RET: go"))
    (should (equal (octocat--button-help "RET: do nothing" #'ignore) "RET, C-c C-v: do nothing"))
    (should (equal (octocat--button-help "RET: go" (lambda () nil)) "RET: go"))
    (local-set-key (kbd "C-c C-m") #'octocat-core-test-key-help)
    (should (equal (octocat--key-help #'octocat-core-test-key-help "go")
                   "RET, C-c C-m: go"))))

(ert-deftest octocat-core-test-run-gh-answers-every-end ()
  "A `gh' call that hangs is stopped and answered, as is one killed."
  (let* ((answers nil)
         (run (lambda (timeout)
                (let ((octocat-gh-timeout timeout))
                  ;; `sleep' stands in for a `gh' that never answers.
                  (cl-letf (((symbol-function 'executable-find) (lambda (_) "sleep")))
                    (octocat--run-gh "test" '("5") #'identity
                                     (lambda (r) (push r answers)))))))
         (wait (lambda ()
                 (let ((n 0))
                   (while (and (null answers) (< n 100))
                     (accept-process-output nil 0.05)
                     (cl-incf n))))))
    (funcall run 0.1)
    (funcall wait)
    (should (eq (car-safe (car answers)) 'error))
    (should (string-search "(timed out)" (cdar answers)))
    (should (eq (octocat-sync--error-kind (cdar answers)) 'offline))
    (setq answers nil)
    (funcall run nil)
    (kill-process (seq-find (lambda (p) (and (eq (process-type p) 'real)
                                             (string-prefix-p "octocat-gh-test" (process-name p))))
                            (process-list)))
    (funcall wait)
    (should (eq (car-safe (car answers)) 'error))))

(provide 'octocat-core-tests)
;;; octocat-core-tests.el ends here
