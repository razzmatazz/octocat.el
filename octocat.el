;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: octocat.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "3.0") (transient "0.4"))
;; Keywords: tools, vc, github
;; URL: https://github.com/octocat.el/octocat.el

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Emacs client for GitHub, powered by the gh CLI.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'json)


;;;; Options

(defcustom octocat-debug nil
  "When non-nil, dump raw gh JSON output to the *octocat-debug* buffer."
  :type 'boolean
  :group 'octocat)


;;;; Custom faces

(defface octocat-ci-success
  '((t :inherit success))
  "Face for a passing CI status."
  :group 'octocat)

(defface octocat-ci-failure
  '((t :inherit error))
  "Face for a failing CI status."
  :group 'octocat)

(defface octocat-ci-pending
  '((t :inherit warning))
  "Face for a pending CI status."
  :group 'octocat)

(defface octocat-pr-number
  '((t :inherit magit-hash))
  "Face for a PR number."
  :group 'octocat)

(defface octocat-pr-author
  '((t :inherit magit-log-author))
  "Face for a PR author."
  :group 'octocat)

(defface octocat-pr-state-open
  '((t :inherit success))
  "Face for an open PR state badge."
  :group 'octocat)

(defface octocat-pr-state-closed
  '((t :inherit error))
  "Face for a closed PR state badge."
  :group 'octocat)

(defface octocat-pr-state-merged
  '((t :inherit font-lock-builtin-face))
  "Face for a merged PR state badge."
  :group 'octocat)


;;;; Repo detection

(defun octocat--current-repo ()
  "Return the \"owner/repo\" string for the current Git repository.
Reads the \\='origin\\=' remote URL and parses both SSH and HTTPS
GitHub remote forms.  Signals an error when the working directory
is not inside a GitHub repository."
  (let ((url (string-trim
              (shell-command-to-string
               "git remote get-url origin 2>/dev/null"))))
    (when (string-empty-p url)
      (user-error "Octocat: Could not find a Git remote named `origin'"))
    (or
     ;; SSH:  git@github.com:owner/repo.git
     (and (string-match
           "git@github\\.com:\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     ;; HTTPS: https://github.com/owner/repo[.git]
     (and (string-match
           "https://github\\.com/\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     (user-error "Octocat: `%s' does not look like a GitHub remote" url))))


;;;; gh integration

;; Ensure Homebrew and common user-local paths are in `exec-path' so that
;; `executable-find' can locate `gh' even when Emacs is launched as a GUI app
;; (which does not inherit the shell's PATH).
(dolist (dir '("/opt/homebrew/bin"   ; Apple-silicon Homebrew
               "/usr/local/bin"      ; Intel Homebrew / manual installs
               "/opt/local/bin"))    ; MacPorts
  (add-to-list 'exec-path dir))

(defun octocat--ci-status (pr)
  "Return a one-character CI-status indicator for PR alist PR.
Returns \"✓\" (success), \"✗\" (failure), or \"●\" (pending/unknown)."
  (let* ((checks (gethash "statusCheckRollup" pr))
         ;; gh returns an array of check objects; derive overall conclusion.
         (conclusions
          (when (and checks (not (eq checks :null)))
            (mapcar (lambda (c) (gethash "conclusion" c)) checks)))
         (states
          (when (and checks (not (eq checks :null)))
            (mapcar (lambda (c) (gethash "state" c)) checks))))
    (cond
     ((cl-some (lambda (s) (member s '("FAILURE" "ERROR" "TIMED_OUT")))
               (append conclusions states))
      (propertize "✗" 'face 'octocat-ci-failure))
     ((cl-every (lambda (s) (equal s "SUCCESS"))
                (append conclusions states))
      (propertize "✓" 'face 'octocat-ci-success))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--debug-log (label data)
  "When `octocat-debug' is non-nil, append LABEL and DATA to *octocat-debug*."
  (when octocat-debug
    (with-current-buffer (get-buffer-create "*octocat-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] "))
      (insert label "\n")
      (insert data "\n\n"))))

(defun octocat--run-gh (name args parse-fn callback)
  "Run `gh' asynchronously with ARGS and call CALLBACK with the result.
NAME is a short identifier used for the process and temp-buffer names.
ARGS is a list of string arguments passed directly to the `gh' executable.
PARSE-FN is called with the raw output string on success; its return value
is forwarded to CALLBACK.  On failure CALLBACK receives the symbol `error'."
  (let* ((gh-executable (executable-find "gh")))
    (if (not gh-executable)
        (funcall callback 'error)
      (let* ((buf     (generate-new-buffer (format " *octocat-gh-%s*" name)))
             (err-buf (generate-new-buffer (format " *octocat-gh-%s-stderr*" name)))
             (cmd     (cons gh-executable args))
             (process-environment (cons "NO_COLOR=1" process-environment)))
        (make-process
         :name (format "octocat-gh-%s" name)
         :buffer buf
         :stderr err-buf
         :command cmd
         :sentinel
         (lambda (proc event)
           (when (string-match-p "\\(finished\\|exited\\)" event)
             (condition-case err
                 (let* ((exit-code (process-exit-status proc))
                        (output    (with-current-buffer (process-buffer proc)
                                     (buffer-string)))
                        (stderr    (with-current-buffer err-buf
                                     (buffer-string))))
                   (kill-buffer (process-buffer proc))
                   (when (buffer-live-p err-buf) (kill-buffer err-buf))
                   (octocat--debug-log
                    (format "gh %s exit-code: %d" name exit-code) output)
                   (octocat--debug-log
                    (format "gh %s stderr" name) stderr)
                   (if (= exit-code 0)
                       (funcall callback (funcall parse-fn output))
                     (funcall callback 'error)))
               (error
                (when (buffer-live-p err-buf) (kill-buffer err-buf))
                (message "Octocat sentinel error: %s" (error-message-string err))
                (funcall callback 'error))))))))))

(defun octocat--parse-prs (json-string)
  "Parse JSON-STRING returned by `gh pr list' into a list of hash-tables.
Returns a list of hash-tables, or signals `error' on failure.
An empty or null response (zero open PRs) is treated as an empty list."
  (let ((trimmed (string-trim json-string)))
    (cond
     ;; gh returns an empty string or literal "null" when there are no PRs.
     ((or (string-empty-p trimmed) (string= trimmed "null"))
      '())
     (t
      (condition-case err
          (let ((parsed (json-parse-string trimmed)))
            (cond
             ((vectorp parsed) (cl-coerce parsed 'list))
             ;; Some gh versions wrap the list in an object with a "data" key.
             ((hash-table-p parsed)
              (let ((inner (gethash "data" parsed)))
                (if (vectorp inner)
                    (cl-coerce inner 'list)
                  (error "Unexpected JSON shape from gh"))))
             (t (error "Unexpected JSON shape from gh"))))
        (json-parse-error
         (error "Failed to parse gh output: %s" (error-message-string err))))))))

(defun octocat--list-prs (repo callback)
  "Fetch open PRs for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of PR hash-tables, or the symbol `error'."
  (octocat--run-gh "prs"
                   (list "pr" "list"
                         "--repo" repo
                         "--state" "all"
                         "--json" "number,title,author,state,statusCheckRollup")
                   #'octocat--parse-prs
                   callback))

(defun octocat--list-issues (repo callback)
  "Fetch issues for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of issue hash-tables, or the symbol `error'."
  (octocat--run-gh "issues"
                   (list "issue" "list"
                         "--repo" repo
                         "--state" "all"
                         "--json" "number,title,author,state")
                   #'octocat--parse-prs
                   callback))

(defun octocat--list-workflows (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or `error'."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state")
                   #'octocat--parse-prs
                   callback))

(defun octocat--fetch-pr (repo number callback)
  "Fetch detail for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of PR data, or the symbol `error'."
  (octocat--run-gh "pr"
                   (list "pr" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,mergedAt,closedAt,"
                                          "baseRefName,headRefName,"
                                          "additions,deletions,changedFiles,"
                                          "labels,reviewDecision,latestReviews,"
                                          "comments,statusCheckRollup,url"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))

;;;; Buffer rendering

(defun octocat--render-prs (prs)
  "Insert the collapsible Pull Requests section for PRS."
  (magit-insert-section (pull-requests)
    (magit-insert-heading
      (propertize "Pull Requests" 'face 'magit-section-heading))
    (if (null prs)
        (insert "  (no pull requests)\n")
      (dolist (pr prs)
        (let* ((number (format "#%-4d" (gethash "number" pr)))
               (title  (or (gethash "title"  pr) ""))
               (author (or (gethash "login"
                                    (gethash "author" pr)) ""))
               (state  (downcase (or (gethash "state" pr) "open")))
               (state-face (cond ((equal state "merged") 'octocat-pr-state-merged)
                                 ((equal state "closed") 'octocat-pr-state-closed)
                                 (t                      'octocat-pr-state-open)))
               (ci     (octocat--ci-status pr)))
          (magit-insert-section (pr pr)
            (magit-insert-heading
              (concat
               "  "
               (propertize number 'face 'octocat-pr-number)
               "  "
               (truncate-string-to-width (format "%-40s" title) 40 nil ?\s "…")
               "  "
               (propertize (format "@%-15s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "  "
               ci
               "\n"))))))))

(defun octocat--render-issues (issues)
  "Insert the collapsible Issues section for ISSUES."
  (magit-insert-section (issues)
    (magit-insert-heading
      (propertize "Issues" 'face 'magit-section-heading))
    (if (null issues)
        (insert "  (no issues)\n")
      (dolist (issue issues)
        (let* ((number (format "#%-4d" (gethash "number" issue)))
               (title  (or (gethash "title"  issue) ""))
               (author (or (gethash "login"
                                    (gethash "author" issue)) ""))
               (state  (downcase (or (gethash "state" issue) "open")))
               (state-face (if (equal state "open")
                               'octocat-pr-state-open
                             'octocat-pr-state-closed)))
          (magit-insert-section (issue issue)
            (magit-insert-heading
              (concat
               "  "
               (propertize number 'face 'octocat-pr-number)
               "  "
               (truncate-string-to-width (format "%-40s" title) 40 nil ?\s "…")
               "  "
               (propertize (format "@%-15s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "\n"))))))))

(defun octocat--render-workflows (workflows)
  "Insert the collapsible Workflows section for WORKFLOWS."
  (magit-insert-section (workflows)
    (magit-insert-heading
      (propertize "Workflows" 'face 'magit-section-heading))
    (if (null workflows)
        (insert "  (no workflows)\n")
      (dolist (workflow workflows)
        (let* ((name  (or (gethash "name"  workflow) ""))
               (state (downcase (or (gethash "state" workflow) "")))
               (state-face (if (equal state "active")
                               'success
                             'magit-dimmed)))
          (magit-insert-section (workflow workflow)
            (magit-insert-heading
              (concat
               "  "
               (truncate-string-to-width (format "%-40s" name) 40 nil ?\s "…")
               "  "
               (propertize state 'face state-face)
               "\n"))))))))

(defun octocat--render-loading (repo)
  "Render a skeleton front view for REPO while data is still loading.
Shows the repo header and collapsed section expanders for Pull Requests,
Issues, and Workflows, each with a dimmed \\='Loading…\\=' placeholder."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (propertize repo 'face 'magit-branch-remote))
      (magit-insert-section (pull-requests)
        (magit-insert-heading
          (propertize "Pull Requests" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
      (magit-insert-section (issues)
        (magit-insert-heading
          (propertize "Issues" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
      (magit-insert-section (workflows)
        (magit-insert-heading
          (propertize "Workflows" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed))))))

(defun octocat--render (prs issues workflows repo)
  "Erase the current buffer and render PRS, ISSUES, and WORKFLOWS for REPO.
Uses the `magit-section' package for collapsible sections."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat (propertize repo 'face 'magit-branch-remote)
                (propertize (format "  %d PR(s)  %d issue(s)  %d workflow(s)"
                                    (length prs) (length issues) (length workflows))
                            'face 'magit-dimmed)))
      (octocat--render-prs prs)
      (octocat--render-issues issues)
      (octocat--render-workflows workflows))))


;;;; PR detail view

(defun octocat--pr-state-face (state)
  "Return the face for PR STATE string."
  (cond ((equal state "MERGED") 'octocat-pr-state-merged)
        ((equal state "CLOSED") 'octocat-pr-state-closed)
        (t                      'octocat-pr-state-open)))

(defun octocat--render-pr-loading (number title state)
  "Render a loading skeleton for PR NUMBER with TITLE and STATE."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-root)
      (magit-insert-heading
        (concat (propertize (or octocat--pr-repo "") 'face 'magit-branch-remote)
                "  "
                (propertize "PR" 'face 'magit-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state) 'face (octocat--pr-state-face state))))
      (magit-insert-section (pr-body)
        (magit-insert-heading (propertize "Body" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
      (magit-insert-section (pr-checks)
        (magit-insert-heading (propertize "Checks" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
      (magit-insert-section (pr-reviews)
        (magit-insert-heading (propertize "Reviews" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
      (magit-insert-section (pr-comments)
        (magit-insert-heading (propertize "Comments" 'face 'magit-section-heading))
        (insert (propertize "  Loading…\n" 'face 'magit-dimmed))))))

(defun octocat--render-pr (pr)
  "Erase the current buffer and render PR detail from hash-table PR."
  (let* ((number      (gethash "number"       pr))
         (title       (or (gethash "title"    pr) ""))
         (state       (or (gethash "state"    pr) "OPEN"))
         (author      (or (gethash "login" (gethash "author" pr)) ""))
         (body        (or (gethash "body"     pr) ""))
         (base        (or (gethash "baseRefName" pr) ""))
         (head        (or (gethash "headRefName" pr) ""))
         (created     (or (gethash "createdAt"   pr) ""))
         (merged      (gethash "mergedAt"  pr))
         (closed      (gethash "closedAt"  pr))
         (additions   (or (gethash "additions"   pr) 0))
         (deletions   (or (gethash "deletions"   pr) 0))
         (files       (or (gethash "changedFiles" pr) 0))
         (checks      (let ((v (gethash "statusCheckRollup" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (reviews     (let ((v (gethash "latestReviews" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (comments    (let ((v (gethash "comments" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--pr-repo "") 'face 'magit-branch-remote)
                "  "
                (propertize "PR" 'face 'magit-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state)
                            'face (octocat--pr-state-face state))))
      ;; ── Meta ────────────────────────────────────────────────────────────
      (magit-insert-section (pr-meta)
        (magit-insert-heading (propertize "Info" 'face 'magit-section-heading))
        (insert (format "  Author   %s\n"
                        (propertize (concat "@" author) 'face 'octocat-pr-author)))
        (insert (format "  Branch   %s → %s\n"
                        (propertize head 'face 'magit-branch-local)
                        (propertize base 'face 'magit-branch-local)))
        (insert (format "  Created  %s\n" (substring created 0 (min 10 (length created)))))
        (when (and merged (not (eq merged :null)) (not (string-empty-p merged)))
          (insert (format "  Merged   %s\n" (substring merged 0 (min 10 (length merged))))))
        (when (and closed (not (eq closed :null)) (not (string-empty-p closed))
                   (not (equal state "MERGED")))
          (insert (format "  Closed   %s\n" (substring closed 0 (min 10 (length closed))))))
        (insert (format "  Changes  %s %s across %d file(s)\n"
                        (propertize (format "+%d" additions) 'face 'diff-added)
                        (propertize (format "-%d" deletions) 'face 'diff-removed)
                        files)))
      ;; ── Body ────────────────────────────────────────────────────────────
      (magit-insert-section (pr-body)
        (magit-insert-heading (propertize "Body" 'face 'magit-section-heading))
        (if (string-empty-p (string-trim body))
            (insert (propertize "  (no description)\n" 'face 'magit-dimmed))
          (dolist (line (split-string body "\n"))
            (insert "  " line "\n"))))
      ;; ── Checks ──────────────────────────────────────────────────────────
      (magit-insert-section (pr-checks)
        (magit-insert-heading
          (propertize (format "Checks (%d)" (length checks))
                      'face 'magit-section-heading))
        (if (zerop (length checks))
            (insert (propertize "  (no checks)\n" 'face 'magit-dimmed))
          (cl-loop for check across checks do
                   (let* ((name       (or (gethash "name"         check) ""))
                          (workflow   (or (gethash "workflowName" check) ""))
                          (conclusion (or (gethash "conclusion"   check) ""))
                          (icon (cond
                                 ((member conclusion '("SUCCESS"))
                                  (propertize "✓" 'face 'octocat-ci-success))
                                 ((member conclusion '("FAILURE" "ERROR" "TIMED_OUT"))
                                  (propertize "✗" 'face 'octocat-ci-failure))
                                 (t
                                  (propertize "●" 'face 'octocat-ci-pending)))))
                     (insert (format "  %s  %-30s  %s\n"
                                     icon
                                     (truncate-string-to-width name 30 nil ?\s "…")
                                     (propertize workflow 'face 'magit-dimmed)))))))
      ;; ── Reviews ─────────────────────────────────────────────────────────
      (magit-insert-section (pr-reviews)
        (magit-insert-heading
          (propertize (format "Reviews (%d)" (length reviews))
                      'face 'magit-section-heading))
        (if (zerop (length reviews))
            (insert (propertize "  (no reviews)\n" 'face 'magit-dimmed))
          (cl-loop for review across reviews do
                   (let* ((login (or (gethash "login" (gethash "author" review)) ""))
                          (rstate (downcase (or (gethash "state" review) ""))))
                     (insert (format "  %-20s  %s\n"
                                     (propertize (concat "@" login) 'face 'octocat-pr-author)
                                     rstate))))))
      ;; ── Comments ────────────────────────────────────────────────────────
      (magit-insert-section (pr-comments)
        (magit-insert-heading
          (propertize (format "Comments (%d)" (length comments))
                      'face 'magit-section-heading))
        (if (zerop (length comments))
            (insert (propertize "  (no comments)\n" 'face 'magit-dimmed))
          (cl-loop for comment across comments do
                   (let* ((login (or (gethash "login" (gethash "author" comment)) ""))
                          (cbody (or (gethash "body" comment) ""))
                          (snippet (truncate-string-to-width
                                    (replace-regexp-in-string "\n" " " cbody)
                                    72 nil ?\s "…")))
                     (insert (format "  %-20s  %s\n"
                                     (propertize (concat "@" login) 'face 'octocat-pr-author)
                                     snippet)))))))))

;;;; Major mode

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-mode'.")
(define-key octocat-mode-map (kbd "q")     #'quit-window)
(define-key octocat-mode-map (kbd "RET")   #'octocat-visit)
(define-key octocat-mode-map (kbd "o")     #'octocat-browse)
(define-key octocat-mode-map (kbd "C-c C-o") #'octocat-browse)
(evil-define-key* 'normal octocat-mode-map
  (kbd "RET")     #'octocat-visit
  (kbd "o")       #'octocat-browse
  (kbd "C-c C-o") #'octocat-browse
  (kbd "q")       #'quit-window)

(define-derived-mode octocat-mode magit-section-mode "Octocat"
  "Major mode for browsing GitHub Pull Requests.

\\{octocat-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-refresh)
  (font-lock-mode -1)
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))


;;;; Async refresh

(defvar-local octocat--repo nil
  "The \"owner/repo\" string this buffer is tracking.")

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat buffer asynchronously.
Fetches pull requests and issues in parallel; renders once both arrive."
  (interactive)
  (unless octocat--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let ((buf (current-buffer))
        (repo octocat--repo)
        (pr-result 'pending)
        (issue-result 'pending)
        (workflow-result 'pending))
    ;; Show skeleton view immediately while fetches are in flight.
    (octocat--render-loading repo)
    ;; Render once all three fetches have completed.
    (cl-flet ((maybe-render ()
                (unless (or (eq pr-result 'pending)
                            (eq issue-result 'pending)
                            (eq workflow-result 'pending))
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (if (or (eq pr-result 'error)
                              (eq issue-result 'error)
                              (eq workflow-result 'error))
                          (progn
                            (let ((inhibit-read-only t))
                              (erase-buffer)
                              (insert (propertize
                                       "  Error: could not fetch data.\n\
  Make sure `gh' is installed and you are authenticated (`gh auth login').\n"
                                       'face 'error))))
                        (octocat--render pr-result issue-result workflow-result repo)))))))
      (octocat--list-prs repo
                         (lambda (result)
                           (setq pr-result result)
                           (maybe-render)))
      (octocat--list-issues repo
                            (lambda (result)
                              (setq issue-result result)
                              (maybe-render)))
      (octocat--list-workflows repo
                               (lambda (result)
                                 (setq workflow-result result)
                                 (maybe-render))))))


;;;; PR detail mode

(defvar octocat-pr-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-pr-mode'.")
(define-key octocat-pr-mode-map (kbd "q")     #'quit-window)
(define-key octocat-pr-mode-map (kbd "g")     #'octocat-pr-refresh)
(define-key octocat-pr-mode-map (kbd "o")     #'octocat-browse)
(define-key octocat-pr-mode-map (kbd "C-c C-o") #'octocat-browse)
(evil-define-key* 'normal octocat-pr-mode-map
  (kbd "RET")     #'octocat-visit
  (kbd "o")       #'octocat-browse
  (kbd "C-c C-o") #'octocat-browse
  (kbd "q")       #'quit-window
  (kbd "g")       #'octocat-pr-refresh)

(define-derived-mode octocat-pr-mode magit-section-mode "Octocat-PR"
  "Major mode for viewing a GitHub Pull Request.

\\{octocat-pr-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-pr-refresh)
  (font-lock-mode -1)
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))

(defvar-local octocat--pr-number nil
  "The PR number this buffer is displaying.")

(defvar-local octocat--pr-repo nil
  "The \"owner/repo\" this PR buffer belongs to.")

(defun octocat-pr-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR detail buffer asynchronously."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let ((buf  (current-buffer))
        (repo octocat--pr-repo)
        (num  octocat--pr-number))
    (octocat--fetch-pr repo num
                       (lambda (result)
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (if (eq result 'error)
                                 (let ((inhibit-read-only t))
                                   (erase-buffer)
                                   (insert (propertize
                                            "  Error: could not fetch PR data.\n"
                                            'face 'error)))
                               (octocat--render-pr result))))))))


;;;; Visitor and browser

(defun octocat-visit ()
  "Open the detail view for the item at point."
  (interactive)
  (let ((section (magit-current-section)))
    (pcase (and section (oref section type))
      ('pr
       (let* ((pr     (oref section value))
              (number (gethash "number" pr))
              (title  (or (gethash "title" pr) ""))
              (state  (or (gethash "state" pr) "OPEN"))
              (repo   octocat--repo)
              (buf-name (format "*octocat-pr: %s#%d*" repo number))
              (buf (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-pr-mode)
           (octocat-pr-mode))
         (setq octocat--pr-repo repo
               octocat--pr-number number)
         ;; Show skeleton immediately from data we already have.
         (octocat--render-pr-loading number title state)
         ;; Then fetch full detail asynchronously.
         (octocat-pr-refresh)))
      ('issue
       (message "Octocat: Issue detail view coming soon!"))
      (_ nil))))

(defun octocat-browse ()
  "Open the item at point in the browser via gh."
  (interactive)
  (let* ((section (magit-current-section))
         (type    (and section (oref section type)))
         (value   (and section (oref section value)))
         (repo    (or octocat--repo octocat--pr-repo))
         (gh      (executable-find "gh")))
    (unless gh
      (user-error "Octocat: `gh' executable not found"))
    (pcase type
      ('pr
       (let ((number (gethash "number" value)))
         (message "Octocat: Opening PR #%d in browser…" number)
         (start-process "octocat-browse" nil gh
                        "pr" "view" "--web"
                        (number-to-string number)
                        "--repo" repo)))
      ('issue
       (let ((number (gethash "number" value)))
         (message "Octocat: Opening issue #%d in browser…" number)
         (start-process "octocat-browse" nil gh
                        "issue" "view" "--web"
                        (number-to-string number)
                        "--repo" repo)))
      (_ nil))))


;;;; Entry point

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat buffer for the current GitHub repository."
  (interactive)
  (let* ((repo (octocat--current-repo))
         (buf-name (format "*octocat: %s*" repo))
         (buf (get-buffer-create buf-name)))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (setq octocat--repo repo)
    (octocat-refresh)))

(provide 'octocat)
;;; octocat.el ends here
