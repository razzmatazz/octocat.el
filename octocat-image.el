;;; octocat-image.el --- Show images uploaded to GitHub in markdown  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; In a graphical frame, `RET' on an image that `octocat-markdown-render'
;; marks as alone on its line (`octocat-markdown-image') fetches it and
;; shows it in place of its "[image: ...]" link; `RET' on the image then
;; opens it in the browser.  Nothing is fetched until asked for.
;;
;; Only images uploaded to GitHub can be fetched, see
;; `octocat-image-allowed-p', and those of the repository a README
;; is in, which `octocat-image-file-function' fetches through `gh': any
;; other URL in a comment would let its
;; author learn who reads the page, and when, and feed Emacs's image
;; decoders whatever they like.  `url-retrieve' would follow a redirect
;; anywhere, so redirects are followed here instead, one hop at a time,
;; each checked against `octocat-image--redirect-hosts'.  An image that
;; cannot be fetched, as one in a private repository, stays a link.
;;
;; A fetched image is kept in memory for the session.  It is put on the
;; buffer's text, not on the rendered string, by a `jit-lock' function,
;; as fontification would be: pages re-render often, from strings cached
;; by `vui-use-memo' before the image was fetched, and the function
;; shows it again on whatever text comes to be displayed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jit-lock)
(require 'url)
(require 'url-http)
(require 'octocat-markdown)

(defcustom octocat-image-max-lines 20
  "The most lines of text an image may be as tall as."
  :type 'natnum
  :group 'octocat-markdown)

(defconst octocat-image--max-bytes (* 20 1024 1024)
  "Larger responses are not shown.")

(defconst octocat-image--max-hops 3
  "The most redirects followed for one image.")

(defconst octocat-image--redirect-hosts
  '("private-user-images.githubusercontent.com"
    "github-production-user-asset-6210df.s3.amazonaws.com")
  "Hosts an upload's URL may redirect to.
github.com/user-attachments/assets/ redirects to S3 when fetched
without a session.")

(defvar octocat-image-file-function nil
  "Function that fetches a file of a repository, for a relative image.
Called with REPO, REF, PATH and a callback, which it calls with the
file's bytes, or nil if they cannot be had.")

(defvar octocat-image-loading-function nil
  "Function that shows whether a buffer waits for an image.
Called with the BUFFER and LOADING, t when it starts waiting for one,
nil when that one arrived or failed.")

(defvar-local octocat-image--shown nil
  "URLs of the images asked for here, to show once fetched.
`octocat-image-reset' forgets them.")

(defvar octocat-image--cache (make-hash-table :test #'equal)
  "URL to its image's bytes, `pending' while fetched, or `failed'.")

(defvar octocat-image--waiting (make-hash-table :test #'equal)
  "URL being fetched to the buffers to show it in once it arrives.")

(defun octocat-image--https-host (url)
  "Return the host of URL, downcased, if it is https on the default port."
  (let ((u (url-generic-parse-url url)))
    (and (equal (url-type u) "https")
         (eql (url-port u) 443)
         (url-host u)
         (downcase (url-host u)))))

(defun octocat-image-allowed-p (url)
  "Return non-nil if URL is of an image uploaded to GitHub.
Uploads went to user-images.githubusercontent.com until 2023; now they
are github.com/user-attachments/assets/, which GitHub's HTML gives as
signed private-user-images.githubusercontent.com links."
  (pcase (octocat-image--https-host url)
    ((or "user-images.githubusercontent.com"
         "private-user-images.githubusercontent.com")
     t)
    ("github.com"
     (string-prefix-p "/user-attachments/assets/"
                      (url-filename (url-generic-parse-url url))))))

(defun octocat-image--fetchable-p (plist)
  "Return non-nil if the image of PLIST can be fetched.
PLIST is its `octocat-markdown-image'."
  (if (plist-get plist :file)
      octocat-image-file-function
    (octocat-image-allowed-p (plist-get plist :url))))

(defun octocat-image--redirect-allowed-p (url)
  "Return non-nil if an upload's URL may redirect to URL."
  (or (octocat-image-allowed-p url)
      (member (octocat-image--https-host url) octocat-image--redirect-hosts)))

(defun octocat-image--fetch (url hops callback)
  "Fetch URL and call CALLBACK with its body, or nil if that failed.
Allowed redirects are followed, at most HOPS of them."
  (condition-case nil
      (let* ((url-max-redirections 0)
             (buf (url-retrieve url #'octocat-image--fetched
                                (list hops callback) t t)))
        ;; Older url-http reads it in the response buffer, once this
        ;; binding is gone.
        (when (buffer-live-p buf)
          (with-current-buffer buf (setq-local url-max-redirections 0))))
    (error (funcall callback nil))))

(defun octocat-image--fetched (status hops callback)
  "Hand the body of the finished fetch to CALLBACK, or follow its redirect.
STATUS is the retrieval's status plist; the current buffer holds the
response, and is killed here.  HOPS is as for `octocat-image--fetch'."
  (let (body next)
    (pcase (plist-get status :error)
      ;; With `url-max-redirections' 0, a redirect is this error.
      (`(error http-redirect-limit ,to) (setq next to))
      ('nil
       (goto-char (point-min))
       (when (and (looking-at "HTTP/[0-9.]+ 200")
                  (re-search-forward "\r?\n\r?\n" nil t)
                  (<= (- (point-max) (point)) octocat-image--max-bytes))
         (setq body (buffer-substring-no-properties (point) (point-max))))))
    (kill-buffer (current-buffer))
    (if (and next (> hops 0) (octocat-image--redirect-allowed-p next))
        (octocat-image--fetch next (1- hops) callback)
      (funcall callback body))))

(defun octocat-image--spans (beg end)
  "Return the (BEG END PLIST) of each image marked from BEG to END.
PLIST is its `octocat-markdown-image'.  A span is returned whole, even
where it reaches past BEG or END."
  (let ((pos (if (and (> beg (point-min)) (get-text-property beg 'octocat-markdown-image))
                 (or (previous-single-property-change beg 'octocat-markdown-image)
                     (point-min))
               beg))
        spans)
    (while (and (< pos end)
                (setq pos (text-property-not-all pos end 'octocat-markdown-image nil)))
      (let ((next (next-single-property-change pos 'octocat-markdown-image nil (point-max))))
        (push (list pos next (get-text-property pos 'octocat-markdown-image)) spans)
        (setq pos next)))
    (nreverse spans)))

(defun octocat-image--image (data plist)
  "Return the image of DATA, sized to fit PLIST's :cols and :width."
  (let ((cols  (plist-get plist :cols))
        (width (plist-get plist :width)))
    (apply #'create-image data nil t
           :max-height (* octocat-image-max-lines (frame-char-height))
           (when-let* ((max (delq nil (list width (and cols (* cols (frame-char-width)))))))
             (list :max-width (apply #'min max))))))

(defvar octocat-image-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'octocat-image-show)
    (define-key map [mouse-1] #'octocat-image-show)
    map)
  "Keymap put on an image's link until the image is shown.")

(defun octocat-image--fontify (beg end)
  "Show the fetched images marked from BEG to END; offer to fetch the others.
For `jit-lock-functions'."
  (when (display-images-p)
    (pcase-dolist (`(,b ,e ,plist) (octocat-image--spans beg end))
      (let* ((url  (plist-get plist :url))
             (data (and (octocat-image--fetchable-p plist)
                        (gethash url octocat-image--cache 'absent)))
             ;; Fetched, but not asked for here since the last reset.
             (data (if (and data (not (member url octocat-image--shown))) 'absent data)))
        (cond ((stringp data)
               (unless (get-text-property b 'octocat-image--face)
                 (put-text-property b e 'octocat-image--face
                                    (list (get-text-property b 'face))))
               (add-text-properties
                ;; The link's underline would be drawn under the image.
                b e (list 'face nil
                          'octocat-vui-spinner nil
                          'display (octocat-image--image data plist)
                          'keymap octocat-markdown-link-map
                          'help-echo (if (plist-get plist :file)
                                         "RET: open the image's file; C-c C-o: on GitHub"
                                       (format "RET: open %s" url)))))
              ((eq data 'pending)
               (let ((link (octocat-image--link b e)))
                 (add-text-properties
                  ;; `octocat-vui' turns the spinner, see `octocat-vui-spinner'.
                  b e (list 'octocat-vui-spinner
                            (lambda (frame) (octocat-image--loading-label frame link))
                            'display (octocat-image--loading-label "…" link)
                            'keymap octocat-image-map
                            'help-echo "Loading image…"))))
              (data
               (when-let* ((face (get-text-property b 'octocat-image--face)))
                 (put-text-property b e 'face (car face)))
               (remove-text-properties
                b e '(display nil octocat-vui-spinner nil octocat-image--face nil))
               (add-text-properties
                b e (list 'keymap octocat-image-map
                          'help-echo "RET: show image")))))))
  nil)

(defun octocat-image--link (beg end)
  "Return the link from BEG to END, without what is displayed over it."
  (let ((link (buffer-substring beg end)))
    (remove-text-properties 0 (length link) '(display nil octocat-vui-spinner nil) link)
    link))

(defun octocat-image--loading-label (frame link)
  "Return LINK, its image loading, after FRAME of a spinner."
  (concat (propertize frame 'face 'shadow) " " link))

(defun octocat-image--refontify (url)
  "Have the current buffer's images of URL shown afresh."
  (pcase-dolist (`(,b ,e ,plist) (octocat-image--spans (point-min) (point-max)))
    (when (equal (plist-get plist :url) url)
      (jit-lock-refontify b e))))

(defun octocat-image--arrived (url data)
  "Record DATA, the bytes of URL or nil, and show it where it was asked for."
  (let ((ok (and data
                 (let ((type (image-type-from-data data)))
                   (and type (image-type-available-p type))))))
    (puthash url (if ok data 'failed) octocat-image--cache)
    (unless ok (message "Octocat: could not load %s" url))
    (dolist (buf (gethash url octocat-image--waiting))
      (when (buffer-live-p buf)
        (when octocat-image-loading-function
          (funcall octocat-image-loading-function buf nil))
        (with-current-buffer buf (octocat-image--refontify url))))
    (remhash url octocat-image--waiting)))

(defun octocat-image--request (plist buffer)
  "Fetch the image of PLIST, to show it in BUFFER once it arrives.
A failed fetch is retried."
  (let* ((url  (plist-get plist :url))
         (file (plist-get plist :file))
         (done (lambda (data) (octocat-image--arrived url data)))
         (have (gethash url octocat-image--cache)))
    ;; Fetched already, as for an image shown again after a reset.
    (unless (stringp have)
      (unless (memq buffer (gethash url octocat-image--waiting))
        (push buffer (gethash url octocat-image--waiting))
        (when octocat-image-loading-function
          (funcall octocat-image-loading-function buffer t)))
      (unless (eq have 'pending)
        (puthash url 'pending octocat-image--cache)
        (if file
            (apply octocat-image-file-function (append file (list done)))
          (octocat-image--fetch url octocat-image--max-hops done))))))

(defun octocat-image-show (&optional event)
  "Fetch and show the image whose link is at point (or at EVENT)."
  (interactive (list last-nonmenu-event))
  (let* ((pos   (if (mouse-event-p event) (posn-point (event-start event)) (point)))
         (buf   (if (mouse-event-p event) (window-buffer (posn-window (event-start event)))
                  (current-buffer)))
         (plist (with-current-buffer buf (get-text-property pos 'octocat-markdown-image)))
         (url   (plist-get plist :url)))
    (unless (and url (octocat-image--fetchable-p plist))
      (user-error "Octocat: no image to show here"))
    (with-current-buffer buf
      (cl-pushnew url octocat-image--shown :test #'equal)
      (octocat-image--request plist buf)
      (octocat-image--refontify url))))

(defun octocat-image-reset ()
  "Show the current buffer's images as their links again.
Those fetched stay kept, so asking again shows them at once."
  (setq octocat-image--shown nil)
  (when (bound-and-true-p jit-lock-mode)
    (jit-lock-refontify)))

(defun octocat-image-enable ()
  "Show fetched images, and offer the others, in the current buffer's markdown."
  (unless (memq #'octocat-image--fontify jit-lock-functions)
    (jit-lock-register #'octocat-image--fontify)))

(provide 'octocat-image)
;;; octocat-image.el ends here
