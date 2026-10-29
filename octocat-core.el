;;; octocat-core.el --- Shared infrastructure for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Shared options, faces, and low-level gh-process helpers used by both
;; octocat.el and octocat-pr.el.  Neither of those files should be loaded
;; before this one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'color)
(require 'json)
(require 'eldoc)
(require 'browse-url)
(require 'octocat-markdown)
(require 'octocat-image)
(require 'consult)

;; Forward declarations for octocat-repo.el functions called from this file.
;; octocat-repo.el is loaded after octocat-core.el, so we cannot require it.
(declare-function octocat-repo-mode            "octocat-repo" ())
(declare-function octocat-repo--local-dir-for  "octocat-repo" (repo))
(declare-function octocat-repo-refresh         "octocat-repo" (&optional _ignore-auto _noconfirm))
(declare-function octocat-repo--current-repo   "octocat-repo" ())
(declare-function octocat-pr-open              "octocat-pr"   (repo number))
(declare-function octocat-issue-open           "octocat-issue" (repo number))
(declare-function octocat-commit-open          "octocat-commit" (repo sha))

;; Buffer-local variable stubs: defined as defvar-local in their respective
;; files (loaded after octocat-core.el).  The plain defvar here lets the
;; byte-compiler see the symbol and suppresses "reference to free variable"
;; warnings without creating a new binding.
(defvar octocat-repo--repo)
(defvar octocat--pr-repo)
(defvar octocat--pr-number)
(defvar octocat--issue-repo)
(defvar octocat--issue-number)
(defvar octocat--commit-repo)
(defvar octocat--workflow-repo)
(defvar octocat--run-repo)
(defvar octocat--job-repo)
(defvar octocat--checks-repo)
(defvar octocat-tree--file-repo)
(defvar octocat-vui-list--repo)


;;;; Options

(defcustom octocat-debug nil
  "When non-nil, dump raw gh JSON output to the *octocat-debug* buffer."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-gh-program "gh"
  "The `gh' executable: a file name, or a name to look for.
A name is looked for in the variable `exec-path'."
  :type 'string
  :group 'octocat)

(defcustom octocat-gh-timeout 60
  "Seconds a `gh' call may take before it is stopped as failed, or nil.
A call can hang without failing, say after the network changed under an
open connection; stopped, it fails as when GitHub cannot be reached, so
its page says so and `g' retries, instead of loading for good."
  :type '(choice (const :tag "Never" nil) number)
  :group 'octocat)

(defcustom octocat-list-page-size 15
  "Number of items the PR and issue list pages show, and load, at a time.
See `octocat-list-compact-page-size' for their compact view."
  :type 'integer
  :group 'octocat)

(defcustom octocat-list-compact-page-size 30
  "Number of items the compact PR and issue list pages show at a time."
  :type 'integer
  :group 'octocat)

(defcustom octocat-settings-file
  (locate-user-emacs-file "octocat/settings.eld")
  "File keeping the choices octocat remembers across sessions.
Such as which list pages are compact; outside the cache directory, so
clearing the cache keeps them."
  :type 'file
  :group 'octocat)

(defcustom octocat-max-width 112
  "Most columns a repo, list, issue or pull request page takes, or nil.
The list pages are the issues, pull requests and Actions of a repo.
The page keeps to the left of a wider window, as GitHub bounds its
conversation column; what does not fit the column, such as a diff's long
lines, runs on past it."
  :type '(choice (const :tag "No limit" nil) integer)
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
  '((t :inherit font-lock-constant-face))
  "Face for a PR number."
  :group 'octocat)

(defface octocat-pr-author
  '((t :inherit font-lock-string-face))
  "Face for a PR author."
  :group 'octocat)

(defface octocat-repo
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a repository or remote-branch name."
  :group 'octocat)

(defface octocat-branch
  '((((class color) (background dark))  :foreground "#8ec07c")
    (((class color) (background light)) :foreground "#427b58")
    (t :inherit font-lock-function-name-face))
  "Face for a local or remote branch name."
  :group 'octocat)

(defface octocat-branch-current
  '((((class color) (background dark))
     :foreground "#8ec07c" :weight bold :underline t)
    (((class color) (background light))
     :foreground "#427b58" :weight bold :underline t)
    (t :inherit (bold octocat-branch) :underline t))
  "Face for the currently checked-out branch in PR and run lists.
Applied to branch names that match the local HEAD branch, following the
Magit convention of marking the current branch with bold + underline."
  :group 'octocat)

(defconst octocat-branch-max-width 16
  "Maximum display width (in characters) for a branch name column.
Longer names are truncated with a trailing ellipsis (…).")

(defconst octocat-title-width 40
  "Display width (in characters) for title/subject columns.
Used by PR titles, issue titles, workflow-run display titles, and commit
subjects so all list views share a uniform column width.")

(defun octocat--format-title (title &optional width)
  "Return TITLE truncated/padded to WIDTH or `octocat-title-width' characters.
Strings shorter than the width are space-padded; longer ones are
truncated with a trailing ellipsis (…)."
  (truncate-string-to-width title (or width octocat-title-width) nil ?\s "…"))

(defun octocat--label-background ()
  "Return the frame's background colour if it is dark, else nil.
This is the BG argument of `octocat--label-face'."
  (and (eq (frame-parameter nil 'background-mode) 'dark)
       (let ((c (face-background 'default nil t)))
         (if (stringp c) c "black"))))

(defun octocat--label-rgb (colour)
  "Return COLOUR as a list of floats 0-1.
\"#rrggbb\" is parsed exactly; `color-name-to-rgb' would round it to the
palette of a terminal frame."
  (if (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" colour)
      (mapcar (lambda (i) (/ (string-to-number (substring colour i (+ i 2)) 16) 255.0))
              '(1 3 5))
    (or (color-name-to-rgb colour) '(0.0 0.0 0.0))))

(defun octocat--label-hex (rgb)
  "Return RGB (floats 0-1) as \"#rrggbb\".
Rounds, where `color-rgb-to-hex' truncates and so shifts colours that
pass through HSL."
  (apply #'format "#%02x%02x%02x" (mapcar (lambda (c) (round (* 255 c))) rgb)))

(defun octocat--label-lightness (rgb)
  "Return the perceived lightness, 0-1, of RGB (floats 0-1), as GitHub does."
  (pcase-let ((`(,r ,g ,b) rgb))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun octocat--label-blend (rgb alpha bg)
  "Return RGB at opacity ALPHA over colour BG, as a \"#rrggbb\" string."
  (octocat--label-hex
   (cl-mapcar (lambda (c b) (+ (* alpha c) (* (- 1 alpha) b)))
              rgb (octocat--label-rgb bg))))

(defun octocat--label-face (label bg)
  "Return the face of GitHub LABEL hash-table, or nil without a valid colour.
BG is nil on a light background: a chip in the label's colour with black
or white text.  On a dark one it is the background colour (see
`octocat--label-background'): a faint tint with the label's colour,
lightened to read, as text and border.  Both follow github.com's CSS."
  (let ((c (gethash "color" label)))
    (and (stringp c) (string-match-p "\\`[0-9a-fA-F]\\{6\\}\\'" c)
         (let* ((rgb (octocat--label-rgb (concat "#" c)))
                (pl  (octocat--label-lightness rgb)))
           (if (not bg)
               (list :background (concat "#" c)
                     :foreground (if (> pl 0.453) "black" "white"))
             (pcase-let* ((`(,h ,s ,l) (apply #'color-rgb-to-hsl rgb))
                          (fg (color-hsl-to-rgb
                               h s (min 1.0 (+ l (max 0 (- 0.6 pl)))))))
               (list :background (octocat--label-blend rgb 0.18 bg)
                     :foreground (octocat--label-hex fg)
                     :box (list :line-width '(-1 . -1)
                                :color (octocat--label-blend fg 0.3 bg)))))))))

(defun octocat--format-label (label bg)
  "Return a propertized chip string for GitHub LABEL hash-table.
BG is as for `octocat--label-face'; without a colour it falls back to
the `octocat-branch' face."
  (let ((name (or (gethash "name" label) ""))
        (face (octocat--label-face label bg)))
    (if face
        (propertize (concat " " name " ") 'face face)
      (propertize name 'face 'octocat-branch))))

(defun octocat--format-labels (labels bg)
  "Return LABELS (vector of label hash-tables) as space-separated chips.
BG is as for `octocat--label-face'.  Returns the empty string when
LABELS is nil, `:null' or empty."
  (if (or (null labels) (eq labels :null) (zerop (length labels)))
      ""
    (mapconcat (lambda (l) (octocat--format-label l bg)) labels " ")))

(defun octocat--format-branch (branch width)
  "Return BRANCH truncated to WIDTH characters and styled with `octocat-branch'.
WIDTH should be at most `octocat-branch-max-width'.  Shorter names are
padded with spaces so columns stay aligned.  The string is decorated
with the `octocat-branch' face."
  (propertize (truncate-string-to-width branch width nil ?\s "…")
              'face 'octocat-branch))

(defun octocat--branch-column-width (runs key)
  "Return the branch column width to use when rendering a workflow list.
KEY names the hash entry holding the branch string (e.g. \"headBranch\"
or \"headRefName\") inside each element of RUNS.  The result is the
minimum of `octocat-branch-max-width' and the longest branch name,
with a floor of 1."
  (min octocat-branch-max-width
       (apply #'max 1
              (mapcar (lambda (r) (length (or (gethash key r) "")))
                      runs))))

(defface octocat-section-heading
  '((t :weight bold :extend t))
  "Face for section headings in octocat buffers."
  :group 'octocat)

(defface octocat-dimmed
  '((t :inherit shadow))
  "Face for secondary / de-emphasised text in octocat buffers."
  :group 'octocat)

(defface octocat-segment
  '((((class color) (background dark))
     :inherit octocat-dimmed :box (:line-width (-1 . -1) :color "gray40"))
    (((class color) (background light))
     :inherit octocat-dimmed :box (:line-width (-1 . -1) :color "gray70"))
    (t :inherit octocat-dimmed))
  "Face for a choice not taken in a segmented control, such as Diff | Patch."
  :group 'octocat)

(defface octocat-segment-current
  '((((class color) (background dark))
     :weight bold :background "gray30" :box (:line-width (-1 . -1) :color "gray40"))
    (((class color) (background light))
     :weight bold :background "gray85" :box (:line-width (-1 . -1) :color "gray70"))
    (t :inverse-video t))
  "Face for the choice taken in a segmented control."
  :group 'octocat)

(defface octocat-blame-rule
  '((((class color) (background dark)) :underline (:color "gray35"))
    (((class color) (background light)) :underline (:color "gray75"))
    (t :underline t))
  "Face for the last line of a blame's run, parting it from the next commit's."
  :group 'octocat)

(defface octocat-skeleton
  '((((class color) (background dark)) :background "gray25")
    (((class color) (background light)) :background "gray88")
    (t :inverse-video t))
  "Face for the grey bars standing in for content that is still loading."
  :group 'octocat)

(defface octocat-merge-ready
  '((((class color) (background dark)) :foreground "#3fb950")
    (((class color) (background light)) :foreground "#1a7f37")
    (t :inherit success))
  "Face for the status of a PR that can be merged, green as on GitHub."
  :group 'octocat)

(defface octocat-filter-input
  '((t :inherit secondary-selection :extend nil))
  "Face for the search query field of the list pages, drawn like an input box."
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

(defface octocat-run-job-name
  '((t :weight bold))
  "Face for a job name in a workflow-run view."
  :group 'octocat)

(defface octocat-run-step-name
  '((t :inherit shadow))
  "Face for a step name in a workflow-run view."
  :group 'octocat)

(defface octocat-annotation-warning
  '((t :inherit warning))
  "Face for a GitHub Actions warning annotation."
  :group 'octocat)

(defface octocat-annotation-error
  '((t :inherit error))
  "Face for a GitHub Actions error annotation."
  :group 'octocat)

(defface octocat-annotation-notice
  '((t :inherit font-lock-comment-face))
  "Face for a GitHub Actions notice annotation."
  :group 'octocat)


;;;; Finding gh

(defun octocat--host ()
  "Return the GitHub host `gh' talks to, such as \"github.com\"."
  (or (getenv "GH_HOST") "github.com"))

(defun octocat--web-url (path &rest args)
  "Return the URL of the web page at PATH, formatted with ARGS, on the host.
The host is `octocat--host', so links follow `gh' to GitHub Enterprise."
  (concat "https://" (octocat--host) "/" (apply #'format path args)))

(defun octocat--gh-executable ()
  "Return the absolute file name of `octocat-gh-program', or nil.
Looked for in the variable `exec-path', then where Homebrew and
MacPorts install it: a GUI Emacs on macOS does not get the shell's PATH."
  (or (executable-find octocat-gh-program)
      (let ((exec-path '("/opt/homebrew/bin"    ; Apple-silicon Homebrew
                         "/usr/local/bin"       ; Intel Homebrew
                         "/opt/local/bin")))    ; MacPorts
        (executable-find octocat-gh-program))))


;;;; Internal helpers

(defun octocat--current-branch ()
  "Return the name of the currently checked-out local git branch, or nil.
Returns nil when HEAD is detached, the working directory is not a git
repository, or git is not on PATH.  Calls git synchronously — this is
intentional because the result is needed at render time and `git
symbolic-ref' completes in milliseconds."
  (let ((branch (string-trim
                 (shell-command-to-string
                  "git symbolic-ref --short HEAD 2>/dev/null"))))
    (and (not (string-empty-p branch)) branch)))

(defun octocat--head-info ()
  "Return a plist describing the current local HEAD, or nil.
The plist has the keys :branch (string or nil when detached), :hash
\(7-character abbreviated commit hash), and :subject (one-line commit
message).  Returns nil when the working directory is not a git
repository or git is not on PATH.  Uses a single `git log' call so it
is cheap enough to call at render time."
  (let ((raw (string-trim
              (shell-command-to-string
               "git log -1 --abbrev=11 --format=%D%x00%h%x00%s HEAD 2>/dev/null"))))
    (when (not (string-empty-p raw))
      (let* ((parts   (split-string raw "\0"))
             (refs    (nth 0 parts))
             (hash    (nth 1 parts))
             (subject (nth 2 parts))
             ;; Extract the branch name from the refs field (e.g. "HEAD ->
             ;; main, origin/main" → "main").  Falls back to nil for detached
             ;; HEAD where the refs field has no "HEAD ->" component.
             (branch  (when (string-match "HEAD -> \\([^,\n]+\\)" refs)
                        (match-string 1 refs))))
        (list :branch branch :hash hash :subject subject)))))

(defun octocat--author-login (obj)
  "Return \"@LOGIN\" for the GitHub author of OBJ, or \"\" when unavailable.
OBJ is any hash-table that has an \\\"author\\\" key whose value is a GitHub
user object with a \\\"login\\\" field — e.g. a PR, issue, review, or comment
hash-table as returned by the gh CLI.  Returns an empty string when the
author field is absent, null, or carries no login."
  (let* ((author (gethash "author" obj))
         (login  (and author
                      (not (eq author :null))
                      (gethash "login" author))))
    (if (and login (not (string-empty-p login)))
        (concat "@" login)
      "")))

(defun octocat--commit-author (commit)
  "Return a compact author string for COMMIT, for use in list rows.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Prefers the GitHub handle: if the top-level \\\"author\\\" user object has a
\\\"login\\\" field the result is \\\"@LOGIN\\\".  Falls back to the git author
name from the nested \\\"commit\\\" → \\\"author\\\" → \\\"name\\\" field
when the
commit is not associated with a GitHub account.  Returns \"\" when neither
is available.  For detail views where space allows, use
`octocat--commit-author-full' instead."
  (let* ((gh-user (gethash "author" commit))
         (login   (and gh-user
                       (not (eq gh-user :null))
                       (gethash "login" gh-user)))
         (c       (gethash "commit" commit))
         (ca      (and c (gethash "author" c))))
    (cond
     ((and login (not (string-empty-p login)))
      (concat "@" login))
     ((and ca (octocat--nonempty (gethash "name" ca)))
      (gethash "name" ca))
     (t ""))))

(defun octocat--commit-author-full (commit)
  "Return a git-log-style author string for COMMIT, for use in detail views.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Returns \\\"Name  <email>\\\" from the nested git identity fields, including
only the parts that are present and non-empty:

  Saulius Menkevičius  <sauliusmenkevicius@fastmail.com>

The GitHub handle is intentionally excluded; callers that want it should
call `octocat--commit-author-login' separately and render it on its own
line.  For compact list rows where horizontal space is constrained, use
`octocat--commit-author' instead."
  (let* ((c     (gethash "commit" commit))
         (ca    (and c (gethash "author" c)))
         (name  (and ca (octocat--nonempty (gethash "name"  ca))))
         (email (and ca (octocat--nonempty (gethash "email" ca)))))
    (cond
     ((and name email) (format "%s  <%s>" name email))
     (name             name)
     (email            (format "<%s>" email))
     (t                ""))))

(defun octocat--commit-date (commit)
  "Return the timestamp COMMIT was committed at, as GitHub's lists show.
COMMIT is shaped as the REST commits endpoint has it.  Its author date
when it has none, as a commit stored before octocat asked for both."
  (let* ((c   (gethash "commit" commit))
         (get (lambda (role)
                (let ((who (and (hash-table-p c) (gethash role c))))
                  (and (hash-table-p who) (octocat--nonempty (gethash "date" who)))))))
    (or (funcall get "committer") (funcall get "author") "")))

(defun octocat--commit-author-login (commit)
  "Return \\\"@login\\\" for the GitHub account linked to COMMIT, or nil.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Returns nil when the commit email is not associated with any GitHub account,
so callers can omit the GitHub line entirely in that case."
  (let* ((gh-user (gethash "author" commit))
         (login   (and gh-user
                       (not (eq gh-user :null))
                       (octocat--nonempty (gethash "login" gh-user)))))
    (and login (concat "@" login))))

(defun octocat--debug-log (label data)
  "When `octocat-debug' is non-nil, append LABEL and DATA to *octocat-debug*."
  (when octocat-debug
    (with-current-buffer (get-buffer-create "*octocat-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] "))
      (insert label "\n")
      (insert data "\n\n"))))

(defvar octocat--gh-owner nil
  "What the `gh' calls started now belong to, so they can be stopped together.
A sync fetch binds it to its token (see `octocat-sync--fetches'); a call
started from another's callback belongs to the same owner, so a fetch
of several calls is stopped whole.")

(defvar octocat--gh-reason nil
  "Why the `gh' calls started now run, such as `page' or `poll'.
For `octocat--gh-log'; bound and passed on as `octocat--gh-owner' is.")

(defvar octocat--gh-log nil
  "The `gh' calls of the last hour, newest first, for `octocat-doctor'.
Each is a vector [START END NAME OK REASON BYTES]; END and BYTES, the
size of what `gh' printed, are nil while it runs.")

(defun octocat--gh-log-start (name now)
  "Record a `gh' call NAME starting at NOW, and return its entry.
Calls over an hour old are dropped."
  (let ((entry (vector now nil name nil octocat--gh-reason nil)))
    (setq octocat--gh-log
          (cons entry (seq-take-while (lambda (e) (> (aref e 0) (- now 3600)))
                                      octocat--gh-log)))
    entry))

(defun octocat--gh-stop (owner)
  "Stop OWNER's `gh' processes, each then answering as failed."
  (when owner
    (dolist (proc (process-list))
      (when (and (eq (process-get proc 'octocat-owner) owner) (process-live-p proc))
        (kill-process proc)))))

(defun octocat--run-gh (name args parse-fn callback)
  "Run `gh' asynchronously with ARGS and call CALLBACK with the result.
NAME is a short identifier used for the process and temp-buffer names.
ARGS is a list of string arguments passed directly to the `gh' executable.
PARSE-FN is called with the raw output string on success; its return value
is forwarded to CALLBACK.  On a `gh' non-zero exit or a parse failure,
CALLBACK receives a cons cell \\=(error . MESSAGE) where MESSAGE is the
human-readable reason.  A call still running after `octocat-gh-timeout'
is stopped, and so is answered too.  Errors raised inside CALLBACK
propagate normally so they appear in the *Backtrace* buffer."
  (let* ((gh-executable (octocat--gh-executable)))
    (if (not gh-executable)
        (funcall callback '(error . "`gh' executable not found"))
      (let* ((owner   octocat--gh-owner)
             (reason  octocat--gh-reason)
             (entry   (octocat--gh-log-start name (float-time)))
             (buf     (generate-new-buffer (format " *octocat-gh-%s*" name)))
             (err-buf (generate-new-buffer (format " *octocat-gh-%s-stderr*" name)))
             (cmd     (cons gh-executable args))
             (process-environment (cons "NO_COLOR=1" process-environment)))
        (octocat--gh-track
         owner
         (make-process
          :name (format "octocat-gh-%s" name)
          :buffer buf
          :stderr err-buf
          :command cmd
          :sentinel
          (lambda (proc _event)
            ;; Every way it can end, a signal included: a call left
            ;; unanswered would keep its page loading for good.
            (unless (process-live-p proc)
              (when-let* ((timer (process-get proc 'octocat-deadline)))
                (cancel-timer timer))
              ;; Collect output before buffers are killed.
              (let* ((exit-code (if (eq (process-status proc) 'exit)
                                    (process-exit-status proc)
                                  -1))
                     (timed-out (process-get proc 'octocat-timed-out))
                     (output    (with-current-buffer (process-buffer proc)
                                  (buffer-string)))
                     (stderr    (with-current-buffer err-buf
                                  (buffer-string))))
                (aset entry 1 (float-time))
                (aset entry 3 (= exit-code 0))
                (aset entry 5 (string-bytes output))
                (kill-buffer (process-buffer proc))
                (when (buffer-live-p err-buf)
                  ;; The stderr pipe-process attached by `make-process :stderr'
                  ;; may still be live when the sentinel fires, causing Emacs to
                  ;; prompt "has running process; kill it?" interactively.
                  ;; Delete it explicitly first so `kill-buffer' is unconditional.
                  (let ((pipe (get-buffer-process err-buf)))
                    (when pipe (delete-process pipe)))
                  (kill-buffer err-buf))
                (octocat--debug-log
                 (format "gh %s exit-code: %d" name exit-code) output)
                (octocat--debug-log
                 (format "gh %s stderr" name) stderr)
                ;; Resolve to a parsed value or an (error . msg) cell.
                ;; The condition-case only covers parse-fn; callback runs
                ;; outside it so renderer errors surface as real Lisp errors.
                (let ((result
                       (if (= exit-code 0)
                           (condition-case err
                               (funcall parse-fn output)
                             (error (cons 'error (error-message-string err))))
                         (cons 'error
                               (cond
                                (timed-out
                                 (format "GitHub did not answer within %ss (timed out)"
                                         timed-out))
                                ((not (string-empty-p (string-trim stderr)))
                                 (string-trim stderr))
                                ((< exit-code 0)
                                 (format "gh was stopped (%s)" (process-status proc)))
                                (t (format "gh exited with code %d" exit-code)))))))
                  (let ((octocat--gh-owner owner)
                        (octocat--gh-reason reason))
                    (funcall callback result))))))))))))

(defun octocat--gh-track (owner proc)
  "Mark PROC, a `gh' call, as OWNER's, and stop it after `octocat-gh-timeout'."
  (process-put proc 'octocat-owner owner)
  (when octocat-gh-timeout
    (process-put proc 'octocat-deadline
                 (run-at-time octocat-gh-timeout nil
                              (lambda ()
                                (when (process-live-p proc)
                                  (process-put proc 'octocat-timed-out octocat-gh-timeout)
                                  (kill-process proc))))))
  proc)

(defun octocat--parse-json-list (json-string)
  "Parse JSON-STRING from gh into a list of hash-tables.
Returns a list of hash-tables, or signals `error' on failure.
An empty or null response is treated as an empty list."
  (let ((trimmed (string-trim json-string)))
    (cond
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

(defun octocat--comment-numeric-id (comment)
  "Return the numeric REST comment ID string from COMMENT hash-table.
The ID is parsed from the comment's \\\"url\\\" field, which ends in
\\\"#issuecomment-NNNNN\\\".  Returns nil if the URL is absent or malformed."
  (let ((url (and comment (gethash "url" comment))))
    (when (and url (stringp url)
               (string-match "#issuecomment-\\([0-9]+\\)\\'" url))
      (match-string 1 url))))

(defun octocat--get (obj &rest keys)
  "Return the value under KEYS in the nested hash-table OBJ, or nil.
Missing keys, non-table intermediates and JSON null all give nil."
  (while (and keys (hash-table-p obj))
    (setq obj (gethash (pop keys) obj)))
  (and (null keys) (not (eq obj :null)) obj))

(defun octocat--nonempty (value)
  "Return VALUE if it is a non-empty, non-null string, otherwise nil.
Treats the JSON null sentinel `:null' and empty strings as absent values."
  (and value
       (not (eq value :null))
       (stringp value)
       (not (string-empty-p value))
       value))

(defconst octocat--reactions
  '(("THUMBS_UP" "+1" "👍") ("THUMBS_DOWN" "-1" "👎") ("LAUGH" "laugh" "😄")
    ("HOORAY" "hooray" "🎉") ("CONFUSED" "confused" "😕") ("HEART" "heart" "❤️")
    ("ROCKET" "rocket" "🚀") ("EYES" "eyes" "👀"))
  "GitHub's reactions, in the order it shows them.
Each is (CONTENT KEY EMOJI): its name in GraphQL and in the REST API.")

(defun octocat--reaction-counts (obj)
  "Return the reactions to OBJ as ((EMOJI . COUNT) ...), in GitHub's order.
OBJ is an issue, PR, comment or review from `gh ... view', which has
\"reactionGroups\", or a comment from the REST API, which has
\"reactions\".  Reactions nobody gave are left out."
  (let ((groups (octocat--get obj "reactionGroups"))
        (rest   (octocat--get obj "reactions")))
    (delq nil
          (mapcar (pcase-lambda (`(,content ,key ,emoji))
                    (let ((n (if (hash-table-p rest)
                                 (gethash key rest)
                               (seq-some (lambda (g)
                                           (and (equal (octocat--get g "content") content)
                                                (octocat--get g "users" "totalCount")))
                                         (and (sequencep groups) groups)))))
                      (and (natnump n) (> n 0) (cons emoji n))))
                  octocat--reactions))))

(defun octocat--reactions-string (obj)
  "Return the reactions to OBJ as \"👍 2  🎉 1\", or nil when it has none.
OBJ is as for `octocat--reaction-counts'."
  (when-let* ((counts (octocat--reaction-counts obj)))
    (mapconcat (lambda (c)
                 (concat (car c) " "
                         (propertize (number-to-string (cdr c)) 'face 'octocat-dimmed)))
               counts "  ")))

(defun octocat--toggle-reaction (groups content add)
  "Return GROUPS, a \"reactionGroups\" vector, with one CONTENT more, or less.
ADD non-nil adds one, else takes one away.  GROUPS is not changed."
  (let* ((groups (append groups nil))
         (old    (seq-find (lambda (g) (equal (octocat--get g "content") content)) groups))
         (n      (max 0 (+ (or (octocat--get old "users" "totalCount") 0) (if add 1 -1))))
         (new    (make-hash-table :test #'equal))
         (users  (make-hash-table :test #'equal)))
    (puthash "totalCount" n users)
    (puthash "content" content new)
    (puthash "users" users new)
    (vconcat (if old
                 (mapcar (lambda (g) (if (eq g old) new g)) groups)
               (append groups (list new))))))

(defun octocat--run-icon (status conclusion)
  "Return a propertized status icon for STATUS and CONCLUSION strings.
STATUS takes priority over CONCLUSION for in-progress detection."
  (let ((st (downcase (or status "")))
        (co (let ((c (octocat--nonempty conclusion))) (and c (downcase c)))))
    (cond
     ((equal st "in_progress")
      (propertize "●" 'face 'octocat-ci-pending))
     ((equal co "success")
      (propertize "✓" 'face 'octocat-ci-success))
     ((member co '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "✗" 'face 'octocat-ci-failure))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--run-duration (started completed)
  "Return a human-readable duration string between STARTED and COMPLETED.
Both are ISO-8601 timestamp strings, or nil/:null.  Returns nil when
either timestamp is unavailable."
  (when (and started
             (not (eq started :null))
             completed
             (not (eq completed :null))
             (not (string-empty-p started))
             (not (string-empty-p completed)))
    (condition-case nil
        (let* ((t1 (float-time (date-to-time started)))
               (t2 (float-time (date-to-time completed)))
               (secs (max 0 (round (- t2 t1)))))
          (cond
           ((< secs 60)   (format "%ds" secs))
           ((< secs 3600) (format "%dm%02ds" (/ secs 60) (% secs 60)))
           (t             (format "%dh%02dm" (/ secs 3600) (/ (% secs 3600) 60)))))
      (error nil))))

(defun octocat--ci-status (pr)
  "Return a one-character CI-status indicator for PR hash-table PR.
Returns \"✓\" (success), \"✗\" (failure), or \"●\" (pending/unknown).
A list row's PR carries GitHub's rolled-up \"ciState\" instead of the
checks themselves (see `octocat--flatten-list-item')."
  (if-let* ((state (octocat--nonempty (gethash "ciState" pr))))
      (octocat--outcomes-ci-status (list state))
    (octocat--checks-ci-status (gethash "statusCheckRollup" pr))))

(defun octocat--checks-ci-status (checks)
  "Return a CI-status indicator, as `octocat--ci-status' does.
The status is that of CHECKS, a `statusCheckRollup' sequence, or nil or
:null.  A check's outcome is its conclusion (a check-run) or its state
\(a commit status); one with neither is still running."
  (octocat--outcomes-ci-status
   (and checks (not (eq checks :null))
        (mapcar (lambda (c)
                  (upcase (or (octocat--nonempty (gethash "conclusion" c))
                              (octocat--nonempty (gethash "state" c))
                              "PENDING")))
                checks))))

(defun octocat--outcomes-ci-status (outcomes)
  "Return the CI-status indicator of OUTCOMES, a list of upcased states."
  (cond
   ((cl-some (lambda (s) (member s '("FAILURE" "ERROR" "TIMED_OUT"))) outcomes)
    (propertize "✗" 'face 'octocat-ci-failure))
   ((cl-every (lambda (s) (member s '("SUCCESS" "NEUTRAL" "SKIPPED"))) outcomes)
    (propertize "✓" 'face 'octocat-ci-success))
   (t
    (propertize "●" 'face 'octocat-ci-pending))))

(defun octocat--ci-label (pr)
  "Return a short labelled CI-status string for PR hash-table PR.
Combines a dimmed \"CI:\" prefix with the coloured status icon from
`octocat--ci-status', e.g. \"CI: ✓\" or \"CI: ✗\"."
  (concat (propertize "CI:" 'face 'octocat-dimmed)
          " "
          (octocat--ci-status pr)))

(defun octocat--ci-count-label (pr)
  "Return PR's CI status as GitHub's list has it, e.g. \"✓ 5/5\".
Without the counts (see `octocat--flatten-list-item') it is
`octocat--ci-label'."
  (if-let* ((total (gethash "ciTotal" pr))
            ((> total 0)))
      (concat (octocat--ci-status pr) " "
              (propertize (format "%d/%d" (gethash "ciPassed" pr) total)
                          'face 'octocat-dimmed))
    (octocat--ci-label pr)))

;;;; Settings
;;
;; An alist of (KEY . VALUE) in `octocat-settings-file', read afresh on
;; each lookup so Emacs sessions running side by side agree.

(defun octocat--settings-load ()
  "Return the settings alist, or nil when the file is absent or unreadable."
  (when (file-readable-p octocat-settings-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents octocat-settings-file)
          (let ((data (read (current-buffer))))
            (and (listp data) data)))
      (error nil))))

(defun octocat--setting (key)
  "Return the value of the setting KEY, compared with `equal', or nil."
  (alist-get key (octocat--settings-load) nil nil #'equal))

(defun octocat--setting-put (key value)
  "Save VALUE as the setting KEY, or remove KEY when VALUE is nil."
  (let ((data (octocat--settings-load)))
    (setf (alist-get key data nil t #'equal) value)
    (make-directory (file-name-directory octocat-settings-file) t)
    (with-temp-file octocat-settings-file
      (let ((print-length nil) (print-level nil))
        (prin1 data (current-buffer))
        (insert "\n")))))

;;;; Timestamp formatting

(defun octocat--format-ts (ts)
  "Format an ISO-8601 UTC timestamp TS as \"YYYY-MM-DD HH:MM\" in local time.
Returns an empty string for nil, :null, or an empty string.
Falls back to the raw date prefix if the string cannot be parsed."
  (if (or (null ts) (eq ts :null) (string-empty-p ts))
      ""
    (condition-case nil
        (format-time-string "%Y-%m-%d %H:%M" (date-to-time ts))
      (error (substring ts 0 (min 10 (length ts)))))))

(defun octocat--relative-ts (ts)
  "Return a human-readable relative string for ISO-8601 UTC timestamp TS.
Examples: \"just now\", \"5 minutes ago\", \"3 days ago\", \"2 years ago\".
Returns an empty string for nil, :null, or an empty string.

Implemented in plain Emacs Lisp using `float-time' and `current-time'.
Does not call into any external package."
  (if (or (null ts) (eq ts :null) (string-empty-p ts))
      ""
    (condition-case nil
        (let* ((then  (float-time (date-to-time ts)))
               (now   (float-time (current-time)))
               (secs  (max 0 (round (- now then)))))
          (cond
           ((< secs 60)
            "just now")
           ((< secs 3600)
            (let ((m (round (/ secs 60))))
              (format "%d %s ago" m (if (= m 1) "minute" "minutes"))))
           ((< secs 86400)
            (let ((h (round (/ secs 3600))))
              (format "%d %s ago" h (if (= h 1) "hour" "hours"))))
           ((< secs 604800)
            (let ((d (round (/ secs 86400))))
              (format "%d %s ago" d (if (= d 1) "day" "days"))))
           ((< secs 2592000)
            (let ((w (round (/ secs 604800))))
              (format "%d %s ago" w (if (= w 1) "week" "weeks"))))
           ((< secs 31536000)
            (let ((mo (round (/ secs 2592000))))
              (format "%d %s ago" mo (if (= mo 1) "month" "months"))))
           (t
            (let ((y (round (/ secs 31536000))))
              (format "%d %s ago" y (if (= y 1) "year" "years"))))))
      (error ""))))

(defun octocat--format-ts-relative (ts)
  "Format TS as a relative age carrying the exact time.
The text is `octocat--relative-ts' (\"3 days ago\"); the local date and
time, e.g. \"Mon 2026-06-08 14:23:05 EEST\", is its `help-echo' (shown
on mouse hover) and its `octocat-ts' property (shown by ElDoc when point
rests on it, see `octocat--ts-eldoc-setup').  Returns an empty string
for nil, :null, or an empty string, and the absolute
`octocat--format-ts' when TS cannot be parsed into an age.

Use this wherever a timestamp is shown to the user."
  (let ((rel (octocat--relative-ts ts)))
    (if (string-empty-p rel)
        (octocat--format-ts ts)
      (let ((exact (format-time-string "%a %Y-%m-%d %H:%M:%S %Z"
                                       (date-to-time ts))))
        (propertize rel 'help-echo exact 'octocat-ts exact)))))

(defun octocat--ts-eldoc (&rest _)
  "Return the exact time of the timestamp at point, or nil.
Also the whole of a cut text at point, its `octocat-full-text'.  An
`eldoc-documentation-functions' member."
  (or (get-text-property (point) 'octocat-ts)
      (get-text-property (point) 'octocat-full-text)))

(defun octocat--key-help (command action)
  "Return the `help-echo' of a button running COMMAND to do ACTION.
It names COMMAND's key in the current buffer, as in \"RET, KEY: hide
the comments\", and ElDoc shows it when point rests on the button, so
the key is learnt from the button (see `octocat--ts-eldoc-setup').
Without a key it is just \"RET: ACTION\"."
  (if-let* ((key (where-is-internal command nil t)))
      ;; C-m and C-i are the RET and TAB characters, which `key-description'
      ;; names so; after a prefix they are typed, and documented, as C-m.
      (propertize (format "RET, %s: %s"
                          (if (cdr (append key nil))
                              (mapconcat (lambda (ev)
                                           (pcase ev
                                             (?\C-m "C-m")
                                             (?\C-i "C-i")
                                             (_ (single-key-description ev))))
                                         key " ")
                            (key-description key))
                          action)
                  'octocat-key-help t)
    (concat "RET: " action)))

(defun octocat--button-help (help on-click)
  "Return HELP, a \"RET: ACTION\" hint, naming ON-CLICK's key if it has one.
ON-CLICK is what the button runs; only a command, a symbol, can have a
key (see `octocat--key-help')."
  (if (and on-click (symbolp on-click) (stringp help)
           (string-prefix-p "RET: " help))
      (octocat--key-help on-click (substring help 5))
    help))

(defun octocat--key-help-eldoc (&rest _)
  "Return the key hint of the button at point, or nil.
An `eldoc-documentation-functions' member; see `octocat--key-help'."
  (let ((help (get-text-property (point) 'help-echo)))
    (and (stringp help)
         (get-text-property 0 'octocat-key-help help)
         help)))

(defun octocat--link-eldoc (&rest _)
  "Return the target of the link or reference at point, or nil.
That is a link's URL, or a #123 or commit reference with its repository
and full SHA; nil when the link's text already says it.  An
`eldoc-documentation-functions' member."
  (let* ((ref    (get-text-property (point) 'octocat-markdown-ref))
         (prop   (if ref 'octocat-markdown-ref 'octocat-markdown-url))
         (target (if ref
                     (pcase-let* ((`(,kind ,repo ,id) ref)
                                  (repo (or repo (octocat--search-repo--current-repo))))
                       (if (eq kind 'issue)
                           (format "%s#%d" (or repo "") id)
                         (concat repo (and repo "@") id)))
                   (get-text-property (point) prop))))
    (when target
      (let ((text (buffer-substring-no-properties
                   (previous-single-property-change (1+ (point)) prop nil (point-min))
                   (next-single-property-change (point) prop nil (point-max)))))
        (unless (string-search target text)
          target)))))

(defun octocat--ts-eldoc-setup ()
  "Show what point rests on in the echo area.
That is the exact time of a timestamp, the whole of a cut title, where a
link goes (see `octocat--link-eldoc'), or the key of a button that has
one (see `octocat--key-help').  Call from a major-mode body.  ElDoc
shows it after `eldoc-idle-delay' when `global-eldoc-mode' is on (the
default)."
  (add-hook 'eldoc-documentation-functions #'octocat--ts-eldoc nil t)
  (add-hook 'eldoc-documentation-functions #'octocat--link-eldoc nil t)
  (add-hook 'eldoc-documentation-functions #'octocat--key-help-eldoc nil t)
  ;; vui motions, so ElDoc reacts to them like to `next-line'.
  (eldoc-add-command-completions "vui-forward" "vui-backward"))


;;;; Markdown rendering

(defvar-local octocat--markdown-raw nil
  "Non-nil means show markdown body text verbatim instead of rendered.
When nil (the default) body text is rendered by
`octocat-markdown-render'.  Toggle with `octocat-toggle-markdown'.")

(defvar-local octocat--refresh-fn nil
  "Buffer-local refresh function called by `octocat-toggle-markdown'.
Each markdown-displaying mode sets this to its own refresh command so the
toggle can re-render the buffer after flipping `octocat--markdown-raw'.")

(defun octocat--markdown-string (text indent raw width)
  "Return TEXT rendered by `octocat-markdown-render', one line per row.
Each line is prefixed with INDENT (a string, nil for \"  \") and ends in a
newline; INDENT is also repeated on the wrapped continuation lines of
long lines.

When RAW is non-nil the text is returned verbatim, without any
rendering.  Otherwise images uploaded to GitHub can be shown in the
current buffer, see `octocat-image-enable'.

WIDTH is the columns to fit, as for `octocat-markdown-render'; callers
read it from the window once, with `octocat--markdown-width'."
  (if raw
      (octocat-markdown-render-verbatim text indent)
    (octocat-image-enable)
    (octocat-markdown-render text indent width)))

(defun octocat--markdown-width ()
  "Return the columns rendered markdown should fit in the current buffer.
That is the number of characters that fit a line of the window showing
the buffer (else of the selected window).  Emacs already leaves out the
last column where it is taken by the continuation glyph (a terminal, or
a window without fringes), so a full line does not wrap.

`window-max-chars-per-line' selects the window, which resets the buffer's
point to the window's point; mid-render that scrambles the page, so
point is saved around it."
  (octocat--cap-width
   (save-excursion
     (window-max-chars-per-line (or (get-buffer-window (current-buffer) t)
                                    (selected-window))))))

;;;; Width cap

(defvar-local octocat--capped nil
  "Non-nil when the page's text is capped at `octocat-max-width' columns.")

(defun octocat--max-width-setup ()
  "Cap the current buffer's page at `octocat-max-width' columns."
  (setq-local octocat--capped t))

(defun octocat--cap-width (width)
  "Return WIDTH, no more than `octocat-max-width' on a capped page."
  (if (and octocat--capped octocat-max-width)
      (min width octocat-max-width)
    width))

;;;; Power

;; From battery.el, loaded on first use.
(defvar battery-status-function)
(defvar battery-load-low)

(defun octocat--power-state (status low)
  "Return the power state STATUS describes: `mains', `battery' or `low'.
STATUS is as `battery-status-function' returns it; `low' is on battery
at or below LOW percent.  No battery, or none reported, is `mains'."
  (let ((line (alist-get ?L status))
        (load (alist-get ?p status)))
    (cond ((not (and (stringp line)
                     ;; Each backend names it its own way.
                     (or (member line '("off-line" "BAT"))
                         (string-prefix-p "Battery" line))))
           'mains)
          ((and (stringp load) (string-match-p "\\`[0-9.]+\\'" load)
                (<= (string-to-number load) low))
           'low)
          (t 'battery))))

(defvar octocat--power nil
  "The last power state read, as (TIME . STATE), see `octocat-power'.")

(defun octocat-power ()
  "Return the power state: `mains', `battery' or `low' (`battery-load-low').
Read at most once a minute, as on macOS it runs `pmset'."
  (let ((now (float-time)))
    (unless (and octocat--power (< (- now (car octocat--power)) 60))
      (setq octocat--power
            (cons now (octocat--power-state
                       (and (require 'battery nil t)
                            battery-status-function
                            (condition-case err
                                (funcall battery-status-function)
                              (error (octocat--debug-log "battery status failed"
                                                         (error-message-string err))
                                     nil)))
                       (or (bound-and-true-p battery-load-low) 25)))))
    (cdr octocat--power)))

;;;; Long lines and large content
;;
;; Emacs draws long lines fast since 29.1, but highlighting or
;; rendering a large file takes seconds, and a long line is unreadable
;; anyway.  See "Long lines and large content" in
;; docs/user-interface-conventions.md.

(defconst octocat--max-line-length 1000
  "Most characters of a line of a file, diff or log shown before a button.")

(defconst octocat--max-file-size (* 256 1024)
  "Largest file, in bytes, fetched, highlighted or rendered unasked.")

(defun octocat--show-hidden ()
  "Show the rest of the line that the button at point stands for."
  (interactive)
  (let ((inhibit-read-only t)
        (beg (if (get-text-property (1- (point)) 'octocat-hidden)
                 (previous-single-property-change (point) 'octocat-hidden nil (pos-bol))
               (point))))
    (remove-text-properties
     beg (next-single-property-change (point) 'octocat-hidden nil (pos-eol))
     '(octocat-hidden nil display nil keymap nil mouse-face nil help-echo nil))))

(defvar octocat--hidden-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'octocat--show-hidden)
    (define-key map [mouse-2] #'octocat--show-hidden)
    map)
  "Keymap of the button standing for the rest of a long line.")

(defun octocat--image-file-p (name)
  "Return non-nil when file NAME is an image, by its extension."
  (string-match-p "\\.\\(?:png\\|jpe?g\\|gif\\|svg\\|webp\\|bmp\\|ico\\|tiff?\\)\\'"
                  (downcase name)))

(defun octocat--image-text (content width)
  "Return a line showing image CONTENT, no wider than WIDTH columns.
Where it cannot be shown, as in a terminal, the line says so."
  (let ((type (image-type-from-data content)))
    (if (and type (display-images-p) (image-type-available-p type))
        ;; At its own size: `image-scaling-factor' would blur it.
        (propertize " " 'display (create-image content type t :scale 1
                                               :max-width (* width (frame-char-width))))
      (propertize (format "An image of %s; C-c C-o opens it on GitHub."
                          (file-size-human-readable (length content)))
                  'face 'octocat-dimmed))))

(defun octocat--clip-line (line max)
  "Return LINE with all past MAX characters drawn as a button to reveal them.
As `compilation-max-output-line-length' does: the text stays, so it is
copied and searched whole, and keeps its faces when shown."
  (if (<= (length line) max)
      line
    (concat (substring line 0 max)
            (propertize (substring line max)
                        'octocat-hidden t
                        'display (propertize (format "[… %d more characters]"
                                                     (- (length line) max))
                                             'face 'octocat-dimmed)
                        'keymap octocat--hidden-map
                        'mouse-face 'highlight
                        'help-echo "RET: show the whole line"))))

(defun octocat--clip-lines (text max)
  "Return TEXT with its lines past MAX characters clipped.
See `octocat--clip-line'."
  (mapconcat (lambda (l) (octocat--clip-line l max)) (split-string text "\n") "\n"))

(defun octocat--markdown-open-ref (kind repo id)
  "Open the reference of KIND (`issue' or `commit') ID in REPO.
A nil REPO means the repository of the current buffer.  An issue number
may belong to a pull request, which the GitHub API tells apart, so that
is asked first and the matching view opened."
  (let ((repo (or repo (octocat--search-repo--current-repo)
                  (user-error "Octocat: no repository to look %s up in" id))))
    (pcase kind
      ('commit (octocat-commit-open repo id))
      ('issue
       (message "Octocat: opening %s#%d…" repo id)
       (let ((buf (current-buffer)))
         (octocat--run-gh
          "resolve-ref"
          (list "api" (format "repos/%s/issues/%d" repo id) "--jq" ".pull_request != null")
          #'string-trim
          (octocat--display-later
           (lambda (result)
             (cond ((eq (car-safe result) 'error)
                    (message "Octocat: cannot open %s#%d: %s" repo id (cdr result)))
                   ((not (octocat--still-selected-p buf))
                    (message "Octocat: not opening %s#%d, as you moved on" repo id))
                   ((equal result "true") (octocat-pr-open repo id))
                   (t (octocat-issue-open repo id)))))))))))

;;;; Syntax highlighting

(defun octocat--set-mode-for-path (path)
  "Set the current buffer's major mode as for repository file PATH.
PATH is relative to the repository root.  Mode hooks are delayed."
  ;; Rooted, as some patterns, such as Dockerfile's, need a "/" before
  ;; the name.
  (with-demoted-errors "Octocat: cannot highlight: %S"
    (let ((buffer-file-name (concat "/" path)))
      (delay-mode-hooks (set-auto-mode)))))

;;;; github.com links
;;
;; github.com links octocat has a view for open in it: always from its
;; own pages (`octocat-follow-url'), and from anywhere in Emacs, through
;; `browse-url-handlers', while `octocat-github-links-mode' is on.
;; Other links go to `browse-url', which lets any package's handler claim
;; them; "open in browser" commands use `octocat-browse-external'.

(declare-function octocat-pr-diff-open  "octocat-pr-diff"  (repo number))
(declare-function octocat-pr-commits-open "octocat-pr"    (repo number))
(declare-function octocat-compare-open  "octocat-compare"  (repo base dots head))
(declare-function octocat-run-open      "octocat-run"      (repo run-id))
(declare-function octocat-job-open      "octocat-job"      (repo run-id job-id name))
(declare-function octocat-workflow-open "octocat-workflow" (repo id name path))
(declare-function octocat-user-open     "octocat-user"     (login))
(declare-function octocat-commit-list-open  "octocat-repo"     (repo &optional ref path))
(declare-function octocat-tree-open     "octocat-repo"     (repo &optional ref path))
(declare-function octocat-tree--open-file-by-path "octocat-tree" (repo branch path))
(declare-function octocat-issue-list    "octocat"          (&optional repo))
(declare-function octocat-pr-list       "octocat"          (&optional repo))
(declare-function octocat-actions       "octocat"          (&optional repo))

(defconst octocat--github-reserved-paths
  '("about" "account" "apps" "codespaces" "collections" "contact" "copilot"
    "customer-stories" "dashboard" "enterprise" "events" "explore" "features"
    "issues" "join" "login" "logout" "marketplace" "new" "notifications"
    "organizations" "orgs" "pricing" "pulls" "search" "security" "settings"
    "site" "sponsors" "stars" "team" "topics" "trending" "users" "watching")
  "First path segments of github.com pages that are not a user or org.")

(defun octocat--github-url-target (url)
  "Return the octocat view of github.com URL as (KIND ARGS...), or nil.
KIND is `user', `repo', `pr', `pr-diff', `pr-commits', `issue', `commit',
`compare', `run', `job', `workflow', `pr-list', `issue-list', `actions',
`tree', `commit-list' or `blob', the last for a /raw/ link too; nil means
octocat has no view for URL.  The
ARGS of the last three are the repo and the path segments after the
kind, a ref and then a path: a ref may have slashes, so which segments
are the ref takes asking GitHub, see `octocat--open-ref-path'.  A
`compare' URL needs both refs: with one, GitHub picks the base."
  (when (string-match "\\`https?://\\(?:www\\.\\)?github\\.com\\(/[^?#]*\\)?\\(?:[?#].*\\)?\\'"
                      url)
    (let* ((parts (split-string (or (match-string 1 url) "") "/" t))
           (num   (lambda (s) (and (string-match-p "\\`[0-9]+\\'" s) (string-to-number s))))
           (sha   (lambda (s) (and (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" s) s))))
      (pcase parts
        (`(,owner)
         (and (not (member owner octocat--github-reserved-paths)) (list 'user owner)))
        ((and `(,owner ,name . ,rest)
              (guard (not (member owner octocat--github-reserved-paths))))
         (let ((repo (concat owner "/" (string-remove-suffix ".git" name))))
           (pcase rest
             ('nil (list 'repo repo))
             ('("pulls") (list 'pr-list repo))
             ('("issues") (list 'issue-list repo))
             ('("actions") (list 'actions repo))
             (`("tree" . ,segs)
              `(tree ,repo ,@(mapcar #'url-unhex-string segs)))
             (`("commits" . ,segs)
              `(commit-list ,repo ,@(mapcar #'url-unhex-string segs)))
             ;; A file's raw bytes, as an image's, open in the viewer too.
             (`(,(or "blob" "raw") ,ref ,file . ,segs)
              `(blob ,repo ,@(mapcar #'url-unhex-string (cons ref (cons file segs)))))
             (`("pull" ,n "commits" ,s . ,_)
              (and (funcall num n) (funcall sha s) (list 'commit repo s)))
             (`("pull" ,n "commits")
              (and (funcall num n) (list 'pr-commits repo (funcall num n))))
             (`("pull" ,n "files" . ,_)
              (and (funcall num n) (list 'pr-diff repo (funcall num n))))
             (`("pull" ,n . ,_) (and (funcall num n) (list 'pr repo (funcall num n))))
             (`("issues" ,n . ,_) (and (funcall num n) (list 'issue repo (funcall num n))))
             (`("commit" ,s . ,_) (and (funcall sha s) (list 'commit repo s)))
             (`("compare" . ,refs)
              (let ((range (string-join refs "/")))
                (and (string-match "\\`\\(.+?\\)\\(\\.\\.\\.?\\)\\(.+\\)\\'" range)
                     (list 'compare repo (match-string 1 range)
                           (match-string 2 range) (match-string 3 range)))))
             (`("actions" "runs" ,r "job" ,j . ,_)
              (and (funcall num r) (funcall num j)
                   (list 'job repo (funcall num r) (funcall num j))))
             (`("actions" "runs" ,r . ,_) (and (funcall num r) (list 'run repo (funcall num r))))
             (`("actions" "workflows" ,file) (list 'workflow repo file)))))))))

(defconst octocat--ref-prefixes-max 10
  "Most leading segments of a github.com path tried as a ref.")

(defun octocat--split-ref-path (segments resolved)
  "Split SEGMENTS of a github.com path into (REF . PATH), as GitHub does.
RESOLVED are the counts of leading SEGMENTS that name a ref; the most
is the ref, else the first segment.  PATH is the rest joined by
slashes, or nil when none is left."
  (let* ((n    (apply #'max 1 resolved))
         (rest (nthcdr n segments)))
    (cons (string-join (seq-take segments n) "/")
          (and rest (string-join rest "/")))))

(defun octocat--ref-prefixes-query (n)
  "Return a GraphQL query resolving N revs, $e1 and on, as p1 and on."
  (let ((is (number-sequence 1 n)))
    (format "query($owner:String!,$name:String!,%s){repository(owner:$owner,name:$name){%s}}"
            (mapconcat (lambda (i) (format "$e%d:String!" i)) is ",")
            (mapconcat (lambda (i) (format "p%d:object(expression:$e%d){oid}" i i)) is " "))))

(defun octocat--open-ref-path (repo segments open)
  "Call OPEN with the ref and the path that SEGMENTS of a REPO link name.
SEGMENTS follow \"tree\", \"commits\" or \"blob\" in the link.  A ref
may have slashes, as \"feature/x\", so with more than one segment GitHub
is asked which leading ones name one, in one query.  With none, the ref
and path are nil: the default branch."
  (if (null (cdr segments))
      (funcall open (car segments) nil)
    (let* ((n     (min (length segments) octocat--ref-prefixes-max))
           (parts (split-string repo "/")))
      (octocat--run-gh
       "ref-prefixes"
       (append (list "api" "graphql"
                     "-f" (concat "query=" (octocat--ref-prefixes-query n))
                     "-f" (concat "owner=" (car parts))
                     "-f" (concat "name=" (cadr parts)))
               (mapcan (lambda (i)
                         (list "-f" (format "e%d=%s^{commit}" i
                                            (string-join (seq-take segments i) "/"))))
                       (number-sequence 1 n)))
       (lambda (json)
         (let ((r (gethash "repository"
                           (gethash "data" (json-parse-string json :null-object nil)))))
           (seq-filter (lambda (i) (and r (gethash (format "p%d" i) r)))
                       (number-sequence 1 n))))
       (octocat--display-later
        (lambda (resolved)
          ;; Unresolved, the first segment is the ref, which the page reports.
          (let ((split (octocat--split-ref-path
                        segments (if (eq (car-safe resolved) 'error) nil resolved))))
            (funcall open (car split) (cdr split)))))))))

(defun octocat-browse-url (url &rest _)
  "Open github.com URL in the octocat view showing it.
The handler `octocat-github-links-mode' adds to `browse-url-handlers'."
  (pcase (octocat--github-url-target url)
    (`(user ,login)        (octocat-user-open login))
    (`(repo ,repo)         (octocat-visit-repo repo))
    (`(pr ,repo ,n)        (octocat-pr-open repo n))
    (`(pr-diff ,repo ,n)   (octocat-pr-diff-open repo n))
    (`(pr-commits ,repo ,n) (octocat-pr-commits-open repo n))
    ;; github.com redirects /issues/N of a PR to it, so ask which it is.
    (`(issue ,repo ,n)     (octocat--markdown-open-ref 'issue repo n))
    (`(commit ,repo ,sha)  (octocat-commit-open repo sha))
    (`(compare ,repo ,base ,dots ,head) (octocat-compare-open repo base dots head))
    (`(run ,repo ,id)      (octocat-run-open repo id))
    (`(job ,repo ,run ,id) (octocat-job-open repo run id nil))
    (`(workflow ,repo ,file)
     (octocat-workflow-open repo file file (concat ".github/workflows/" file)))
    (`(pr-list ,repo)      (octocat-pr-list repo))
    (`(issue-list ,repo)   (octocat-issue-list repo))
    (`(actions ,repo)      (octocat-actions repo))
    (`(tree ,repo . ,segs)
     (octocat--open-ref-path repo segs
                             (lambda (ref path)
                               (if path
                                   (octocat-tree-open repo ref path)
                                 (octocat-visit-repo repo ref)))))
    (`(commit-list ,repo . ,segs)
     (octocat--open-ref-path repo segs
                             (lambda (ref path) (octocat-commit-list-open repo ref path))))
    (`(blob ,repo . ,segs)
     (octocat--open-ref-path repo segs
                             (lambda (ref path)
                               (octocat-tree--open-file-by-path repo ref path))))
    (_ (user-error "Octocat: no view for %s" url))))

;; So `browse-url-with-browser-kind' skips it when asked for a browser.
(function-put 'octocat-browse-url 'browse-url-browser-kind 'internal)

(defun octocat-follow-url (url)
  "Open URL in its octocat view, or with `browse-url' if it has none."
  (if (octocat--github-url-target url)
      (octocat-browse-url url)
    (browse-url url)))

(defun octocat-browse-external (url)
  "Open URL in a browser, even one octocat or another Emacs package handles."
  (browse-url-with-browser-kind 'external url))

;;;; The URL of what is at point

(defvar-local octocat--url-function nil
  "Function of no arguments returning the URL of the page, or nil.
Each page's mode sets it.  It may look at point too, as a PR's page
does for the comment there.")

(defun octocat--ref-url (ref)
  "Return the URL of the markdown reference REF, (KIND REPO ID), or nil.
A REPO of nil is the buffer's."
  (pcase-let ((`(,kind ,repo ,id) ref))
    (when-let* ((repo (or repo (octocat--search-repo--current-repo))))
      (if (eq kind 'issue)
          ;; GitHub redirects a PR's /issues/N to its /pull/N.
          (octocat--web-url "%s/issues/%d" repo id)
        (octocat--web-url "%s/commit/%s" repo id)))))

(defun octocat--url-at-point ()
  "Return the URL of what point is on, or else of the page, or nil.
That is a link or reference in markdown, a row's `octocat-url' (see
`octocat-vui-row'), or what the page's `octocat--url-function' returns."
  (or (octocat-markdown-url-at)
      (when-let* ((ref (get-text-property (point) 'octocat-markdown-ref)))
        (octocat--ref-url ref))
      (get-text-property (point) 'octocat-url)
      (and octocat--url-function (funcall octocat--url-function))))

(defun octocat--item-url (kind repo number &optional data)
  "Return the URL of the PR or issue (KIND `pr' or `issue') NUMBER in REPO.
DATA's own `url', if it has one, has the right host on GitHub Enterprise."
  (let ((url (and data (gethash "url" data))))
    (if (stringp url) url
      (octocat--web-url "%s/%s/%d" repo (if (eq kind 'pr) "pull" "issues") number))))

(defun octocat--short-ref (url)
  "Return the short reference of URL, as GitHub writes one, or nil.
Such as owner/repo#12 for a PR or issue, owner/repo@abc1234 for a
commit, owner/repo for a repository and @login for a user."
  (let ((path (and (string-match "\\`https?://[^/]+/\\([^?#]*?\\)/?\\'" url)
                   (split-string (match-string 1 url) "/"))))
    (pcase path
      (`(,login) (and (not (string-empty-p login)) (concat "@" login)))
      (`(,owner ,name) (concat owner "/" name))
      (`(,owner ,name ,(or "pull" "issues") ,(and n (pred (string-match-p "\\`[0-9]+\\'"))))
       (format "%s/%s#%s" owner name n))
      ((or `(,owner ,name "commit" ,sha)
           `(,owner ,name "pull" ,_ "commits" ,sha))
       (and (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" sha)
            (format "%s/%s@%s" owner name (substring sha 0 7)))))))

(defun octocat-browse ()
  "Open what point is on, or else the page, in a browser.
That is a row, a comment or a link; see `octocat-copy-url'."
  (interactive)
  (let ((url (or (octocat--url-at-point)
                 (user-error "Octocat: Nothing here has a page on GitHub"))))
    (message "Octocat: Opening %s in browser…" url)
    (octocat-browse-external url)))

(defun octocat-copy-url (&optional short)
  "Copy the URL of what point is on, or else of the page, to the kill ring.
That is a link or reference in markdown, a comment, or the page itself.
With prefix argument SHORT, copy its short reference instead, such as
owner/repo#12, where it has one."
  (interactive "P")
  (let* ((url  (or (octocat--url-at-point)
                   (user-error "Octocat: Nothing here has a page on GitHub")))
         (text (or (and short (octocat--short-ref url)) url)))
    (kill-new text)
    (message "Octocat: Copied %s%s" text
             (if (and short (equal text url)) " (it has no short reference)" ""))))

(defun octocat-toggle-markdown ()
  "Toggle between rendered and raw markdown display in the current buffer.
When raw mode is active the body text is shown verbatim; when rendered mode
is active (the default) it is processed through `octocat-markdown-render'.
After toggling, the buffer is refreshed via `octocat--refresh-fn'."
  (interactive)
  (setq octocat--markdown-raw (not octocat--markdown-raw))
  (message "Markdown display: %s" (if octocat--markdown-raw "raw" "rendered"))
  (when octocat--refresh-fn
    (funcall octocat--refresh-fn)))

;;;; Repo navigation

(defvar octocat-repo--repo)
(defvar octocat-repo--local-dir)
(defvar octocat-repo--ref)

(declare-function octocat--async-search-repos "octocat-search" (&optional gate))
(declare-function octocat-user-open "octocat-user" (login))

(defun octocat-switch-repo ()
  "Search GitHub repositories or users interactively with live API queries.
Input starting with \"@\" searches users and organizations instead.
The repos and users octocat has stored that match the input show at
once, newest first.  GitHub's results, debounced by
`consult-async-input-debounce', then lead the list in GitHub's order,
the stored matches it did not return after them.

Uses `consult--read' with a custom async pipeline so Vertico, Embark,
Marginalia, and other consult-aware packages integrate seamlessly.

The selected repository is opened via `octocat-visit-repo', a selected
\"@login\" via `octocat-user-open'."
  (interactive)
  (let ((repo
         (consult--read
          (consult--async-pipeline
           (consult--async-min-input 2)
           (octocat--async-search-repos))
          :prompt   "Search GitHub repos (@ for users): "
          :category 'octocat-repo
          :sort     nil)))          ; preserve server-side ranking
    (when (and repo (not (string-empty-p (string-trim repo))))
      (let ((choice (string-trim repo)))
        (if (string-prefix-p "@" choice)
            (octocat-user-open choice)
          (octocat-visit-repo choice))))))

(declare-function octocat-search-repo "octocat-search" ())

(defun octocat-jump (&optional other)
  "Find something to open: in the current repository, or elsewhere.
Without a prefix argument OTHER, search the current repository's PRs,
issues, commits and files, as `octocat-search-repo' does.  With one, or
where there is no current repository, search other repositories and
users, as `octocat-switch-repo' does."
  (interactive "P")
  (if (or other (not (octocat--search-repo--current-repo)))
      (octocat-switch-repo)
    (octocat-search-repo)))

(defvar octocat-common-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j")    #'octocat-jump)
    (define-key map (kbd "S-<return>") #'octocat-visit-other-window)
    map)
  "Keys every octocat page shares, whatever its major mode.
Each page's mode map inherits it: the vui pages through
`octocat-vui-page-map', the others with `make-composed-keymap'.")


;;;; Repo tab strip
;;
;; The Code / Issues / Pull requests / Actions strip the repo page and the
;; list pages (issues, PRs, actions) show beside the repo name, as
;; GitHub's tabs do, drawn by `octocat-vui-repo-tabs'.  Code is the repo
;; page, as on GitHub, with the file tree on it.  Detail
;; pages leave it out; their repo name leads back to the repo page.

(defconst octocat--repo-tabs
  '((code    "Code"          "RET: open repository page"     octocat-visit-repo)
    (issues  "Issues"        "RET: list issues"              octocat-issue-list)
    (pulls   "Pull requests" "RET: list pull requests"       octocat-pr-list)
    (actions "Actions"       "RET: list workflows and runs"  octocat-actions))
  "The repo tabs: (SYMBOL LABEL HELP-ECHO COMMAND).
COMMAND takes the \"owner/name\" repo to open the tab's page for.")

;;;; Windows
;;
;; As Magit (`magit-display-buffer-traditional', `magit-mode-quit-window'):
;; RET on an octocat page opens the next one in the same window, and `q'
;; steps back out, deleting the window once it was made for octocat and
;; has nothing of octocat left to show.

(defun octocat-buffer-p (&optional buffer)
  "Return non-nil if BUFFER (default: the current one) is an octocat page."
  (string-prefix-p "octocat-" (symbol-name (buffer-local-value
                                            'major-mode (or buffer (current-buffer))))))

(defun octocat-display-buffer (buffer)
  "Show BUFFER and select its window, as Magit does.
From an octocat page, in the selected window; from elsewhere, wherever
`display-buffer' puts it.  `display-buffer-alist' overrides both."
  (pop-to-buffer buffer (and (octocat-buffer-p) '(display-buffer-same-window)))
  ;; A window with no earlier buffers was made for BUFFER: remember it
  ;; for `octocat-quit-window', as `magit-maybe-set-dedicated' does.
  (unless (window-prev-buffers)
    (set-window-parameter nil 'octocat-dedicated t)))

(defun octocat-call-in-other-window (fn)
  "Call FN, showing the page it opens in another window, selected.
A lone window is split to the right, and `octocat-quit-window' deletes
the new one; else another window is reused, so repeated opens keep one
pane."
  (let ((display-buffer-overriding-action
         '((display-buffer-reuse-window
            display-buffer-use-some-window
            display-buffer-in-direction)
           (direction . right)
           (inhibit-same-window . t))))
    (funcall fn)))

(defun octocat--display-later (fn)
  "Return FN, made to show a page where the command calling this would.
For a page shown once `gh' answers: by then the command has returned,
and `octocat-call-in-other-window''s binding with it."
  (let ((action display-buffer-overriding-action))
    (lambda (&rest args)
      (let ((display-buffer-overriding-action action))
        (apply fn args)))))

(defun octocat-visit ()
  "Do what RET does at point.
Rows, buttons and modes each bind RET their own way, so this looks the
binding up rather than knowing them.  `last-command-event' is RET's, as
`push-button' reads it."
  (interactive)
  (let ((command (or (key-binding [return] t) (key-binding (kbd "RET") t)))
        (last-command-event ?\r))
    (if (commandp command)
        (call-interactively command)
      (user-error "Octocat: Nothing to open here"))))

(defun octocat-visit-other-window ()
  "Do what RET does at point, showing the page it opens in another window."
  (interactive)
  (octocat-call-in-other-window #'octocat-visit))

(defun octocat--still-selected-p (buffer)
  "Return non-nil when BUFFER is still the selected window's buffer.
An async callback may show a page or open a prompt only then: the user
may have gone on to another buffer while `gh' ran, and must not be
pulled back to it (see docs/user-interface-conventions.md)."
  (eq (window-buffer (selected-window)) buffer))

(defun octocat-quit-window (&optional kill)
  "Quit the selected window and bury its buffer, or kill it with KILL.
As `quit-window', which shows the window's previous buffer, but a window
made for octocat is deleted once no other octocat page it showed is
left."
  (interactive "P")
  (if (or (one-window-p)
          (seq-find (pcase-lambda (`(,buffer))
                      (and (not (eq buffer (current-buffer)))
                           (buffer-live-p buffer)
                           (or (not (window-parameter nil 'octocat-dedicated))
                               (octocat-buffer-p buffer))))
                    (window-prev-buffers)))
      (quit-window kill)
    (let ((window (selected-window)))
      (quit-window kill)
      (when (window-live-p window)
        (delete-window window)))))

(defun octocat-visit-repo (repo &optional ref)
  "Open (or switch to) the *REPO* buffer.
REPO is an \"owner/name\" string.  This is the shared implementation used
by the repo-nav section in every detail view.  REF, a branch, tag or
SHA, is the one to show instead of the default branch."
  (let* ((buf-name (format "*%s*" repo))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo)
          octocat-repo--ref       ref)
    (octocat-repo-refresh)))

;;;; Current repo detection
;;
;; Used by the repo-wide search in octocat-search.el and by markdown
;; reference opening.

(defun octocat--search-repo--current-repo ()
  "Return the \"owner/repo\" string for the current octocat buffer context.
Tries each buffer-local repo variable in priority order, then falls
back to parsing the git origin remote via `octocat-repo--current-repo'."
  (or (bound-and-true-p octocat-repo--repo)
      (bound-and-true-p octocat--pr-repo)
      (bound-and-true-p octocat--issue-repo)
      (bound-and-true-p octocat--commit-repo)
      (bound-and-true-p octocat--workflow-repo)
      (bound-and-true-p octocat--run-repo)
      (bound-and-true-p octocat--job-repo)
      (bound-and-true-p octocat--checks-repo)
      (bound-and-true-p octocat-tree--file-repo)
      (bound-and-true-p octocat-vui-list--repo)
      (condition-case nil (octocat-repo--current-repo) (user-error nil))))

;;;; List filters
;;
;; The PR and issue list pages are filtered by a GitHub search query
;; string such as \"is:open author:@me label:bug -label:wontfix\".  The
;; state is part of the query (is:open / is:closed / is:merged); a query
;; without a state token matches every state.

(defconst octocat--default-list-query "is:open"
  "Query a PR or issue list starts with.")

(defun octocat--search-query (repo kind query)
  "Return the GitHub search string for the KIND items of REPO matching QUERY.
KIND is `issues' or `pulls'.  A nil QUERY means
`octocat--default-list-query'.  QUERY is parenthesised, as gh does, so an
OR in it cannot escape the repo scope."
  (let ((query (string-trim (or query octocat--default-list-query)))
        (scope (format "repo:%s type:%s" repo (if (eq kind 'pulls) "pr" "issue"))))
    (if (string-empty-p query)
        scope
      (format "( %s ) %s" query scope))))

(defconst octocat--list-item-fields
  `((pulls  . ,(concat "...on PullRequest{number title state isDraft reviewDecision "
                       "createdAt author{login} labels(first:100){nodes{name color}} "
                       "comments{totalCount} commits(last:1){nodes{commit{statusCheckRollup{"
                       "state contexts{checkRunCountsByState{state count} "
                       "statusContextCountsByState{state count}}}}}}}"))
    (issues . ,(concat "...on Issue{number title state createdAt author{login} "
                       "labels(first:100){nodes{name color}} comments{totalCount} "
                       "closedByPullRequestsReferences(first:20){nodes{number repository{"
                       "name owner{login}}}}}")))
  "The GraphQL fields of a list row, by KIND.
Only what the row shows: `gh pr/issue list --json' would fetch every
comment's body and every check run, many times the size and the API cost.
Labels are all fetched, since the sync store keeps them on the item's
entity, which must hold the whole set.")

(defun octocat--list-items-query (kind)
  "Return the GraphQL search query for a page of KIND list items."
  (format (concat "query($q:String!,$limit:Int!,$after:String){search(query:$q,"
                  "type:ISSUE_ADVANCED,first:$limit,after:$after){nodes{%s}pageInfo{"
                  "hasNextPage endCursor}}}")
          (alist-get kind octocat--list-item-fields)))

(defun octocat--flatten-list-item (item)
  "Flatten the connections of the search result ITEM in place; return it.
\"labels\" and \"closedByPullRequestsReferences\" become vectors of their
nodes, as gh's JSON has them; the comments become their count,
\"commentCount\"; and the head commit's checks become GitHub's rolled-up
state, \"ciState\", and how many passed of how many, \"ciPassed\" and
\"ciTotal\", absent without checks."
  (dolist (key '("labels" "closedByPullRequestsReferences"))
    (let ((conn (gethash key item)))
      (when (hash-table-p conn)
        (puthash key (gethash "nodes" conn) item))))
  (let ((comments (gethash "comments" item)))
    (when (hash-table-p comments)
      (puthash "commentCount" (gethash "totalCount" comments) item)
      (remhash "comments" item)))
  (let* ((commits (gethash "commits" item))
         (node    (and (hash-table-p commits) (seq-first (gethash "nodes" commits))))
         (rollup  (and node (gethash "statusCheckRollup" (gethash "commit" node)))))
    (when (hash-table-p rollup)
      (puthash "ciState" (gethash "state" rollup) item)
      (let ((ctx (gethash "contexts" rollup)) (passed 0) (total 0))
        (when (hash-table-p ctx)
          (dolist (kind '(("checkRunCountsByState" "SUCCESS" "NEUTRAL" "SKIPPED")
                          ("statusContextCountsByState" "SUCCESS")))
            (seq-doseq (c (or (gethash (car kind) ctx) []))
              (let ((n (gethash "count" c)))
                (setq total (+ total n))
                (when (member (gethash "state" c) (cdr kind))
                  (setq passed (+ passed n))))))
          (puthash "ciPassed" passed item)
          (puthash "ciTotal" total item))))
    (remhash "commits" item))
  item)

(defun octocat--parse-list-items (json-string)
  "Parse the list search response JSON-STRING into (:items LIST :cursor C).
The items are flattened by `octocat--flatten-list-item'.  C is the cursor
to pass for the next page, or nil on the last."
  (let* ((search (gethash "search" (gethash "data" (json-parse-string json-string))))
         (info   (gethash "pageInfo" search)))
    (list :items  (mapcar #'octocat--flatten-list-item (gethash "nodes" search))
          :cursor (and (eq (gethash "hasNextPage" info) t)
                       (octocat--nonempty (gethash "endCursor" info))))))

(defun octocat--list-items (kind repo callback &optional query after limit)
  "Fetch a page of the KIND items of REPO matching the search QUERY.
KIND is `issues' or `pulls'.  AFTER, a cursor from an earlier page,
fetches the page after it; a page is LIMIT items, by default
`octocat-list-page-size'.
CALLBACK is called with the plist from `octocat--parse-list-items', or a
cons \\=(error . MSG).  One API call."
  (octocat--run-gh
   (symbol-name kind)
   (append (list "api" "graphql"
                 "-f" (concat "query=" (octocat--list-items-query kind))
                 "-f" (concat "q=" (octocat--search-query repo kind query))
                 "-F" (format "limit=%d" (or limit octocat-list-page-size)))
           (and after (list "-f" (concat "after=" after))))
   #'octocat--parse-list-items
   callback))

(defun octocat--counts-query (kind)
  "Return the GraphQL query counting items of KIND (`issues' or `pulls')."
  (let ((field (if (eq kind 'pulls) "pullRequests" "issues"))
        (states (if (eq kind 'pulls)
                    '(("open" . "OPEN") ("closed" . "CLOSED") ("merged" . "MERGED"))
                  '(("open" . "OPEN") ("closed" . "CLOSED")))))
    (format "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){%s}}"
            (mapconcat (lambda (s)
                         (format "%s:%s(states:%s){totalCount}" (car s) field (cdr s)))
                       states " "))))

(defun octocat--parse-counts (json-string)
  "Parse the GraphQL counts response JSON-STRING into a plist.
Keys: :open, :closed and, for pull requests, :merged."
  (let ((repo (gethash "repository"
                       (gethash "data" (json-parse-string json-string :null-object nil)))))
    (apply #'append
           (mapcar (lambda (key)
                     (let ((entry (gethash (substring (symbol-name key) 1) repo)))
                       (and entry (list key (gethash "totalCount" entry)))))
                   '(:open :closed :merged)))))

(defun octocat--fetch-counts (repo kind callback)
  "Fetch the open/closed(/merged) counts of KIND in REPO asynchronously.
KIND is `issues' or `pulls'.  CALLBACK is called with the plist described
in `octocat--parse-counts', or a cons \\=(error . MSG).  One API call."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "counts"
     (list "api" "graphql"
           "-f" (concat "query=" (octocat--counts-query kind))
           "-F" (concat "owner=" (car parts))
           "-F" (concat "name=" (cadr parts)))
     #'octocat--parse-counts
     callback)))

(defconst octocat--repo-summary-query
  (concat "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){"
          "defaultBranchRef{name} parent{nameWithOwner} issues(states:OPEN){totalCount} "
          "pullRequests(states:OPEN){totalCount}}}")
  "GraphQL query behind `octocat--fetch-repo-summary'.")

(defun octocat--parse-repo-summary (json-string)
  "Parse the GraphQL response JSON-STRING into a summary plist.
Keys: :default-branch (string or nil), :fork-parent (\"owner/repo\" or
nil), :open-issues and :open-prs (integers)."
  (let* ((repo (gethash "repository"
                        (gethash "data" (json-parse-string json-string :null-object nil))))
         (ref    (gethash "defaultBranchRef" repo))
         (parent (gethash "parent" repo)))
    (list :default-branch (and ref (gethash "name" ref))
          :fork-parent    (and parent (gethash "nameWithOwner" parent))
          :open-issues    (gethash "totalCount" (gethash "issues" repo))
          :open-prs       (gethash "totalCount" (gethash "pullRequests" repo)))))

(defun octocat--fetch-repo-summary (repo callback)
  "Fetch the repo-view summary for REPO asynchronously in one API call.
Calls CALLBACK with the plist described in `octocat--parse-repo-summary',
or a cons \\=(error . MSG) on failure.  One GraphQL request replaces what
would otherwise be separate default-branch, fork-parent and
issue/PR-count lookups."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "repo-summary"
     (list "api" "graphql"
           "-f" (concat "query=" octocat--repo-summary-query)
           "-F" (concat "owner=" (car parts))
           "-F" (concat "name=" (cadr parts)))
     #'octocat--parse-repo-summary
     callback)))

(defun octocat--list-labels (repo callback)
  "Fetch the labels of REPO asynchronously and call CALLBACK.
CALLBACK is called with a list of tables of \"name\" and \"color\", or a
cons \\=(error . MSG)."
  (octocat--run-gh "labels"
                   (list "label" "list"
                         "--repo" repo
                         "--limit" "200"
                         "--json" "name,color")
                   #'octocat--parse-json-list
                   callback))

(defun octocat--list-people (repo callback)
  "Fetch the logins that can be assigned in REPO and call CALLBACK.
CALLBACK is called with a list of strings, or a cons \\=(error . MSG)."
  (octocat--run-gh "people"
                   (list "api" (format "repos/%s/assignees?per_page=100" repo)
                         "--jq" ".[].login")
                   (lambda (output) (split-string output "\n" t))
                   callback))

(defun octocat--list-branches (repo callback)
  "Fetch the branch names of REPO and call CALLBACK.
CALLBACK is called with a list of strings, or a cons \\=(error . MSG)."
  (octocat--run-gh "branches"
                   (list "api" "--paginate"
                         (format "repos/%s/branches?per_page=100" repo)
                         "--jq" ".[].name")
                   (lambda (output) (split-string output "\n" t))
                   callback))

(defun octocat--branch-candidates (names default local)
  "Return branch NAMES ordered for a picker, as GitHub's branch dropdown.
DEFAULT (the default branch) comes first, then LOCAL (the checked-out
branch) when it was pushed, then the rest as given."
  (let ((front (delete-dups (seq-filter (lambda (b) (and b (member b names)))
                                        (list default local)))))
    (append front (seq-difference names front))))

(defun octocat--branch-note (branch default local)
  "Return the picker annotation of BRANCH, given DEFAULT and LOCAL, or nil."
  (cond ((equal branch default) "  default")
        ((equal branch local)   "  checked out")))

(provide 'octocat-core)
;;; octocat-core.el ends here
