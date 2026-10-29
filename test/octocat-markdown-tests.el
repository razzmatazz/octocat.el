;;; octocat-markdown-tests.el --- ERT tests for the markdown renderer  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5
;; Assisted-by: Claude:claude-sonnet-5-5

;;; Commentary:

;; Tests for octocat-markdown.el and the glue around it in octocat-core.el
;; and octocat-edit.el.  Run via:
;;   eldev test test/octocat-markdown-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(defun octocat-markdown-tests--md (text &optional width)
  "Return TEXT rendered as markdown, without indent or text properties.
WIDTH is passed on to `octocat-markdown-render'."
  (substring-no-properties (octocat-markdown-render text "" width)))

(defun octocat-markdown-tests--prop (rendered needle prop)
  "Return property PROP of the first character of NEEDLE in RENDERED."
  (get-text-property (string-match (regexp-quote needle) rendered) prop rendered))


;;; Glue in octocat-core

(ert-deftest octocat-markdown-test-string ()
  "Every line gets the indent and a wrap prefix; raw text is kept verbatim."
  (let ((out (octocat--markdown-string "a *b*\r\nc" "> " t 80)))
    (should (equal (substring-no-properties out) "> a *b*\n> c\n"))
    (should (equal (get-text-property 0 'wrap-prefix out) "> "))))

(ert-deftest octocat-markdown-test-width-is-the-full-line ()
  "Rendered markdown may use every column Emacs can show, not one less."
  (with-temp-buffer
    (should (= (octocat--markdown-width)
               (window-max-chars-per-line (selected-window))))))

(ert-deftest octocat-markdown-test-width-keeps-point ()
  "Reading the width leaves point alone in a buffer in an unselected window.
`window-max-chars-per-line' selects the window, which would set point to
the window's point; mid-render that scrambled the page."
  (let ((buf (generate-new-buffer " *octocat-width-test*")))
    (save-window-excursion
      (unwind-protect
          (let ((other (split-window)))
            (set-window-buffer other buf)
            (with-current-buffer buf
              (insert "0123456789")
              (set-window-point other 1)
              (goto-char 5)
              (octocat--markdown-width)
              (should (= (point) 5))))
        (kill-buffer buf)))))


;;; Inline

(ert-deftest octocat-markdown-test-inline ()
  "Inline markup is replaced by faces; snake_case and escapes survive."
  (let ((out (octocat-markdown-render "*a* **b** `c` snake_case_name \\*x\\*" "")))
    (should (equal (substring-no-properties out) "a b c snake_case_name *x*\n"))
    (should (equal (get-text-property 0 'face out) 'italic))
    (should (equal (get-text-property 2 'face out) 'bold)))
  (let ((out (octocat-markdown-render "[some link](https://google.com)" "")))
    (should (equal (substring-no-properties out) "some link\n"))
    (should (equal (get-text-property 0 'octocat-markdown-url out) "https://google.com")))
  (should (equal (octocat-markdown-tests--md "@bob fixed #5 <!-- x --><b>hi</b>")
                 "@bob fixed #5 hi\n")))

(ert-deftest octocat-markdown-test-emoji-img-kbd ()
  "Shortcodes become emoji, <img> a link and <kbd> a key; unknown codes stay."
  (should (equal (octocat-markdown-tests--md "ship it :rocket: :nope: 12:30:45")
                 "ship it 🚀 :nope: 12:30:45\n"))
  (let ((out (octocat-markdown-render "<img src=\"http://x/y.png\" alt=\"logo\">" "")))
    (should (equal (substring-no-properties out) "[image: logo]\n"))
    (should (equal (get-text-property 0 'octocat-markdown-url out) "http://x/y.png")))
  (should (equal (octocat-markdown-tests--md "press <kbd>Ctrl</kbd>") "press [Ctrl]\n")))

(ert-deftest octocat-markdown-test-image-alone ()
  "An image alone on its line is marked, with its columns, and not wrapped."
  (let* ((out  (octocat-markdown-render
                "- <img width=\"300\" alt=\"a long description\" src=\"https://x/y.png\">"
                "" 12))
         (mark (octocat-markdown-tests--prop out "[image" 'octocat-markdown-image)))
    (should (equal (substring-no-properties out) "• [image: a long description]\n"))
    (should (equal mark '(:url "https://x/y.png" :width 300 :cols 10))))
  (let ((out (octocat-markdown-render "![shot](https://x/y.png)" "" nil)))
    (should (equal (get-text-property 0 'octocat-markdown-image out)
                   '(:url "https://x/y.png" :width nil :cols nil))))
  (dolist (md '("see ![shot](https://x/y.png)" "![a](https://x/a.png) ![b](https://x/b.png)"
                "| ![shot](https://x/y.png) |\n|-|"))
    (let ((out (octocat-markdown-render md "" nil)))
      (should-not (text-property-not-all 0 (length out) 'octocat-markdown-image nil out))))
  (let ((out (octocat-markdown-render "<img width=\"80%\" src=\"https://x/y.png\">" "" nil)))
    (should (equal (get-text-property 0 'octocat-markdown-image out)
                   '(:url "https://x/y.png" :width nil :cols nil)))))

(ert-deftest octocat-markdown-test-entities ()
  "Named, decimal and hex character references are decoded; unknown ones kept."
  (should (equal (substring-no-properties
                  (octocat-markdown-render
                   "<a>x</a>&ensp;Vulns &mdash; &#x2713; &#65; &bogus; a < b && c" ""))
                 "x\u2002Vulns — ✓ A &bogus; a < b && c\n"))
  ;; In a code span, an entity is as written.
  (should (equal (octocat-markdown-tests--md "`&amp;`") "&amp;\n")))

(ert-deftest octocat-markdown-test-emphasis-spans-lines ()
  "Emphasis may span a paragraph's lines, which stay a row each."
  (let ((out (octocat-markdown-render "a **b\nc** d ~~e\nf~~ *g\nh*\n<b>i\nj</b> k" "")))
    (should (equal (substring-no-properties out) "a b\nc d e\nf g\nh\ni\nj k\n"))
    (dolist (c '("b" "c" "i" "j"))
      (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out c 'face)))))
    (should (eq (octocat-markdown-tests--prop out "f" 'face) 'octocat-markdown-strike))
    (should (eq (octocat-markdown-tests--prop out "h" 'face) 'italic))
    (should-not (octocat-markdown-tests--prop out "d" 'face))
    (should-not (octocat-markdown-tests--prop out "k" 'face)))
  ;; A block ends the paragraph, so emphasis does not run into it.
  (should (equal (octocat-markdown-tests--md "a **b\n# h\nc** d")
                 "a **b\n\nh\nc** d\n")))

(ert-deftest octocat-markdown-test-html-parsed ()
  "HTML is read by a parser: nesting, quoted `>', unclosed tags, spacing."
  (let ((out (octocat-markdown-render "<b><b>x</b> y</b> z" "")))
    (should (equal (substring-no-properties out) "x y z\n"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "y" 'face))))
    (should-not (octocat-markdown-tests--prop out "z" 'face)))
  (let ((out (octocat-markdown-render "<a href=\"https://x.org/?a=1>2\">y</a>" "")))
    (should (equal (substring-no-properties out) "y\n"))
    (should (equal (octocat-markdown-tests--prop out "y" 'octocat-markdown-url)
                   "https://x.org/?a=1>2")))
  (should (memq 'bold (ensure-list (octocat-markdown-tests--prop
                                    (octocat-markdown-render "<b>open y" "") "y" 'face))))
  ;; libxml drops the space between two images unless kept from it.
  (should (equal (octocat-markdown-tests--md
                  "<img src=\"https://x/a.png\" alt=\"a\"> <img src=\"https://x/b.png\" alt=\"b\">")
                 "[image: a] [image: b]\n")))

(ert-deftest octocat-markdown-test-html-block ()
  "An HTML block runs to a blank line: indented lines in it are no code."
  (let ((out (octocat-markdown-render
              (concat "<p align=\"center\">\n  <a href=\"https://x.org/map\">\n"
                      "    <img src=\"https://x/map.svg\" alt=\"map\" width=\"100%\">\n"
                      "  </a>\n</p>\n\n**after**")
              "" 40)))
    (should (equal (substring-no-properties out) "[image: map]\n\nafter\n"))
    (should (equal (octocat-markdown-tests--prop out "[image" 'octocat-markdown-url)
                   "https://x.org/map"))
    (should (octocat-markdown-tests--prop out "[image" 'octocat-markdown-image)))
  ;; Block elements break the line; markdown in the block stays as written.
  (should (equal (octocat-markdown-tests--md "<div><h1>Title</h1><p>a **b**</p></div>")
                 "Title\na **b**\n"))
  (should (equal (octocat-markdown-tests--md "<ul>\n  <li>one</li>\n  <li><b>two</b></li>\n</ul>")
                 "• one\n• two\n"))
  ;; Centred where the width is known.
  (should (equal (octocat-markdown-tests--md "<p align=\"center\">hi</p>\n\n<center>abcd</center>" 10)
                 "    hi\n\n   abcd\n"))
  (should (equal (octocat-markdown-tests--md "<p align=\"center\">hi</p>") "hi\n")))

(ert-deftest octocat-markdown-test-html-without-libxml ()
  "Without libxml, HTML shows as its source; markdown is still rendered."
  (cl-letf (((symbol-function 'libxml-available-p) #'ignore))
    (should (equal (octocat-markdown-tests--md "<b>x</b> *y* &amp;")
                   "<b>x</b> y &amp;\n"))
    (should (string-match-p "<table>" (octocat-markdown-tests--md
                                       "<table><tr><td>a</td></tr></table>")))))

(ert-deftest octocat-markdown-test-emphasis-around-tag ()
  "Markdown in a tag's attributes is not rendered, nor ends emphasis."
  (dolist (src '("*<a href=\"https://x.org/s/*a*\" target=\"_blank\">view</a>*"
                 "*<a href=\"https://x.org/~~a(b)%20[c](d)\">view</a>*"
                 "_<a href=\"https://x.org/a_b\" target=\"_blank\">view</a>_"))
    (let ((out (octocat-markdown-render src "")))
      (should (equal (substring-no-properties out) "view\n"))
      (should (memq 'italic (ensure-list (octocat-markdown-tests--prop out "view" 'face))))
      (should (string-prefix-p "https://x.org/"
                               (octocat-markdown-tests--prop out "view" 'octocat-markdown-url))))))

(ert-deftest octocat-markdown-test-inline-html ()
  "Inline HTML formatting tags become faces and <a href> a link."
  (let ((out (octocat-markdown-render
              (concat "<b>b</b> <strong>s</strong> <i>i</i> <em>e</em> "
                      "<code>c</code> <del>d</del> <s>x</s> <ins>u</ins>")
              "")))
    (should (equal (substring-no-properties out) "b s i e c d x u\n"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "b" 'face))))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "s" 'face))))
    (should (memq 'italic (ensure-list (octocat-markdown-tests--prop out "i" 'face))))
    (should (memq 'italic (ensure-list (octocat-markdown-tests--prop out "e" 'face))))
    (should (memq 'octocat-markdown-code
                  (ensure-list (octocat-markdown-tests--prop out "c" 'face))))
    (should (memq 'octocat-markdown-strike
                  (ensure-list (octocat-markdown-tests--prop out "d" 'face))))
    (should (memq 'octocat-markdown-strike
                  (ensure-list (octocat-markdown-tests--prop out "x" 'face))))
    (should (memq 'underline (ensure-list (octocat-markdown-tests--prop out "u" 'face)))))
  ;; Markdown inside the tags is still rendered.
  (let ((out (octocat-markdown-render "<b>a *it*</b>" "")))
    (should (equal (substring-no-properties out) "a it\n"))
    (should (equal (sort (copy-sequence (ensure-list (octocat-markdown-tests--prop out "it" 'face)))
                         #'string<)
                   '(bold italic))))
  (let ((out (octocat-markdown-render
              "see <a href=\"https://x.org/a\" title=\"t\">the <b>site</b></a> or <a name=\"n\">here</a>"
              "")))
    (should (equal (substring-no-properties out) "see the site or here\n"))
    (should (equal (octocat-markdown-tests--prop out "the" 'octocat-markdown-url)
                   "https://x.org/a"))
    (should (equal (octocat-markdown-tests--prop out "site" 'octocat-markdown-url)
                   "https://x.org/a"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "site" 'face))))
    (should-not (octocat-markdown-tests--prop out "here" 'octocat-markdown-url)))
  ;; <sup> and <sub> use script digits when they can, else the plain text.
  (should (equal (octocat-markdown-tests--md "x<sup>2</sup> H<sub>2</sub>O <sub>small print</sub>")
                 "x² H₂O small print\n")))

(ert-deftest octocat-markdown-test-pre ()
  "<pre> keeps its whitespace as a code block, rendering only HTML inside."
  (let* ((out (octocat-markdown-render
               (concat "<pre>\n"
                       "  a  *b*  &lt;c&gt;\n"
                       "<a href=\"https://x.org\">link</a> <b>bold</b> <code>kode</code>\n"
                       "</pre>\nafter")
               ""))
         (plain (substring-no-properties out)))
    (should (equal plain (concat "   a  *b*  <c>  \n"
                                 " link bold kode \n"
                                 "after\n")))
    (should (equal (octocat-markdown-tests--prop out "link" 'octocat-markdown-url)
                   "https://x.org"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "bold" 'face))))
    (should (memq 'octocat-markdown-code-block
                  (ensure-list (octocat-markdown-tests--prop out "bold" 'face))))
    (should-not (memq 'octocat-markdown-code
                      (ensure-list (octocat-markdown-tests--prop out "kode" 'face)))))
  ;; Content on the tag lines, and a one-line <pre>.
  (should (equal (octocat-markdown-tests--md "<pre lang=\"x\">one\ntwo</pre>")
                 " one \n two \n"))
  (should (equal (octocat-markdown-tests--md "<pre>x  y</pre>") " x  y \n"))
  ;; A blank line inside does not end it.
  (should (equal (octocat-markdown-tests--md "<pre>\na\n\nb\n</pre>") " a \n   \n b \n")))

(ert-deftest octocat-markdown-test-html-across-lines ()
  "An HTML element spanning lines formats every line of it, up to a blank line."
  (let ((out (octocat-markdown-render "<b>one\ntwo</b> three" "")))
    (should (equal (substring-no-properties out) "one\ntwo three\n"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "one" 'face))))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "two" 'face))))
    (should-not (memq 'bold (ensure-list (octocat-markdown-tests--prop out "three" 'face)))))
  (let ((out (octocat-markdown-render "<a href=\"https://x.org\">one\n<i>two</i></a>" "")))
    (should (equal (substring-no-properties out) "one\ntwo\n"))
    (should (equal (octocat-markdown-tests--prop out "one" 'octocat-markdown-url) "https://x.org"))
    (should (equal (octocat-markdown-tests--prop out "two" 'octocat-markdown-url) "https://x.org"))
    (should (memq 'italic (ensure-list (octocat-markdown-tests--prop out "two" 'face)))))
  (let ((out (octocat-markdown-render "<b>one\n\ntwo" "")))
    (should (equal (substring-no-properties out) "one\n\ntwo\n"))
    (should-not (memq 'bold (ensure-list (octocat-markdown-tests--prop out "two" 'face)))))
  ;; A tag in a code span opens nothing.
  (let ((out (octocat-markdown-render "`<b>` one\ntwo" "")))
    (should (equal (substring-no-properties out) "<b> one\ntwo\n"))
    (should-not (memq 'bold (ensure-list (octocat-markdown-tests--prop out "two" 'face)))))
  (let ((out (octocat-markdown-render "> <i>one\n> two</i>" "")))
    (should (equal (substring-no-properties out) "│ one\n│ two\n"))
    (should (memq 'italic (ensure-list (octocat-markdown-tests--prop out "two" 'face)))))
  (let ((out (octocat-markdown-render "<pre><b>one\ntwo</b> x</pre>" "")))
    (should (equal (substring-no-properties out) " one   \n two x \n"))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "one" 'face))))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "two" 'face))))
    (should-not (memq 'bold (ensure-list (octocat-markdown-tests--prop out "x " 'face))))))

(ert-deftest octocat-markdown-test-reference-links ()
  "Reference-style links resolve through their definitions, else stay literal."
  (let ((out (octocat-markdown-render
              "see [the docs][1], [Other] and [nope][x]\n\n[1]: http://docs\n[other]: http://o"
              "")))
    (should (equal (substring-no-properties out) "see the docs, Other and [nope][x]\n"))
    (should (equal (octocat-markdown-tests--prop out "the docs" 'octocat-markdown-url)
                   "http://docs"))
    (should (equal (octocat-markdown-tests--prop out "Other" 'octocat-markdown-url)
                   "http://o"))))

(ert-deftest octocat-markdown-test-linked-images ()
  "Images, inline or by reference, link to the link around them, as badges do."
  (let ((defs "\n\n[b]: https://x/b.svg\n[ci]: https://x/ci"))
    (dolist (md '("[![CI](https://x/b.svg)](https://x/ci)" "[![CI][b]][ci]"
                  "[![CI][b]](https://x/ci)" "[![CI](https://x/b.svg)][ci]"))
      (let ((out (octocat-markdown-render (concat md defs) "" nil)))
        (should (equal (substring-no-properties out) "[image: CI]\n"))
        (should (equal (get-text-property 0 'octocat-markdown-url out) "https://x/ci"))
        (should (equal (get-text-property 0 'octocat-markdown-image out)
                       '(:url "https://x/b.svg" :width nil :cols nil)))))
    (let ((out (octocat-markdown-render (concat "![CI][b] ![b] ![no][x] ![no]" defs) "")))
      (should (equal (substring-no-properties out) "[image: CI] [image: b] ![no][x] ![no]\n"))
      (should (equal (octocat-markdown-tests--prop out "[image: b" 'octocat-markdown-url)
                     "https://x/b.svg")))))

(ert-deftest octocat-markdown-test-footnotes ()
  "Footnote references are numbered in order and listed below a rule."
  (should (equal (octocat-markdown-tests--md
                  "b[^b] a[^a] b[^b]\n\n[^a]: Note A\n[^b]: Note B\n  runs on")
                 (concat "b¹ a² b¹\n"
                         (make-string 20 ?─) "\n"
                         "¹ Note B runs on\n"
                         "² Note A\n")))
  ;; An undefined footnote stays as written.
  (should (equal (octocat-markdown-tests--md "x[^none]") "x[^none]\n")))

(ert-deftest octocat-markdown-test-math ()
  "Inline and fenced TeX is approximated in Unicode; currency is left alone."
  (should (equal (octocat-markdown-tests--md "so $x^2 + \\alpha_1$ holds")
                 "so x² + α₁ holds\n"))
  (should (equal (octocat-markdown-tests--md "costs $5 and $10") "costs $5 and $10\n"))
  (should (equal (octocat-markdown-tests--md "```math\n\\frac{a}{b} \\le \\sqrt{x}\n```")
                 " a⁄b ≤ √(x) \n")))


;;; References

(ert-deftest octocat-markdown-test-references ()
  "#123, owner/repo#123 and commit hashes carry what is needed to open them."
  (let ((out (octocat-markdown-render
              "see #12, octo/cat#3, abc1234 and octo/cat@deadbeef1" "")))
    (should (equal (octocat-markdown-tests--prop out "#12" 'octocat-markdown-ref)
                   '(issue nil 12)))
    (should (equal (octocat-markdown-tests--prop out "octo/cat#3" 'octocat-markdown-ref)
                   '(issue "octo/cat" 3)))
    (should (equal (octocat-markdown-tests--prop out "abc1234" 'octocat-markdown-ref)
                   '(commit nil "abc1234")))
    (should (equal (octocat-markdown-tests--prop out "octo/cat@deadbeef1" 'octocat-markdown-ref)
                   '(commit "octo/cat" "deadbeef1"))))
  ;; Words and plain numbers made of hex digits are not hashes.
  (let ((out (octocat-markdown-render "defaced 1234567 123e4567-e89b" "")))
    (should-not (cl-some (lambda (i) (get-text-property i 'octocat-markdown-ref out))
                         (number-sequence 0 (1- (length out)))))))

(ert-deftest octocat-markdown-test-mention-links-to-profile ()
  "A mention links to the user's, or the team's, GitHub page."
  (let ((out (octocat-markdown-render "@bob and @org/team" "")))
    (should (equal (octocat-markdown-tests--prop out "@bob" 'octocat-markdown-url)
                   "https://github.com/bob"))
    (should (equal (octocat-markdown-tests--prop out "@org/team" 'octocat-markdown-url)
                   "https://github.com/orgs/org/teams/team"))))

(ert-deftest octocat-markdown-test-follow ()
  "RET on a link browses it and on a reference calls the reference function."
  (let ((out (octocat-markdown-render "[l](http://u) #7" "")) browsed opened)
    (should (eq (lookup-key (get-text-property 0 'keymap out) (kbd "RET"))
                #'octocat-markdown-follow))
    (cl-letf (((symbol-function 'browse-url) (lambda (u) (setq browsed u)))
              (octocat-markdown-ref-function (lambda (&rest args) (setq opened args))))
      (with-temp-buffer
        (insert out)
        (goto-char (point-min))
        (octocat-markdown-follow)
        (goto-char (1+ (string-match "#7" out)))
        (octocat-markdown-follow)
        (goto-char (point-max))
        (should-error (octocat-markdown-follow) :type 'user-error)))
    (should (equal browsed "http://u"))
    (should (equal opened '(issue nil 7)))))

(ert-deftest octocat-markdown-test-link-label-is-not-a-reference ()
  "A #123 or @mention in a link's label opens the link, as on GitHub."
  (dolist (md '("<a href=\"https://x.org/a\">#42 by @bob</a>"
                "[#42 by @bob](https://x.org/a)"))
    (let ((out (octocat-markdown-render md "")))
      (should-not (octocat-markdown-tests--prop out "#42" 'octocat-markdown-ref))
      (should (equal (octocat-markdown-tests--prop out "#42" 'octocat-markdown-url)
                     "https://x.org/a"))
      (should (equal (octocat-markdown-tests--prop out "@bob" 'octocat-markdown-url)
                     "https://x.org/a"))
      (should (equal (ensure-list (octocat-markdown-tests--prop out "#42" 'face))
                     '(octocat-markdown-link))))))

(ert-deftest octocat-markdown-test-relative-links ()
  "Relative links and images point into the repository of `octocat-markdown-base'."
  (let* ((octocat-markdown-base '("o/r" "feat/x" "docs/"))
         (out (octocat-markdown-render
               (concat "[a](shots/README.md) [b](../LICENSE#mit) [c](/src/) "
                       "[d](#usage) [e](https://x.org/y)\n\n![p](shots/a%20b.png)")
               "")))
    (should (equal (octocat-markdown-tests--prop out "a" 'octocat-markdown-url)
                   "https://github.com/o/r/blob/feat/x/docs/shots/README.md"))
    (should (equal (octocat-markdown-tests--prop out "b" 'octocat-markdown-url)
                   "https://github.com/o/r/blob/feat/x/LICENSE#mit"))
    (should (equal (octocat-markdown-tests--prop out "c" 'octocat-markdown-url)
                   "https://github.com/o/r/tree/feat/x/src"))
    (should (equal (octocat-markdown-tests--prop out "d" 'octocat-markdown-url) "#usage"))
    (should (equal (octocat-markdown-tests--prop out "e" 'octocat-markdown-url)
                   "https://x.org/y"))
    (should (memq 'octocat-markdown-image
                  (ensure-list (octocat-markdown-tests--prop out "[image: p]" 'face))))
    (should (equal (octocat-markdown-tests--prop out "[image: p]" 'octocat-markdown-img)
                   '(:url "https://github.com/o/r/raw/feat/x/docs/shots/a%20b.png"
                     :width nil :file ("o/r" "feat/x" "docs/shots/a b.png")))))
  (let ((out (octocat-markdown-render "[a](docs/README.md)" "")))
    (should (equal (octocat-markdown-tests--prop out "a" 'octocat-markdown-url)
                   "docs/README.md"))))

(ert-deftest octocat-markdown-test-follow-relative ()
  "A link left relative is not handed to `browse-url', which takes it for a file."
  (let ((out (octocat-markdown-render "[a](docs/README.md)" "")) browsed)
    (cl-letf (((symbol-function 'browse-url) (lambda (u) (setq browsed u))))
      (with-temp-buffer
        (insert out)
        (goto-char (point-min))
        (should-error (octocat-markdown-follow) :type 'user-error)))
    (should-not browsed)))

(ert-deftest octocat-markdown-test-open-ref ()
  "A number is opened as a PR or an issue, as GitHub says; a hash as a commit."
  (let (opened (answer "true"))
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback) (funcall callback (funcall parse answer))))
              ((symbol-function 'octocat-pr-open)
               (lambda (&rest a) (push (cons 'pr a) opened)))
              ((symbol-function 'octocat-issue-open)
               (lambda (&rest a) (push (cons 'issue a) opened)))
              ((symbol-function 'octocat-commit-open)
               (lambda (&rest a) (push (cons 'commit a) opened)))
              ((symbol-function 'octocat--still-selected-p) #'always))
      (octocat--markdown-open-ref 'issue "o/r" 5)
      (setq answer "false\n")
      (octocat--markdown-open-ref 'issue "o/r" 6)
      (octocat--markdown-open-ref 'commit "o/r" "abc1234"))
    (should (equal (nreverse opened)
                   '((pr "o/r" 5) (issue "o/r" 6) (commit "o/r" "abc1234"))))))

(ert-deftest octocat-markdown-test-open-ref-moved-on ()
  "A number resolved after the user went on to another buffer is not opened."
  (let (opened)
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback) (funcall callback (funcall parse "true"))))
              ((symbol-function 'octocat-pr-open)
               (lambda (&rest a) (push a opened)))
              ((symbol-function 'octocat--still-selected-p) #'ignore))
      (octocat--markdown-open-ref 'issue "o/r" 5))
    (should-not opened)))


;;; Blocks

(ert-deftest octocat-markdown-test-blocks ()
  "Headings, rules, fences, quotes and lists lose their markup."
  (should (equal (octocat-markdown-tests--md "# Title\n\n\n\ntext")
                 "Title\ntext\n"))
  ;; A heading always has one blank row above it, and none below.
  (should (equal (octocat-markdown-tests--md "text\n## Sub\n\nmore\n\n---\n### Deep")
                 (concat "text\n\nSub\nmore\n" (make-string 40 ?─) "\n\nDeep\n")))
  ;; Blank rows next to standalone blocks are dropped; prose keeps one.
  (should (equal (octocat-markdown-tests--md "*a* **b**\n\n---\n\n```\nx\n```\n\none\n\ntwo")
                 (concat "a b\n" (make-string 40 ?─) "\n x \n\none\n\ntwo\n")))
  (should (equal (octocat-markdown-tests--md "```\ncore\nlonger\n```")
                 " core   \n longer \n"))
  (should (equal (octocat-markdown-tests--md "- a\n  - b\n- [x] c\n- [ ] d\n1. e")
                 "• a\n  ◦ b\n☑ c\n☐ d\n1. e\n"))
  (should (equal (octocat-markdown-tests--md "> [!NOTE]\n> hi") "│ Note\n│ hi\n"))
  (should (string-prefix-p "─" (octocat-markdown-tests--md "---"))))

(ert-deftest octocat-markdown-test-setext-headings ()
  "A line underlined by === or --- is a heading, not text and a rule."
  (let ((out (octocat-markdown-render "Big\n===\n\nSmall\n---\ntext" "")))
    (should (equal (substring-no-properties out) "Big\n\nSmall\ntext\n"))
    (should (eq (octocat-markdown-tests--prop out "Big" 'face) 'octocat-markdown-heading-1))
    (should (eq (octocat-markdown-tests--prop out "Small" 'face) 'octocat-markdown-heading-2)))
  ;; A rule after a blank row is still a rule.
  (should (equal (octocat-markdown-tests--md "text\n\n---")
                 (concat "text\n" (make-string 40 ?─) "\n"))))

(ert-deftest octocat-markdown-test-indented-code ()
  "Four spaces after a blank row make a code block; inside a paragraph they do not."
  (should (equal (octocat-markdown-tests--md "text\n\n    a\n\n      b\n\nafter")
                 "text\n\n a   \n     \n   b \n\nafter\n"))
  (should (equal (octocat-markdown-tests--md "text\n    still text") "text\nstill text\n")))

(ert-deftest octocat-markdown-test-code-highlighting ()
  "Fenced code is fontified by its language, and plain without one."
  (let ((out (octocat-markdown-render "```elisp\n(defun f ())\n```" "")))
    (should (memq 'font-lock-keyword-face
                  (ensure-list (octocat-markdown-tests--prop out "defun" 'face))))
    (should (memq 'octocat-markdown-code-block
                  (ensure-list (octocat-markdown-tests--prop out "defun" 'face)))))
  (let ((out (octocat-markdown-render "```nosuchlang\n(defun f ())\n```" "")))
    (should (eq (octocat-markdown-tests--prop out "defun" 'face)
                'octocat-markdown-code-block)))
  (let ((out (let ((octocat-markdown-highlight-code nil))
               (octocat-markdown-render "```elisp\n(defun f ())\n```" ""))))
    (should (eq (octocat-markdown-tests--prop out "defun" 'face)
                'octocat-markdown-code-block))))

(ert-deftest octocat-markdown-test-code-block-fits-width ()
  "A code block pads to the width, not its longest line, which wraps marked."
  (let* ((out (octocat-markdown-render
               (concat "```\nshort\n" (make-string 50 ?x) "\n```") "" 20))
         (lines (split-string out "\n" t)))
    (should (= (string-width (car lines)) 20))
    (should (string-search "↪" (get-text-property 0 'wrap-prefix (cadr lines))))
    (should-not (string-search "↪" (or (get-text-property
                                         0 'wrap-prefix
                                         (octocat-markdown-render "text" "" 20))
                                        "")))))

(ert-deftest octocat-markdown-test-mermaid-is-labelled ()
  "A mermaid fence is shown as source, labelled as such."
  (should (equal (octocat-markdown-tests--md "```mermaid\nA-->B\n```")
                 "mermaid diagram (source)\n A-->B \n")))

(ert-deftest octocat-markdown-test-tight-lists-and-quotes ()
  "Blank rows between and inside list items and in quotes are dropped."
  (should (equal (octocat-markdown-tests--md "- a\n\n- b\n- c")
                 "• a\n• b\n• c\n"))
  ;; A blank row inside an item survives only between paragraphs (and is
  ;; indented like the rest of the item).
  (should (equal (octocat-markdown-tests--md "- one\n\n  two\n\n  ---\n\n  three")
                 (concat "• one\n  \n  two\n  " (make-string 40 ?─) "\n  three\n")))
  (should (equal (octocat-markdown-tests--md "> \n> a\n>\n> # h\n>\n> b\n> ")
                 "│ a\n│ \n│ h\n│ b\n")))

(ert-deftest octocat-markdown-test-lazy-continuation ()
  "Unindented text after a list item line continues the item; blocks end it."
  (should (equal (octocat-markdown-tests--md "- a\nb\n- c\n# h")
                 "• a\n  b\n• c\n\nh\n"))
  ;; After a blank row it is a paragraph of its own.
  (should (equal (octocat-markdown-tests--md "- a\n\nb") "• a\n\nb\n")))

(ert-deftest octocat-markdown-test-blank-row-after-list ()
  "A blank line after a list is kept, as on GitHub; one before it is not."
  (should (equal (octocat-markdown-tests--md "text\n\n- a\n- b\n\nafter")
                 "text\n• a\n• b\n\nafter\n"))
  ;; Also after an item with a nested list, numbered or not.
  (should (equal (octocat-markdown-tests--md "1. a\n   - b\n\nafter")
                 "1. a\n   ◦ b\n\nafter\n"))
  (should (equal (octocat-markdown-tests--md "- a\n  - b\n\n```\nc\n```")
                 "• a\n  ◦ b\n\n c \n"))
  ;; A heading after a list still gets just one blank row.
  (should (equal (octocat-markdown-tests--md "- a\n\n\n# h") "• a\n\nh\n")))

(ert-deftest octocat-markdown-test-blank-row-after-quote ()
  "A blank line after a quote or alert is kept, as on GitHub; one before it is not."
  (should (equal (octocat-markdown-tests--md "text\n\n> a\n\nafter")
                 "text\n│ a\n\nafter\n"))
  (should (equal (octocat-markdown-tests--md "> [!NOTE]\n> a\n\nafter")
                 "│ Note\n│ a\n\nafter\n")))

(ert-deftest octocat-markdown-test-quote-lazy-continuation ()
  "A paragraph in a quote runs on into lines with fewer `>', as on GitHub."
  (should (equal (octocat-markdown-tests--md "> a\nb") "│ a\n│ b\n"))
  (should (equal (octocat-markdown-tests--md "> > a\n> b\nc") "│ │ a\n│ │ b\n│ │ c\n"))
  (should (equal (octocat-markdown-tests--md "> - a\nb") "│ • a\n│   b\n"))
  ;; A heading or blank line ends the paragraph, and a block the quote.
  (should (equal (octocat-markdown-tests--md "> # h\nb") "│ h\nb\n"))
  (should (equal (octocat-markdown-tests--md "> > a\n>\n> b") "│ │ a\n│ \n│ b\n"))
  (should (equal (octocat-markdown-tests--md "> a\n- b") "│ a\n• b\n")))

(ert-deftest octocat-markdown-test-nested-quote-wraps ()
  "A wrapped line of a nested quote carries every bar, at full width."
  (should (equal (octocat-markdown-tests--md "> > one two three four five" 16)
                 "│ │ one two\n│ │ three four\n│ │ five\n"))
  (should (equal (octocat-markdown-tests--md "> > > - one two three four" 16)
                 "│ │ │ • one two\n│ │ │   three\n│ │ │   four\n"))
  ;; Unfilled, Emacs's own wrapping repeats the bars.
  (let ((out (octocat-markdown-render "> > > a" "  ")))
    (should (equal (substring-no-properties (get-text-property 0 'wrap-prefix out))
                   "  │ │ │ "))))

(ert-deftest octocat-markdown-test-table ()
  "Tables are drawn with aligned columns."
  (should (equal (octocat-markdown-tests--md "| a | b |\n|---|--:|\n| 1 | 22 |")
                 (concat "┌───┬────┐\n"
                         "│ a │  b │\n"
                         "├───┼────┤\n"
                         "│ 1 │ 22 │\n"
                         "└───┴────┘\n"))))

(ert-deftest octocat-markdown-test-table-escaped-pipe ()
  "An escaped pipe stays in its cell, in a code span too; a bare one splits."
  (should (equal (octocat-markdown-tests--md "| a |\n|---|\n| `x\\|y` |")
                 (concat "┌─────┐\n"
                         "│ a   │\n"
                         "├─────┤\n"
                         "│ x|y │\n"
                         "└─────┘\n"))))

(ert-deftest octocat-markdown-test-table-fits-width ()
  "A table wider than WIDTH wraps its cells; a short one is untouched."
  (let* ((md "| id | description |\n|--|--|\n| 1 | a rather long description of things |\n| 2 | short |")
         (out (octocat-markdown-tests--md md 24))
         (lines (split-string (string-trim-right out) "\n")))
    (dolist (l lines) (should (<= (string-width l) 24)))
    (should (string-match-p "rather" out))
    (should (string-match-p "things" out))
    ;; Wrapped rows are told apart by a rule between them.
    (should (= 2 (cl-count-if (lambda (l) (string-prefix-p "├" l)) (cdr (cdr lines)))))
    (should (equal (octocat-markdown-render md "" 200)
                   (octocat-markdown-render md "")))))


;;; HTML tables
;;
;; Expected results follow what GitHub's renderer (POST /markdown) makes
;; of the same source.

(defun octocat-markdown-tests--lines (&rest lines)
  "Return LINES as rendered text: each ended by a newline."
  (mapconcat (lambda (l) (concat l "\n")) lines ""))

(ert-deftest octocat-markdown-test-html-table-needs-table ()
  "Rows and cells outside a <table> are stripped, their text run together."
  (should (equal (octocat-markdown-tests--md "x <tr><td>alpha</td><td>beta</td></tr> y")
                 "x alphabeta y\n"))
  ;; Indented four spaces, it is code.
  (should (string-match-p "<table><tr><td>a</td></tr></table>"
                          (octocat-markdown-tests--md
                           "    <table><tr><td>a</td></tr></table>"))))

(ert-deftest octocat-markdown-test-html-table ()
  "A <table> is drawn as a grid; a leading row of <th> is its header."
  (should (equal (octocat-markdown-tests--md "<table><td>a</td><td>b</td></table>")
                 (octocat-markdown-tests--lines
                  "┌───┬───┐"
                  "│ a │ b │"
                  "└───┴───┘")))
  ;; <th> straight under <table>, as browsers allow: it starts a row.
  (let ((out (octocat-markdown-render
              "<table>\n<th>Name</th><th>Age</th>\n<tr><td>Ann</td><td>7</td></tr>\n</table>"
              "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌──────┬─────┐"
                    "│ Name │ Age │"
                    "├──────┼─────┤"
                    "│ Ann  │ 7   │"
                    "└──────┴─────┘")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "Name" 'face)))))
  ;; Tags in any case; <thead> and <tbody> are looked through; <br>
  ;; breaks the line in its cell.
  (should (equal (octocat-markdown-tests--md
                  (concat "<TABLE><THEAD><TR><TH>h</TH></TR></THEAD>"
                          "<TBODY><TR><TD>one<BR>two</TD></TR></TBODY></TABLE>"))
                 (octocat-markdown-tests--lines
                  "┌─────┐"
                  "│ h   │"
                  "├─────┤"
                  "│ one │"
                  "│ two │"
                  "└─────┘"))))

(ert-deftest octocat-markdown-test-html-table-cells ()
  "Cells align as their align says; a bold first row of <td> is no header."
  (let ((out (octocat-markdown-render
              (concat "<table>\n"
                      "<tr><td align=\"center\"><strong>Before</strong></td>"
                      "<td align=\"center\"><strong>After</strong></td></tr>\n"
                      "<tr><td align=\"center\">ab</td><td align=\"right\">n</td></tr>\n"
                      "</table>")
              "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌────────┬───────┐"
                    "│ Before │ After │"
                    "│   ab   │     n │"
                    "└────────┴───────┘")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "Before" 'face))))))

(ert-deftest octocat-markdown-test-html-table-colspan ()
  "A table on one line, as tools write it: colspan, entities, a stray </td>."
  (let ((out (octocat-markdown-render
              (concat "<table width='100%' align='center'>"
                      "<tr><td>Tool version</td><td>1.2</td></tr>"
                      "<tr><td colspan=\"2\">&nbsp;</td></tr>"
                      "<tr><td colspan=\"2\"><b>Libraries</b></td></tr>"
                      "<tr><td>Widget</td><td><a href=\"https://example.com/w\">3.4</a></td></td></tr>"
                      "</table>")
              "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌──────────────┬─────┐"
                    "│ Tool version │ 1.2 │"
                    "├──────────────┴─────┤"
                    "│                    │"
                    "│ Libraries          │"
                    "├──────────────┬─────┤"
                    "│ Widget       │ 3.4 │"
                    "└──────────────┴─────┘")))
    ;; A spanning first row has no divider to meet; one wider than its
    ;; columns widens the last.
    (should (equal (octocat-markdown-tests--md
                    "<table><tr><th colspan=\"2\">Versions</th></tr><tr><td>a</td><td>1</td></tr></table>")
                   (octocat-markdown-tests--lines
                    "┌──────────┐"
                    "│ Versions │"
                    "├───┬──────┤"
                    "│ a │ 1    │"
                    "└───┴──────┘")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "Libraries" 'face))))
    (should (equal (octocat-markdown-tests--prop out "3.4" 'octocat-markdown-url)
                   "https://example.com/w"))))

(ert-deftest octocat-markdown-test-html-table-markdown-in-cells ()
  "A cell is markdown only after a blank line, as on GitHub; else HTML alone."
  (should (equal (octocat-markdown-tests--md "<table><tr><td>**b** `c`</td></tr></table>")
                 (octocat-markdown-tests--lines
                  "┌───────────┐"
                  "│ **b** `c` │"
                  "└───────────┘")))
  (should (memq 'octocat-markdown-code
                (ensure-list (octocat-markdown-tests--prop
                              (octocat-markdown-render "<table><tr><td><code>c</code></td></tr></table>" "")
                              "c" 'face))))
  (let ((out (octocat-markdown-render
              "<table><tr><td>\n\n- one\n- **two**\n\n</td><td>x</td></tr></table>" "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌───────┬───┐"
                    "│ • one │ x │"
                    "│ • two │   │"
                    "└───────┴───┘")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "two" 'face)))))
  ;; The cell may close on the markdown's last line.
  (let ((out (octocat-markdown-render "<table><tr><td>\n\n**b** text</td></tr></table>" "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌────────┐"
                    "│ b text │"
                    "└────────┘")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "b" 'face))))))

(ert-deftest octocat-markdown-test-html-table-surroundings ()
  "A table ends at </table>, or at the end of the text if it never closes."
  ;; The rest of its last line is HTML, as on GitHub: no markdown.
  (should (equal (octocat-markdown-tests--md
                  "<table><tr><td>a</td></tr></table> trailing **b**")
                 (octocat-markdown-tests--lines
                  "┌───┐" "│ a │" "└───┘" "trailing **b**")))
  ;; Text in a table but in no cell follows it.  (GitHub's browser puts
  ;; it before the table instead.)
  (should (equal (octocat-markdown-tests--md "<table><tr><td>a</td></tr>\n\nafter")
                 (octocat-markdown-tests--lines "┌───┐" "│ a │" "└───┘" "after")))
  ;; It may interrupt a paragraph, and sit in a list item.
  (should (equal (octocat-markdown-tests--md "para\n<table><tr><td>a</td></tr></table>")
                 (octocat-markdown-tests--lines "para" "┌───┐" "│ a │" "└───┘")))
  (should (equal (octocat-markdown-tests--md "- item\n\n  <table><tr><td>a</td></tr></table>")
                 (octocat-markdown-tests--lines "• item" "  ┌───┐" "  │ a │" "  └───┘"))))

(ert-deftest octocat-markdown-test-html-table-stacks ()
  "A table too narrow for its columns lists each row's cells by header."
  (let* ((md  (concat "<table><tr><th>Name</th><th>Role</th><th>Since</th></tr>"
                      "<tr><td>Ann</td><td>maintainer</td><td>2019</td></tr>"
                      "<tr><td>Bo</td><td>triage</td><td>2024</td></tr></table>"))
         (out (octocat-markdown-render md "" 20)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "Name: Ann" "Role: maintainer" "Since: 2019"
                    (make-string 20 ?─)
                    "Name: Bo" "Role: triage" "Since: 2024")))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "Name" 'face))))
    (should (string-prefix-p "┌" (octocat-markdown-tests--md md 80)))))

(defun octocat-markdown-tests--image-span (rendered alt)
  "Return (PLIST . LENGTH) of the image mark on ALT's link in RENDERED."
  (let ((pos (string-match (regexp-quote (format "[image: %s]" alt)) rendered)))
    (cons (get-text-property pos 'octocat-markdown-image rendered)
          (- (next-single-property-change pos 'octocat-markdown-image rendered
                                          (length rendered))
             pos))))

(ert-deftest octocat-markdown-test-html-table-images ()
  "A table of images and captions lays the images side by side.
Each image's mark spans its column, so the image can fill it."
  (let* ((u   "https://github.com/user-attachments/assets/")
         (out (octocat-markdown-render
               (concat "<table>\n  <tr>\n    <th>Before</th>\n    <th>After</th>\n  </tr>\n"
                       "  <tr>\n    <td><img width=\"400\" alt=\"old\" src=\"" u "old\" /></td>\n"
                       "    <td><img width=\"400\" alt=\"new\" src=\"" u "new\" /></td>\n"
                       "  </tr>\n</table>")
               "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    (concat "Before" (make-string 15 ?\s) "After")
                    (concat "[image: old]" (make-string 9 ?\s)
                            "[image: new]" (make-string 7 ?\s)))))
    (should (memq 'bold (ensure-list (octocat-markdown-tests--prop out "Before" 'face))))
    (should (equal (octocat-markdown-tests--image-span out "old")
                   (cons (list :url (concat u "old") :width 400 :cols 19 :fill t) 19)))
    (should (equal (octocat-markdown-tests--image-span out "new")
                   (cons (list :url (concat u "new") :width 400 :cols 19 :fill t) 19))))
  ;; Captions in bold <td>s, centred over their images.
  (should (equal (octocat-markdown-tests--md
                  (concat "<table>\n<tr><td align=\"center\"><strong>Before</strong></td>"
                          "<td align=\"center\"><strong>After</strong></td></tr>\n"
                          "<tr><td><img alt=\"old\" src=\"https://x/old.png\" /></td>"
                          "<td><img alt=\"new\" src=\"https://x/new.png\" /></td></tr>\n"
                          "</table>")
                  40)
                 (octocat-markdown-tests--lines
                  (concat (make-string 6 ?\s) "Before" (make-string 16 ?\s) "After")
                  (concat "[image: old]" (make-string 9 ?\s)
                          "[image: new]" (make-string 7 ?\s)))))
  ;; No captions, rows of images, a missing cell.
  (let ((out (octocat-markdown-render
              (concat "<table>\n<tr>\n<td>\n<img alt=\"a\" src=\"https://x/a.png\" />\n</td>\n"
                      "<td>\n<img alt=\"b\" src=\"https://x/b.png\" />\n</td>\n</tr>\n"
                      "<tr>\n<td>\n<img alt=\"c\" src=\"https://x/c.png\" />\n</td>\n</tr>\n"
                      "</table>")
              "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    (concat "[image: a]" (make-string 11 ?\s) "[image: b]" (make-string 9 ?\s))
                    (concat "[image: c]" (make-string 9 ?\s)))))
    (should (equal (cdr (octocat-markdown-tests--image-span out "c")) 19))))

(ert-deftest octocat-markdown-test-html-table-images-stack ()
  "Images too wide to sit side by side stack, each alone on its line."
  (let ((out (octocat-markdown-render
              (concat "<table><tr><th>Before</th><th>After</th></tr>"
                      "<tr><td><img alt=\"old\" src=\"https://x/old.png\"></td>"
                      "<td><img alt=\"new\" src=\"https://x/new.png\"></td></tr></table>")
              "" 20)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "Before:" "  [image: old]" "After:" "  [image: new]")))
    (should (equal (octocat-markdown-tests--image-span out "old")
                   (cons (list :url "https://x/old.png" :width nil :cols 18) 12)))))

(ert-deftest octocat-markdown-test-html-table-images-among-text ()
  "An image in a row of text stays a link in the grid, not shown in place."
  (let ((out (octocat-markdown-render
              "<table><tr><td><img alt=\"a\" src=\"https://x/a.png\"></td><td>text</td></tr></table>"
              "" 40)))
    (should (equal (substring-no-properties out)
                   (octocat-markdown-tests--lines
                    "┌────────────┬──────┐"
                    "│ [image: a] │ text │"
                    "└────────────┴──────┘")))
    (should (equal (octocat-markdown-tests--prop out "[image" 'octocat-markdown-url)
                   "https://x/a.png"))
    (should-not (text-property-not-all 0 (length out) 'octocat-markdown-image nil out))))

(ert-deftest octocat-markdown-test-wrap-prefix ()
  "List continuation lines hang under the item text."
  (let ((out (octocat-markdown-render "- item" "> ")))
    (should (equal (get-text-property 0 'wrap-prefix out) ">   "))))


;;; <details>

(defun octocat-markdown-tests--visible ()
  "Return the visible text of the current buffer, newlines shown as |.
Text replaced by a `display' string shows as that string."
  (let (out)
    (dotimes (i (- (point-max) (point-min)))
      (let ((pos (+ (point-min) i)))
        (unless (invisible-p pos)
          (let ((display (get-text-property pos 'display)))
            (push (if (stringp display) display (string (char-after pos))) out)))))
    (replace-regexp-in-string "\n" "|" (apply #'concat (nreverse out)))))

(ert-deftest octocat-markdown-test-details-starts-collapsed ()
  "The summary shows and the body is hidden until RET toggles it."
  (with-temp-buffer
    (insert (octocat-markdown-render
             "<details>\n<summary>Why <b>so</b></summary>\n\nfirst\n\nsecond\n</details>\nafter" ""))
    (setq buffer-invisibility-spec '((other . t)))
    (octocat-markdown--ensure-invisibility)
    (should (equal (octocat-markdown-tests--visible) "▸ Why so|after|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    ;; The blank row between the paragraphs is a single space.
    (should (equal (octocat-markdown-tests--visible) "▾ Why so|first| |second|after|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    (should (equal (octocat-markdown-tests--visible) "▸ Why so|after|"))))

(ert-deftest octocat-markdown-test-details-open-and-nested ()
  "An `open' <details> starts expanded; a nested one shows as a title."
  (with-temp-buffer
    (insert (octocat-markdown-render
             "<details open><summary>A</summary>\nx\n<details><summary>B</summary>\ny\n</details>\n</details>"
             ""))
    (setq buffer-invisibility-spec '((other . t)))
    (octocat-markdown--ensure-invisibility)
    (should (equal (octocat-markdown-tests--visible) "▾ A|x|B|y|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    (should (equal (octocat-markdown-tests--visible) "▸ A|"))))

(ert-deftest octocat-markdown-test-details-reset ()
  "Each <details> goes back to how it was first rendered, open or closed."
  (with-temp-buffer
    (insert (octocat-markdown-render
             "<details open><summary>A</summary>\nx\n</details>\n\n<details><summary>B</summary>\ny\n</details>"
             ""))
    (setq buffer-invisibility-spec '((other . t)))
    (octocat-markdown--ensure-invisibility)
    (should (equal (octocat-markdown-tests--visible) "▾ A|x|▸ B|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    (search-forward "▸ B")
    (goto-char (match-beginning 0))
    (octocat-markdown-follow)
    (should (equal (octocat-markdown-tests--visible) "▸ A|▾ B|y|"))
    (octocat-markdown-reset-details)
    (should (equal (octocat-markdown-tests--visible) "▾ A|x|▸ B|"))))

(ert-deftest octocat-markdown-test-details-without-summary ()
  "A <details> without a summary is titled \"Details\"."
  (should (string-prefix-p "▸ Details\n"
                           (octocat-markdown-tests--md "<details>\nbody\n</details>"))))


;;; Font-lock in the edit buffer

(ert-deftest octocat-markdown-test-edit-mode-font-lock ()
  "The edit buffer highlights markdown source with the renderer's faces."
  (with-temp-buffer
    (insert "# Title\n\n**bold** `code` @bob #12\n\n```\n**not bold**\n```\n")
    (octocat-edit-mode)
    (font-lock-ensure)
    (cl-flet ((face-at (needle)
                (ensure-list (get-text-property
                              (+ (point-min) (string-match (regexp-quote needle) (buffer-string)))
                              'face))))
      (should (memq 'octocat-markdown-heading (face-at "Title")))
      (should (memq 'bold (face-at "bold**")))
      (should (memq 'octocat-markdown-code (face-at "code")))
      (should (memq 'octocat-markdown-mention (face-at "@bob")))
      (should (memq 'octocat-markdown-mention (face-at "#12")))
      (should (memq 'octocat-markdown-code-block (face-at "not bold")))
      (should-not (memq 'bold (face-at "not bold"))))))

(ert-deftest octocat-markdown-test-fill-prose ()
  "Paragraphs and list items wider than WIDTH break at spaces, hung."
  (should (equal (octocat-markdown-tests--md "aaa bbb ccc ddd" 8)
                 "aaa bbb\nccc ddd\n"))
  (should (equal (octocat-markdown-tests--md "- aaa bbb ccc" 8)
                 "• aaa\n  bbb\n  ccc\n"))
  (should (equal (octocat-markdown-tests--md "aaa bbb ccc ddd") "aaa bbb ccc ddd\n")))

(ert-deftest octocat-markdown-test-fill-heading ()
  "A heading drawn wider than the default breaks to fit WIDTH as drawn."
  ;; As a graphic display draws h1, 1.5 times as wide as the default.
  (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 10))
            ((symbol-function 'string-pixel-width)
             (lambda (s &rest _)
               (* (string-width s)
                  (if (get-text-property 0 'octocat-markdown-heading s) 15 10)))))
    (should (equal (octocat-markdown-tests--md "# aaa bbb ccc\n\naaa bbb ccc" 12)
                   "aaa bbb\nccc\naaa bbb ccc\n"))))

(ert-deftest octocat-markdown-test-fill-code ()
  "A code line wider than WIDTH is cut, its continuations marked and padded."
  (let* ((out (octocat-markdown-render
               (concat "```\n" (make-string 20 ?x) "\n```") "" 10))
         (lines (split-string out "\n" t)))
    (should (cl-every (lambda (l) (= (string-width l) 10)) lines))
    (should (string-prefix-p "↪ " (cadr lines)))
    (should (= (cl-count ?x out) 20))
    (should (memq 'octocat-markdown-code-block
                  (ensure-list (get-text-property (- (length out) 2) 'face out))))))

(provide 'octocat-markdown-tests)
;;; octocat-markdown-tests.el ends here
