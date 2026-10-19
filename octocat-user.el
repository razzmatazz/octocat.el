;;; octocat-user.el --- GitHub user / organization page for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
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

(require 'octocat-avatar)
(require 'octocat-core)
(require 'octocat-repo)
(require 'octocat-sync)
(require 'octocat-vui)
(require 'subr-x)
(require 'vui)
(require 'vui-components)

(defcustom octocat-user-show-avatar t
  "Whether the user page draws the avatar as ASCII art beside the profile."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-user-avatar-max-columns 40
  "Widest the avatar is drawn, in characters.
The avatar takes a quarter of the window's width up to this limit, so it
grows when the window does, and is left out of a window too narrow for
it.  It is half as many lines tall as it is wide."
  :type 'integer
  :group 'octocat)

(defcustom octocat-user-avatar-style nil
  "Characters the avatar is drawn with.
nil picks quadrant blocks, or plain 7-bit ASCII when Emacs cannot
display Unicode.  The others are `blocks' (quadrant blocks with
foreground and background colours), `ramp' (Unicode shade characters)
and `ascii'.  See `octocat-avatar-render'."
  :type '(choice (const :tag "Automatic" nil)
                 (const :tag "Quadrant blocks" blocks)
                 (const :tag "Unicode shade ramp" ramp)
                 (const :tag "7-bit ASCII" ascii))
  :group 'octocat)

(defconst octocat-user--avatar-pixels 128
  "Size, in pixels, of the avatar requested from GitHub.
Enough for `octocat-user-avatar-max-columns' at the default of 40.")

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

(defun octocat-user--table (&rest pairs)
  "Return a hash table of PAIRS, alternating keys and values."
  (let ((h (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) h))
    h))

(defun octocat-user--parse-profile (json-string)
  "Parse the `users/LOGIN' response JSON-STRING into the profile resource.
The user is an entity; the counts belong to this resource."
  (let ((p (json-parse-string json-string :null-object nil)))
    (octocat-user--table
     "user" (octocat-sync-entity
             'user (concat "user:" (downcase (gethash "login" p)))
             (octocat-user--table
              "login" (gethash "login" p)
              "__typename" (gethash "type" p)
              "name" (gethash "name" p)
              "bio" (gethash "bio" p)
              "company" (gethash "company" p)
              "location" (gethash "location" p)
              "websiteUrl" (gethash "blog" p)
              "avatarUrl" (gethash "avatar_url" p)))
     "followers" (gethash "followers" p)
     "following" (gethash "following" p)
     "publicRepos" (gethash "public_repos" p))))

(defun octocat-user--parse-repos (json-string)
  "Parse the `users/LOGIN/repos' response JSON-STRING into a list resource."
  (octocat-user--table
   "nodes" (cl-map 'vector #'octocat-sync-repo-rest
                   (json-parse-string json-string :null-object nil))))

(defconst octocat-user--pinned-query
  "query($login:String!){repositoryOwner(login:$login){... on ProfileOwner{pinnedItems(first:6,types:REPOSITORY){nodes{... on Repository{nameWithOwner description stargazerCount primaryLanguage{name} pushedAt isFork isArchived}}}}}}"
  "GraphQL query behind the `user-pinned' resource.
The REST API does not expose pinned repositories.")

(defun octocat-user--parse-pinned (json-string)
  "Parse the GraphQL response JSON-STRING into a list resource.
Pinned gists, which come back as empty nodes, are left out."
  (let* ((data  (gethash "data" (json-parse-string json-string :null-object nil)))
         (owner (and data (gethash "repositoryOwner" data)))
         (items (and owner (gethash "pinnedItems" owner)))
         (nodes (and items (gethash "nodes" items))))
    (octocat-user--table
     "nodes" (vconcat (delq nil (mapcar (lambda (node)
                                          (and node (gethash "nameWithOwner" node)
                                               (octocat-sync-repo node)))
                                        nodes))))))

(octocat-sync-define-resource user-profile (login)
  :fetch (lambda (done)
           (octocat--run-gh "user-profile" (list "api" (format "users/%s" login))
                            #'octocat-user--parse-profile done)))

(octocat-sync-define-resource user-repos (login limit)
  ;; The limit is in the URL so that `gh api' issues a GET.
  :fetch (lambda (done)
           (octocat--run-gh "user-repos"
                            (list "api" (format "users/%s/repos?sort=pushed&per_page=%d"
                                                login limit))
                            #'octocat-user--parse-repos done)))

(octocat-sync-define-resource user-pinned (login)
  :fetch (lambda (done)
           (octocat--run-gh "user-pinned"
                            (list "api" "graphql"
                                  "-f" (concat "query=" octocat-user--pinned-query)
                                  "-F" (concat "login=" login))
                            #'octocat-user--parse-pinned done)))


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

(defun octocat-user--beside (avatar lines)
  "Return LINES, each placed to the right of the matching row of AVATAR.
AVATAR is a list of equally wide strings; the shorter list is padded."
  (let ((pad (make-string (string-width (car avatar)) ?\s)))
    (cl-loop for i below (max (length avatar) (length lines))
             collect (concat (or (nth i avatar) pad) "  " (or (nth i lines) "")))))

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
     "RET: open repository")))


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
    (octocat-vui-use-mode-line-loading loading)
    (let ((repos (car shown)))
      (vui-vstack
       (vui-text "Repositories" :face 'octocat-section-heading)
       (cond
        ((and (null data) (plist-get snap :error) (not loading))
         (vui-text (plist-get snap :error) :face 'octocat-dimmed))
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
    (octocat-vui-use-mode-line-loading (plist-get snap :loading))
    (if (null repos)
        (vui-fragment)
      (vui-vstack
       (vui-text "Pinned" :face 'octocat-section-heading)
       (vui-list repos #'octocat-user--repo-row #'octocat-user--repo-key)
       (vui-newline)))))

(vui-defcomponent octocat-user--header (profile)
  "Profile lines of PROFILE with its avatar drawn beside them in ASCII.
The image is fetched and decoded once; it is drawn again, cheaply, each
time the window's width changes."
  :render
  (let* ((width  (octocat-vui-window-width))
         (url    (and octocat-user-show-avatar
                      (octocat--nonempty (gethash "avatarUrl" (gethash "user" profile)))))
         (result (vui-use-async (list 'user-avatar url)
                   (lambda (resolve reject)
                     (if (null url)
                         (funcall resolve nil)
                       (octocat-avatar-fetch
                        (concat url (if (string-search "?" url) "&" "?")
                                "s=" (number-to-string octocat-user--avatar-pixels))
                        (lambda (r)
                          (if (eq (car-safe r) 'error)
                              (funcall reject (cdr r))
                            (funcall resolve (octocat-avatar-decode r)))))))))
         (cols   (octocat-user--avatar-columns width))
         (image  (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data)))
         (lines  (octocat-user--profile-lines profile))
         (art    (cond ((= cols 0) nil)
                       (image (octocat-avatar-render
                               image cols nil octocat-user-avatar-style))
                       ;; A grey block the size of the square avatar, so
                       ;; the text stays put when it arrives.
                       ((and url (eq (plist-get result :status) 'pending))
                        (make-list (max 1 (/ cols 2)) (octocat-vui-skeleton-bar cols))))))
    (vui-vstack
     (mapcar (lambda (line) (vui-text line))
             (if art (octocat-user--beside art lines) lines)))))

(vui-defcomponent octocat-user--root (login tick)
  "Root component of the user page: profile header, then repositories.
A new TICK fetches everything again."
  :render
  (let* ((snap    (octocat-vui-use-resource (list 'user-profile login) tick))
         (profile (plist-get snap :data))
         (handle  (vui-text (propertize (concat "@" login) 'face 'octocat-repo))))
    (octocat-vui-use-mode-line-loading (plist-get snap :loading))
    (vui-vstack
     (cond
      (profile (vui-component 'octocat-user--header :profile profile))
      ((and (plist-get snap :error) (not (plist-get snap :loading)))
       (vui-vstack handle (vui-text (plist-get snap :error) :face 'octocat-dimmed)))
      (t (vui-vstack handle (vui-text (octocat-vui-skeleton '((24) (40) (18)))))))
     (vui-newline)
     (vui-component 'octocat-user--pinned-section :login login :tick tick)
     (vui-component 'octocat-user--repos-section :login login :tick tick))))


;;;; Major mode

(defun octocat-user-browse ()
  "Open the current user's or organization's GitHub page in a browser."
  (interactive)
  (unless octocat-user--login
    (user-error "Octocat: Buffer is not associated with a GitHub user"))
  (message "Octocat: Opening @%s in browser…" octocat-user--login)
  (octocat-browse-external (concat "https://github.com/" octocat-user--login)))

(defvar octocat-user-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-user-mode'.")
(define-key octocat-user-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-user-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-user-mode-map (kbd "C-c C-o") #'octocat-user-browse)
(define-key octocat-user-mode-map (kbd "C-c C-j") #'octocat-switch-repo)

(define-derived-mode octocat-user-mode vui-mode "Octocat-User"
  "Major mode for a GitHub user or organization page.

\\{octocat-user-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-user-refresh)
  (octocat--ts-eldoc-setup))

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

;; NOTE: the `M-x octocat-user' entry point is defined in `octocat.el' --
;; see CONTRIBUTING.md, "Entry points".

(provide 'octocat-user)
;;; octocat-user.el ends here
