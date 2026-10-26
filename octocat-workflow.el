;;; octocat-workflow.el --- Workflow detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6
;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5

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

;; A workflow and its runs: `octocat-workflow-mode', a vui.el page
;; opened from the workflow list, a run or `C-c C-j'.  Its runs are the
;; run list's section (octocat-run.el).  Also the workflow list,
;; `octocat-workflow-list-mode', the second page of the Actions tab.
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-run)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list



;;;; Buffer-local declarations

(defvar-local octocat--workflow-repo nil
  "The \"owner/repo\" this workflow buffer belongs to.")

(defvar-local octocat--workflow-id nil
  "The workflow ID, or its file name, this buffer is displaying.")

(defvar-local octocat--workflow-name nil
  "The display name of the workflow this buffer is displaying.")

(defvar-local octocat--workflow-path nil
  "The workflow file, e.g. \".github/workflows/ci.yml\", or nil.")


;;;; Data fetching

(defun octocat--fetch-workflow (repo id callback)
  "Fetch workflow ID of REPO asynchronously.
Calls CALLBACK with a hash-table of it, or a cons \\=(error . MSG)."
  (octocat--run-gh
   "workflow-detail"
   (list "api" (format "repos/%s/actions/workflows/%s" repo id))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))


;;;; Rendering helpers

(defun octocat--workflow-state-face (state)
  "Return the face for workflow STATE string."
  (if (equal state "active") 'success 'octocat-dimmed))

(defun octocat-workflow--url (repo id path)
  "Return the github.com page of workflow ID of REPO.
GitHub names it by its file, the last part of PATH, when known."
  (format "https://github.com/%s/actions/workflows/%s" repo
          (if (octocat--nonempty path) (file-name-nondirectory path) id)))


;;;; Page

(defun octocat-workflow--crumbs (name path)
  "Return the crumb of workflow NAME, with its file PATH when known.
See `octocat-vui-actions-header'."
  (list (list (concat name
                      (and (octocat--nonempty path)
                           (concat "  " (propertize path 'face 'octocat-branch)))))))

(defun octocat-workflow--header (repo workflow width)
  "Return the header vnodes of WORKFLOW of REPO, kept within WIDTH.
The top row names it and its file; under it its state and dates."
  (let ((state   (or (octocat--nonempty (downcase (or (gethash "state" workflow) "")))
                     "unknown"))
        (created (octocat--nonempty (gethash "created_at" workflow)))
        (updated (octocat--nonempty (gethash "updated_at" workflow))))
    (octocat-vui-actions-header
     repo
     (octocat-workflow--crumbs (or (gethash "name" workflow) "")
                               (gethash "path" workflow))
     width
     (propertize state 'face (octocat--workflow-state-face state))
     (list (list (cons "Created" (and created (octocat--format-ts-relative created)))
                 (cons "Updated" (and updated (octocat--format-ts-relative updated))))))))


(octocat-sync-define-resource workflow (repo id)
  :fetch (lambda (done) (octocat--fetch-workflow repo id done)))

(vui-defcomponent octocat-workflow--page (repo id name path tick)
  "Workflow ID of REPO and its runs, as the run list shows them.
NAME and PATH, its file or nil, show while it loads.  A new TICK
fetches them again."
  :render
  (let* ((width (octocat-vui-window-width))
         (local-branch (vui-use-memo () (octocat--current-branch)))
         (snap  (octocat-vui-use-resource (list 'workflow repo id) tick))
         (data  (plist-get snap :data)))
    (apply #'vui-vstack
           (append
            (if data
                (octocat-workflow--header repo data width)
              (octocat-vui-actions-header repo (octocat-workflow--crumbs name path) width))
            (list
             (vui-newline)
             (if (eq (octocat-vui-snapshot-status snap) 'error)
                 (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error)
               (vui-component 'octocat-run-list--runs
                              :repo repo
                              :current-branch local-branch
                              :tick tick :query "" :workflow id)))))))


;;;; Major mode

(defun octocat-workflow-browse ()
  "Open this workflow in a browser."
  (interactive)
  (unless (and octocat--workflow-repo octocat--workflow-id)
    (user-error "Octocat: Buffer is not associated with a workflow"))
  (message "Octocat: Opening workflow in browser…")
  (octocat-browse-external (octocat-workflow--url octocat--workflow-repo octocat--workflow-id
                                                  octocat--workflow-path)))

(defvar octocat-workflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-workflow-browse)
    map)
  "Keymap for `octocat-workflow-mode'.")

(define-derived-mode octocat-workflow-mode vui-mode "Octocat-Workflow"
  "Major mode for viewing a GitHub Actions Workflow.

\\{octocat-workflow-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-workflow-refresh)
  (add-hook 'post-command-hook #'octocat-vui--prefetch-schedule nil t)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-workflow-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow buffer.
The page paints from the sync store at once and fetches the workflow and
its runs in the background, in place."
  (interactive)
  (unless (and octocat--workflow-repo octocat--workflow-id)
    (user-error "Octocat: Buffer is not associated with a workflow"))
  (octocat-vui-refresh-page 'octocat-workflow--page
                            (cons octocat--workflow-repo octocat--workflow-id)
                            (list :repo octocat--workflow-repo
                                  :id octocat--workflow-id
                                  :name (or octocat--workflow-name "")
                                  :path octocat--workflow-path)))

(defun octocat-workflow-open (repo id name path)
  "Show workflow ID of REPO in its own buffer.
NAME is its display name and PATH its file, or nil."
  (let ((buf (get-buffer-create (format "*%s workflow %s*" repo name))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-workflow-mode)
      (octocat-workflow-mode))
    (setq octocat--workflow-repo repo
          octocat--workflow-id   id
          octocat--workflow-name name
          octocat--workflow-path path)
    (octocat-workflow-refresh)))

;;;; Workflow list
;;
;; `octocat-workflow-list-mode': a repository's workflows and whether
;; each is enabled, the second page of the Actions tab (see the run list
;; in octocat-run.el).

(defun octocat-workflow--list (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(octocat-sync-define-resource workflows (repo)
  :fetch (lambda (done)
           (octocat-workflow--list
            repo (lambda (r) (funcall done (if (eq (car-safe r) 'error) r (vconcat r)))))))

(defun octocat-workflow--state (workflow)
  "Return the state of WORKFLOW as shown on its row, such as \"active\"."
  (downcase (or (gethash "state" workflow) "")))

(defun octocat-workflow--file (workflow)
  "Return the file name of WORKFLOW, such as \"test.yml\"."
  (file-name-nondirectory (or (gethash "path" workflow) "")))

(defun octocat-workflow-list--name-width (workflows width state-w)
  "Return the width of the name column of WORKFLOWS: the longest name.
It is at most what WIDTH columns leave beside the STATE-W wide state and
the longest file name, but cuts no name shorter than 10."
  (let ((longest (lambda (f) (apply #'max 0 (mapcar (lambda (wf) (string-width (funcall f wf)))
                                                    workflows)))))
    (min (funcall longest (lambda (wf) (or (gethash "name" wf) "")))
         (max 10 (- width 1 state-w 2 2
                    (funcall longest #'octocat-workflow--file))))))

(defun octocat-workflow-list--row (repo workflow &optional state-w name-w)
  "Return a row vnode for WORKFLOW in REPO: its state, name and file name.
The state is padded to STATE-W columns and the name to NAME-W, cut to
it when longer (40 by default), so the columns line up."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (octocat-workflow--state workflow))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
           (propertize (string-pad state (max (or state-w 0) (string-width state)))
                       'face state-face)
           "  "
           (truncate-string-to-width name (or name-w 40) nil ?\s "…")
           "  "
           (propertize (octocat-workflow--file workflow) 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-workflow-open repo (gethash "id" workflow) name
                                                       (gethash "path" workflow)))
                     "RET: open workflow")))

(defun octocat-workflow-list--workflows (repo snap)
  "Return the workflows of REPO, from SNAP, their sync snapshot.
No pagination: run history lives on the runs page."
  (pcase (octocat-vui-snapshot-status snap)
    ('pending (vui-text (octocat-vui-line-skeleton)))
    ('error   (vui-text (concat (octocat-vui-error-text snap) "\n") :face 'octocat-dimmed))
    ('ready
     (let ((workflows (append (plist-get snap :data) nil)))
       (if (null workflows)
           (vui-text "(no workflows)\n" :face 'octocat-dimmed)
         (let* ((state-w (apply #'max (mapcar (lambda (wf)
                                                (string-width
                                                 (octocat-workflow--state wf)))
                                              workflows)))
                (name-w  (octocat-workflow-list--name-width
                          workflows (octocat-vui-window-width) state-w)))
           (vui-list workflows
                     (lambda (wf) (octocat-workflow-list--row repo wf state-w name-w))
                     (lambda (wf) (gethash "id" wf)))))))))

(vui-defcomponent octocat-workflow-list--page (repo tick)
  "The page of REPO's workflows.
Stored, they show at once; a new TICK refetches them, keeping what is
shown up until the fresh data replaces it."
  :render
  (let ((workflows (octocat-vui-use-resource (list 'workflows repo) tick)))
    (vui-vstack
     (vui-component 'octocat-vui-list-header :repo repo :tab 'actions :tick tick)
     (octocat-run-list--tab-row repo 'workflows workflows)
     (vui-newline)
     (octocat-workflow-list--workflows repo workflows))))

(defun octocat-workflow-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow list buffer, as `octocat-run-list-refresh'."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-workflow-list--page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo)))

(define-derived-mode octocat-workflow-list-mode octocat-vui-list-mode "Octocat-Workflows"
  "Major mode for the list of a repository's workflows.

\\{octocat-workflow-list-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-workflow-list-refresh))

(provide 'octocat-workflow)
;;; octocat-workflow.el ends here
