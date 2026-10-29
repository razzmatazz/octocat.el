;;; screenshots.el --- Screenshots of octocat.el's pages  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Renders pages from the made-up data in fixtures.el into
;; docs/screenshots/, for `make screenshots': each as a PNG of a GUI
;; frame and as text, beside README.md there, which links them.  Each
;; shot there is a marker naming the page, then what this writes, up to
;; an end marker:
;;
;;   <!-- screenshot: (pr "acme/rocket" 128) :name "pr-merged" :press ("Files") -->
;;   <!-- /screenshot -->
;;
;; The page is (COMMAND ARGS...), opened by `octocat-COMMAND-open', or
;; by `octocat-COMMAND' when there is no such function, as (dashboard)
;; for `octocat' and (pr-list "acme/rocket").  :press lists buttons to
;; press first, by their text, or rows to press RET on, by a text on
;; them, or (:key KEY) to call KEY's command.  :name names its files,
;; NAME.png and NAME.txt; it defaults to COMMAND.  To add a shot, add a
;; marker; to
;; show other data, edit fixtures.el.  A `gh' call fixtures.el lacks
;; fails the run, naming it.
;;
;; Pages fetch through the sync layer and `octocat--run-gh' as usual;
;; only the `gh' process is replaced, its output read from a fixture.
;; Avatars come from a made-up image, and other images fail to load.
;; The clock is frozen at `octocat-screenshots-now', so ages stay put.
;;
;; Run it in a GUI Emacs, as `make screenshots' does under Xvfb; in a
;; terminal or batch Emacs only the text is written.

;;; Code:

(defvar octocat-screenshots-root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name)))
  "The octocat.el checkout.")

;; The dependencies, as Eldev would load them: the image's, else the checkout's.
(let ((package-user-dir (expand-file-name (format ".eldev/%s.%s/packages"
                                                  emacs-major-version emacs-minor-version)
                                          (or (getenv "OCTOCAT_DEPS")
                                              octocat-screenshots-root))))
  (when (file-directory-p package-user-dir)
    (package-initialize)))
(add-to-list 'load-path octocat-screenshots-root)

(require 'cl-lib)
(require 'octocat)

(declare-function x-export-frames "xfns.c" (&optional frames type))
(declare-function scroll-bar-mode "scroll-bar" (&optional arg))

(load (expand-file-name "test/screenshots/fixtures" octocat-screenshots-root) nil t)
(defvar octocat-screenshots-fixtures)
(defvar octocat-screenshots-now)
(defvar modus-vivendi-tinted-palette-overrides)

(defvar octocat-screenshots-directory
  (expand-file-name "docs/screenshots/" octocat-screenshots-root)
  "Where the shots go: README.md, whose shots are rewritten, and the PNGs.")

(defvar octocat-screenshots-file (expand-file-name "README.md" octocat-screenshots-directory)
  "The Markdown file whose shots are rewritten.")

(defvar octocat-screenshots-avatar
  (expand-file-name "test/screenshots/avatar.png" octocat-screenshots-root)
  "The image every avatar is drawn from.")

(defvar octocat-screenshots-font "JetBrains Mono 13"
  "The font of the PNGs.")

(defvar octocat-screenshots-width 100
  "The columns a page keeps within.")

(defvar octocat-screenshots--problems nil
  "What went wrong in the shots, newest first: `gh' calls with no fixture, say.")

(defun octocat-screenshots--fixture (name args)
  "Return the output of the fixture of `gh' call NAME with ARGS, or nil.
That is the first of `octocat-screenshots-fixtures' for NAME whose
strings all appear in ARGS, as a string: a value other than a string
is serialized as JSON."
  (let ((joined (string-join args " ")))
    (when-let* ((fixture (seq-find (pcase-lambda (`(,fname ,match . ,_))
                                     (and (equal fname name)
                                          (seq-every-p (lambda (s) (string-search s joined))
                                                       match)))
                                   octocat-screenshots-fixtures)))
      (let ((output (nth 2 fixture)))
        (if (stringp output)
            output
          (decode-coding-string (json-serialize output) 'utf-8))))))

(defun octocat-screenshots--run-gh (name args parse-fn callback)
  "Answer `gh' call NAME with ARGS from its fixture, as `octocat--run-gh' does.
PARSE-FN and CALLBACK are as there."
  (let ((output (octocat-screenshots--fixture name args))
        (owner octocat--gh-owner))
    (unless output
      (cl-pushnew (format "No fixture for gh %s: %S" name args)
                  octocat-screenshots--problems :test #'equal))
    ;; Answer later, as `gh' does, so pages paint their skeleton first.
    (run-at-time 0 nil
                 (lambda ()
                   (let ((result (if output
                                     (condition-case err
                                         (funcall parse-fn output)
                                       (error (cons 'error (error-message-string err))))
                                   (cons 'error (format "No fixture for gh %s" name))))
                         (octocat--gh-owner owner))
                     (funcall callback result))))))

(defun octocat-screenshots--avatar (_url callback)
  "Call CALLBACK with the made-up avatar's bytes, as `octocat-avatar-fetch'."
  (run-at-time 0 nil
               (lambda ()
                 (funcall callback
                          (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally octocat-screenshots-avatar)
                            (buffer-string))))))

(defun octocat-screenshots--setup ()
  "Point octocat.el at fixtures, a fresh store and a frozen clock; style the frame."
  (let ((dir (make-temp-file "octocat-screenshots" t)))
    (setq octocat-sync-directory (expand-file-name "sync/" dir)
          octocat-settings-file (expand-file-name "settings.eld" dir)
          octocat-sync-prefetch nil
          octocat-sync-poll-interval nil
          octocat-max-width octocat-screenshots-width
          ;; Not in a clone: pages show GitHub's data only.
          default-directory (file-name-as-directory dir)))
  (set-time-zone-rule "UTC")
  (advice-add 'octocat--run-gh :override #'octocat-screenshots--run-gh)
  (advice-add 'octocat-avatar-fetch :override #'octocat-screenshots--avatar)
  (advice-add 'octocat-image--fetch :override
              (lambda (_url _hops callback) (run-at-time 0 nil callback nil)))
  (advice-add 'octocat-repo--local-dir-for :override #'ignore)
  ;; No animations: a slide or spinner turns through `display'
  ;; properties, which the text a shot waits on to settle does not show.
  (advice-add 'octocat-power :override (lambda () 'low))
  (advice-add 'current-time :override
              (lambda () (time-convert octocat-screenshots-now 'list)))
  (advice-add 'float-time :around
              (lambda (fn &optional time) (funcall fn (or time octocat-screenshots-now))))
  ;; So a page is as wide and tall whatever the window.
  (advice-add 'octocat-vui-window-width :override (lambda () octocat-screenshots-width))
  (advice-add 'octocat-vui-window-height :override (lambda () 40))
  (advice-add 'octocat--markdown-width :override (lambda () octocat-screenshots-width))
  (when (display-graphic-p)
    ;; Dark, but dim enough to sit well on GitHub's light pages too:
    ;; the greys of its own "dark dimmed" theme.
    (setq modus-vivendi-tinted-palette-overrides
          '((bg-main "#22272e") (bg-dim "#2d333b") (bg-inactive "#2d333b")
            (fg-main "#d1d7e0")))
    (load-theme 'modus-vivendi-tinted t)
    (set-frame-font octocat-screenshots-font nil t)
    (menu-bar-mode -1)
    (tool-bar-mode -1)
    (scroll-bar-mode -1)
    (blink-cursor-mode -1)
    (setq-default cursor-type nil
                  cursor-in-non-selected-windows nil
                  mode-line-format nil
                  header-line-format nil)
    ;; The pointer rests somewhere on the frame; it must not light a row.
    (setq mouse-highlight nil
          inhibit-message t)))

(defun octocat-screenshots--settle (buffer)
  "Wait until BUFFER has fetched everything and stopped changing.
That is, unchanged for 0.3s: a fold starts unfolding a moment after
it is pressed."
  (let ((last nil) (still 0) (tries 0))
    (while (and (< still 15) (< (cl-incf tries) 400))
      (accept-process-output nil 0.02)
      (let ((text (with-current-buffer buffer (buffer-string))))
        (if (and (equal text last) (zerop (hash-table-count octocat-sync--loading)))
            (cl-incf still)
          (setq still 0 last text))))))

(defun octocat-screenshots--press (buffer label)
  "Press the button whose text is LABEL in BUFFER, or RET on its row.
A LABEL of (:key KEY) calls the command KEY is bound to in BUFFER."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (cond
       ((eq (car-safe label) :key)
        (call-interactively (key-binding (kbd (cadr label)))))
       ((search-forward label nil t)
          (let ((pos (match-beginning 0)))
            (if (button-at pos)
                (push-button pos)
              ;; A RET-able row, as a job's step: see
              ;; docs/user-interface-conventions.md.
              (goto-char pos)
              (call-interactively (key-binding (kbd "RET"))))))
       (t (push (format "No button %S on %s" label (buffer-name))
                octocat-screenshots--problems))))))

(defun octocat-screenshots--text (buffer)
  "Return BUFFER's text, without trailing blanks."
  (with-current-buffer buffer
    (replace-regexp-in-string
     "[ \t]+$" "" (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))))

(defun octocat-screenshots--png (buffer file)
  "Save BUFFER, shown whole in a frame of its own, to FILE as PNG."
  (let* ((lines (with-current-buffer buffer
                  (count-lines (point-min) (point-max))))
         (frame (make-frame `((minibuffer . nil) (width . ,(+ octocat-screenshots-width 2))
                              (height . ,(1+ lines)) (left-fringe . 0) (right-fringe . 0)
                              (internal-border-width . 16) (visibility . t)))))
    (unwind-protect
        (progn
          (set-window-buffer (frame-root-window frame) buffer)
          (with-selected-frame frame
            (set-window-start nil 1)
            (redisplay t))
          (make-directory (file-name-directory file) t)
          (let ((coding-system-for-write 'binary))
            (write-region (x-export-frames frame 'png) nil file nil 0)))
      (delete-frame frame t))))

(defun octocat-screenshots--clock ()
  "Return the seconds since the epoch, of the real clock, not the frozen one.
`format-time-string' reads it in C, past the advice."
  (string-to-number (format-time-string "%s.%N")))

(defun octocat-screenshots--open (page)
  "Open PAGE, (COMMAND ARGS...), and return its buffer."
  (pcase-let ((`(,command . ,args) page))
    (save-window-excursion
      (if (eq command 'dashboard)
          (octocat)
        (let ((open (intern (format "octocat-%s-open" command))))
          (apply (if (fboundp open) open (intern (format "octocat-%s" command))) args)))
      (window-buffer (selected-window)))))

(defun octocat-screenshots-shoot (page &optional press png)
  "Return the text of PAGE, (COMMAND ARGS...), after pressing PRESS.
See the Commentary for PAGE.  PRESS is a list of the labels of buttons
to press, in turn.  With PNG, a file name, save the page there too,
when graphic."
  (let ((start (octocat-screenshots--clock))
        (buffer (octocat-screenshots--open page)))
    (octocat-screenshots--settle buffer)
    (dolist (label press)
      (octocat-screenshots--press buffer label)
      (octocat-screenshots--settle buffer))
    (when (and png (display-graphic-p))
      (octocat-screenshots--png buffer png))
    ;; So a slow page shows.
    (princ (format "%5.2fs %S\n" (- (octocat-screenshots--clock) start) page)
           #'external-debugging-output)
    (prog1 (octocat-screenshots--text buffer)
      (kill-buffer buffer))))

(defconst octocat-screenshots--marker "^<!-- screenshot: \\(.*\\) -->\n"
  "A shot's marker.")

(defun octocat-screenshots--shot-end ()
  "Return the end of what was written for the shot whose marker point is after.
That is after its end marker, or point when there is none yet: a shot
just added."
  (save-match-data
    (save-excursion
      (let ((next (save-excursion
                    (if (re-search-forward octocat-screenshots--marker nil t)
                        (match-beginning 0)
                      (point-max)))))
        (search-forward "<!-- /screenshot -->\n" next t)
        (point)))))

(defun octocat-screenshots--block (marker name)
  "Return the Markdown of the shot at MARKER, whose files are named NAME."
  (let ((image (concat name ".png")))
    (concat "<!-- screenshot: " marker " -->\n"
            (if (file-exists-p (expand-file-name image octocat-screenshots-directory))
                (format "![%s](%s)\n\n" name image)
              "")
            (format "[As text](%s.txt)\n" name)
            "<!-- /screenshot -->\n")))

(defun octocat-screenshots-update ()
  "Rewrite every shot of `octocat-screenshots-file'.
Signal an error after if something went wrong, as a page making a
`gh' call with no fixture: its shot shows the error."
  (octocat-screenshots--setup)
  (let* ((names nil)
         (text
          (with-temp-buffer
            (insert-file-contents octocat-screenshots-file)
            (goto-char (point-min))
            (while (re-search-forward octocat-screenshots--marker nil t)
              (let* ((start (match-beginning 0))
                     (end (copy-marker (octocat-screenshots--shot-end)))
                     (marker (match-string 1))
                     (spec (car (read-from-string (concat "(" marker ")"))))
                     (name (or (plist-get (cdr spec) :name) (symbol-name (caar spec))))
                     (shot (save-current-buffer
                             (octocat-screenshots-shoot
                              (car spec) (plist-get (cdr spec) :press)
                              (expand-file-name (concat name ".png")
                                                octocat-screenshots-directory)))))
                (when (member name names)
                  (push (format "Two shots are named %s; give one a :name" name)
                        octocat-screenshots--problems))
                (push name names)
                (with-temp-file (expand-file-name (concat name ".txt")
                                                  octocat-screenshots-directory)
                  (insert shot "\n"))
                (delete-region start end)
                (goto-char start)
                (insert (octocat-screenshots--block marker name))))
            (buffer-string))))
    (with-temp-file octocat-screenshots-file
      (insert text))
    ;; So a shot renamed or dropped leaves no file behind.
    (dolist (file (directory-files octocat-screenshots-directory t "\\.\\(?:png\\|txt\\)\\'"))
      (unless (member (file-name-base file) names)
        (delete-file file)))
    (message "Wrote %s" octocat-screenshots-file)
    (when octocat-screenshots--problems
      (error "Octocat screenshots:\n%s"
             (string-join (reverse octocat-screenshots--problems) "\n")))))

(defun octocat-screenshots-update-and-exit ()
  "Run `octocat-screenshots-update' and exit Emacs, 1 if it failed."
  (kill-emacs (condition-case err
                  (progn (octocat-screenshots-update) 0)
                (error (princ (format "%s\n" (error-message-string err))
                              #'external-debugging-output)
                       1))))

(provide 'screenshots)
;;; screenshots.el ends here
