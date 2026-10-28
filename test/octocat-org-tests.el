;;; octocat-org-tests.el --- ERT tests for the org to markdown converter  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Tests for octocat-org.el.  Run via:
;;   eldev test test/octocat-org-tests.el

;;; Code:

(require 'ert)
(require 'octocat-org)

(defun octocat-org-tests--md (&rest lines)
  "Return the org LINES, joined by newlines, as markdown."
  (octocat-org-to-markdown (string-join lines "\n")))

(defun octocat-org-tests--lines (&rest lines)
  "Join LINES with newlines, to write markdown out line by line."
  (string-join lines "\n"))

(ert-deftest octocat-org-test-headings ()
  "The title and headings become markdown headings, their tags dropped."
  (should (equal (octocat-org-tests--md "#+TITLE: vui.el" "#+AUTHOR: me"
                                        "* Features" "** TODO Later   :wip:docs:")
                 (octocat-org-tests--lines "# vui.el" "# Features" "## TODO Later"))))

(ert-deftest octocat-org-test-emphasis ()
  "Emphasis and verbatim become markdown's, but not within words or paths."
  (should (equal (octocat-org-tests--md
                  "*bold*, /italic/, +gone+ and _under_; =code= and ~code~.")
                 "**bold**, *italic*, ~~gone~~ and <u>under</u>; `code` and `code`."))
  (should (equal (octocat-org-tests--md "*not /italic/ inside* bold")
                 "**not *italic* inside** bold"))
  (should (equal (octocat-org-tests--md "a*b*c, /usr/bin/emacs and 2 * 3 * 4")
                 "a*b*c, /usr/bin/emacs and 2 * 3 * 4"))
  (should (equal (octocat-org-tests--md "=*not bold*= and ~a`b~")
                 "`*not bold*` and `` a`b ``")))

(ert-deftest octocat-org-test-links ()
  "Links become markdown's; file: links stay relative, images show."
  (should (equal (octocat-org-tests--md
                  "[[https://x.org][the /site/]], [[file:docs/a.org][guide]], [[#id][below]]")
                 "[the *site*](https://x.org), [guide](docs/a.org), [below](#id)"))
  (should (equal (octocat-org-tests--md "[[https://x.org]] and [[file:img/logo.png]]")
                 "[https://x.org](https://x.org) and ![](img/logo.png)"))
  (should (equal (octocat-org-tests--md "[[https://x.org][file:img/badge.svg]]")
                 "[![](img/badge.svg)](https://x.org)")))

(ert-deftest octocat-org-test-blocks ()
  "Src and example blocks are fenced, a quote quoted, comments dropped."
  (should (equal (octocat-org-tests--md
                  "#+BEGIN_SRC elisp :tangle no" "(setq a 1)" ",* not a heading" "#+END_SRC"
                  "#+begin_example" "plain" "#+end_example"
                  "#+begin_quote" "Said *this*." "#+end_quote"
                  "#+begin_comment" "hidden" "#+end_comment"
                  "# a comment")
                 (octocat-org-tests--lines
                  "```elisp" "(setq a 1)" "* not a heading" "```"
                  "```" "plain" "```"
                  "> Said **this**."))))

(ert-deftest octocat-org-test-html ()
  "An HTML block passes through as is, set apart by blank lines."
  (dolist (begin '(("#+begin_html" . "#+end_html")
                   ("#+begin_export html" . "#+end_export")))
    (should (equal (octocat-org-tests--md (car begin) "<p align=\"center\">*x*</p>" (cdr begin))
                   (octocat-org-tests--lines "" "<p align=\"center\">*x*</p>" ""))))
  (should (equal (octocat-org-tests--md "#+begin_export latex" "\\LaTeX" "#+end_export") "")))

(ert-deftest octocat-org-test-table ()
  "A table's first row is its header, its rules dropped."
  (should (equal (octocat-org-tests--md "| Name | /What/ |" "|------+--------|"
                                        "| a    | one    |" "|------+--------|"
                                        "| b    | two    |" "#+TBLFM: $1=x")
                 (octocat-org-tests--lines "| Name | *What* |" "|---|---|"
                                           "| a | one |" "| b | two |"))))

(ert-deftest octocat-org-test-lists ()
  "Lists keep their nesting; checkboxes and descriptions become markdown's."
  (should (equal (octocat-org-tests--md "- [X] done" "  + [ ] todo" "1) first"
                                        "2. second" "- term :: what it /is/")
                 (octocat-org-tests--lines "- [x] done" "  - [ ] todo" "1. first"
                                           "2. second" "- **term**: what it *is*"))))

(ert-deftest octocat-org-test-drawers-and-fixed-width ()
  "Drawers are dropped; fixed-width lines are fenced; dashes make a rule."
  (should (equal (octocat-org-tests--md "* A" ":PROPERTIES:" ":CUSTOM_ID: a" ":END:"
                                        ": $ make" ":" ": done" "-----")
                 (octocat-org-tests--lines "# A" "```" "$ make" "" "done" "```" "---"))))

(provide 'octocat-org-tests)
;;; octocat-org-tests.el ends here
