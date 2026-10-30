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
;; run list's section (octocat-run.el).  A workflow with a
;; `workflow_dispatch' trigger is run by hand from a form above them,
;; its inputs read from the workflow's file.  Also the workflow list,
;; `octocat-workflow-list-mode', the second page of the Actions tab.
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-run)
(require 'octocat-search) ; `octocat--read-branch'
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
  "Return the web page of workflow ID of REPO.
GitHub names it by its file, the last part of PATH, when known."
  (octocat--web-url "%s/actions/workflows/%s" repo
                    (if (octocat--nonempty path) (file-name-nondirectory path) id)))


;;;; Running by hand
;;
;; GitHub's API doesn't say what a `workflow_dispatch' trigger asks:
;; it is read from the workflow's file, at the branch it is to run on.
;; Elisp has no YAML reader, so `octocat-workflow--yaml-parse' reads
;; the little of YAML that triggers are written in, and only the `on'
;; block is given to it.

(defun octocat-workflow--yaml-uncomment (line)
  "Return LINE without its comment and trailing blanks.
A comment starts at a `#' outside quotes, first or after a blank."
  (let ((i 0) (n (length line)) quote end)
    (while (and (< i n) (not end))
      (let ((c (aref line i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((and (eq c ?#) (or (zerop i) (memq (aref line (1- i)) '(?\s ?\t))))
               (setq end i))))
      (setq i (1+ i)))
    (string-trim-right (substring line 0 end))))

(defun octocat-workflow--yaml-item-p (text)
  "Return non-nil if TEXT, a trimmed line, is an item of a block sequence."
  (or (equal text "-") (string-prefix-p "- " text)))

(defun octocat-workflow--yaml-key (text)
  "Return (KEY . REST) if TEXT, a trimmed line, is a mapping entry.
REST is what follows the colon, \"\" when nothing does."
  (when (string-match (concat "\\`\\(\"[^\"]*\"\\|'[^']*'\\|[^\"' ][^:]*?\\)"
                              "[ \t]*:\\(?:[ \t]+\\(.*\\)\\)?\\'")
                      text)
    (cons (octocat-workflow--yaml-scalar (match-string 1 text))
          (or (match-string 2 text) ""))))

(defun octocat-workflow--yaml-split (text)
  "Return TEXT, the inside of a flow collection, split at its top commas."
  (let ((i 0) (start 0) (depth 0) quote parts)
    (while (< i (length text))
      (let ((c (aref text i)))
        (cond (quote (when (eq c quote) (setq quote nil)))
              ((memq c '(?\" ?\')) (setq quote c))
              ((memq c '(?\[ ?\{)) (setq depth (1+ depth)))
              ((memq c '(?\] ?\})) (setq depth (1- depth)))
              ((and (eq c ?,) (zerop depth))
               (push (substring text start i) parts)
               (setq start (1+ i)))))
      (setq i (1+ i)))
    (push (substring text start) parts)
    (seq-remove #'string-empty-p (mapcar #'string-trim (nreverse parts)))))

(defun octocat-workflow--yaml-scalar (text)
  "Return TEXT, a value on one line, as `octocat-workflow--yaml-parse' does."
  (cond
   ((member text '("" "~" "null" "Null" "NULL")) nil)
   ((string-match "\\`\"\\(.*\\)\"\\'" text)
    (condition-case nil (read text) (error (match-string 1 text))))
   ((string-match "\\`'\\(.*\\)'\\'" text)
    (string-replace "''" "'" (match-string 1 text)))
   ((string-match "\\`\\[\\(.*\\)\\]\\'" text)
    (vconcat (mapcar #'octocat-workflow--yaml-scalar
                     (octocat-workflow--yaml-split (match-string 1 text)))))
   ((string-match "\\`{\\(.*\\)}\\'" text)
    (delq nil (mapcar (lambda (part)
                        (when-let* ((pair (octocat-workflow--yaml-key part)))
                          (cons (car pair) (octocat-workflow--yaml-scalar (cdr pair)))))
                      (octocat-workflow--yaml-split (match-string 1 text)))))
   (t text)))

(defun octocat-workflow--yaml-parse (text)
  "Return TEXT, YAML, as Lisp.
A mapping is an alist of (KEY . VALUE), in order, a sequence a vector,
a scalar a string, and an empty value nil.  It reads block mappings
and sequences, flow ones on one line, quoted and plain scalars and
block scalars (`|', `>'): what triggers are written in.  Anchors, tags
and values over several lines otherwise are not read."
  (let* ((lines (vconcat
                 (mapcar (lambda (raw)
                           (let ((s (octocat-workflow--yaml-uncomment raw)))
                             ;; (INDENT TEXT RAW); INDENT nil for a blank line
                             (list (and (not (string-blank-p s))
                                        (- (length s) (length (string-trim-left s))))
                                   (string-trim s) raw)))
                         (split-string text "\n"))))
         (i 0))
    (cl-labels
        ((indent ()
           (while (and (< i (length lines)) (null (car (aref lines i))))
             (setq i (1+ i)))
           (and (< i (length lines)) (car (aref lines i))))
         (line () (nth 1 (aref lines i)))
         (node (min)
           (let ((ind (indent)))
             (cond ((or (null ind) (< ind min)) nil)
                   ((octocat-workflow--yaml-item-p (line)) (items ind))
                   (t (pairs ind)))))
         (items (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-workflow--yaml-item-p (line)))
               (let ((rest (string-trim-left (substring (line) 1))))
                 (cond ((string-empty-p rest)
                        (setq i (1+ i))
                        (push (node (1+ ind)) out))
                       ((octocat-workflow--yaml-key rest)
                        ;; "- key: value" starts a mapping at key's column.
                        (aset lines i (list (+ ind (- (length (line)) (length rest))) rest nil))
                        (push (pairs (car (aref lines i))) out))
                       (t (setq i (1+ i))
                          (push (octocat-workflow--yaml-scalar rest) out)))))
             (vconcat (nreverse out))))
         (pairs (ind)
           (let (out)
             (while (and (eql (indent) ind) (octocat-workflow--yaml-key (line)))
               (pcase-let ((`(,key . ,rest) (octocat-workflow--yaml-key (line))))
                 (setq i (1+ i))
                 (push (cons key
                             (cond ((string-match-p "\\`[|>][-+0-9]*\\'" rest)
                                    (block ind (eq (aref rest 0) ?>)))
                                   ((not (string-empty-p rest))
                                    (octocat-workflow--yaml-scalar rest))
                                   ;; A sequence may sit at its key's indent.
                                   ((and (eql (indent) ind)
                                         (octocat-workflow--yaml-item-p (line)))
                                    (items ind))
                                   (t (node (1+ ind)))))
                       out)))
             (nreverse out)))
         (block (ind folded)
           (let (raws)
             (while (and (< i (length lines))
                         (let ((raw (nth 2 (aref lines i))))
                           (and raw (or (string-blank-p raw)
                                        (> (- (length raw) (length (string-trim-left raw)))
                                           ind)))))
               (push (nth 2 (aref lines i)) raws)
               (setq i (1+ i)))
             (let* ((raws (nreverse raws))
                    (cut  (apply #'min most-positive-fixnum
                                 (mapcar (lambda (r) (- (length r) (length (string-trim-left r))))
                                         (seq-remove #'string-blank-p raws)))))
               (string-trim-right
                (string-join (mapcar (lambda (r) (if (string-blank-p r) "" (substring r cut)))
                                     raws)
                             (if folded " " "\n")))))))
      (node 0))))

(defun octocat-workflow--yaml-on (yaml)
  "Return the triggers of workflow file YAML, its `on' value, as Lisp.
Only the `on' block is read, so what the jobs are written in does not
matter.  YAML 1.1 reads a bare `on' as true, so `true' is taken too."
  (let ((lines (split-string yaml "\n")) block)
    (while (and lines (not (string-match-p "\\`\\(on\\|\"on\"\\|'on'\\|true\\)[ \t]*:"
                                           (car lines))))
      (setq lines (cdr lines)))
    (when lines
      (push (car lines) block)
      (setq lines (cdr lines))
      (while (and lines (let ((l (octocat-workflow--yaml-uncomment (car lines))))
                          (or (string-empty-p l) (memq (aref l 0) '(?\s ?\t ?-)))))
        (push (car lines) block)
        (setq lines (cdr lines)))
      (cdar (octocat-workflow--yaml-parse (string-join (nreverse block) "\n"))))))

(defun octocat-workflow--dispatch-spec (yaml)
  "Return what running workflow file YAML by hand asks, as a hash-table.
\"dispatch\" is t when it has a `workflow_dispatch' trigger, else
`:false', and \"inputs\" a vector of its inputs, each with its
\"name\", \"type\", \"required\" (t or `:false'), \"options\" and,
when given, \"description\" and \"default\", strings."
  (let* ((on       (octocat-workflow--yaml-on yaml))
         (trigger  (cond ((stringp on) (and (equal on "workflow_dispatch") (list on)))
                         ((vectorp on) (and (seq-contains-p on "workflow_dispatch") (list on)))
                         ((consp on)   (assoc "workflow_dispatch" on))))
         (inputs   (let ((v (cdr trigger))) (and (consp v) (cdr (assoc "inputs" v)))))
         (spec     (make-hash-table :test #'equal)))
    (puthash "dispatch" (if trigger t :false) spec)
    (puthash "inputs"
             (vconcat
              (mapcar (pcase-lambda (`(,name . ,props))
                        (let ((in  (make-hash-table :test #'equal))
                              (get (lambda (k) (and (consp props) (cdr (assoc k props))))))
                          (puthash "name" name in)
                          (puthash "type" (or (funcall get "type") "string") in)
                          (puthash "required"
                                   (if (member (funcall get "required") '("true" "True" "TRUE"))
                                       t :false)
                                   in)
                          (puthash "options" (vconcat (funcall get "options")) in)
                          (dolist (k '("description" "default"))
                            (when (stringp (funcall get k))
                              (puthash k (funcall get k) in)))
                          in))
                      (and (consp inputs) inputs)))
             spec)
    spec))

(defun octocat-workflow--dispatchable-path-p (path)
  "Return non-nil if PATH is a workflow file, which can be run by hand.
Not one of GitHub's own, such as \"dynamic/pages/pages-build-deployment\"."
  (and (stringp path) (string-prefix-p ".github/workflows/" path)))

(octocat-sync-define-resource workflow-dispatch (repo path ref)
  :max-age 300
  :poll 300
  :fetch (lambda (done)
           (octocat--run-gh
            "workflow-file"
            (list "api" "-X" "GET"
                  (format "repos/%s/contents/%s" repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
                  "-f" (concat "ref=" ref)
                  "-H" "Accept: application/vnd.github.raw")
            #'octocat-workflow--dispatch-spec
            done)))

(defun octocat-workflow--input-default (input)
  "Return the first value of INPUT in the form, as GitHub's: a string."
  (or (gethash "default" input)
      (pcase (gethash "type" input)
        ("boolean" "false")
        ("choice"  (let ((options (gethash "options" input)))
                     (if (> (length options) 0) (aref options 0) "")))
        (_ ""))))

(defun octocat-workflow--input-values (inputs values)
  "Return the value of each of INPUTS, as an alist (NAME . STRING).
VALUES, an alist of the same, has those the user set; the others are
their defaults."
  (mapcar (lambda (in)
            (let ((name (gethash "name" in)))
              (cons name (or (cdr (assoc name values))
                             (octocat-workflow--input-default in)))))
          inputs))

(defun octocat-workflow--input-errors (inputs values)
  "Return what is wrong with VALUES of INPUTS, an alist (NAME . MESSAGE).
VALUES is as `octocat-workflow--input-values' returns.  GitHub refuses
a run missing a required input, a number that is none, or a choice not
among the options."
  (delq nil
        (mapcar (lambda (in)
                  (let* ((name  (gethash "name" in))
                         (value (or (cdr (assoc name values)) ""))
                         (blank (string-blank-p value)))
                    (cond
                     ((and blank (eq (gethash "required" in) t)) (cons name "required"))
                     ((and (not blank) (equal (gethash "type" in) "number")
                           (not (string-match-p
                                 (concat "\\`[-+]?\\([0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)"
                                         "\\([eE][-+]?[0-9]+\\)?\\'")
                                 (string-trim value))))
                      (cons name "not a number"))
                     ((and (equal (gethash "type" in) "choice")
                           (not (seq-contains-p (gethash "options" in) value)))
                      (cons name "not one of the options")))))
                inputs)))

(defun octocat-workflow--input-label (input &optional width)
  "Return the label of INPUT: its description's first line, or its name.
A required one is marked `*', as on GitHub.  With WIDTH, the text is
cut to keep the label within it, the mark kept."
  (let ((text (car (split-string (or (octocat--nonempty (gethash "description" input))
                                     (gethash "name" input))
                                 "\n")))
        (mark (if (eq (gethash "required" input) t) (propertize " *" 'face 'error) "")))
    (concat (if width (octocat-vui--fit text (- width (string-width mark))) text)
            mark)))

(defun octocat-workflow--parse-dispatched (output)
  "Return the ID of the run GitHub started, from OUTPUT, or nil.
Asked for with `return_run_details'; a GitHub without it answers with
nothing."
  (let ((text (string-trim output)))
    (and (not (string-empty-p text))
         (octocat--get (json-parse-string text) "workflow_run_id"))))

(octocat-sync-define-mutation dispatch-workflow (repo id ref inputs)
  :label "Starting workflow…"
  :slot 'dispatch
  :resources (lambda () `((workflow ,repo ,id)))
  :send (lambda (done)
          (octocat--run-gh "workflow-dispatch"
                           (append (list "api" "--method" "POST"
                                         (format "repos/%s/actions/workflows/%s/dispatches"
                                                 repo id)
                                         "-f" (concat "ref=" ref)
                                         "-F" "return_run_details=true")
                                   (mapcan (pcase-lambda (`(,name . ,value))
                                             (list "-f" (format "inputs[%s]=%s" name value)))
                                           inputs))
                           #'octocat-workflow--parse-dispatched done))
  :invalidates (lambda () `((runs ,repo _ _))))

(defun octocat-workflow--input-control (input value on-change on-submit)
  "Return the control of INPUT showing VALUE, a string.
ON-CHANGE is called with each new value; ON-SUBMIT runs on RET in a
text field."
  (let ((name (gethash "name" input)))
    (pcase (gethash "type" input)
      ("boolean" (vui-checkbox :key (list 'input name)
                               :checked (equal value "true")
                               :on-change (lambda (v) (funcall on-change (if v "true" "false")))))
      ("choice"  (vui-select :key (list 'input name)
                             :value value
                             :options (append (gethash "options" input) nil)
                             :prompt (format "%s: " name)
                             :on-change on-change))
      (_ (vui-field :key (list 'input name)
                    :value value
                    :size 30
                    :face 'octocat-filter-input
                    :on-change on-change
                    :on-submit (lambda (_) (funcall on-submit)))))))

(vui-defcomponent octocat-workflow--dispatch (repo id path default-branch local busy tick)
  "The \"Run workflow\" button of workflow ID of REPO, and its form.
PATH is the workflow's file, read at DEFAULT-BRANCH, or at the branch
picked, for its `workflow_dispatch' inputs; LOCAL is the clone's branch,
for the picker.  The form slides out under the button, as GitHub's
drops down, and closes as the run is sent.  BUSY is the label of the
run being started, shown in the button's place.  TICK is the page's."
  :state ((open nil) (shown 0) (ref nil) (values nil) (tried nil))
  :render
  (let* ((_ (octocat-vui-use-view-reset
             (vui-async-callback ()
               (vui-set-state :open nil)
               (vui-set-state :shown 0))))
         (buf    (current-buffer))
         (shown-ref (or ref default-branch))
         (snap   (octocat-vui-use-resource (list 'workflow-dispatch repo path shown-ref) tick))
         (spec   (plist-get snap :data))
         (inputs (and spec (append (gethash "inputs" spec) nil)))
         (dispatch (and spec (eq (gethash "dispatch" spec) t)))
         (current (octocat-workflow--input-values inputs values))
         (errors (and tried (octocat-workflow--input-errors inputs current)))
         (set-state (vui-async-callback (key value) (vui-set-state key value)))
         (set-value (vui-async-callback (name value)
                      (vui-set-state :values
                                     (lambda (vs) (cons (cons name value)
                                                        (assoc-delete-all name (copy-alist vs)))))))
         (toggle (vui-async-callback () (vui-set-state :open (not open))))
         (run
          (vui-async-callback ()
            (cond
             ((not dispatch) (user-error "Octocat: No workflow_dispatch trigger on %s" shown-ref))
             ((octocat-workflow--input-errors inputs current)
              (vui-set-state :tried t)
              (message "Octocat: Fill in the inputs marked"))
             (t
              ;; Closed at once: the run is shown under way in the
              ;; button's place, and the form comes back if it fails.
              (vui-set-state :open nil)
              (vui-set-state :shown 0)
              (vui-set-state :tried nil)
              (octocat-sync-submit
               `(dispatch-workflow ,repo ,id ,shown-ref ,current)
               (lambda (result)
                 (cond
                  ((eq (car-safe result) 'error)
                   (funcall set-state :open t))
                  (t
                   (funcall set-state :values nil)
                   (cond ((and result (octocat--still-selected-p buf))
                          (with-current-buffer buf (octocat-run-open repo result)))
                         ((not result)
                          (message "Octocat: Workflow started on %s" shown-ref)))))))))))
         (pick-ref
          (lambda ()
            (let ((picked (octocat--read-branch repo default-branch local shown-ref)))
              (funcall set-state :ref (unless (equal picked default-branch) picked)))))
         (label-w (min 40 (apply #'max (string-width "Use workflow from")
                                 (mapcar (lambda (in) (string-width
                                                       (octocat-workflow--input-label in)))
                                         inputs))))
         (label   (lambda (text)
                    (vui-text (concat "  " (string-pad text label-w) "  "))))
         (rows
          (append
           (list (vui-hstack :spacing 0
                             (funcall label "Use workflow from")
                             (vui-button (format "%s ▾" shown-ref)
                               :key 'dispatch-ref
                               :help-echo "RET: pick the branch to run the workflow from"
                               :on-click pick-ref)))
           (cond
            ((eq (octocat-vui-snapshot-status snap) 'error)
             (list (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error)))
            ((not spec) (list (vui-text (octocat-vui-line-skeleton))))
            ((not dispatch)
             (list (vui-text (format "  No workflow_dispatch trigger on %s" shown-ref)
                     :face 'octocat-dimmed)))
            (t
             (mapcar (lambda (in)
                       (let* ((name  (gethash "name" in))
                              (error (cdr (assoc name errors))))
                         (vui-hstack :spacing 0
                                     (funcall label (octocat-workflow--input-label in label-w))
                                     (octocat-workflow--input-control
                                      in (cdr (assoc name current))
                                      (lambda (v) (funcall set-value name v))
                                      run)
                                     (and error (vui-text (concat "  " error) :face 'error)))))
                     inputs)))
           (list (vui-hstack :spacing 2
                             (vui-text (make-string (+ label-w 2) ?\s))
                             (vui-button "Run workflow"
                               :key 'dispatch-run
                               :face 'success
                               :disabled (not dispatch)
                               :help-echo "RET: start the workflow"
                               :on-click run)
                             (vui-button "Cancel"
                               :key 'dispatch-cancel
                               :face 'octocat-dimmed
                               :help-echo "RET: close without running"
                               :on-click toggle)))))
         (now (octocat-vui-use-unfold shown open (length rows))))
    ;; No button until the file is known to have the trigger: on another
    ;; branch it may lack one, and the form says so.
    (when (or busy open (> now 0) ref dispatch)
      (apply #'vui-vstack
             (vui-hstack :spacing 2
                         (vui-text "This workflow has a workflow_dispatch event trigger."
                           :face 'octocat-dimmed)
                         (if busy
                             (vui-text (concat (octocat-vui-spinner) " " busy) :face 'bold)
                           (vui-button (if open "Run workflow ▴" "Run workflow ▾")
                             :key 'dispatch-toggle
                             :help-echo (if open
                                            "RET: close the form"
                                          "RET: run the workflow by hand")
                             :on-click toggle)))
             (append (seq-take rows now) (list (vui-newline)))))))

;;;; Page

(defun octocat-workflow--header (repo workflow width)
  "Return the header vnodes of WORKFLOW of REPO, kept within WIDTH.
The top row names it; under it its state, file and dates."
  (let ((state   (or (octocat--nonempty (downcase (or (gethash "state" workflow) "")))
                     "unknown"))
        (created (octocat--nonempty (gethash "created_at" workflow)))
        (updated (octocat--nonempty (gethash "updated_at" workflow))))
    (octocat-vui-actions-header
     repo
     (list (list (or (gethash "name" workflow) "")))
     width
     (propertize state 'face (octocat--workflow-state-face state))
     (list (list (cons nil (let ((path (octocat--nonempty (gethash "path" workflow))))
                             (and path (propertize path 'face 'octocat-branch))))
                 (cons "Created" (and created (octocat--format-ts-relative created)))
                 (cons "Updated" (and updated (octocat--format-ts-relative updated))))))))


(octocat-sync-define-resource workflow (repo id)
  :fetch (lambda (done) (octocat--fetch-workflow repo id done)))

(vui-defcomponent octocat-workflow--page (repo id name path tick)
  "Workflow ID of REPO and its runs, as the run list shows them.
NAME shows while it loads, and PATH, its file or nil, stands in for
the fetched one meanwhile.  A new TICK fetches them again."
  :render
  (let* ((width (octocat-vui-window-width))
         (local-branch (vui-use-memo () (octocat--current-branch)))
         (snap  (octocat-vui-use-resource (list 'workflow repo id) tick))
         (data  (plist-get snap :data))
         (summary (plist-get (octocat-vui-use-resource (list 'repo-summary repo) tick) :data))
         (default-branch (and summary (gethash "default-branch" summary)))
         (file  (or (and data (gethash "path" data)) path)))
    (apply #'vui-vstack
           (append
            (if data
                (octocat-workflow--header repo data width)
              (octocat-vui-actions-header repo (list (list name)) width))
            (list
             (vui-newline)
             (and data default-branch
                  (equal (gethash "state" data) "active")
                  (octocat-workflow--dispatchable-path-p file)
                  (vui-component 'octocat-workflow--dispatch
                    :key 'dispatch
                    :repo repo :id id :path file
                    :default-branch default-branch :local local-branch
                    :busy (alist-get 'dispatch (plist-get snap :mutating))
                    :tick tick))
             (octocat-vui-section-heading "Runs" width)
             (if (eq (octocat-vui-snapshot-status snap) 'error)
                 (vui-text (concat "  " (octocat-vui-error-text snap)) :face 'error)
               (vui-component 'octocat-run-list--runs
                 :repo repo
                 :current-branch local-branch
                 :tick tick :query "" :workflow id)))))))


;;;; Major mode

(defun octocat-workflow--page-url ()
  "Return the URL of this workflow."
  (and octocat--workflow-repo octocat--workflow-id
       (octocat-workflow--url octocat--workflow-repo octocat--workflow-id
                              octocat--workflow-path)))

(defvar octocat-workflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-vui-page-map)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
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
  (octocat--ts-eldoc-setup)
  (setq-local octocat--url-function #'octocat-workflow--page-url))


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
                     "RET: open workflow"
                     (octocat-workflow--url repo (gethash "id" workflow)
                                            (gethash "path" workflow)))))

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
