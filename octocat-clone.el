;;; octocat-clone.el --- Read GitHub data from a repo's local clone  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-opus-5-5

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

;; The local clone of a GitHub repo: which repo a directory is a clone
;; of, what it has checked out and not pushed, and the objects it holds.
;; It requires no other module.
;;
;; What a SHA names is the same in a repo's clone as on GitHub, so a
;; resource named by one can be read from the clone when it has it,
;; in a few milliseconds rather than a round trip; see a resource's
;; :local in `octocat-sync-define-resource'.  The clone only makes a
;; page load sooner: what it lacks, or fails to read in time, is
;; fetched from GitHub.
;;
;; A clone is found as pages open from inside it, and kept for the
;; session only: a directory can move or go.  Objects are read
;; asynchronously rather than through vc, whose reads block Emacs, and
;; which reads files of the working tree, not objects by SHA.

;;; Code:

(require 'cl-lib)
(require 'parse-time)
(require 'seq)
(require 'subr-x)
(require 'vc-git)

;;;; Finding the clone

(defun octocat-clone-current-repo ()
  "Return the \"owner/repo\" string for the current Git repository.
Reads the \\='origin\\=' remote URL and parses both SSH and HTTPS
GitHub remote forms.  Signals an error when the working directory
is not inside a GitHub repository."
  (let ((url (condition-case nil
                 (string-trim (vc-git-repository-url default-directory))
               (error ""))))
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

(defconst octocat-clone-timeout 2
  "Seconds a `git' read from a local clone may take.
Past it, git is stopped, the clone is no longer used this session, and
the data is fetched from GitHub.")

(defvar octocat-clone--roots (make-hash-table :test #'equal)
  "Each repo, \"owner/name\", to the root of its clone found this session.")

(defvar octocat-clone--git-version nil
  "The version of `vc-git-program', as \"2.44.0\", once asked.")

(defun octocat-clone--git-version ()
  "Return the version of `vc-git-program', \"0\" when it can't be run."
  (or octocat-clone--git-version
      (setq octocat-clone--git-version
            (let ((out (condition-case nil
                           (car (process-lines vc-git-program "version"))
                         (error ""))))
              (if (string-match "[0-9]+\\(?:\\.[0-9]+\\)+" out)
                  (match-string 0 out)
                "0")))))

(defun octocat-clone--lazy-p (root)
  "Return non-nil if `git' may fetch objects missing from the clone at ROOT.
A partial clone's git fetches them from origin, unless it is 2.44 or
later, which `GIT_NO_LAZY_FETCH' stops.  A clone whose .git is a file,
a worktree's, may be partial too."
  (and (version< (octocat-clone--git-version) "2.44")
       (let ((pack (expand-file-name ".git/objects/pack" root)))
         (or (not (file-directory-p pack))
             (directory-files pack nil "\\.promisor\\'" t 1)))))

(defun octocat-clone-add (repo root)
  "Remember ROOT as the clone of REPO for this session.
Not one on a remote host, nor one whose git could fetch over the
network what it lacks."
  (unless (or (file-remote-p root) (octocat-clone--lazy-p root))
    (puthash repo (file-name-as-directory (expand-file-name root)) octocat-clone--roots)))

(defun octocat-clone-drop (repo)
  "Stop reading REPO from its clone this session, as its git failed."
  (remhash repo octocat-clone--roots))

(defun octocat-clone-root (repo)
  "Return the root of the clone of REPO found this session, or nil.
A clone whose .git is gone is forgotten."
  (when-let* ((root (gethash repo octocat-clone--roots)))
    (if (file-exists-p (expand-file-name ".git" root))
        root
      (octocat-clone-drop repo)
      nil)))

(defun octocat-clone-dir-for (repo)
  "Return the local clone directory for REPO, or nil.
REPO is an \"owner/repo\" string.  Returns the absolute path to the root
of the current working tree when its \\='origin\\=' remote resolves to REPO,
and nil in every other case — including when `default-directory' is not
inside any git repository, when there is no \\='origin\\=' remote, or when
the remote points to a different repository.  A clone found is
remembered, see `octocat-clone-root'."
  (condition-case nil
      (when-let* ((root (vc-git-root default-directory))
                  ((string= repo (octocat-clone-current-repo)))
                  (root (expand-file-name root)))
        (octocat-clone-add repo root)
        root)
    (error nil)))

;;;; The checkout

(defun octocat-clone--git-lines (dir &rest args)
  "Return the output lines of git ARGS run in DIR, or nil when it fails."
  (let ((default-directory dir))
    (with-temp-buffer
      (and (eq 0 (apply #'process-file vc-git-program nil '(t nil) nil args))
           (split-string (buffer-string) "\n" t)))))

(defun octocat-clone--parse-unpushed (lines)
  "Parse LINES of \"SHA NUL PARENTS NUL SUBJECT\" into plists.
:merge is t for one of more than one parent."
  (mapcar (lambda (l)
            (pcase-let ((`(,sha ,parents ,subject) (split-string l "\0")))
              (list :sha sha
                    :merge (and (cdr (split-string (or parents ""))) t)
                    :subject subject)))
          lines))

(defun octocat-clone-unpushed (dir)
  "Return the local commits in DIR not yet on GitHub, or nil when none.
The result is a plist: :commits from `octocat-clone--parse-unpushed',
newest first, :upstream the remote-tracking branch they are counted
against (nil for a branch never pushed, counted against every origin
branch), and :behind how many upstream commits HEAD lacks, as of the
last fetch; non-zero means the branches diverged.  Reads git synchronously."
  (let* ((upstream (car (octocat-clone--git-lines
                         dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}")))
         (log      (append '("log" "--format=%H%x00%P%x00%s")
                           (if upstream
                               '("@{u}..HEAD")
                             '("HEAD" "--not" "--remotes=origin"))))
         (commits  (octocat-clone--parse-unpushed
                    (apply #'octocat-clone--git-lines dir log))))
    (when commits
      (list :commits commits
            :upstream upstream
            :behind (if upstream
                        (string-to-number
                         (or (car (octocat-clone--git-lines
                                   dir "rev-list" "--count" "HEAD..@{u}"))
                             "0"))
                      0)))))

(defun octocat-clone-tracked-branch (dir)
  "Return the GitHub branch the clone in DIR has checked out, or nil.
That is its upstream on origin, or else origin's branch of the same
name, as of the last fetch.  Nil when DIR is nil, HEAD is detached or
the branch was never pushed: GitHub has nothing to show for it."
  (when-let* ((dir)
              (branch (car (octocat-clone--git-lines dir "symbolic-ref" "--short" "HEAD"))))
    (let ((upstream (car (octocat-clone--git-lines
                          dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}"))))
      (cond ((and upstream (string-prefix-p "origin/" upstream))
             (substring upstream (length "origin/")))
            ((octocat-clone--git-lines dir "rev-parse" "--verify" "--quiet"
                                       (concat "refs/remotes/origin/" branch))
             branch)))))

(defun octocat-clone--git-ok (dir &rest args)
  "Return non-nil when git ARGS run in DIR succeeds."
  (let ((default-directory dir))
    (eq 0 (apply #'process-file vc-git-program nil nil nil args))))

(defun octocat-clone-here-ref (dir)
  "Return (REF . REV) for what GitHub has of the checkout of the clone in DIR.
REF names it to GitHub: the tracked branch, else a detached HEAD's SHA
once origin has it, else nil for the default branch.  REV names that
commit to the clone's git, as of the last fetch."
  (if-let* ((branch (octocat-clone-tracked-branch dir)))
      (cons branch (concat "origin/" branch))
    (let ((sha (and (not (octocat-clone--git-ok dir "symbolic-ref" "--quiet" "HEAD"))
                    (octocat-clone--git-lines dir "branch" "--remotes" "--contains" "HEAD"
                                              "--list" "origin/*")
                    (car (octocat-clone--git-lines dir "rev-parse" "HEAD")))))
      (if sha (cons sha sha) (cons nil "origin/HEAD")))))

;;;; Reading objects

(defconst octocat-clone--timed-out '(error . "git timed out")
  "What `octocat-clone--git' answers for a git run past `octocat-clone-timeout'.")

(defun octocat-clone--git (dir args input callback)
  "Run `vc-git-program' with ARGS in DIR, given INPUT; call CALLBACK.
CALLBACK gets what git prints, as bytes, or (error . MESSAGE) when git
can't start, exits non-zero, or runs past `octocat-clone-timeout', then
`octocat-clone--timed-out'.  git never prompts, nor fetches an object
the clone lacks."
  (let ((out (generate-new-buffer " *octocat-git*" t))
        (err (generate-new-buffer " *octocat-git-stderr*" t))
        called proc timer)
    (cl-flet ((finish (result)
                (unless called
                  (setq called t)
                  (when timer (cancel-timer timer))
                  (when (process-live-p proc) (delete-process proc))
                  (kill-buffer out)
                  (kill-buffer err)
                  (funcall callback result))))
      (with-current-buffer out (set-buffer-multibyte nil))
      (condition-case e
          (let ((default-directory dir)
                (process-environment (append '("GIT_TERMINAL_PROMPT=0" "GIT_NO_LAZY_FETCH=1")
                                             process-environment)))
            (setq proc (make-process
                        :name "octocat-git" :buffer out :stderr err
                        :command (cons vc-git-program args)
                        :connection-type 'pipe :coding 'binary :noquery t
                        :sentinel
                        (lambda (p _)
                          (unless (or called (process-live-p p))
                            (finish (if (eql 0 (process-exit-status p))
                                        (with-current-buffer out (buffer-string))
                                      (cons 'error
                                            (format "git %s exited %s: %s" (car args)
                                                    (process-exit-status p)
                                                    (with-current-buffer err
                                                      (string-trim (buffer-string)))))))))))
            (setq timer (run-at-time octocat-clone-timeout nil
                                     (lambda () (finish octocat-clone--timed-out))))
            ;; Only then: git may be done, and gone, before an EOF is sent.
            (when input
              (process-send-string proc input)
              (process-send-eof proc)))
        (error (finish (cons 'error (error-message-string e))))))))

(defconst octocat-clone--jobs 8
  "How many git runs of one read run at once.")

(defun octocat-clone--git-each (dir arg-lists callback)
  "Run git with each of ARG-LISTS in DIR, `octocat-clone--jobs' at once.
CALLBACK gets the list of what each prints, in order, or the first
\(error . MESSAGE) of one, as `octocat-clone--git'.  Once one fails, no
more are started."
  (let* ((outs   (make-vector (length arg-lists) nil))
         (todo   (seq-map-indexed #'cons arg-lists))
         (left   (length arg-lists))
         failed)
    (cl-labels ((start ()
                  (pcase-let ((`(,args . ,i) (pop todo)))
                    (octocat-clone--git
                     dir args nil
                     (lambda (out)
                       (cond (failed)
                             ((stringp out)
                              (aset outs i out)
                              (if (zerop (cl-decf left))
                                  (funcall callback (append outs nil))
                                (when todo (start))))
                             (t (setq failed t)
                                (funcall callback out))))))))
      (if (null todo)
          (funcall callback nil)
        (dotimes (_ (min octocat-clone--jobs (length todo)))
          (start))))))

(defun octocat-clone-read (repo object type args parse &optional slow)
  "Return a :local reading a resource of REPO from its clone, or nil.
OBJECT, as `git cat-file' names it, must be there and of TYPE, such as
\"tree\".  Then ARGS of its SHA are run, and DONE gets PARSE of what git
prints, the object's SHA and its size in bytes.  ARGS may also give a
list of git argument lists, run at once: PARSE then gets the list of
what each prints.  An object missing, or of another type, answers an
error; so does git failing, which also forgets the clone.  Either way
the resource is fetched from GitHub.  With SLOW, a walk of history that
may run out of time on a long one with nothing wrong with git, the
clone is kept then."
  (when-let* (((not (string-search "\n" object)))
              (dir (octocat-clone-root repo)))
    (lambda (done)
      (cl-flet ((failed (result)
                  (octocat-clone-drop repo)
                  (funcall done result)))
        (octocat-clone--git
         dir '("cat-file" "--batch-check") (encode-coding-string (concat object "\n") 'utf-8)
         (lambda (check)
           (pcase (and (stringp check) (split-string check))
             (`(,sha ,(pred (equal type)) ,size)
              (let ((runs (funcall args sha)))
                (funcall
                 (if (stringp (car runs))
                     (lambda (callback) (octocat-clone--git dir runs nil callback))
                   (lambda (callback) (octocat-clone--git-each dir runs callback)))
                 (lambda (out)
                   (cond ((not (eq (car-safe out) 'error))
                          (funcall done (condition-case e
                                            (funcall parse out sha (string-to-number size))
                                          (error (cons 'error (error-message-string e))))))
                         ((and slow (eq out octocat-clone--timed-out)) (funcall done out))
                         (t (failed out)))))))
             ;; "OBJECT missing", or another type.
             ((guard (stringp check))
              (funcall done (cons 'error (format "%s not in the local clone" object))))
             (_ (failed check)))))))))

(defun octocat-clone-read-blob (repo object parse)
  "Return a :local reading blob OBJECT of REPO from its clone, or nil.
DONE gets PARSE of its bytes, its SHA and its size; see
`octocat-clone-read'."
  (octocat-clone-read repo object "blob" (lambda (sha) (list "cat-file" "blob" sha)) parse))

(defun octocat-clone-run-lines (dir arg-lists callback)
  "Run git in DIR with each of ARG-LISTS in turn, then CALLBACK.
CALLBACK gets the output lines of all of them; a command that fails
adds none.  Return a function that stops it, after which CALLBACK is
never called."
  (let (proc lines stopped)
    (cl-labels
        ((next (lists)
           (if (or (null lists) (not (executable-find vc-git-program)))
               (funcall callback lines)
             (let ((default-directory dir)
                   (buf (generate-new-buffer " *octocat-git*"))
                   (err (generate-new-buffer " *octocat-git-stderr*")))
               (setq proc
                     (make-process
                      :name "octocat-git" :buffer buf :stderr err :noquery t
                      :connection-type 'pipe :command (cons vc-git-program (car lists))
                      :sentinel
                      (lambda (p _event)
                        (unless (process-live-p p)
                          (let ((out (and (eq (process-status p) 'exit)
                                          (eq 0 (process-exit-status p))
                                          (with-current-buffer buf (buffer-string)))))
                            (kill-buffer buf)
                            ;; As `octocat--run-gh': the stderr pipe may outlive it.
                            (when-let* ((pipe (get-buffer-process err)))
                              (delete-process pipe))
                            (kill-buffer err)
                            (unless stopped
                              (setq lines (append lines (split-string (or out "") "\n" t)))
                              (next (cdr lists))))))))))))
      (next arg-lists)
      (lambda ()
        (setq stopped t)
        (when (process-live-p proc) (delete-process proc))))))

;;;; Last commits

(defconst octocat-clone--log-format
  "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cI%x1f%B"
  "The `git log' format of a commit, as `octocat-clone--log-commit' reads.")

(defun octocat-clone--table (&rest pairs)
  "Return a hash table of PAIRS, alternating keys and values."
  (let ((h (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) h))
    h))

(defun octocat-clone--headline (message)
  "Return the headline of commit MESSAGE, as GitHub's messageHeadline.
That is its first line, but one past 72 characters is cut to 69 and \"…\"."
  (let ((line (car (split-string message "\n"))))
    (if (> (length line) 72) (concat (substring line 0 69) "…") line)))

(defun octocat-clone--log-commit (header)
  "Return the commit of HEADER, as `octocat-clone--log-format' prints it.
It is as GitHub gives a commit's oid, messageHeadline, authoredDate,
committedDate, author's name and email, and first two parents: its
dates in UTC, as GitHub's.  The author's \"user\", who GitHub links to
the email, is nil: git doesn't know it."
  (pcase-let ((`(,oid ,parents ,name ,email ,authored ,committed . ,message)
               (split-string (decode-coding-string header 'utf-8) "\x1f"))
              (utc (lambda (date)
                     (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                         (parse-iso8601-time-string date) t))))
    (octocat-clone--table
     "oid" oid
     "messageHeadline" (octocat-clone--headline (string-join message "\x1f"))
     "authoredDate" (funcall utc authored)
     "committedDate" (funcall utc committed)
     "author" (octocat-clone--table "name" name "email" email "user" nil)
     "parents" (octocat-clone--table
                "nodes" (vconcat (mapcar (lambda (p) (octocat-clone--table "oid" p))
                                         (seq-take (split-string parents " " t) 2)))))))

(defun octocat-clone-last-commits (repo commit dir names)
  "Return a :local finding the last commit of each of NAMES in DIR of REPO.
NAMES are DIR's entries, DIR \"\" for the root, and the history is
COMMIT's.  DONE gets a table of each one's path, DIR/NAME, to its
commit, as `octocat-clone--log-commit' gives it; one with none is left
out, as GitHub does.  Each is git's last commit of that path alone, as
GitHub's is: one walk of DIR's history would differ at merges, which
change a directory from every parent while each file in it is one
parent's.  Nil without a clone."
  (let ((paths (mapcar (lambda (name)
                         (if (equal dir "") name (concat (file-name-as-directory dir) name)))
                       names)))
    (octocat-clone-read
     repo commit "commit"
     (lambda (sha)
       (mapcar (lambda (path)
                 (list "-c" "log.follow=false" "log" "-1" octocat-clone--log-format sha
                       "--" (concat ":(literal)" path)))
               paths))
     (lambda (outs _sha _size)
       (let ((found (make-hash-table :test #'equal)))
         (cl-loop for path in paths
                  for out in outs
                  unless (string-empty-p out)
                  do (puthash path (octocat-clone--log-commit out) found))
         found))
     t)))

(defun octocat-clone-parse-ls-tree (out)
  "Return the entries in OUT, as `git ls-tree -z' prints, as GitHub's.
That is a list of tables of \"path\", \"mode\", \"type\" (\"blob\",
\"tree\", or \"commit\" for a submodule), \"sha\" and, with --long, a
blob's \"size\"."
  (mapcar (lambda (line)
            (unless (string-match (concat "\\`\\([0-7]+\\) \\([a-z]+\\) \\([0-9a-f]+\\)"
                                          "\\(?: +\\([0-9]+\\|-\\)\\)?\t")
                                  line)
              (error "Unexpected `git ls-tree' line: %S" line))
            (let ((size  (match-string 4 line))
                  (entry (make-hash-table :test #'equal)))
              (puthash "path" (decode-coding-string (substring line (match-end 0)) 'utf-8) entry)
              (puthash "mode" (match-string 1 line) entry)
              (puthash "type" (match-string 2 line) entry)
              (puthash "sha"  (match-string 3 line) entry)
              (when (and size (not (equal size "-")))
                (puthash "size" (string-to-number size) entry))
              entry))
          (split-string out "\0" t)))

(provide 'octocat-clone)
;;; octocat-clone.el ends here
