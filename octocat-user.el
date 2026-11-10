;;; octocat-user.el --- GitHub user / organization page for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5
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

;; A page for a GitHub handle such as `@octocat': the profile (name, bio,
;; company, location, follower counts), the repositories it has pinned,
;; and its repositories, most recently pushed first.  Organizations work too, since the
;; `users/LOGIN' endpoints serve both.  RET on a repository opens its
;; octocat-repo page.
;;
;; The first page on the sync layer (octocat-sync.el): the profile, the
;; pinned and the full repository list are sync resources, painted from
;; the store at once and refetched behind.  The `M-x octocat-user' entry
;; point is defined in octocat.el (see CONTRIBUTING.md, "Entry points");
;; this file defines `octocat-user-mode' and everything it needs.

;;; Code:

(require 'octocat-core)
(require 'octocat-vui)
(require 'subr-x)
(require 'vui)

(defcustom octocat-section-limit 15
  "Default number of items to display per paged section.
Used as the initial page size for user repos.  Each
section starts with this many items and increments by this amount
every time its \"Load more\" button is used."
  :type 'integer
  :group 'octocat)

(defcustom octocat-user-show-avatar t
  "Whether the user page shows the avatar beside the profile.
Only a graphical frame shows it."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-user-avatar-max-columns 40
  "Widest the avatar is shown, in characters.
The avatar takes a quarter of the window's width up to this limit, so it
grows when the window does, and is left out of a window too narrow for
it.  It is half as many lines tall as it is wide."
  :type 'integer
  :group 'octocat)

(defconst octocat-user--avatar-pixels 460
  "Size, in pixels, of the avatar requested from GitHub, the largest it serves.
It is scaled down to the columns it gets.")

(defvar-local octocat-user--login nil
  "The GitHub login (without the leading \"@\") this buffer shows.")


;;;; Fetching
;;
;; The page reads three sync resources.  The profile is a `user' entity;
;; repositories are `repo' entities, shared by the pinned and the full
;; list.  Entities use GraphQL's field names, so the REST responses are
;; mapped to them.

(defun octocat-user--normalize (input)
  "Return INPUT as a bare GitHub login, or nil when it is not one.
Surrounding whitespace and a leading \"@\" are dropped."
  (let ((login (string-trim-left (string-trim (or input "")) "@")))
    (and (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9-]*\\'" login)
         login)))


;;;; Rendering

(defun octocat-user--count (n label)
  "Return \"N LABEL\" with N in the default face, or nil when N is absent."
  (and (integerp n)
       (concat (number-to-string n) " " (propertize label 'face 'octocat-dimmed))))

(defun octocat-user--profile-lines (profile)
  "Return the list of header strings describing PROFILE.
PROFILE is the data of the `user-profile' resource: the user's fields
under \"user\", and the counts."
  (let* ((user    (gethash "user" profile))
         (login   (gethash "login" user))
         (name    (octocat--nonempty (gethash "name" user)))
         (bio     (octocat--nonempty (gethash "bio" user)))
         (type    (gethash "__typename" user))
         (details (delq nil
                        (mapcar #'octocat--nonempty
                                (list (gethash "company" user)
                                      (gethash "location" user)
                                      (gethash "websiteUrl" user)))))
         (counts  (delq nil
                        (list (octocat-user--count (gethash "followers" profile) "followers")
                              (octocat-user--count (gethash "following" profile) "following")
                              (octocat-user--count (gethash "publicRepos" profile)
                                                   "public repos")))))
    (delq nil
          (list
           ;; The page's pin too, see `octocat-user--root'.
           (concat (propertize (concat "@" login) 'face 'octocat-repo)
                   (when name (concat "  " (propertize name 'face 'octocat-pr-author)))
                   (when (equal type "Organization")
                     (propertize "  (organization)" 'face 'octocat-dimmed)))
           bio
           (and details (mapconcat #'identity details "  ·  "))
           (and counts (mapconcat #'identity counts "  ·  "))))))

(defun octocat-user--avatar-columns (window-width)
  "Return how many columns the avatar gets in a window WINDOW-WIDTH wide.
Zero means too narrow to draw it."
  (let ((cols (min octocat-user-avatar-max-columns (/ window-width 4))))
    (if (< cols 12) 0 cols)))

(defun octocat-user--avatar-rows (data size line-height)
  "Return the image of DATA, SIZE pixels square, cut into LINE-HEIGHT rows.
Each row is a one-character string showing its slice of the image, so
the profile's lines can sit beside them.  Return nil if Emacs cannot
show DATA."
  (let ((type (image-type-from-data data)))
    (when (and type (image-type-available-p type))
      ;; At :scale 1, as `image-scaling-factor' would make it bigger;
      ;; centred on the text, as the default ascent makes each line
      ;; taller than its slice, leaving gaps between them.
      (let ((image (create-image data type t :width size :height size :scale 1
                                 :ascent 'center)))
        (cl-loop for y from 0 below size by line-height
                 collect (propertize " " 'display
                                     (list (list 'slice 0 y size line-height) image)))))))

(defun octocat-user--beside (avatar pad lines)
  "Return LINES, each placed to the right of the matching row of AVATAR.
AVATAR is a list of equally wide strings, and PAD stands in for a row
past its last; the shorter list is padded."
  (cl-loop for i below (max (length avatar) (length lines))
           collect (concat (or (nth i avatar) pad) "  " (or (nth i lines) ""))))

(defun octocat-user--repo-row (repo)
  "Return a RET-able row vnode for REPO, the fields of a `repo' entity."
  (let* ((full  (gethash "nameWithOwner" repo))
         (desc  (octocat--nonempty (gethash "description" repo)))
         (lang  (let ((l (gethash "primaryLanguage" repo)))
                  (and l (octocat--nonempty (gethash "name" l)))))
         (stars (gethash "stargazerCount" repo))
         (pushed (octocat--format-ts-relative (or (gethash "pushedAt" repo) "")))
         (flags (concat (and (eq (gethash "isFork" repo) t) " fork")
                        (and (eq (gethash "isArchived" repo) t) " archived"))))
    (octocat-vui-row
     (concat "  "
             (propertize (or full "") 'face 'octocat-repo)
             (propertize flags 'face 'octocat-dimmed)
             (when desc (concat "  " (truncate-string-to-width desc 60 nil nil "…")))
             (propertize
              (concat (when lang (concat "  " lang))
                      (when (and (integerp stars) (> stars 0)) (format "  ★ %d" stars))
                      (unless (string-empty-p pushed) (concat "  " pushed)))
              'face 'octocat-dimmed))
     (lambda () (octocat-visit-repo full))
     "RET: open repository"
     (and full (octocat--web-url "%s" full)))))


;;;; Components

(defun octocat-user--repo-key (repo)
  "Return the `vui-list' key of REPO."
  (gethash "nameWithOwner" repo))

(vui-defcomponent octocat-user--repos-section (login tick)
  "Repositories of LOGIN, with its own \"load more\" limit.
A new TICK fetches them again."
  :state ((limit octocat-section-limit))
  :render
  (let* ((snap    (octocat-vui-use-resource (list 'user-repos login limit) tick))
         (shown   (vui-use-ref nil))
         (data    (plist-get snap :data))
         (loading (plist-get snap :loading)))
    ;; Each limit is its own resource: keep the shorter list while the
    ;; longer one loads.
    (when data (setcar shown (append (gethash "nodes" data) nil)))
    (let ((repos (car shown)))
      (vui-vstack
       (vui-text "Repositories" :face 'octocat-section-heading)
       (cond
        ((and (null data) (plist-get snap :error) (not loading))
         (vui-text (octocat-vui-error-text snap) :face 'octocat-dimmed))
        ((and (null data) (null repos))
         (vui-text (octocat-vui-line-skeleton "  ")))
        (t
         (vui-fragment
          (if (null repos)
              (vui-text "(no public repositories)" :face 'octocat-dimmed)
            (octocat-vui-reveal-list repos #'octocat-user--repo-row
                                     #'octocat-user--repo-key))
          (when (and repos
                     (or (>= (length repos) limit)
                         ;; Keep the button in place while a further page
                         ;; loads, but not for the first paint.
                         (and loading (> limit octocat-section-limit))))
            (octocat-vui-load-more-button
             'load-more-user-repos octocat-section-limit
             "RET: load more repositories"
             (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
             (and loading (< (length repos) limit)) 2
             (octocat-vui-line-skeleton))))))))))

(vui-defcomponent octocat-user--pinned-section (login tick)
  "Pinned repositories of LOGIN, shown only when there are any.
Pinned repositories are decoration, so nothing is drawn while they load
or when the fetch fails.  A new TICK fetches them again."
  :render
  (let* ((snap  (octocat-vui-use-resource (list 'user-pinned login) tick))
         (data  (plist-get snap :data))
         (repos (and data (append (gethash "nodes" data) nil))))
    (if (null repos)
        (vui-fragment)
      (vui-vstack
       (vui-text "Pinned" :face 'octocat-section-heading)
       (vui-list repos #'octocat-user--repo-row #'octocat-user--repo-key)
       (vui-newline)))))

(vui-defcomponent octocat-user--header (profile)
  "Profile lines of PROFILE with its avatar beside them.
The image is fetched once; it is scaled again each time the window's
width changes."
  :render
  (let* ((width  (octocat-vui-window-width))
         (url    (and octocat-user-show-avatar
                      (display-images-p)
                      (octocat--nonempty (gethash "avatarUrl" (gethash "user" profile)))))
         (result (vui-use-async (list 'user-avatar url)
                   (lambda (resolve reject)
                     (if (null url)
                         (funcall resolve nil)
                       (octocat-image-fetch
                        (concat url (if (string-search "?" url) "&" "?")
                                "s=" (number-to-string octocat-user--avatar-pixels))
                        (lambda (data)
                          (if data
                              (funcall resolve data)
                            (funcall reject "Could not fetch the avatar"))))))))
         (cols   (if url (octocat-user--avatar-columns width) 0))
         (size   (* cols (frame-char-width)))
         (data   (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data)))
         (lines  (octocat-user--profile-lines profile))
         (art    (cond ((= cols 0) nil)
                       (data (octocat-user--avatar-rows data size (frame-char-height)))
                       ;; A grey block the size of the avatar, so the
                       ;; text stays put when it arrives.
                       ((eq (plist-get result :status) 'pending)
                        (make-list (ceiling size (frame-char-height))
                                   (octocat-vui-skeleton-bar cols))))))
    (vui-vstack
     (mapcar (lambda (line) (vui-text line))
             (if art
                 (octocat-user--beside
                  art (propertize " " 'display `(space :width (,size))) lines)
               lines)))))

(vui-defcomponent octocat-user--root (login tick)
  "Root component of the user page: profile header, then repositories.
A new TICK fetches everything again."
  :render
  (let* ((snap    (octocat-vui-use-resource (list 'user-profile login) tick))
         (handle  (vui-text (propertize (concat "@" login) 'face 'octocat-repo)))
         (profile (plist-get snap :data)))
    (octocat-vui-page
     (if profile
         (car (octocat-user--profile-lines profile))
       (propertize (concat "@" login) 'face 'octocat-repo))
     (vui-vstack
      (when (eq (octocat-vui-snapshot-status snap) 'error) handle)
      (octocat-vui-resource-view
       snap
       :skeleton (lambda (_)
                   (vui-vstack handle (vui-text (octocat-vui-skeleton '((24) (40) (18))))))
       :render (lambda (profile) (vui-component 'octocat-user--header :profile profile)))
      (vui-newline)
      (vui-component 'octocat-user--pinned-section :login login :tick tick)
      (vui-component 'octocat-user--repos-section :login login :tick tick)))))


;;;; Major mode

(defun octocat-user--page-url ()
  "Return the URL of the current user's or organization's GitHub page."
  (and octocat-user--login (octocat--web-url "%s" octocat-user--login)))

(defvar octocat-user-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map octocat-page-mode-map)
    map)
  "Keymap for `octocat-user-mode'.")

(define-derived-mode octocat-user-mode octocat-page-mode "Octocat-User"
  "Major mode for a GitHub user or organization page.

\\{octocat-user-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-user-refresh)
  (setq-local octocat--url-function #'octocat-user--page-url))

(defun octocat-user-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-user buffer."
  (interactive)
  (unless octocat-user--login
    (user-error "Octocat: Buffer is not associated with a GitHub user"))
  (octocat-vui-refresh-page 'octocat-user--root octocat-user--login
                            (list :login octocat-user--login)))

(defun octocat-user-open (login)
  "Open (or switch to) the page of the GitHub user or organization LOGIN.
A leading \"@\" is accepted."
  (let ((login (or (octocat-user--normalize login)
                   (user-error "Octocat: `%s' is not a GitHub login" login))))
    (octocat-display-buffer (get-buffer-create (format "*@%s*" login)))
    (unless (derived-mode-p 'octocat-user-mode)
      (octocat-user-mode))
    (setq octocat-user--login login)
    (octocat-user-refresh)))

(cl-defmethod octocat-open ((_kind (eql 'user)) login)
  "Open the page of LOGIN, as `octocat-user-open'."
  (octocat-user-open login))

;; NOTE: the `M-x octocat-user' entry point is defined in `octocat.el' --
;; see CONTRIBUTING.md, "Entry points".

(provide 'octocat-user)
;;; octocat-user.el ends here
