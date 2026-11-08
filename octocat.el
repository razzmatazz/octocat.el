;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: Saulius Menkevicius <sauliusmenkevicius@fastmail.com>
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (consult "1.0") (vui "0.1") (yaml "1.0.0"))
;; Keywords: tools, vc, github
;; URL: https://github.com/razzmatazz/octocat.el

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

;; Emacs client for GitHub, powered by the gh CLI.
;;
;; Entry points:
;;   M-x octocat      — GitHub account dashboard (your open PRs and issues,
;;                      recent repos, activity feed)
;;   M-x octocat-repo — Per-repository view (summary, Commits)
;;   M-x octocat-here — This file or directory, as GitHub has it
;;   M-x octocat-pr-list / octocat-issue-list / octocat-actions — list pages
;;   M-x octocat-run-list / octocat-workflow-list — the Actions pages

;;; Code:

(require 'octocat-core)
(require 'octocat-image)
(require 'octocat-sync)
(require 'octocat-model)
(require 'octocat-pr)
(require 'octocat-issue)
(require 'octocat-timeline)
(require 'octocat-actions)
(require 'octocat-vui)
(require 'octocat-repo)
(require 'octocat-user)
(require 'octocat-search)
(require 'octocat-dashboard)
(require 'octocat-doctor)

;; Evil integration is optional; declare its entry point to silence the
;; byte-compiler when `octocat-evil' has not been loaded yet.
(declare-function octocat-evil-setup "octocat-evil" ())
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))


;;;; Entry points
;;
;; All `;;;###autoload' commands live here, even when the mode/logic they
;; open is defined in another file (e.g. `octocat-repo' below only calls
;; into `octocat-repo.el').  This funnels every user-facing entry point
;; through this one file, guaranteeing `octocat--evil-init' (bottom of this
;; file) always runs on the very first octocat command of a session.  See
;; CONTRIBUTING.md, "Entry points", and
;; plans/repo-mode-evil-ret-binding.md for the bug this convention fixes.

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat GitHub account dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*octocat*")))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (octocat-refresh)))

;;;###autoload
(defalias 'octocat-dashboard #'octocat)

;;;###autoload
(defun octocat-pr ()
  "Open the pull request of the branch checked out in this Git clone.
That is the PR `gh pr view' finds for it: of its upstream branch, or
of the branch of the same name."
  (interactive)
  (let ((branch (or (octocat--current-branch)
                    (user-error "Octocat: No branch is checked out here"))))
    (octocat-repo--current-repo)        ; signals outside a GitHub clone
    (message "Octocat: Looking up the pull request of %s…" branch)
    (octocat--run-gh "pr-of-branch" (list "pr" "view" "--json" "url")
                     (lambda (output) (gethash "url" (json-parse-string output)))
                     (lambda (result)
                       (pcase result
                         (`(error . ,msg)
                          (if (string-match-p "no pull requests found" msg)
                              (message "Octocat: %s has no pull request" branch)
                            (message "Octocat: Could not look up the pull request: %s" msg)))
                         (url
                          (pcase (octocat--github-url-target url)
                            (`(pr ,repo ,number)
                             (message nil)
                             (octocat-pr-open repo number))
                            (_ (message "Octocat: %s has no pull request" branch)))))))))

;;;###autoload
(defun octocat-repo ()
  "Open (or switch to) the octocat-repo buffer for the current GitHub repository.
When invoked from inside a git working tree the buffer is opened in
\\='attached\\=' mode: `octocat-repo--local-dir' is set to the root of that
working tree, and the repo is derived from its \\='origin\\=' remote.
When invoked without a detectable working tree (or when the user supplies
a REPO argument in a future extension), the buffer runs in \\='detached\\='
mode with no local directory bound."
  (interactive)
  (let* ((repo     (octocat-repo--current-repo))
         (local-dir (locate-dominating-file default-directory ".git"))
         (buf-name (format "*%s*" repo))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (and local-dir
                                       (expand-file-name local-dir))
          octocat-repo--ref       nil)
    (octocat-repo-refresh)))

;;;###autoload
(defun octocat-here (&optional pick)
  "Open the file or directory of this buffer in octocat, as GitHub has it.
A file opens in the file viewer at point's line or the region's, a
directory in the tree browser, the clone's root on the repo page, a
workflow's file on its workflow page; in Dired, the entry at point.
The ref is the branch checked out, as pushed to origin; a branch never
pushed shows the default branch.  With PICK, interactively a prefix
argument, prompt for the branch instead.  A path that ref lacks shows
the nearest directory above it that it has."
  (interactive "P")
  (let* ((target (expand-file-name
                  (or (and (derived-mode-p 'dired-mode) (dired-get-filename nil t))
                      buffer-file-name
                      default-directory)))
         (dir-p  (file-directory-p target))
         (default-directory (if dir-p
                                (file-name-as-directory target)
                              (file-name-directory target)))
         (root   (expand-file-name
                  (or (locate-dominating-file target ".git")
                      (user-error "Octocat: %s is not in a Git clone" target))))
         (repo   (octocat-repo--current-repo))
         (rel    (file-relative-name target root))
         (path   (and (not (equal rel ".")) (directory-file-name rel)))
         (at     (and (equal target buffer-file-name)
                      (if (use-region-p)
                          (let ((beg (region-beginning)) (end (region-end)))
                            ;; A region ending at a line's start ends on the line above.
                            (when (and (> end beg)
                                       (save-excursion (goto-char end) (bolp)))
                              (setq end (1- end)))
                            (list 'lines (line-number-at-pos beg) (line-number-at-pos end)))
                        (let ((n (line-number-at-pos)))
                          (list 'lines n n)))))
         (ref+rev (octocat-repo--here-ref root))
         (ref+rev (if pick
                      (let* ((default (octocat-tree--file-ref repo nil))
                             (default (unless (equal default "HEAD") default))
                             (picked  (octocat--read-branch
                                       repo default (octocat-repo--tracked-branch root)
                                       (or (car ref+rev) default "HEAD"))))
                        (cons picked (concat "origin/" picked)))
                    ref+rev))
         (rev    (cdr ref+rev))
         (known  (octocat-repo--git-ok root "rev-parse" "--verify" "--quiet" rev))
         (args   (octocat-repo--here-target
                  repo (car ref+rev) path dir-p at
                  (lambda (p) (or (not known)
                                  (octocat-repo--git-ok root "cat-file" "-e"
                                                        (concat rev ":" p))))
                  (and (not pick) (car ref+rev)
                       (equal (car ref+rev) (octocat-repo--tracked-branch root)))))
         (shown  (nth 3 args))
         (notes  (delq nil
                       (list (unless (car ref+rev)
                               (format "%s isn't on GitHub; showing the default branch"
                                       (or (octocat--current-branch) "HEAD")))
                             (and path (memq (car args) '(repo tree))
                                  (not (equal shown path))
                                  (format "%s isn't there; showing %s"
                                          path (or shown "the repository")))
                             (and (eq (car args) 'file) known
                                  (not (octocat-repo--git-ok root "diff" "--quiet" rev
                                                             "--" path))
                                  "local changes; lines may differ")))))
    (apply #'octocat-open args)
    (when notes
      (message "Octocat: %s" (string-join notes "; ")))))

;;;###autoload
(defun octocat-user (login)
  "Open the page of the GitHub user or organization LOGIN, e.g. \"@octocat\".
With a nil or empty LOGIN, open the authenticated user's own page.
Interactively that is the default; with a prefix argument, prompt for
the handle instead (a leading \"@\" is optional)."
  (interactive
   (list (and current-prefix-arg
              (read-string "GitHub user or organization: "
                           (and (derived-mode-p 'octocat-user-mode)
                                octocat-user--login)))))
  (if (string-empty-p (string-trim (or login "")))
      (progn
        (message "Octocat: Looking up your GitHub login…")
        (octocat-sync-get
         '(viewer)
         (lambda (result)
           (if (eq (car-safe result) 'error)
               (message "Octocat: Could not look up your login: %s" (cdr result))
             (octocat-user-open (gethash "login" result))))))
    (octocat-user-open login)))

(defun octocat--open-list (mode name path &optional repo)
  "Open (or switch to) the list page for the current repository.
MODE is the list major mode to enable, NAME the suffix of the buffer
name, and PATH the github.com sub-path `octocat-browse' opens.
REPO, an \"owner/name\" string, overrides the repository below.
Inside an octocat repo or list buffer the page is for that buffer's
repository and local clone; elsewhere the repository is derived from
the current git working tree.  A page already open isn't refreshed."
  (let* ((repo      (cond (repo)
                          ((derived-mode-p 'octocat-repo-mode) octocat-repo--repo)
                          ((derived-mode-p 'octocat-vui-list-mode) octocat-vui-list--repo)
                          (t (octocat-repo--current-repo))))
         (local-dir (if (derived-mode-p 'octocat-repo-mode)
                        octocat-repo--local-dir
                      (octocat-repo--local-dir-for repo)))
         (buf       (get-buffer-create (format "*%s %s*" repo name))))
    (octocat-display-buffer buf)
    (when local-dir
      (setq default-directory (file-name-as-directory local-dir)))
    (if (and (derived-mode-p mode) octocat-vui--page)
        (octocat-vui-revisit-page)
      (funcall mode)
      (setq octocat-vui-list--repo repo
            octocat-vui-list--path path)
      (funcall revert-buffer-function))))

;;;###autoload
(defun octocat-pr-list (&optional repo)
  "Open the pull request list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-pr-list-mode "pr-list" "pulls" repo))

;;;###autoload
(defun octocat-issue-list (&optional repo)
  "Open the issue list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-issue-list-mode "issue-list" "issues" repo))

;;;###autoload
(defun octocat-run-list (&optional repo)
  "Open the run list of the current GitHub repository.
It lists the recent workflow runs across all workflows.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-run-list-mode "run-list" "actions" repo))

;;;###autoload
(defun octocat-workflow-list (&optional repo)
  "Open the list of workflows of the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-workflow-list-mode "workflow-list" "actions" repo))

;;;###autoload
(defun octocat-actions (&optional repo)
  "Open the Actions tab of the current GitHub repository.
That is its run list, `octocat-run-list'; see also `octocat-workflow-list'.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat-run-list repo))

;; The list pages, for code below them (see `octocat-open').

(cl-defmethod octocat-open ((_kind (eql 'pr-list)) &optional repo)
  "Open the pull request list of REPO, as `octocat-pr-list'."
  (octocat-pr-list repo))

(cl-defmethod octocat-open ((_kind (eql 'issue-list)) &optional repo)
  "Open the issue list of REPO, as `octocat-issue-list'."
  (octocat-issue-list repo))

(cl-defmethod octocat-open ((_kind (eql 'actions)) &optional repo)
  "Open the Actions tab of REPO, as `octocat-actions'."
  (octocat-actions repo))

(cl-defmethod octocat-open ((_kind (eql 'run-list)) &optional repo)
  "Open the run list of REPO, as `octocat-run-list'."
  (octocat-run-list repo))

(cl-defmethod octocat-open ((_kind (eql 'workflow-list)) &optional repo)
  "Open the workflow list of REPO, as `octocat-workflow-list'."
  (octocat-workflow-list repo))

;;;###autoload
(define-minor-mode octocat-github-links-mode
  "Open github.com links in octocat views, wherever Emacs follows them.
This covers every link `browse-url' opens: in Org, mail, other packages'
buffers.  Links octocat has no view for still go to the browser.  Links
in octocat's own pages open in it whether this mode is on or not."
  :global t
  :group 'octocat
  (setq browse-url-handlers
        (rassq-delete-all #'octocat-browse-url browse-url-handlers))
  (when octocat-github-links-mode
    (push (cons #'octocat--github-url-target #'octocat-browse-url)
          browse-url-handlers)))


;;;; Doctor

;;;###autoload
(defun octocat-doctor ()
  "Show a report on octocat's code, store, refreshes and requests to GitHub.
It is plain text, to paste into a bug report; `g' redoes it.  See
`octocat-doctor-report'."
  (interactive)
  (octocat-doctor-show))


;;;; Evil integration

(defun octocat--evil-init ()
  "Load and activate `octocat-evil' when Evil mode is enabled."
  (require 'octocat-evil)
  (octocat-evil-setup))

;; Run immediately if Evil is already active, otherwise hook into evil-mode.
(if (bound-and-true-p evil-mode)
    (octocat--evil-init)
  (add-hook 'evil-mode-hook #'octocat--evil-init))

(provide 'octocat)
;;; octocat.el ends here
