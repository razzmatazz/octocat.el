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

;; In a graphical frame, shows the images that `octocat-markdown-render'
;; marks as alone on their line (`octocat-markdown-image') in place of
;; their "[image: ...]" link.
;;
;; Only images uploaded to GitHub are fetched, see
;; `octocat-image-allowed-p': any other URL in a comment would let its
;; author learn who reads the page, and when, and feed Emacs's image
;; decoders whatever they like.  `url-retrieve' would follow a redirect
;; anywhere, so redirects are followed here instead, one hop at a time,
;; each checked against `octocat-image--redirect-hosts'.
;;
;; An image is fetched once a session and kept in memory.  A rendered
;; string shows the images already fetched at once; one that arrives
;; later is put in place in the buffers that asked for it, without
;; re-rendering them.  An image that cannot be fetched, as one in a
;; private repository, stays a link.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'octocat-markdown)

(defcustom octocat-image-show t
  "Non-nil to show images uploaded to GitHub in markdown.
Only in a graphical frame; elsewhere, and when nil, they are links."
  :type 'boolean
  :group 'octocat-markdown)

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

(defun octocat-image--spans (&optional string)
  "Return the (BEG END PLIST) of each image marked in STRING.
PLIST is its `octocat-markdown-image'.  STRING nil means the current
buffer."
  (let ((pos (if string 0 (point-min)))
        (end (if string (length string) (point-max)))
        spans)
    (while (setq pos (text-property-not-all pos end 'octocat-markdown-image nil string))
      (let ((next (next-single-property-change pos 'octocat-markdown-image string end)))
        (push (list pos next (get-text-property pos 'octocat-markdown-image string))
              spans)
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

(defun octocat-image--arrived (url data)
  "Record DATA, the bytes of URL or nil, and show it where it is waited for."
  (let ((ok (and data
                 (let ((type (image-type-from-data data)))
                   (and type (image-type-available-p type))))))
    (puthash url (if ok data 'failed) octocat-image--cache)
    (when ok
      (dolist (buf (gethash url octocat-image--waiting))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (with-silent-modifications
                (pcase-dolist (`(,beg ,end ,plist) (octocat-image--spans))
                  (when (equal (plist-get plist :url) url)
                    (put-text-property beg end 'display
                                       (octocat-image--image data plist))))))))))
    (remhash url octocat-image--waiting)))

(defun octocat-image--request (url buffer)
  "Fetch URL unless it was, to show it in BUFFER once it arrives."
  (cl-pushnew buffer (gethash url octocat-image--waiting))
  (unless (gethash url octocat-image--cache)
    (puthash url 'pending octocat-image--cache)
    ;; Called while rendering: start the request after it.
    (run-at-time 0 nil #'octocat-image--fetch url octocat-image--max-hops
                 (lambda (data) (octocat-image--arrived url data)))))

(defun octocat-image-display (string)
  "Return STRING, rendered markdown, showing its images already fetched.
Those of its images not fetched yet are fetched, and shown in the
current buffer once they arrive.  STRING is changed."
  (when (and octocat-image-show (display-images-p))
    (pcase-dolist (`(,beg ,end ,plist) (octocat-image--spans string))
      (let* ((url  (plist-get plist :url))
             (data (and (octocat-image-allowed-p url)
                        (gethash url octocat-image--cache 'absent))))
        (cond ((stringp data)
               (put-text-property beg end 'display (octocat-image--image data plist)
                                  string))
              ((memq data '(absent pending))
               (octocat-image--request url (current-buffer)))))))
  string)

(provide 'octocat-image)
;;; octocat-image.el ends here
