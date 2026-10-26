;;; octocat-markdown.el --- GitHub markdown renderer  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Renders GitHub-flavoured markdown for display in octocat buffers.
;;
;; This module has no dependencies on the rest of octocat (or on any
;; markdown package), so `octocat-core' can require it.  The renderer
;; turns markdown source into a propertized string, one source line per
;; row (GitHub shows single newlines in comments as line breaks), with
;; the markup characters removed and faces applied instead.
;;
;; Block level: ATX and setext headings, horizontal rules, fenced and
;; indented code (syntax-highlighted by language), block quotes
;; (including `> [!NOTE]' alerts), bullet, numbered and task lists with
;; nesting, tables, HTML <table>s, footnotes, collapsible <details> and
;; <pre> (where, as on GitHub, only HTML is rendered).  Inline: `code', **bold**,
;; *italic*, ~~strike~~, inline and reference-style links, images,
;; autolinks, @mentions, #123 and commit references, :emoji: shortcodes
;; and $math$.  HTML formatting tags and <a href> links are rendered too;
;; comments are dropped and other tags stripped, keeping their content.  Mermaid fences are
;; drawn by `octocat-mermaid' to fit the width.
;;
;; Links, #123 and commit references and <details> summaries are
;; interactive: they carry a `keymap' text property binding RET and
;; mouse-1 to `octocat-markdown-follow', which works in any buffer the
;; rendered string is inserted into.  Relative links and images, as in
;; a README, point into the repository `octocat-markdown-base' names.
;;
;; Entry points: `octocat-markdown-render' and
;; `octocat-markdown-render-verbatim'.  `octocat-markdown-font-lock-keywords'
;; highlights markdown source in an edit buffer.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-util)
(require 'octocat-mermaid)

(declare-function octocat--markdown-open-ref "octocat-core" (kind repo id))

;;;; Faces

(defgroup octocat-markdown nil
  "Markdown rendering in octocat buffers."
  :group 'tools
  :prefix "octocat-markdown-")

(defface octocat-markdown-heading
  '((t :weight bold))
  "Face for markdown headings."
  :group 'octocat-markdown)

;; A terminal ignores :height, so there h1 is underlined and h2 coloured
;; to tell the levels apart.
(defface octocat-markdown-heading-1
  '((((type graphic)) :inherit octocat-markdown-heading :height 1.3)
    (t :inherit octocat-markdown-heading :underline t))
  "Face for first-level markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-heading-2
  '((((type graphic)) :inherit octocat-markdown-heading :height 1.15)
    (t :inherit (octocat-markdown-heading font-lock-function-name-face)))
  "Face for second-level markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-code
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face for inline code and code blocks."
  :group 'octocat-markdown)

(defface octocat-markdown-code-block
  '((((class color) (background dark))  :inherit fixed-pitch :background "grey20")
    (((class color) (background light)) :inherit fixed-pitch :background "grey92")
    (t :inherit fixed-pitch))
  "Face for the lines of a fenced code block."
  :group 'octocat-markdown)

(defface octocat-markdown-image
  '((t :inherit octocat-markdown-link :slant italic :weight bold))
  "Face for the link of an image, apart from other links."
  :group 'octocat-markdown)

(defface octocat-markdown-link
  '((t :inherit link))
  "Face for markdown links."
  :group 'octocat-markdown)

(defface octocat-markdown-mention
  '((t :inherit font-lock-keyword-face))
  "Face for @mentions and #123 references."
  :group 'octocat-markdown)

(defface octocat-markdown-strike
  '((t :strike-through t))
  "Face for ~~struck~~ text."
  :group 'octocat-markdown)

(defface octocat-markdown-dimmed
  '((t :inherit shadow))
  "Face for markdown decoration: quote bars, rules, table borders."
  :group 'octocat-markdown)

;;;; Inline

(defconst octocat-markdown--entities
  '(("amp" . "&") ("lt" . "<") ("gt" . ">") ("quot" . "\"")
    ("apos" . "'") ("nbsp" . " "))
  "Named character references understood by the inline renderer.")

(defun octocat-markdown--face (string &rest faces)
  "Return STRING with FACES added on top of any faces it already has."
  (let ((s (copy-sequence string)))
    (dolist (f faces)
      (add-face-text-property 0 (length s) f t s))
    s))

;;;; Following links

(defvar octocat-markdown-ref-function #'octocat--markdown-open-ref
  "Function that opens a reference found in rendered markdown.
Called with KIND (`issue' or `commit'), REPO (an \"owner/name\" string, or
nil for the repository of the current buffer) and ID (an issue number or
a commit SHA).")

(defvar octocat-markdown-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'octocat-markdown-follow)
    (define-key map [mouse-1] #'octocat-markdown-follow)
    map)
  "Keymap put on links, references and <details> summaries.
It is a `keymap' text property, which takes precedence over the major mode
and Evil state maps, so RET works in every buffer a rendered string lands in.")

(defun octocat-markdown--interactive (s help &rest props)
  "Return S made interactive: highlighted, with HELP and PROPS, RET-able."
  (let ((s (copy-sequence s)))
    (add-text-properties 0 (length s)
                         (append (list 'help-echo help
                                       'mouse-face 'highlight
                                       'keymap octocat-markdown-link-map)
                                 props)
                         s)
    s))

(defvar octocat-markdown-base nil
  "Where the markdown being rendered is, for its relative links, or nil.
A list (REPO REF DIR): directory DIR, \"\" for the root, of REPO at REF,
as for a README.  Bound around `octocat-markdown-render'.")

(defun octocat-markdown--relative-path (url)
  "Return the path in the repository that relative URL names, or nil.
It is resolved against `octocat-markdown-base', a leading slash from
the root; nil when there is none, or URL is absolute or a #fragment.
A link to a directory keeps its trailing slash."
  (when (and octocat-markdown-base
             (not (string-match-p "\\`\\(?:[a-zA-Z][a-zA-Z0-9+.-]*:\\|#\\|//\\)" url)))
    (let* ((path  (car (split-string url "[?#]")))
           (full  (if (string-prefix-p "/" path)
                      path
                    (concat (nth 2 octocat-markdown-base) "/" path)))
           parts)
      (dolist (seg (split-string full "/" t))
        (pcase seg
          ("." nil)
          (".." (pop parts))
          (_ (push seg parts))))
      (concat (string-join (nreverse parts) "/")
              (and (string-suffix-p "/" path) parts "/")))))

(defun octocat-markdown--absolute (url kind)
  "Return URL, or its github.com page when it is relative.
See `octocat-markdown-base'.  KIND is the page of a file: \"blob\" to
read it, \"raw\" for its bytes; a directory's is its \"tree\"."
  (if-let* ((path (octocat-markdown--relative-path url)))
      (format "https://github.com/%s/%s/%s/%s%s"
              (nth 0 octocat-markdown-base)
              (if (string-suffix-p "/" path) "tree" kind)
              (nth 1 octocat-markdown-base)
              (string-remove-suffix "/" path)
              (if (string-match "#.*\\'" url) (match-string 0 url) ""))
    url))

(defun octocat-markdown--unlink (label)
  "Return LABEL without the #123, SHA and @mention links in it.
As on GitHub, a link's label links only to the link's target."
  (let ((s (copy-sequence label)) (i 0))
    (remove-text-properties 0 (length s)
                            '(octocat-markdown-ref nil octocat-markdown-url nil)
                            s)
    (while (< i (length s))
      (let ((next (next-single-property-change i 'face s (length s)))
            (face (get-text-property i 'face s)))
        (when (memq 'octocat-markdown-mention (ensure-list face))
          (let ((rest (remq 'octocat-markdown-mention (ensure-list face))))
            (if rest
                (put-text-property i next 'face (if (cdr rest) rest (car rest)) s)
              (remove-text-properties i next '(face nil) s))))
        (setq i next)))
    s))

(defun octocat-markdown--link (label url)
  "Return LABEL as a link to URL, made absolute if it is relative."
  (let ((url (octocat-markdown--absolute url "blob")))
    (octocat-markdown--interactive
     (octocat-markdown--face (octocat-markdown--unlink label)
                             'octocat-markdown-link)
     (format "RET: open %s" url) 'octocat-markdown-url url)))

(defun octocat-markdown--ref (label kind repo id)
  "Return LABEL as a reference to KIND (`issue' or `commit') ID in REPO."
  (octocat-markdown--interactive
   (octocat-markdown--face label 'octocat-markdown-mention)
   (format "RET: open %s" label) 'octocat-markdown-ref (list kind repo id)))

(defun octocat-markdown--mention (name)
  "Return @NAME (a user or an org/team) as a link to its GitHub page."
  (octocat-markdown--interactive
   (octocat-markdown--face name 'octocat-markdown-mention)
   (format "RET: open %s" name)
   'octocat-markdown-url
   (if (string-match "\\`@\\([^/]+\\)/\\(.+\\)\\'" name)
       (format "https://github.com/orgs/%s/teams/%s"
               (match-string 1 name) (match-string 2 name))
     (concat "https://github.com/" (substring name 1)))))

(defun octocat-markdown--ensure-invisibility ()
  "Make folded <details> bodies invisible in the current buffer."
  (unless (and (listp buffer-invisibility-spec)
               (memq 'octocat-markdown-details buffer-invisibility-spec))
    (add-to-invisibility-spec 'octocat-markdown-details)))

(defun octocat-markdown-toggle-details (&optional pos)
  "Expand or collapse the <details> whose summary is at POS (default point)."
  (interactive)
  (save-excursion
    (goto-char (or pos (point)))
    (let* ((bol (line-beginning-position))
           (arrow (text-property-any bol (line-end-position)
                                     'octocat-markdown-arrow t))
           (inhibit-read-only t)
           beg end hidden)
      (forward-line 1)
      (setq beg (point)
            hidden (eq (get-text-property beg 'invisible) 'octocat-markdown-details))
      (while (and (not (eobp)) (get-text-property (point) 'octocat-markdown-fold))
        (forward-line 1))
      (setq end (point))
      (octocat-markdown--ensure-invisibility)
      (when (> end beg)
        (if hidden
            (remove-text-properties beg end '(invisible nil))
          (put-text-property beg end 'invisible 'octocat-markdown-details))
        (when arrow
          (put-text-property arrow (1+ arrow) 'display (if hidden "▾" "▸")))))))

(defun octocat-markdown-url-at (&optional pos)
  "Return the URL of the link or image at POS (default point), or nil.
Only an absolute one: a link left relative has nowhere to go."
  (let ((url (get-text-property (or pos (point)) 'octocat-markdown-url)))
    (and url (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" url) url)))

(defun octocat-markdown-reset-details ()
  "Open or close every <details> of the current buffer as first rendered."
  (let ((pos (point-min)))
    (while (setq pos (text-property-any pos (point-max) 'octocat-markdown-arrow t))
      (let ((open  (equal (get-text-property pos 'display) "▾"))
            (first (save-excursion
                     (goto-char pos)
                     (forward-line 1)
                     (eq (get-text-property (point) 'octocat-markdown-fold) 'open))))
        (unless (eq open first)
          (octocat-markdown-toggle-details pos))
        (setq pos (1+ pos))))))

(defun octocat-markdown-follow (&optional event)
  "Follow the link, reference or <details> summary at point (or at EVENT)."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (mouse-event-p event) (posn-point (event-start event)) (point)))
         (url (get-text-property pos 'octocat-markdown-url))
         (ref (get-text-property pos 'octocat-markdown-ref)))
    (cond (ref (if octocat-markdown-ref-function
                   (apply octocat-markdown-ref-function ref)
                 (user-error "Octocat: no way to open %s" (nth 2 ref))))
          ;; `browse-url' would take a relative link for a local file.
          ((and url (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" url)))
           (user-error "Octocat: no way to open %s" url))
          (url (browse-url url))
          ((get-text-property pos 'octocat-markdown-details)
           (octocat-markdown-toggle-details pos))
          (t (user-error "Octocat: nothing to follow here")))))

;;;; Emoji, math and footnote helpers

(defconst octocat-markdown--emoji
  '(("tada" . "🎉") ("+1" . "👍") ("-1" . "👎") ("thumbsup" . "👍")
    ("thumbsdown" . "👎") ("rocket" . "🚀") ("heart" . "❤️") ("smile" . "😄")
    ("smiley" . "😃") ("grin" . "😁") ("joy" . "😂") ("laughing" . "😆")
    ("wink" . "😉") ("thinking" . "🤔") ("confused" . "😕") ("cry" . "😢")
    ("sob" . "😭") ("warning" . "⚠️") ("white_check_mark" . "✅")
    ("heavy_check_mark" . "✔️") ("x" . "❌") ("bug" . "🐛") ("sparkles" . "✨")
    ("fire" . "🔥") ("eyes" . "👀") ("memo" . "📝") ("lock" . "🔒")
    ("wrench" . "🔧") ("hammer" . "🔨") ("construction" . "🚧") ("zap" . "⚡")
    ("bulb" . "💡") ("books" . "📚") ("star" . "⭐") ("100" . "💯")
    ("pray" . "🙏") ("clap" . "👏") ("wave" . "👋") ("ok_hand" . "👌")
    ("muscle" . "💪") ("boom" . "💥") ("package" . "📦") ("gear" . "⚙️")
    ("link" . "🔗") ("mag" . "🔍") ("bookmark" . "🔖") ("pushpin" . "📌")
    ("hourglass" . "⌛") ("tada2" . "🎊") ("question" . "❓")
    ("exclamation" . "❗") ("point_right" . "👉") ("point_left" . "👈")
    ("recycle" . "♻️") ("art" . "🎨") ("lipstick" . "💄") ("ambulance" . "🚑")
    ("rewind" . "⏪") ("truck" . "🚚") ("shipit" . "🐿️") ("turtle" . "🐢")
    ("snake" . "🐍") ("coffee" . "☕") ("beer" . "🍺") ("pizza" . "🍕")
    ("skull" . "💀") ("poop" . "💩") ("see_no_evil" . "🙈")
    ("information_source" . "ℹ️") ("arrow_right" . "➡️") ("arrow_left" . "⬅️")
    ("arrow_up" . "⬆️") ("arrow_down" . "⬇️") ("green_circle" . "🟢")
    ("red_circle" . "🔴") ("large_blue_circle" . "🔵") ("sunny" . "☀️")
    ("octocat" . "🐙") ("trophy" . "🏆") ("crown" . "👑") ("gift" . "🎁"))
  "Emoji shortcodes understood by the inline renderer.")

(defconst octocat-markdown--tex-symbols
  '(("alpha" . "α") ("beta" . "β") ("gamma" . "γ") ("delta" . "δ")
    ("epsilon" . "ε") ("varepsilon" . "ε") ("zeta" . "ζ") ("eta" . "η")
    ("theta" . "θ") ("iota" . "ι") ("kappa" . "κ") ("lambda" . "λ")
    ("mu" . "μ") ("nu" . "ν") ("xi" . "ξ") ("pi" . "π") ("rho" . "ρ")
    ("sigma" . "σ") ("tau" . "τ") ("upsilon" . "υ") ("phi" . "φ")
    ("varphi" . "φ") ("chi" . "χ") ("psi" . "ψ") ("omega" . "ω")
    ("Gamma" . "Γ") ("Delta" . "Δ") ("Theta" . "Θ") ("Lambda" . "Λ")
    ("Xi" . "Ξ") ("Pi" . "Π") ("Sigma" . "Σ") ("Phi" . "Φ") ("Psi" . "Ψ")
    ("Omega" . "Ω") ("sum" . "∑") ("prod" . "∏") ("int" . "∫")
    ("oint" . "∮") ("infty" . "∞") ("partial" . "∂") ("nabla" . "∇")
    ("pm" . "±") ("mp" . "∓") ("times" . "×") ("div" . "÷") ("cdot" . "·")
    ("ast" . "∗") ("circ" . "∘") ("le" . "≤") ("leq" . "≤") ("ge" . "≥")
    ("geq" . "≥") ("ne" . "≠") ("neq" . "≠") ("approx" . "≈")
    ("equiv" . "≡") ("sim" . "∼") ("propto" . "∝") ("ll" . "≪")
    ("gg" . "≫") ("in" . "∈") ("notin" . "∉") ("subset" . "⊂")
    ("supset" . "⊃") ("subseteq" . "⊆") ("supseteq" . "⊇") ("cup" . "∪")
    ("cap" . "∩") ("emptyset" . "∅") ("forall" . "∀") ("exists" . "∃")
    ("neg" . "¬") ("land" . "∧") ("lor" . "∨") ("to" . "→")
    ("rightarrow" . "→") ("leftarrow" . "←") ("leftrightarrow" . "↔")
    ("Rightarrow" . "⇒") ("Leftarrow" . "⇐") ("Leftrightarrow" . "⇔")
    ("mapsto" . "↦") ("ldots" . "…") ("cdots" . "⋯") ("dots" . "…")
    ("angle" . "∠") ("degree" . "°") ("prime" . "′") ("hbar" . "ℏ")
    ("ell" . "ℓ") ("Re" . "ℜ") ("Im" . "ℑ") ("aleph" . "ℵ")
    ("langle" . "⟨") ("rangle" . "⟩") ("quad" . " ") ("qquad" . "  ")
    ("," . " ") (";" . " ") (":" . " ") ("!" . "") ("{" . "{") ("}" . "}")
    ("%" . "%") ("$" . "$") ("&" . "&") ("#" . "#") ("_" . "_"))
  "TeX control words rendered by `octocat-markdown--tex'.")

(defconst octocat-markdown--super
  '((?0 . "⁰") (?1 . "¹") (?2 . "²") (?3 . "³") (?4 . "⁴") (?5 . "⁵")
    (?6 . "⁶") (?7 . "⁷") (?8 . "⁸") (?9 . "⁹") (?+ . "⁺") (?- . "⁻")
    (?= . "⁼") (?\( . "⁽") (?\) . "⁾") (?n . "ⁿ") (?i . "ⁱ"))
  "Superscript forms of characters.")

(defconst octocat-markdown--sub
  '((?0 . "₀") (?1 . "₁") (?2 . "₂") (?3 . "₃") (?4 . "₄") (?5 . "₅")
    (?6 . "₆") (?7 . "₇") (?8 . "₈") (?9 . "₉") (?+ . "₊") (?- . "₋")
    (?= . "₌") (?\( . "₍") (?\) . "₎") (?a . "ₐ") (?e . "ₑ") (?o . "ₒ")
    (?x . "ₓ") (?i . "ᵢ") (?j . "ⱼ") (?n . "ₙ"))
  "Subscript forms of characters.")

(defun octocat-markdown--script (text table marker)
  "Return TEXT in the scripts of TABLE, or \"MARKER(TEXT)\" if it has no form."
  (if (cl-every (lambda (c) (assq c table)) text)
      (mapconcat (lambda (c) (cdr (assq c table))) text "")
    (concat marker "(" text ")")))

(defun octocat-markdown--tex (tex)
  "Return the TeX math source TEX approximated in Unicode."
  (let ((s tex)
        (group "{\\([^{}]*\\)}"))
    ;; Innermost groups first, so \frac{\sqrt{x}}{2} works.
    (dotimes (_ 4)
      (setq s (replace-regexp-in-string
               (concat "\\\\\\(?:d\\|t\\)?frac *" group " *" group)
               "\\1⁄\\2" s)
            s (replace-regexp-in-string (concat "\\\\sqrt *" group) "√(\\1)" s)
            s (replace-regexp-in-string
               (concat "\\\\\\(?:text\\|mathrm\\|mathbf\\|mathit\\|mathbb\\|operatorname"
                       "\\|mathcal\\) *" group)
               "\\1" s)))
    (setq s (replace-regexp-in-string "\\\\sqrt *\\([^ {]\\)" "√\\1" s)
          s (replace-regexp-in-string "\\\\\\(?:left\\|right\\|big\\|Big\\)\\([.|(]?\\)" "\\1" s))
    (setq s (replace-regexp-in-string
             "\\\\\\([A-Za-z]+\\|[^A-Za-z]\\)"
             (lambda (m)
               (let ((hit (assoc (substring m 1) octocat-markdown--tex-symbols)))
                 (if hit (cdr hit) (substring m 1))))
             s t t))
    (setq s (replace-regexp-in-string
             "\\^\\(?:{\\([^{}]*\\)}\\|\\([^ {]\\)\\)"
             (lambda (m)
               (octocat-markdown--script
                (or (and (string-match "\\^{\\([^{}]*\\)}" m) (match-string 1 m))
                    (substring m 1))
                octocat-markdown--super "^"))
             s t t)
          s (replace-regexp-in-string
             "_\\(?:{\\([^{}]*\\)}\\|\\([^ {]\\)\\)"
             (lambda (m)
               (octocat-markdown--script
                (or (and (string-match "_{\\([^{}]*\\)}" m) (match-string 1 m))
                    (substring m 1))
                octocat-markdown--sub "_"))
             s t t))
    (string-trim (replace-regexp-in-string "[{}]" "" s))))

(defvar octocat-markdown--definitions nil
  "Hash table of reference-link definitions (lowercase label -> URL), or nil.")

(defvar octocat-markdown--footnotes nil
  "Alist of footnote definitions (label . text) of the text being rendered.")

(defvar octocat-markdown--footnote-order nil
  "Labels of the footnotes referenced so far, most recent first.")

(defun octocat-markdown--footnote-number (label)
  "Return the number of footnote LABEL, or nil if it is not defined."
  (when (assoc label octocat-markdown--footnotes)
    (unless (member label octocat-markdown--footnote-order)
      (push label octocat-markdown--footnote-order))
    (- (length octocat-markdown--footnote-order)
       (cl-position label octocat-markdown--footnote-order :test #'equal))))

(defun octocat-markdown--superscript (n)
  "Return the number N in superscript digits."
  (octocat-markdown--script (number-to-string n) octocat-markdown--super "^"))

(defun octocat-markdown--definition (label)
  "Return the URL of reference-link LABEL, or nil."
  (and octocat-markdown--definitions
       (gethash (downcase (string-join (split-string label) " "))
                octocat-markdown--definitions)))

(defun octocat-markdown--sha-p (sha)
  "Return non-nil if SHA is plausibly an abbreviated commit hash.
Besides being 7 to 40 hex digits it must mix letters and digits, so words
like \"defaced\" and numbers like 1234567 are not taken for hashes."
  (and (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" sha)
       (string-match-p "[0-9]" sha)
       (string-match-p "[a-f]" sha)))

(defun octocat-markdown--image (alt src &optional width)
  "Return the image of SRC as a link labelled by ALT.
It carries its SRC and WIDTH, in pixels, as `octocat-markdown-img', for
`octocat-markdown--image-row' to tell an image alone on its line.  A
relative SRC is a file of the repository, which it carries as :file,
\(REPO REF PATH), see `octocat-markdown-base'."
  (let* ((path (octocat-markdown--relative-path src))
         (url  (octocat-markdown--absolute src "raw"))
         (s    (octocat-markdown--link
                (octocat-markdown--face
                 (format "[image%s]" (if (string-empty-p (or alt "")) "" (concat ": " alt)))
                 'octocat-markdown-image)
                url)))
    (put-text-property 0 (length s) 'octocat-markdown-img
                       (append (list :url url :width width)
                               (and path (not (string-suffix-p "/" path))
                                    (list :file (list (nth 0 octocat-markdown-base)
                                                      (nth 1 octocat-markdown-base)
                                                      (url-unhex-string path)))))
                       s)
    s))

(defun octocat-markdown--img (tag)
  "Return the HTML <img> TAG as an image link."
  (let ((attr (lambda (name)
                (and (string-match (concat "\\b" name "=\"\\([^\"]*\\)\"") tag)
                     (match-string 1 tag)))))
    (octocat-markdown--image
     (funcall attr "alt") (or (funcall attr "src") "")
     ;; A percentage is of a width GitHub's page has and this one lacks.
     (let ((w (funcall attr "width")))
       (and w (string-match-p "\\`[0-9]+\\'" w) (string-to-number w))))))

(defun octocat-markdown--tag-re (names)
  "Return a regexp matching an HTML element NAMES (an alternation) on one line.
Group 2 is its content."
  (concat "<\\(" names "\\)\\b[^>]*>\\(.*?\\)</\\1 *>"))

(defun octocat-markdown--html-script (text table)
  "Return TEXT in the scripts of TABLE, or rendered as is if it has no form."
  (if (cl-every (lambda (c) (assq c table)) text)
      (octocat-markdown--script text table "")
    (octocat-markdown--inline text)))

(defvar octocat-markdown--html-rules
  `((,"<!--.*?-->" ,(lambda (_m) ""))
    (,"<br */?>" ,(lambda (_m) " "))
    (,"<img\\b[^>]*>" ,(lambda (m) (octocat-markdown--img (nth 0 m))))
    (,"<kbd>\\(.*?\\)</kbd>"
     ,(lambda (m) (octocat-markdown--face (concat "[" (nth 1 m) "]")
                                          'octocat-markdown-code)))
    (,"<a +[^>]*?href=[\"']\\([^\"']*\\)[\"'][^>]*>\\(.*?\\)</a *>"
     ,(lambda (m) (octocat-markdown--link (octocat-markdown--inline (nth 2 m))
                                          (nth 1 m))))
    (,(octocat-markdown--tag-re "b\\|strong")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m)) 'bold)))
    (,(octocat-markdown--tag-re "i\\|em")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m)) 'italic)))
    (,(octocat-markdown--tag-re "s\\|del\\|strike")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                          'octocat-markdown-strike)))
    (,(octocat-markdown--tag-re "u\\|ins")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                          'underline)))
    (,(octocat-markdown--tag-re "sup")
     ,(lambda (m) (octocat-markdown--html-script (nth 2 m) octocat-markdown--super)))
    (,(octocat-markdown--tag-re "sub")
     ,(lambda (m) (octocat-markdown--html-script (nth 2 m) octocat-markdown--sub)))
    (,"</?[a-zA-Z][^<>\n]*>" ,(lambda (_m) ""))
    (,"&\\(#?[a-zA-Z0-9]+\\);"
     ,(lambda (m)
        (let ((name (nth 1 m)) (whole (nth 0 m)))
          (cond ((assoc name octocat-markdown--entities)
                 (cdr (assoc name octocat-markdown--entities)))
                ((string-match "\\`#\\([0-9]+\\)\\'" name)
                 (string (string-to-number (match-string 1 name))))
                (t whole))))))
  "Inline rules for HTML, as in `octocat-markdown--inline-rules'.
They alone apply inside <pre>, where markdown is not rendered.")

(defconst octocat-markdown--label-re
  (concat "\\(\\(?:[^][\n]\\|\\[[^][\n]*\\]"
          "\\(?:([^)[:space:]]*)\\|\\[[^][\n]*\\]\\)?\\)+\\)")
  "Matches a link's label, as group 1.
It may hold bracketed text, and so an image, as badges are linked:
`[![CI](badge.svg)](url)'.")

(defvar octocat-markdown--inline-rules
  `(;; Code spans bind tighter than anything else.
    (,"``\\(.+?\\)``"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-code)))
    (,"`\\([^`\n]+\\)`"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-code)))
    (,"\\\\\\([][\\`*_{}()#+.!<>~|-]\\)"
     ,(lambda (m) (nth 1 m)))
    (,"<\\(https?://[^>[:space:]]+\\)>"
     ,(lambda (m) (octocat-markdown--link (nth 1 m) (nth 1 m))))
    ;; Not among the HTML rules: inside <pre> it is already code.
    (,(octocat-markdown--tag-re "code\\|tt")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                          'octocat-markdown-code)))
    ,@octocat-markdown--html-rules
    ;; Images show their alt text; links their label.
    (,"!\\[\\([^]\n]*\\)\\](\\([^)[:space:]]+\\)\\(?: +\"[^\"]*\"\\)?)"
     ,(lambda (m) (octocat-markdown--image (nth 1 m) (nth 2 m))))
    (,(concat "\\[" octocat-markdown--label-re
              "\\](\\([^)[:space:]]+\\)\\(?: +\"[^\"]*\"\\)?)")
     ,(lambda (m)
        (octocat-markdown--link (octocat-markdown--inline (nth 1 m))
                                (nth 2 m))))
    ;; Reference-style images and links, footnote references and
    ;; [shortcut] links stay literal unless the label has a definition.
    (,"!\\[\\([^]\n]*\\)\\]\\[\\([^]\n]*\\)\\]"
     ,(lambda (m)
        (if-let* ((url (octocat-markdown--definition
                        (if (string-empty-p (nth 2 m)) (nth 1 m) (nth 2 m)))))
            (octocat-markdown--image (nth 1 m) url)
          (concat "!" (octocat-markdown--inline (substring (nth 0 m) 1))))))
    (,"!\\[\\([^]\n^][^]\n]*\\)\\]"
     ,(lambda (m)
        (if-let* ((url (octocat-markdown--definition (nth 1 m))))
            (octocat-markdown--image (nth 1 m) url)
          (concat "!" (octocat-markdown--inline (substring (nth 0 m) 1))))))
    (,(concat "\\[" octocat-markdown--label-re "\\]\\[\\([^]\n]*\\)\\]")
     ,(lambda (m)
        (let* ((id  (if (string-empty-p (nth 2 m)) (nth 1 m) (nth 2 m)))
               (url (octocat-markdown--definition id)))
          (if url
              (octocat-markdown--link (octocat-markdown--inline (nth 1 m)) url)
            (concat "[" (octocat-markdown--inline (nth 1 m)) "]["
                    (nth 2 m) "]")))))
    (,"\\[\\^\\([^]\n]+\\)\\]"
     ,(lambda (m)
        (if-let* ((n (octocat-markdown--footnote-number (nth 1 m))))
            (octocat-markdown--face (octocat-markdown--superscript n)
                                    'octocat-markdown-mention)
          (nth 0 m))))
    (,"\\[\\([^]\n^][^]\n]*\\)\\]"
     ,(lambda (m)
        (if-let* ((url (octocat-markdown--definition (nth 1 m))))
            (octocat-markdown--link (octocat-markdown--inline (nth 1 m)) url)
          (concat "[" (octocat-markdown--inline (nth 1 m)) "]"))))
    (,"https?://[^[:space:]<>]*[^[:space:]<>.,;:!?)\"']"
     ,(lambda (m) (octocat-markdown--link (nth 0 m) (nth 0 m))))
    (,"\\*\\*\\*\\([^[:space:]]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                          'bold 'italic)))
    (,"\\*\\*\\([^[:space:]]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                          'bold)))
    ;; Underscore emphasis needs non-word neighbours (snake_case stays).
    (,(concat "\\(?:\\`\\|[^[:alnum:]_]\\)\\(__\\([^[:space:]_]"
              "\\(?:.*?[^[:space:]_]\\)?\\)__\\)\\(?:[^[:alnum:]_]\\|\\'\\)")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                          'bold))
     1)
    (,"\\*\\([^*[:space:]]\\(?:[^*]*?[^*[:space:]]\\)?\\)\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                          'italic)))
    (,(concat "\\(?:\\`\\|[^[:alnum:]_]\\)\\(_\\([^_[:space:]]"
              "\\(?:[^_]*?[^_[:space:]]\\)?\\)_\\)\\(?:[^[:alnum:]_]\\|\\'\\)")
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                          'italic))
     1)
    (,"~~\\([^[:space:]~]\\(?:.*?[^[:space:]~]\\)?\\)~~"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                          'octocat-markdown-strike)))
    (,"\\(?:\\`\\|[^[:alnum:]_/]\\)\\(@[A-Za-z0-9][A-Za-z0-9-]*\\(?:/[A-Za-z0-9_.-]+\\)?\\)"
     ,(lambda (m) (octocat-markdown--mention (nth 1 m)))
     1)
    (,"\\(?:\\`\\|[^[:alnum:]_&]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)?#[0-9]+\\)\\b"
     ,(lambda (m)
        (string-match "\\`\\(.*\\)#\\([0-9]+\\)\\'" (nth 1 m))
        (octocat-markdown--ref (nth 1 m) 'issue
                               (let ((repo (match-string 1 (nth 1 m))))
                                 (and (not (string-empty-p repo)) repo))
                               (string-to-number (match-string 2 (nth 1 m)))))
     1)
    ;; Commit hashes: a short or full SHA, optionally as owner/repo@sha.
    (,(concat "\\(?:\\`\\|[^[:alnum:]_/#&@.-]\\)\\("
              "\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@\\)?[0-9a-f]\\{7,40\\}\\)"
              "\\(?:[^[:alnum:]_-]\\|\\'\\)")
     ,(lambda (m)
        (let* ((text (nth 1 m))
               (at   (string-search "@" text))
               (sha  (if at (substring text (1+ at)) text)))
          (if (octocat-markdown--sha-p sha)
              (octocat-markdown--ref (if at text (substring sha 0 7))
                                     'commit (and at (substring text 0 at)) sha)
            text)))
     1)
    (,":\\([a-z0-9_+-]+\\):"
     ,(lambda (m) (or (cdr (assoc (nth 1 m) octocat-markdown--emoji)) (nth 0 m))))
    ;; $math$: the opening $ is followed, and the closing one preceded, by
    ;; a non-space, and the closing one is not followed by a digit ($5 and $10).
    (,(concat "\\(?:\\`\\|[^[:alnum:]_$\\]\\)\\(\\$[^$[:space:]]"
              "\\(?:[^$\n]*?[^$[:space:]\\]\\)?\\$\\)\\(?:[^[:digit:]]\\|\\'\\)")
     ,(lambda (m)
        (octocat-markdown--face
         (octocat-markdown--tex (substring (nth 1 m) 1 -1))
         'octocat-markdown-code))
     1))
  "Inline rules: each is (REGEXP HANDLER) or (REGEXP HANDLER GROUP).
HANDLER is called with the list of the match's group strings (group 0
first) and returns the replacement string.  With GROUP, only that group
of the match is replaced and the rest (a leading boundary character) is
kept.")

(defconst octocat-markdown--span-tags
  '("a" "b" "strong" "i" "em" "s" "del" "strike" "u" "ins" "code" "tt"
    "sup" "sub" "kbd")
  "HTML elements that `octocat-markdown--balance' carries across lines.")

(defun octocat-markdown--balance (line open &optional html)
  "Return (LINE2 . OPEN2): LINE closing the elements left open in it.
OPEN is the elements left open by the lines before, as (NAME . TAG),
innermost first; LINE2 reopens them and OPEN2 is what LINE2 leaves open.
The inline rules see one line at a time, so this lets an element span
lines.  Tags in code spans are skipped unless HTML (inside <pre>)."
  (let* ((line  (concat (mapconcat #'cdr (reverse open) "") line))
         (scan  (if html line (replace-regexp-in-string "`[^`\n]+`" "" line)))
         (pos   0))
    (while (string-match "<\\(/?\\)\\([a-zA-Z]+\\)\\b[^<>]*>" scan pos)
      (let ((name (downcase (match-string 2 scan))))
        (when (member name octocat-markdown--span-tags)
          (if (string-empty-p (match-string 1 scan))
              (push (cons name (match-string 0 scan)) open)
            (when-let* ((hit (assoc name open)))
              (setq open (delq hit open))))))
      (setq pos (match-end 0)))
    (cons (concat line (mapconcat (lambda (o) (concat "</" (car o) ">")) open ""))
          open)))

(defvar octocat-markdown--rules nil
  "Inline rules in force, or nil for `octocat-markdown--inline-rules'.")

(defun octocat-markdown--inline (text)
  "Return TEXT (a single line) with inline markdown rendered."
  (let ((pos 0) (out nil) (len (length text)))
    (while (< pos len)
      (let (best)                       ; (BEG END DATA RULE)
        (dolist (rule (or octocat-markdown--rules octocat-markdown--inline-rules))
          (when (string-match (car rule) text pos)
            (let ((group (or (nth 2 rule) 0)))
              (when (or (null best) (< (match-beginning group) (car best)))
                (setq best (list (match-beginning group) (match-end group)
                                 (cl-loop for i from 0 to 3
                                          collect (match-string i text))
                                 rule))))))
        (if (not best)
            (progn (push (substring text pos) out) (setq pos len))
          (pcase-let ((`(,beg ,end ,groups ,rule) best))
            (push (substring text pos beg) out)
            (push (funcall (cadr rule) groups) out)
            (setq pos end)))))
    (apply #'concat (nreverse out))))

;;;; Blocks
;;
;; Blocks render to a list of lines, each (STRING . HANG): the text of
;; the row and the prefix its wrapped continuation lines start with,
;; spaces under a list item's text, a quote's bars to carry them on.

(defconst octocat-markdown--fence-re "^ \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)$")
(defconst octocat-markdown--hr-re "^ \\{0,3\\}\\([-*_]\\)\\(?: *\\1\\)\\{2,\\} *$")
(defconst octocat-markdown--heading-re
  "^ \\{0,3\\}\\(#\\{1,6\\}\\)\\(?: +\\(.*?\\)\\)?\\(?: +#+\\)? *$")
(defconst octocat-markdown--quote-re "^ \\{0,3\\}>")
(defconst octocat-markdown--item-re "^\\( *\\)\\([-*+]\\|[0-9]+[.)]\\)\\(?: +\\(.*\\)\\|\\(\\)\\)$")
(defconst octocat-markdown--table-delim-re
  "^ *|? *:?-+:? *\\(?:| *:?-+:? *\\)*|? *$")
(defconst octocat-markdown--setext-re "^ \\{0,3\\}\\(=+\\|-+\\) *$")
(defconst octocat-markdown--details-re "\\`[ \t]*<details\\b\\([^>]*\\)>")
(defconst octocat-markdown--pre-re "\\` \\{0,3\\}<pre\\b[^>]*>")
(defconst octocat-markdown--link-def-re
  (concat "^ \\{0,3\\}\\[\\([^]^][^]]*\\)\\]: *<?\\([^[:space:]>]+\\)>?"
          "\\(?: +\\(?:\"[^\"]*\"\\|'[^']*'\\|([^)]*)\\)\\)? *$")
  "Matches a reference-link definition, `[label]: url \"title\"'.")
(defconst octocat-markdown--footnote-def-re "^\\[\\^\\([^]]+\\)\\]: *\\(.*\\)$"
  "Matches the first line of a footnote definition, `[^label]: text'.")

(defun octocat-markdown--indentation (line)
  "Return the number of leading spaces of LINE."
  (string-match "[^ ]" line)
  (or (match-beginning 0) (length line)))

(defun octocat-markdown--blank-p (line)
  "Return non-nil if LINE is empty or whitespace."
  (string-match-p "\\`[ \t]*\\'" line))

(defun octocat-markdown--split-row (line)
  "Return the trimmed cells of table row LINE."
  (let* ((line (string-trim line))
         (line (string-remove-prefix "|" line))
         (line (if (and (string-suffix-p "|" line) (not (string-suffix-p "\\|" line)))
                   (substring line 0 -1)
                 line)))
    (mapcar (lambda (c) (string-trim (replace-regexp-in-string "\0" "|" c)))
            (split-string (replace-regexp-in-string "\\\\|" "\0" line) "|"))))

(defun octocat-markdown--pad (cell width align)
  "Pad CELL to WIDTH columns according to ALIGN (`left', `right', `center')."
  (let ((gap (max 0 (- width (string-width cell)))))
    (pcase align
      ('right  (concat (make-string gap ?\s) cell))
      ('center (concat (make-string (/ gap 2) ?\s) cell
                       (make-string (- gap (/ gap 2)) ?\s)))
      (_       (concat cell (make-string gap ?\s))))))

(defvar octocat-markdown--avail nil
  "Columns available to the block being rendered, or nil for no limit.
Bound by `octocat-markdown-render' and narrowed inside quotes and lists.")

(defun octocat-markdown--image-row (s)
  "Return paragraph line S, marked if it is an image alone.
The mark is `octocat-markdown-image': the image's plist, as
`octocat-markdown--image' made it, plus :cols, the columns it may take,
or nil for no limit.  Only such an image can be shown in its link's
place, as one tall line, without breaking the layout of the text; but
see `octocat-markdown--html-gallery', for images side by side."
  (let ((img (and (> (length s) 0) (get-text-property 0 'octocat-markdown-img s))))
    (if (or (null img) (next-single-property-change 0 'octocat-markdown-img s))
        s
      (let ((s (copy-sequence s)))
        (put-text-property 0 (length s) 'octocat-markdown-image
                           (append img (list :cols octocat-markdown--avail))
                           s)
        s))))

(defconst octocat-markdown--min-column 6
  "Narrowest a table column is squeezed to before the table overflows instead.")

(defun octocat-markdown--fit-widths (natural avail)
  "Return column widths for a table of NATURAL widths fitting AVAIL columns.
Each column costs 3 columns of borders and padding, plus one for the
last border.  Columns narrower than their fair share keep their natural
width and the wide ones split what is left.  When even that would squeeze
a column below `octocat-markdown--min-column', or AVAIL is nil, NATURAL is
returned and the table is left to overflow."
  (let* ((n      (length natural))
         (budget (and avail (- avail (* 3 n) 1))))
    (if (or (null budget) (<= (apply #'+ natural) budget)
            (< budget (* n octocat-markdown--min-column)))
        natural
      (let ((fixed (make-vector n nil)) (left budget) (open n) share changed)
        (setq changed t)
        (while (and changed (> open 0))
          (setq changed nil share (/ left open))
          (dotimes (i n)
            (when (and (not (aref fixed i)) (<= (nth i natural) share))
              (aset fixed i (nth i natural))
              (setq left (- left (nth i natural)) open (1- open) changed t))))
        (let ((share (if (> open 0) (/ left open) 0))
              (extra (if (> open 0) (% left open) 0)))
          (cl-loop for i below n
                   collect (or (aref fixed i)
                               (prog1 (+ share (if (> extra 0) 1 0))
                                 (when (> extra 0) (setq extra (1- extra)))))))))))

(defun octocat-markdown--wrap (string width)
  "Return STRING broken into lines of at most WIDTH columns, as a list.
Lines break at spaces; a word wider than WIDTH is cut.  Text properties
are kept.  An empty STRING gives one empty line."
  (let ((pos 0) (lines nil) (cur nil))   ; CUR is (BEG . END) of the open line
    (while (string-match "[^ ]+" string pos)
      (let ((beg (match-beginning 0)) (end (match-end 0)))
        (setq pos end)
        ;; Cut a word that cannot fit a line of its own.
        (while (> (string-width (substring string beg end)) width)
          (let ((cut (1+ beg)))
            (while (and (< cut end)
                        (<= (string-width (substring string beg (1+ cut))) width))
              (setq cut (1+ cut)))
            (when cur (push (substring string (car cur) (cdr cur)) lines) (setq cur nil))
            (push (substring string beg cut) lines)
            (setq beg cut)))
        (cond ((= beg end))
              ((null cur) (setq cur (cons beg end)))
              ((<= (string-width (substring string (car cur) end)) width)
               (setcdr cur end))
              (t (push (substring string (car cur) (cdr cur)) lines)
                 (setq cur (cons beg end))))))
    (when cur (push (substring string (car cur) (cdr cur)) lines))
    (or (nreverse lines) (list ""))))

(defun octocat-markdown--table (header delim rows)
  "Return the lines of a table with HEADER and body ROWS.
DELIM is the delimiter row, which gives the column alignments.  A table
wider than `octocat-markdown--avail' squeezes its columns and wraps cell
text onto several lines, with a rule between rows to keep them apart."
  (let* ((head   (mapcar #'octocat-markdown--inline (octocat-markdown--split-row header)))
         (ncols  (length head))
         (aligns (mapcar (lambda (d)
                           (cond ((string-match-p "\\`:.*:\\'" d) 'center)
                                 ((string-suffix-p ":" d) 'right)
                                 (t 'left)))
                         (octocat-markdown--split-row delim)))
         (body   (mapcar (lambda (r)
                           (let ((cells (mapcar #'octocat-markdown--inline
                                                (octocat-markdown--split-row r))))
                             ;; Ragged rows are cut or padded to the header.
                             (take ncols (append cells (make-list ncols "")))))
                         rows))
         (natural (apply #'cl-mapcar (lambda (&rest cells)
                                       (apply #'max 1 (mapcar #'string-width cells)))
                         head body))
         (widths (octocat-markdown--fit-widths natural octocat-markdown--avail))
         (wrapped (cl-some #'< widths natural))
         (bar    (lambda (s) (propertize s 'face 'octocat-markdown-dimmed)))
         (rule   (lambda (l m r)
                   (funcall bar (concat l (mapconcat (lambda (w) (make-string (+ w 2) ?─))
                                                     widths m)
                                        r))))
         ;; One logical row as its physical lines (several when wrapped).
         (row    (lambda (cells face)
                   (let* ((cols   (cl-mapcar #'octocat-markdown--wrap cells widths))
                          (height (apply #'max 1 (mapcar #'length cols)))
                          (specs  (cl-mapcar #'list cols widths
                                             (take ncols (append aligns
                                                                 (make-list ncols 'left))))))
                     (cl-loop
                      for i below height
                      collect (concat
                               (funcall bar "│")
                               (mapconcat
                                (lambda (c)
                                  (let ((cell (or (nth i (cl-first c)) "")))
                                    (concat " " (octocat-markdown--pad
                                                 (if face (octocat-markdown--face cell face) cell)
                                                 (cl-second c) (cl-third c))
                                            " ")))
                                specs (funcall bar "│"))
                               (funcall bar "│")))))))
    (mapcar (lambda (s) (cons (propertize s 'octocat-markdown-table t) ""))
            (append
             (list (funcall rule "┌" "┬" "┐"))
             (funcall row head 'bold)
             (list (funcall rule "├" "┼" "┤"))
             (cl-loop for (r . more) on body
                      append (funcall row r nil)
                      when (and wrapped more)
                      collect (funcall rule "├" "┼" "┤"))
             (list (funcall rule "└" "┴" "┘"))))))

;;;; HTML tables
;;
;; A <table> is drawn as a grid, as a pipe table is.  Its tags are read
;; leniently, as a browser reads them: a cell outside a <tr> starts a
;; row, and a cell or row ends where the next begins.  As on GitHub, a
;; cell is HTML up to its first blank line and markdown after it.  A
;; table of images and captions lays the images side by side instead,
;; marked to be shown there; a table too wide even squeezed lists each
;; row's cells under their headers.

(defconst octocat-markdown--html-table-re "\\` \\{0,3\\}<table\\b"
  "Matches the line an HTML table starts on.")

(defvar octocat-markdown--html-block-rules
  (cons (assoc (octocat-markdown--tag-re "code\\|tt") octocat-markdown--inline-rules)
        octocat-markdown--html-rules)
  "Inline rules for HTML that is not markdown, outside <pre>: <code> too.")

(defun octocat-markdown--html-table-source (line lines)
  "Return (SOURCE AFTER REST) of the <table> opened on LINE, the rest in LINES.
SOURCE is the table's text inside its own tags, AFTER what follows the
closing tag on its line, and REST the lines after that.  A table that
is never closed runs to the end of LINES."
  (let ((case-fold-search t) (level 0) body after)
    (push line lines)
    (while (and lines (not after))
      (let ((l (pop lines)) (pos 0))
        (while (and (not after) (string-match "<\\(/?\\)table\\b[^>]*>" l pos))
          (setq pos   (match-end 0)
                level (+ level (if (string-empty-p (match-string 1 l)) 1 -1)))
          (when (<= level 0)
            (setq after (substring l pos)
                  l     (substring l 0 (match-beginning 0)))))
        (push l body)))
    (let ((source (string-join (nreverse body) "\n")))
      (string-match "<table\\b[^>]*>" source)
      (list (substring source (match-end 0)) (or after "") lines))))

(defun octocat-markdown--html-attr (attrs name)
  "Return the value of attribute NAME in a tag's ATTRS, or nil."
  (let ((case-fold-search t))
    (and (string-match (concat "\\b" name
                               "=\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\|\\([^[:space:]>]+\\)\\)")
                       attrs)
         (or (match-string 1 attrs) (match-string 2 attrs) (match-string 3 attrs)))))

(defun octocat-markdown--html-table-parse (source)
  "Return (ROWS . LOOSE) of the table SOURCE, from inside its tags.
Each row is a list of cells, each (HEADER-P ALIGN SPAN CONTENT), CONTENT
its source.  LOOSE is the text in no cell, which browsers move out of
the table.  A table inside a cell is left in its CONTENT."
  (let ((case-fold-search t) (pos 0) (mark 0) (nest 0) rows row cell loose)
    (let ((close-cell (lambda (end)
                        (when cell
                          (push (append (butlast cell)
                                        (list (substring source (car (last cell)) end)))
                                row)
                          (setq cell nil))))
          (close-row (lambda () (when row (push (nreverse row) rows) (setq row nil)))))
      (while (string-match
              "<\\(/?\\)\\(table\\|thead\\|tbody\\|tfoot\\|tr\\|th\\|td\\)\\b\\([^>]*\\)>"
              source pos)
        (let ((beg (match-beginning 0)) (end (match-end 0))
              (closing (not (string-empty-p (match-string 1 source))))
              (name (downcase (match-string 2 source)))
              (attrs (match-string 3 source)))
          (setq pos end)
          (cond
           ((equal name "table") (setq nest (max 0 (+ nest (if closing -1 1)))))
           ((> nest 0))
           (t
            (if cell
                (funcall close-cell beg)
              (push (substring source mark beg) loose))
            (setq mark end)
            (pcase name
              ((or "td" "th")
               (unless closing
                 (setq cell (list (equal name "th")
                                  (pcase (downcase
                                          (or (octocat-markdown--html-attr attrs "align") ""))
                                    ("center" 'center) ("right" 'right) (_ 'left))
                                  (max 1 (min 100 (string-to-number
                                                   (or (octocat-markdown--html-attr attrs "colspan")
                                                       "1"))))
                                  end))))
              ;; Rows end at <tr>, </tr> and the table's sections.
              (_ (funcall close-row)))))))
      (if cell
          (funcall close-cell (length source))
        (push (substring source mark) loose))
      (funcall close-row))
    (cons (nreverse rows) (string-trim (string-join (nreverse loose) "\n")))))

(defun octocat-markdown--html-cell-lines (cell width)
  "Return the rendered lines of table CELL, fit to WIDTH columns or nil.
As on GitHub, its content is HTML up to its first blank line, where
whitespace runs together and <br> breaks the line, and markdown after."
  (let* ((case-fold-search t)
         (content (nth 3 cell))
         (split   (string-match "\n[ \t]*\n" content))
         (md      (and split (substring content (match-end 0))))
         (html    (string-trim (replace-regexp-in-string
                                "[ \t\n]+" " " (substring content 0 split))))
         (lines   (unless (and md (string-empty-p html))
                    (let ((octocat-markdown--rules octocat-markdown--html-block-rules))
                      (cl-mapcan (lambda (l)
                                   (let ((s (octocat-markdown--inline (string-trim l))))
                                     (if width (octocat-markdown--wrap s width) (list s))))
                                 (split-string html "<br */?>")))))
         (lines   (append lines
                          (and md
                               (let ((octocat-markdown--avail width))
                                 (mapcar #'car
                                         (octocat-markdown--fill
                                          (octocat-markdown--tidy
                                           (octocat-markdown--blocks (split-string md "\n")))
                                          width))))))
         (lines   (or lines (list ""))))
    (if (car cell)
        (mapcar (lambda (l) (octocat-markdown--face l 'bold)) lines)
      lines)))

(defun octocat-markdown--html-image (lines)
  "Return the image plist of cell LINES that are an image alone, or nil."
  (let ((s (car lines)))
    (and (null (cdr lines)) (> (length s) 0)
         (not (next-single-property-change 0 'octocat-markdown-img s))
         (get-text-property 0 'octocat-markdown-img s))))

(defun octocat-markdown--html-blank-p (lines)
  "Return non-nil if cell LINES are empty."
  (equal lines '("")))

(defun octocat-markdown--html-table (line lines)
  "Render the <table> opened on LINE, the rest of it in LINES.
Return (ROWS . REST), REST being the lines after the closing tag.  Text
after the tag on its line is HTML, as on GitHub."
  (pcase-let* ((`(,source ,after ,rest) (octocat-markdown--html-table-source line lines))
               (`(,rows . ,loose) (octocat-markdown--html-table-parse source))
               (after (let ((octocat-markdown--rules octocat-markdown--html-block-rules))
                        (string-trim (octocat-markdown--inline after)))))
    (cons (append (and rows (octocat-markdown--html-table-rows rows))
                  (and (not (string-empty-p loose))
                       (octocat-markdown--tidy
                        (octocat-markdown--blocks (split-string loose "\n"))))
                  (and (not (string-empty-p after)) (list (cons after ""))))
          rest)))

(defun octocat-markdown--html-table-rows (rows)
  "Return the rendered rows of the table ROWS, as parsed.
A table of images and captions is a gallery, one of text a grid; either
too wide for `octocat-markdown--avail' is stacked."
  (let* ((head  (cl-every #'car (car rows)))
         (ncols (apply #'max (mapcar (lambda (r) (apply #'+ (mapcar #'cl-third r))) rows)))
         ;; Short rows are made up with empty cells; each cell is paired
         ;; with its lines at their natural width.
         (rows  (mapcar (lambda (r)
                          (mapcar (lambda (c) (cons c (octocat-markdown--html-cell-lines c nil)))
                                  (append r (make-list (- ncols (apply #'+ (mapcar #'cl-third r)))
                                                       (list nil 'left 1 "")))))
                        rows))
         (image-row (lambda (r)
                      (and (cl-some (lambda (c) (octocat-markdown--html-image (cdr c))) r)
                           (cl-every (lambda (c) (or (octocat-markdown--html-image (cdr c))
                                                     (octocat-markdown--html-blank-p (cdr c))))
                                     r))))
         (caption-row (lambda (r)
                        (cl-every (lambda (c) (and (null (cddr c))
                                                   (not (octocat-markdown--html-image (cdr c)))))
                                  r))))
    (if (and (cl-some image-row rows)
             (cl-every (lambda (r) (or (funcall image-row r) (funcall caption-row r))) rows)
             (cl-every (lambda (r) (cl-every (lambda (c) (= (cl-third (car c)) 1)) r)) rows))
        (or (octocat-markdown--html-gallery rows ncols)
            (octocat-markdown--html-stack
             rows (and (funcall caption-row (car rows)) (cdr rows) (car rows))))
      (or (octocat-markdown--html-grid rows ncols head)
          (octocat-markdown--html-stack rows (and head (car rows)))))))

(defun octocat-markdown--html-gallery (rows ncols)
  "Return ROWS of images and captions in NCOLS columns side by side.
Each image is marked, with :fill, over its whole column, so that shown
it takes the column's width and the next column stays in place.  Return
nil if they cannot fit `octocat-markdown--avail'."
  (let* ((avail  octocat-markdown--avail)
         (gap    2)
         (share  (and avail (/ (- avail (* gap (1- ncols))) ncols)))
         (widths (if share
                     (make-list ncols share)
                   (cl-loop for i below ncols
                            collect (apply #'max 1
                                           (mapcar (lambda (r) (string-width (cadr (nth i r))))
                                                   rows))))))
    (when (and (or (null share) (>= share octocat-markdown--min-column))
               (cl-every (lambda (r)
                           (cl-every #'identity
                                     (cl-mapcar (lambda (c w) (<= (string-width (cadr c)) w))
                                                r widths)))
                         rows))
      (mapcar
       (lambda (r)
         (let* ((cells (cl-mapcar
                        (lambda (c w)
                          (let* ((s   (cadr c))
                                 (img (octocat-markdown--html-image (cdr c)))
                                 (s   (octocat-markdown--pad s w
                                                             (if img 'left (cl-second (car c))))))
                            (when img
                              (put-text-property 0 (length s) 'octocat-markdown-image
                                                 (append img (list :cols share :fill t)) s))
                            (cons s img)))
                        r widths))
                (cells (let ((l (reverse cells)))
                         (while (and l (octocat-markdown--html-blank-p
                                        (list (string-trim (caar l)))))
                           (pop l))
                         (nreverse l)))
                (line  (mapconcat #'car cells (make-string gap ?\s))))
           ;; An image keeps its column's padding: the image covers it.
           (octocat-markdown--standout
            (cons (if (cdar (last cells)) line (string-trim-right line)) ""))))
       rows))))

(defun octocat-markdown--html-stack (rows labels)
  "Return ROWS listed one cell under another, as each row's own block.
LABELS, the header row among ROWS or nil, names each column's cells; a
rule parts the rows."
  (let* ((avail octocat-markdown--avail)
         (rule  (octocat-markdown--standout
                 (cons (propertize (make-string (or avail 20) ?─) 'face 'octocat-markdown-dimmed)
                       "")))
         (names (and labels
                     (cl-mapcan (lambda (c)
                                  (cons (string-trim (substring-no-properties (cadr c)))
                                        (make-list (1- (cl-third (car c))) "")))
                                labels)))
         (blocks
          (cl-loop
           for r in (remq labels rows)
           collect
           (let ((col 0) out)
             (dolist (c r)
               (let ((name (nth col names)))
                 (setq col (+ col (cl-third (car c))))
                 (unless (octocat-markdown--html-blank-p (cdr c))
                   (if (or (null name) (string-empty-p name))
                       (dolist (l (octocat-markdown--html-cell-lines (car c) avail))
                         (push (cons (octocat-markdown--image-row l) "") out))
                     (let ((label (octocat-markdown--face name 'bold))
                           (lines (octocat-markdown--html-cell-lines (car c) avail)))
                       (if (and (null (cdr lines)) (not (octocat-markdown--html-image lines)))
                           (push (cons (concat label ": " (car lines)) "  ") out)
                         (push (cons (concat label ":") "") out)
                         (let ((octocat-markdown--avail (and avail (- avail 2))))
                           (dolist (l (octocat-markdown--html-cell-lines
                                       (car c) octocat-markdown--avail))
                             (push (cons (concat "  " (octocat-markdown--image-row l)) "  ")
                                   out)))))))))
             (nreverse out)))))
    (cl-loop for (b . more) on (delq nil blocks)
             append b
             when more collect rule)))

(defun octocat-markdown--html-grid (rows ncols head)
  "Return ROWS drawn as a grid of NCOLS columns, HEAD its header row or nil.
A cell spanning columns is drawn across them, with a rule where the
columns change, so that no divider stops short.  Return nil if even
squeezed the grid cannot fit `octocat-markdown--avail'."
  (let* ((avail octocat-markdown--avail)
         (width (lambda (c) (apply #'max 1 (mapcar #'string-width (cdr c)))))
         (natural (make-vector ncols 1)))
    ;; Natural widths: single cells first, then spanning cells widen
    ;; the last of their columns as they need.
    (dolist (r rows)
      (let ((col 0))
        (dolist (c r)
          (when (= (cl-third (car c)) 1)
            (aset natural col (max (aref natural col) (funcall width c))))
          (setq col (+ col (cl-third (car c)))))))
    (dolist (r rows)
      (let ((col 0))
        (dolist (c r)
          (let* ((span (cl-third (car c)))
                 (have (+ (cl-loop for i from col below (+ col span) sum (aref natural i))
                          (* 3 (1- span))))
                 (need (funcall width c)))
            (when (> need have)
              (aset natural (+ col span -1) (+ (aref natural (+ col span -1)) (- need have))))
            (setq col (+ col span))))))
    (let* ((natural (append natural nil))
           (budget  (and avail (- avail (* 3 ncols) 1))))
      (unless (and budget (> (apply #'+ natural) budget)
                   (< budget (* ncols octocat-markdown--min-column)))
        (let* ((widths  (octocat-markdown--fit-widths natural avail))
               (wrapped (cl-some #'< widths natural))
               (bar     (lambda (s) (propertize s 'face 'octocat-markdown-dimmed)))
               ;; The column indexes a row has a divider after.
               (bounds  (lambda (r)
                          (let ((col 0) out)
                            (dolist (c r)
                              (setq col (+ col (cl-third (car c))))
                              (when (< col ncols) (push (1- col) out)))
                            out)))
               (rule    (lambda (above below l r)
                          (funcall bar
                                   (concat l
                                           (mapconcat
                                            #'identity
                                            (cl-loop
                                             for i below ncols
                                             collect (make-string (+ (nth i widths) 2) ?─)
                                             when (< i (1- ncols))
                                             collect (let ((a (memq i above)) (b (memq i below)))
                                                       (cond ((and a b) "┼") (a "┴")
                                                             (b "┬") (t "─"))))
                                            "")
                                           r))))
               (draw    (lambda (r)
                          (let* ((col 0)
                                 (cells
                                  (mapcar
                                   (lambda (c)
                                     (let* ((span (cl-third (car c)))
                                            (w (+ (cl-loop for i from col below (+ col span)
                                                           sum (nth i widths))
                                                  (* 3 (1- span)))))
                                       (setq col (+ col span))
                                       (list (if (> (funcall width c) w)
                                                 (octocat-markdown--html-cell-lines (car c) w)
                                               (cdr c))
                                             w (cl-second (car c)))))
                                   r))
                                 (height (apply #'max
                                                (mapcar (lambda (c) (length (car c))) cells))))
                            (cl-loop for i below height
                                     collect (concat
                                              (funcall bar "│")
                                              (mapconcat
                                               (lambda (c)
                                                 (concat " " (octocat-markdown--pad
                                                              (or (nth i (car c)) "")
                                                              (cl-second c) (cl-third c))
                                                         " "))
                                               cells (funcall bar "│"))
                                              (funcall bar "│")))))))
          (mapcar (lambda (s) (octocat-markdown--standout
                               (cons (propertize s 'octocat-markdown-table t) "")))
                  (append
                   (list (funcall rule nil (funcall bounds (car rows)) "┌" "┐"))
                   (cl-loop for (r . more) on rows
                            append (funcall draw r)
                            when (and more (or (and head (eq r (car rows))) wrapped
                                               (not (equal (funcall bounds r)
                                                           (funcall bounds (car more))))))
                            collect (funcall rule (funcall bounds r) (funcall bounds (car more))
                                             "├" "┤"))
                   (list (funcall rule (funcall bounds (car (last rows))) nil "└" "┘")))))))))

(defcustom octocat-markdown-highlight-code t
  "Non-nil means fenced code is syntax-highlighted by its language."
  :type 'boolean
  :group 'octocat-markdown)

(defcustom octocat-markdown-language-modes
  '(("elisp" . emacs-lisp-mode) ("el" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("scheme" . scheme-mode) ("clojure" . clojure-mode)
    ("python" . python-mode) ("py" . python-mode)
    ("ruby" . ruby-mode) ("rb" . ruby-mode) ("perl" . perl-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode)
    ("zsh" . sh-mode) ("console" . sh-mode)
    ("c" . c-mode) ("cpp" . c++-mode) ("c++" . c++-mode)
    ("java" . java-mode) ("go" . go-mode) ("rust" . rust-mode)
    ("rs" . rust-mode) ("swift" . swift-mode) ("kotlin" . kotlin-mode)
    ("js" . js-mode) ("javascript" . js-mode) ("jsx" . js-mode)
    ("ts" . typescript-mode) ("typescript" . typescript-mode)
    ("json" . js-json-mode) ("jsonc" . js-json-mode)
    ("yaml" . yaml-mode) ("yml" . yaml-mode) ("toml" . conf-toml-mode)
    ("ini" . conf-mode) ("html" . html-mode) ("xml" . nxml-mode)
    ("css" . css-mode) ("scss" . scss-mode) ("sql" . sql-mode)
    ("lua" . lua-mode) ("make" . makefile-mode) ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode) ("diff" . diff-mode)
    ("patch" . diff-mode) ("tex" . latex-mode) ("latex" . latex-mode))
  "Alist mapping a code fence's language to the major mode that highlights it.
Languages whose mode is not available are shown unhighlighted."
  :type '(alist :key-type string :value-type symbol)
  :group 'octocat-markdown)

(defconst octocat-markdown--highlight-limit 20000
  "Longest code, in characters, that is syntax-highlighted.")

(defun octocat-markdown--highlight (code lang)
  "Return the lines of CODE (a list of strings) fontified for LANG, or nil.
The fontified text is built in a scratch buffer under LANG's major mode
with its hooks suppressed, and only the faces are kept."
  (let ((mode (and octocat-markdown-highlight-code lang
                   (cdr (assoc (downcase lang) octocat-markdown-language-modes))))
        (text (string-join code "\n")))
    (when (and mode (fboundp mode)
               (<= (length text) octocat-markdown--highlight-limit))
      (condition-case nil
          (with-temp-buffer
            (insert text)
            (delay-mode-hooks (funcall mode))
            (font-lock-ensure)
            (let ((pos (point-min)) out)
              (while (< pos (point-max))
                (let ((next (next-single-char-property-change pos 'face nil (point-max)))
                      (face (get-text-property pos 'face)))
                  (push (if face
                            (propertize (buffer-substring-no-properties pos next)
                                        'face face)
                          (buffer-substring-no-properties pos next))
                        out)
                  (setq pos next)))
              (split-string (apply #'concat (nreverse out)) "\n")))
        (error nil)))))

(defun octocat-markdown--code-block (code &optional lang)
  "Return the lines of fenced CODE (a list of strings) as a padded block.
LANG is the fence's language, which picks the syntax highlighting.  A
`math' fence is shown as Unicode text.  A `mermaid' one is drawn by
`octocat-mermaid-render' to fit the width available; when that cannot
draw it, the source is shown, labelled as such."
  (let* ((lang (and lang (car (split-string lang))))
         (diagram (and (equal lang "mermaid")
                       (octocat-mermaid-render
                        code (and octocat-markdown--avail (- octocat-markdown--avail 2)))))
         (code (cond (diagram diagram)
                     ((member lang '("math" "latex-math"))
                      (split-string (octocat-markdown--tex (string-join code "\n")) "\n"))
                     (t code)))
         (code (or (and (not diagram) (octocat-markdown--highlight code lang)) code))
         ;; Padding stops at the column, so one long line wraps alone
         ;; instead of padding every line to its width.
         (width (min (apply #'max 0 (mapcar #'string-width code))
                     (if octocat-markdown--avail
                         (max 1 (- octocat-markdown--avail 2))
                       most-positive-fixnum))))
    (append
     (when (and (equal lang "mermaid") (not diagram))
       (list (cons (octocat-markdown--face "mermaid diagram (source)"
                                           'octocat-markdown-dimmed 'italic)
                   "")))
     (mapcar (lambda (l)
               (let ((s (concat " " l (make-string (max 0 (- width (string-width l))) ?\s) " ")))
                 (add-face-text-property 0 (length s) 'octocat-markdown-code-block t s)
                 (put-text-property 0 (length s) 'octocat-markdown-code t s)
                 (cons s "")))
             (or code '(""))))))

(defun octocat-markdown--alert (label)
  "Return the heading line for the GitHub alert LABEL, or nil."
  (when (string-match "\\`\\[!\\(NOTE\\|TIP\\|IMPORTANT\\|WARNING\\|CAUTION\\)\\] *\\'" label)
    (octocat-markdown--face (capitalize (match-string 1 label)) 'bold)))

(defconst octocat-markdown--indented-re "\\`\\(?: \\{4\\}\\|\t\\)"
  "Matches a line indented far enough to be an indented code block.")

(defun octocat-markdown--unindent (line)
  "Return LINE less the four columns that make it indented code."
  (if (string-prefix-p "\t" line)
      (substring line 1)
    (substring line (min 4 (length line)))))

(defun octocat-markdown--block-start-p (line)
  "Return non-nil if LINE opens a block, so it cannot continue a paragraph."
  (or (string-match-p octocat-markdown--item-re line)
      (string-match-p octocat-markdown--fence-re line)
      (string-match-p octocat-markdown--hr-re line)
      (string-match-p octocat-markdown--quote-re line)
      (string-match-p "\\` \\{0,3\\}#\\{1,6\\}\\(?: \\|\\'\\)" line)
      (string-match-p octocat-markdown--details-re line)
      (string-match-p octocat-markdown--pre-re line)
      (string-match-p octocat-markdown--html-table-re line)))

(defun octocat-markdown--lazy-p (prev next)
  "Return non-nil if NEXT continues, unindented, the paragraph line PREV.
PREV is a list item's or quote's line, its markers taken off."
  (and prev
       (not (octocat-markdown--blank-p prev))
       (not (octocat-markdown--blank-p next))
       (not (string-match-p octocat-markdown--fence-re prev))
       (not (string-match-p octocat-markdown--heading-re prev))
       (not (string-match-p octocat-markdown--hr-re prev))
       (not (octocat-markdown--block-start-p next))))

(defun octocat-markdown--heading-row (text level)
  "Return the row of a heading of LEVEL with markdown source TEXT."
  (let ((row (octocat-markdown--standout
              (cons (octocat-markdown--face
                     (octocat-markdown--inline text)
                     (pcase level (1 'octocat-markdown-heading-1)
                            (2 'octocat-markdown-heading-2)
                            (_ 'octocat-markdown-heading)))
                    ""))))
    (put-text-property 0 (length (car row)) 'octocat-markdown-heading t (car row))
    row))

(defun octocat-markdown--count (regexp string)
  "Return how many times REGEXP matches in STRING."
  (let ((n 0) (pos 0))
    (while (string-match regexp string pos)
      (setq n (1+ n) pos (max (1+ pos) (match-end 0))))
    n))

(defvar octocat-markdown--in-details nil
  "Non-nil while rendering the body of a <details>.
A <details> inside another does not fold: it shows as a bold title.")

(defun octocat-markdown--details (line lines depth)
  "Render the <details> element opened on LINE, the rest of it in LINES.
DEPTH is as for `octocat-markdown--blocks'.  Return (ROWS . REST), REST
being the lines after the closing tag.

The summary becomes a row that RET expands or collapses; the body rows
carry an `octocat-markdown-fold' property (see `octocat-markdown--finish')
and start collapsed unless the tag has `open'."
  (string-match octocat-markdown--details-re line)
  (let* ((open  (string-match-p "\\bopen\\b" (match-string 1 line)))
         (level 1)
         inner)
    (push (substring line (match-end 0)) lines)
    (while (and lines (> level 0))
      (let ((l (pop lines)))
        (setq level (+ level (octocat-markdown--count "<details\\b" l)
                       (- (octocat-markdown--count "</details>" l))))
        (when (<= level 0)
          (setq l (if (string-match "\\`\\(.*\\)</details>" l) (match-string 1 l) l)))
        (push l inner)))
    (let* ((text (string-join (nreverse inner) "\n"))
           (summary nil)
           (body text))
      (when (string-match "<summary[^>]*>\\(\\(?:.\\|\n\\)*?\\)</summary>" text)
        (setq summary (string-trim (replace-regexp-in-string
                                    "[ \t\n]+" " " (match-string 1 text)))
              body (concat (substring text 0 (match-beginning 0))
                           (substring text (match-end 0)))))
      (let* ((title (octocat-markdown--face
                     (octocat-markdown--inline (if (member summary '(nil "")) "Details" summary))
                     'bold))
             (rows  (let ((octocat-markdown--in-details t))
                      (octocat-markdown--tidy
                       (octocat-markdown--blocks (split-string body "\n") depth)))))
        (cons
         (if octocat-markdown--in-details
             (cons (octocat-markdown--standout (cons title "")) rows)
           (cons
            (octocat-markdown--standout
             (cons (octocat-markdown--interactive
                    (concat (propertize "▸" 'octocat-markdown-arrow t
                                        'display (and open "▾"))
                            " " title)
                    "RET: expand or collapse" 'octocat-markdown-details t)
                   ""))
            (mapcar (lambda (r)
                      (let ((s (copy-sequence (if (string-empty-p (car r)) " " (car r)))))
                        (put-text-property 0 (length s) 'octocat-markdown-fold
                                           (if open 'open 'closed) s)
                        (cons s (cdr r))))
                    rows)))
         lines)))))

(defun octocat-markdown--pre (line lines)
  "Render the <pre> element opened on LINE, the rest of it in LINES.
Return (ROWS . REST), REST being the lines after the closing tag.  As
on GitHub, its whitespace is kept and only HTML inside it is rendered."
  (string-match octocat-markdown--pre-re line)
  (let ((l (substring line (match-end 0))) (close "</pre *>") body rest)
    (while (and (not (string-match-p close l)) lines)
      (push l body)
      (setq l (pop lines)))
    (if (not (string-match close l))
        (push l body)
      (push (substring l 0 (match-beginning 0)) body)
      (setq rest (string-trim (substring l (match-end 0)))))
    (setq body (nreverse body))
    ;; HTML drops a newline straight after <pre>, and one before </pre>
    ;; ends the last line rather than adding an empty one.
    (when (and (cdr body) (string-empty-p (car body))) (pop body))
    (when (and (cdr body) (string-empty-p (car (last body))))
      (setq body (butlast body)))
    (cons (octocat-markdown--code-block
           (let ((octocat-markdown--rules octocat-markdown--html-rules)
                 (open nil))
             (mapcar (lambda (l)
                       (pcase-let ((`(,l2 . ,o) (octocat-markdown--balance l open t)))
                         (setq open o)
                         (octocat-markdown--inline l2)))
                     body)))
          (if (member rest '(nil "")) lines (cons rest lines)))))

(defun octocat-markdown--blocks (lines &optional depth)
  "Return the rendered rows of markdown LINES (a list of strings).
DEPTH is the list nesting depth, which picks the bullet."
  (let ((depth (or depth 0)) out open)
    (while lines
      ;; OPEN carries HTML elements from one paragraph line to the next.
      (let ((line (pop lines)) (carry open))
        (setq open nil)
        (cond
         ((octocat-markdown--blank-p line)
          (push (cons "" "") out))
         ;; HTML comment, possibly spanning lines.
         ((string-match-p "\\`[ \t]*<!--" line)
          (while (and (not (string-match-p "-->" line)) lines)
            (setq line (pop lines))))
         ((string-match-p octocat-markdown--pre-re line)
          (pcase-let ((`(,rows . ,rest) (octocat-markdown--pre line lines)))
            (dolist (r rows) (push r out))
            (setq lines rest)))
         ((string-match-p octocat-markdown--html-table-re line)
          (pcase-let ((`(,rows . ,rest) (octocat-markdown--html-table line lines)))
            (dolist (r rows) (push r out))
            (setq lines rest)))
         ((string-match octocat-markdown--fence-re line)
          (let ((fence (match-string 1 line))
                (lang  (string-trim (match-string 2 line)))
                code)
            (while (and lines
                        (not (string-match-p
                              (concat "^ \\{0,3\\}" (regexp-quote (substring fence 0 1))
                                      "\\{" (number-to-string (length fence)) ",\\} *$")
                              (car lines))))
              (push (pop lines) code))
            (pop lines)
            (dolist (l (octocat-markdown--code-block (nreverse code) lang))
              (push l out))))
         ;; Indented code: four spaces, after a blank row or a block.
         ((and (string-match-p octocat-markdown--indented-re line)
               (let ((prev (car out)))
                 (or (null prev) (string-empty-p (car prev))
                     (octocat-markdown--standout-p prev))))
          (let ((code (list (octocat-markdown--unindent line))))
            (while (and lines
                        (or (string-match-p octocat-markdown--indented-re (car lines))
                            (and (octocat-markdown--blank-p (car lines))
                                 (let ((next (seq-find
                                              (lambda (l) (not (octocat-markdown--blank-p l)))
                                              lines)))
                                   (and next
                                        (string-match-p octocat-markdown--indented-re next))))))
              (push (octocat-markdown--unindent (pop lines)) code))
            (dolist (l (octocat-markdown--code-block (nreverse code)))
              (push l out))))
         ((string-match-p octocat-markdown--details-re line)
          (pcase-let ((`(,rows . ,rest) (octocat-markdown--details line lines depth)))
            (dolist (r rows) (push r out))
            (setq lines rest)))
         ((string-match-p octocat-markdown--hr-re line)
          (push (octocat-markdown--standout
                 (cons (propertize (make-string 40 ?─) 'face 'octocat-markdown-dimmed) ""))
                out))
         ((string-match octocat-markdown--heading-re line)
          (push (octocat-markdown--heading-row (or (match-string 2 line) "")
                                               (length (match-string 1 line)))
                out))
         ((string-match-p octocat-markdown--quote-re line)
          (let ((quoted (list line)))
            (while (and lines
                        (or (string-match-p octocat-markdown--quote-re (car lines))
                            ;; Lazy continuation: a paragraph in the
                            ;; quote runs on into a line with fewer `>'.
                            (octocat-markdown--lazy-p
                             (replace-regexp-in-string "\\`\\(?: \\{0,3\\}> ?\\)+" "" (car quoted))
                             (car lines))))
              (push (pop lines) quoted))
            (setq quoted (mapcar (lambda (l) (replace-regexp-in-string "^ \\{0,3\\}> ?" "" l))
                                 (nreverse quoted)))
            (when-let* ((alert (octocat-markdown--alert (car quoted))))
              (setq quoted (cons (concat "**" (substring-no-properties alert) "**")
                                 (cdr quoted))))
            (let ((bar (propertize "│ " 'face 'octocat-markdown-dimmed)))
              (dolist (l (let ((octocat-markdown--avail
                                (and octocat-markdown--avail (- octocat-markdown--avail 2))))
                           (octocat-markdown--tidy
                            (octocat-markdown--blocks quoted depth))))
                (push (octocat-markdown--standout
                       (cons (concat bar (car l)) (concat bar (cdr l))))
                      out)))))
         ((string-match octocat-markdown--item-re line)
          (let* ((indent  (length (match-string 1 line)))
                 (marker  (match-string 2 line))
                 (first   (or (match-string 3 line) ""))
                 (ordered (not (string-match-p "\\`[-*+]\\'" marker)))
                 (width   (+ (length marker) 1))
                 (content (list first)))
            ;; Continuation: indented lines, and blanks leading into them.
            (while (and lines
                        (or (> (octocat-markdown--indentation (car lines)) indent)
                            (and (octocat-markdown--blank-p (car lines))
                                 (let ((next (seq-find
                                              (lambda (l) (not (octocat-markdown--blank-p l)))
                                              lines)))
                                   (and next (> (octocat-markdown--indentation next) indent))))
                            ;; Lazy continuation: unindented text running on.
                            (octocat-markdown--lazy-p (car content) (car lines))))
              (let ((l (pop lines)))
                (push (substring l (min (length l) (min (octocat-markdown--indentation l)
                                                        (+ indent width))))
                      content)))
            (setq content (nreverse content))
            (let* ((task (and (string-match "\\`\\[\\([ xX]\\)\\] +" first)
                              (cons (equal (match-string 1 first) " ") (match-end 0))))
                   (label (cond (task (propertize (if (car task) "☐" "☑")
                                                  'face (if (car task)
                                                            'octocat-markdown-dimmed
                                                          'success)))
                                (ordered (propertize marker 'face 'octocat-markdown-dimmed))
                                (t (propertize (if (cl-evenp depth) "•" "◦")
                                               'face 'octocat-markdown-dimmed))))
                   (pad (+ (if (and (not task) ordered) (length marker) 1) 1))
                   (rows (let ((octocat-markdown--avail
                                (and octocat-markdown--avail (- octocat-markdown--avail pad))))
                           (octocat-markdown--tidy
                            (octocat-markdown--blocks
                             (if task (cons (substring first (cdr task)) (cdr content)) content)
                             (1+ depth))))))
              (when (null rows) (setq rows (list (cons "" ""))))
              (let ((firstp t))
                (dolist (r rows)
                  (push (octocat-markdown--standout
                         (cons (if firstp
                                   (concat label " " (car r))
                                 (concat (make-string pad ?\s) (car r)))
                               (concat (make-string pad ?\s) (cdr r))))
                        out)
                  (setq firstp nil))))
            ;; Items of one list sit together: no blank row between them.
            (while (and lines (octocat-markdown--blank-p (car lines))
                        (cdr lines) (string-match-p octocat-markdown--item-re (cadr lines)))
              (pop lines))))
         ;; Table: a header row followed by a delimiter row.
         ((and (string-match-p "|" line) lines
               (string-match-p octocat-markdown--table-delim-re (car lines))
               (string-match-p "|" (car lines)))
          (let ((delim (pop lines)) rows)
            (while (and lines (not (octocat-markdown--blank-p (car lines)))
                        (string-match-p "|" (car lines)))
              (push (pop lines) rows))
            (dolist (l (octocat-markdown--table line delim (nreverse rows)))
              (push (octocat-markdown--standout l) out))))
         ;; Setext heading: a line underlined by === or ---.
         ((and lines (string-match octocat-markdown--setext-re (car lines)))
          (let ((level (if (string-prefix-p "=" (string-trim-left (pop lines))) 1 2)))
            (push (octocat-markdown--heading-row (string-trim line) level) out)))
         (t
          (pcase-let ((`(,l . ,o) (octocat-markdown--balance (string-trim line) carry)))
            (setq open o)
            (push (cons (octocat-markdown--image-row (octocat-markdown--inline l)) "")
                  out))))))
    (nreverse out)))

(defun octocat-markdown--standout (row)
  "Return ROW marked as a block that needs no blank row beside it."
  (let ((s (copy-sequence (car row))))
    (put-text-property 0 (length s) 'octocat-markdown-standout t s)
    (cons s (cdr row))))

(defun octocat-markdown--standout-p (row)
  "Return non-nil if ROW is marked by `octocat-markdown--standout'."
  (and row (> (length (car row)) 0)
       (get-text-property 0 'octocat-markdown-standout (car row))))

(defun octocat-markdown--heading-p (row)
  "Return non-nil if ROW is a heading."
  (and (> (length (car row)) 0)
       (get-text-property 0 'octocat-markdown-heading (car row))))

(defun octocat-markdown--tidy (rows)
  "Return ROWS packed tightly, to save vertical space.
Blank rows at either end, doubled blank rows, and blank rows next to a
block that stands out by itself (rule, table, heading, quote) are
dropped.  Blank rows beside a code box or between paragraphs are kept.
A heading after other rows always gets one blank row above it, so
sections are easy to tell apart."
  (let (out)
    (dolist (r rows)
      (unless (and (string-empty-p (car r))
                   (or (null out) (string-empty-p (caar out))))
        (push r out)))
    (when (and out (string-empty-p (caar out))) (pop out))
    (setq out (nreverse out))
    (let (tight prev)
      (while out
        (let ((r (pop out)))
          (when (and tight (octocat-markdown--heading-p r)
                     (not (string-empty-p (caar tight))))
            (push (cons "" "") tight))
          (unless (and (string-empty-p (car r))
                       (or (octocat-markdown--standout-p prev)
                           (octocat-markdown--standout-p (car out))))
            (push r tight))
          (setq prev r)))
      (nreverse tight))))

;;;; Entry points

(defun octocat-markdown--lines (text)
  "Return TEXT as a list of lines with CR characters stripped."
  (split-string (replace-regexp-in-string "\r" "" text) "\n"))

(defun octocat-markdown--row-fold (row)
  "Return the fold state (`open' or `closed') of ROW, or nil if it is not folded."
  (let* ((s (car row))
         (i (text-property-not-all 0 (length s) 'octocat-markdown-fold nil s)))
    (and i (get-text-property i 'octocat-markdown-fold s))))

(defun octocat-markdown--cut (string width)
  "Return STRING cut into pieces of at most WIDTH columns, as a list."
  (let ((beg 0) pieces)
    (while (< beg (length string))
      (let ((end (1+ beg)))
        (while (and (< end (length string))
                    (<= (string-width (substring string beg (1+ end))) width))
          (setq end (1+ end)))
        (push (substring string beg end) pieces)
        (setq beg end)))
    (or (nreverse pieces) (list ""))))

(defun octocat-markdown-wrap-hung (string width hang)
  "Return STRING broken at spaces into lines of at most WIDTH columns.
Its leading spaces are kept, and the lines after the first start with
HANG, a string, or that many spaces, as a `wrap-prefix' would show it."
  (let* ((lead   (- (length string) (length (string-trim-left string " +"))))
         (prefix (if (stringp hang) hang (make-string hang ?\s)))
         (text   (substring string lead))
         ;; The first line has no prefix, so it gets the whole width.
         (first  (car (octocat-markdown--wrap text (max 1 (- width lead)))))
         (rest   (string-trim-left (substring text (length first)) " +")))
    (cons (concat (substring string 0 lead) first)
          (unless (string-empty-p rest)
            (mapcar (lambda (l) (concat prefix l))
                    (octocat-markdown--wrap
                     rest (max 1 (- width (max lead (string-width prefix))))))))))

(defun octocat-markdown--fill (rows width)
  "Return ROWS with those wider than WIDTH columns broken to fit it.
Emacs would wrap them at the window's edge, past a capped page's column.
Prose breaks at spaces, hung as a wrap would be; code breaks anywhere,
each continuation marked with an arrow.  Tables were already fit where
they can be.  A nil WIDTH leaves ROWS as they are."
  (if (null width)
      rows
    (cl-mapcan
     (lambda (row)
       (let* ((s    (car row))
              (hang (cdr row))
              (has  (lambda (prop) (text-property-not-all 0 (length s) prop nil s))))
         (cond
          ;; An image's link is replaced whole by the image.
          ((or (<= (string-width s) width) (funcall has 'octocat-markdown-table)
               (funcall has 'octocat-markdown-image))
           (list row))
          ((funcall has 'octocat-markdown-code)
           (let* ((head  (car (octocat-markdown--cut s width)))
                  (room  (max 1 (- width (string-width hang) 2)))
                  (arrow (propertize "↪ " 'face 'octocat-markdown-dimmed))
                  (code  (lambda (str)
                           (add-face-text-property 0 (length str)
                                                   'octocat-markdown-code-block t str)
                           (put-text-property 0 (length str) 'octocat-markdown-code t str)
                           str)))
             ;; Only the arrow joins the box: HANG lies outside it.
             (setq arrow (concat hang (funcall code arrow)))
             ;; Pad each piece, the last above all, so the block's
             ;; background reaches the column like its other lines.
             (cons (cons head hang)
                   (mapcar (lambda (piece)
                             (cons (concat arrow piece
                                           (funcall code (make-string
                                                          (max 0 (- room (string-width piece)))
                                                          ?\s)))
                                   hang))
                           (octocat-markdown--cut (substring s (length head)) room)))))
          (t
           (mapcar (lambda (l) (cons l hang))
                   (octocat-markdown-wrap-hung s width hang))))))
     rows)))

(defun octocat-markdown--finish (rows indent)
  "Join ROWS (see `octocat-markdown--blocks') into a string prefixed by INDENT.
Wrapped continuation lines repeat INDENT, plus each row's hang, and a
code line's also an arrow, so the wrap is not taken for a newline.  The
lines of a collapsed <details> body are invisible, newline included."
  (mapconcat (lambda (row)
               (let ((full (concat indent (car row) "\n"))
                     (fold (octocat-markdown--row-fold row)))
                 (put-text-property
                  0 (length full) 'wrap-prefix
                  (concat indent (cdr row)
                          (and (text-property-not-all 0 (length (car row))
                                                      'octocat-markdown-code nil (car row))
                               (propertize "↪ " 'face 'octocat-markdown-dimmed)))
                  full)
                 (when fold
                   (add-text-properties
                    0 (length full)
                    ;; FOLD, not t: `octocat-markdown-reset-details' reads it.
                    (append (list 'octocat-markdown-fold fold)
                            (and (eq fold 'closed) '(invisible octocat-markdown-details)))
                    full))
                 full))
             rows ""))

(defun octocat-markdown--extract-definitions (lines)
  "Return LINES less the link and footnote definitions, which are recorded.
Link definitions go to `octocat-markdown--definitions' and footnotes to
`octocat-markdown--footnotes'.  Code fences are left alone."
  (let (out fence)
    (while lines
      (let ((l (pop lines)))
        (cond
         ((string-match octocat-markdown--fence-re l)
          (let ((mark (substring (match-string 1 l) 0 1)))
            (setq fence (cond ((null fence) mark) ((equal fence mark) nil) (t fence))))
          (push l out))
         (fence (push l out))
         ((string-match octocat-markdown--link-def-re l)
          (puthash (downcase (string-join (split-string (match-string 1 l)) " "))
                   (match-string 2 l) octocat-markdown--definitions))
         ((string-match octocat-markdown--footnote-def-re l)
          (let ((label (match-string 1 l))
                (text  (match-string 2 l)))
            (while (and lines (string-match-p "\\`  +[^ ]\\|\\`\t" (car lines)))
              (setq text (concat text " " (string-trim (pop lines)))))
            (push (cons label text) octocat-markdown--footnotes)))
         (t (push l out)))))
    (nreverse out)))

(defun octocat-markdown--footnote-rows ()
  "Return the rows listing the footnotes referenced by the text, or nil."
  (when octocat-markdown--footnote-order
    (cons (octocat-markdown--standout
           (cons (propertize (make-string 20 ?─) 'face 'octocat-markdown-dimmed) ""))
          (cl-loop for label in (reverse octocat-markdown--footnote-order)
                   for n from 1
                   collect (cons (concat (octocat-markdown--face
                                          (octocat-markdown--superscript n)
                                          'octocat-markdown-mention)
                                         " "
                                         (octocat-markdown--inline
                                          (cdr (assoc label octocat-markdown--footnotes))))
                                 "  ")))))

(defun octocat-markdown-render-verbatim (text &optional indent)
  "Return markdown TEXT unrendered, one line per row.
Each line is prefixed with INDENT (a string, default \"  \") and ends in
a newline; INDENT is also repeated on the wrapped continuation lines of
long lines.  Windows-style CR characters are stripped first."
  (octocat-markdown--finish
   (mapcar (lambda (l) (cons l "")) (octocat-markdown--lines text))
   (or indent "  ")))

(defun octocat-markdown-render (text &optional indent width)
  "Return markdown TEXT rendered for display, one line per row.
INDENT is as for `octocat-markdown-render-verbatim'.

WIDTH is the number of columns the output, INDENT included, should fit,
or nil for no limit.  Longer lines are broken to fit, see
`octocat-markdown--fill'.  A table that would be wider squeezes its
columns and wraps its cells over several lines instead, since breaking
a table's lines breaks its borders; one that cannot fit even squeezed
is left at its natural width.

Markup is replaced by faces; see the Commentary for what is understood."
  (let* ((indent (or indent "  "))
         (octocat-markdown--avail (and width (- width (string-width indent))))
         (octocat-markdown--definitions (make-hash-table :test #'equal))
         (octocat-markdown--footnotes nil)
         (octocat-markdown--footnote-order nil)
         (octocat-markdown--in-details nil)
         (rows (octocat-markdown--blocks
                (octocat-markdown--extract-definitions
                 (octocat-markdown--lines text)))))
    ;; Folded bodies are `invisible' by a symbol that must be in the
    ;; buffer's invisibility spec from the start, not only once a
    ;; summary has been toggled, or they show while the arrow says ▸.
    (octocat-markdown--ensure-invisibility)
    (octocat-markdown--finish
     (octocat-markdown--fill
      (or (octocat-markdown--tidy (append rows (octocat-markdown--footnote-rows)))
          (list (cons "" "")))
      octocat-markdown--avail)
     indent)))

;;;; Font-lock for markdown source

(defvar octocat-markdown-font-lock-keywords
  `(;; Fenced code first, so nothing inside it is taken for markup.
    ("^ \\{0,3\\}\\(?:```\\|~~~\\).*\n\\(?:.*\n\\)*?\\(?: \\{0,3\\}\\(?:```\\|~~~\\).*$\\|\\'\\)"
     (0 'octocat-markdown-code-block t))
    ("^ \\{0,3\\}\\(#\\{1,6\\}\\)\\( +.*\\)$"
     (1 'octocat-markdown-dimmed) (2 'octocat-markdown-heading))
    ("^ \\{0,3\\}\\([=-]+\\) *$" (1 'octocat-markdown-dimmed))
    ("^ \\{0,3\\}\\(>[> ]*\\)" (1 'octocat-markdown-dimmed))
    ("^ *\\([-*+]\\|[0-9]+[.)]\\)\\(?: +\\(\\[[ xX]\\]\\)\\)? "
     (1 'font-lock-builtin-face) (2 'font-lock-builtin-face nil t))
    ("^ \\{0,3\\}\\(?:\\([-*_]\\) *\\)\\{3,\\}$" (0 'octocat-markdown-dimmed))
    ("^|.*|$" (0 'octocat-markdown-dimmed))
    ("`[^`\n]+`" (0 'octocat-markdown-code))
    ("\\*\\*\\([^[:space:]*]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*" (0 'bold))
    ("\\(?:\\`\\|[^[:alnum:]_]\\)\\(__[^[:space:]_]\\(?:.*?[^[:space:]_]\\)?__\\)"
     (1 'bold))
    ("\\*\\([^*[:space:]]\\(?:[^*\n]*?[^*[:space:]]\\)?\\)\\*" (0 'italic))
    (,(concat "\\(?:\\`\\|[^[:alnum:]_]\\)\\(_[^_[:space:]]\\(?:[^_\n]*?[^_[:space:]]\\)?_\\)"
              "\\(?:[^[:alnum:]_]\\|\\'\\)")
     (1 'italic))
    ("~~[^[:space:]~]\\(?:.*?[^[:space:]~]\\)?~~" (0 'octocat-markdown-strike))
    ("!?\\[\\([^]\n]+\\)\\](\\([^)\n]*\\))"
     (1 'octocat-markdown-link) (2 'octocat-markdown-dimmed))
    ("\\[\\([^]\n]+\\)\\]\\[[^]\n]*\\]" (1 'octocat-markdown-link))
    ("^ \\{0,3\\}\\(\\[[^]\n]+\\]\\):" (1 'octocat-markdown-link))
    ("<\\(?:https?://[^>\n]+\\|/?[a-zA-Z][^<>\n]*\\|!--.*?--\\)>"
     (0 'octocat-markdown-dimmed))
    ("https?://[^[:space:]<>]*[^[:space:]<>.,;:!?)\"']" (0 'octocat-markdown-link))
    ("\\(?:\\`\\|[^[:alnum:]_/]\\)\\(@[A-Za-z0-9][A-Za-z0-9-]*\\(?:/[A-Za-z0-9_.-]+\\)?\\)"
     (1 'octocat-markdown-mention))
    ("\\(?:\\`\\|[^[:alnum:]_&]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)?#[0-9]+\\)\\b"
     (1 'octocat-markdown-mention)))
  "Font-lock keywords for markdown source, as in `octocat-edit-mode'.
Fenced code is matched across lines, so the buffer sets `font-lock-multiline'.")

(provide 'octocat-markdown)
;;; octocat-markdown.el ends here
