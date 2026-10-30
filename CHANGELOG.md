# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* RET shows a README's images from other sites, such as badges, via GitHub's proxy
* A diff's comments switch on and off from a Comments | Diff only pill, and roll in and out
* Replies to a review comment in a PR diff sit in its box, indented off bubbles on its edge
* Posting a comment keeps the buttons under the timeline, its spinner on the comment only
* The Marked bar on a PR list can request or withdraw reviews on all the marked PRs
* The Marked bar can assign or unassign people on all the marked PRs or issues
* Marking PRs or issues swaps the filters for a bar that labels them all at once
* A PR list with a closed PR that has no commits no longer fails to load
* Mark PRs and issues in their lists as in dired: `m`, `u`, `U` (unmark all)
* Long runs of commits or events in a timeline fold behind `▸ N more`; RET expands them
* Downloading a run's artifact uploaded as a lone file, not a zip, no longer fails
* RET on a run's or job's artifact previews it, asking first if binary; `d` downloads it
* A run's annotations stay on screen while its jobs change, and refresh as they finish
* Run and job annotations wrap at the page width and keep their jobs' order
* Rendered markdown always leaves a blank line after a code block
* READMEs and markdown files join a paragraph's lines, as GitHub shows them
* After a push, the repo page keeps its files and README until the new ones load
* Until a new commit's are fetched, the last commits stored for an older one show
* The file page shows the blame; a Preview | Code | Blame switch, or `C-c C-v`, picks the view
* The commit page shows the commit as a patch: a Diff | Patch switch on its top line, or `C-c C-v`
* The tree and repo page show each entry's last commit and its age, as GitHub does
* The mode line's spinner comes before `:loading`, so a narrow one still shows it
* Images show at their own size, not enlarged and blurred by `image-scaling-factor`
* Markdown bold, italic and strikethrough can span the lines of a paragraph
* A list whose last item has indented lines keeps the blank line after it
* The file page drops its `[Browse tree]` button: the directories of its path open the tree
* PRs in a stack (`gh stack`) show their place in it, `≡ 2/3`; a PR page lists the stack
* A job's steps show their log again, now that GitHub labels no line with its step
* On tree, file and commit pages, the repo name opens the repo page
* Commit lists show a commit's age without "committed", as the repo page does
* The commit page cuts its SHA with … when the top line would wrap; ElDoc shows it whole
* The compare page counts its commits and changed files on its top line
* The repo page's branch picker sits on the top line, after the repo name
* The commit list and dashboard leave a blank line under their top line, as other pages
* Large markdown headings wrap within the page's width instead of running past it
* Files at the repository root, like a Dockerfile or .gitignore, are highlighted as in a directory
* The tree, file and commit-list pages set the branch picker apart from the repo name, as the repo page
* A file page's last-commit line is underlined under its subject too
* Org files, such as a README.org, are rendered like markdown ones
* The last-commit line above a repo's files drops its author and "committed", as GitHub's
* `octocat-doctor` gives the speed over the time requests ran, not the whole hour
* `C-c C-o` on a row of a list opens that PR, issue, commit, run, job or check
* `M-x octocat-copy-url` copies the URL of the thing at point, or `C-u` its short ref
* `C-c C-o` on a link, `#123` or commit in markdown opens it, on every page
* Pages opened in the browser are on the host `GH_HOST` names, as for `gh`
* `C-c C-o` on a PR or issue opens it in your `browse-url` browser, not via `gh`
* Markdown keeps the blank line after a quote or `> [!NOTE]` alert, as GitHub does
* An image in a diff shows inline when RET unfolds it, fetched only then
* A diff tells a binary or empty file apart from one too large to show
* An unfolded file's diff ends in a line across the page, setting it apart from the next file
* Diffs mark the words changed within a line, as `diff-refine-hunk` does
* A diff's file names are bold; only the A, D or R before one is coloured
* Diffs highlight their code as its major mode would, under the added and removed faces
* A `*`, `~` or `(` in an HTML link's href no longer breaks the markdown around it
* Markdown decodes every HTML entity, like `&ensp;` and `&mdash;`, and hex `&#x…;` ones
* HTML in markdown is read by libxml2: nested and unclosed tags show as on GitHub
* An HTML block, like a README's `<p align="center">` of linked images, no longer shows as code
* HTML `align="center"` and `<center>` centre their text, and `<li>` items show bullets
* Merges, comments, reviews and other changes sent to GitHub show in every mode line
* `#123` refs and branch links opened in another window no longer open in the same one
* Markdown keeps the blank line written after a list, as GitHub shows it
* Pages on screen refresh on their own every minute, and runs in progress every 10 s
* Refreshes slow down while you're away or on battery, and stop on low battery
* On low battery, folds open at once and spinners stand still, saving power
* `M-x octocat-doctor` reports, to paste into a bug report, on the code, store, refreshes and requests
* `C-c C-l` reacts to the PR, issue or comment at point, or takes a reaction back
* Loading octocat no longer changes `exec-path`; `octocat-gh-program` names `gh`
* github.com links elsewhere in Emacs open in octocat only with `octocat-github-links-mode`
* A commit's message starts at the left edge, so it copies without an indent
* The commit and PR diff pages open with the review comments in the diff shown
* A PR's Merge box heading is underlined across the page, setting it apart
* Section headings and the last-commit line are underlined across the page, not ruled off
* Issues, pull requests, comments and reviews show their reactions, such as 👍 3
* New and edited comments and descriptions show at once, with a spinner until saved
* Expanding a long comment no longer scrolls the window; RET still folds it back
* octocat passes melpazoid, the checks of MELPA's review, which `make ci` now runs
* A workflow's runs are listed as on the run list; `octocat-workflow-runs-limit` is gone
* `octocat-actions-runs-page-size` is now `octocat-run-list-page-size`
* Run, job and workflow pages open with a header like a PR's, linking up to the workflow
* `M-x octocat-run-list` and `M-x octocat-workflow-list` open the Actions pages
* `C-c C-j` finds a repository's workflows, by name or file
* Runs are laid out as on GitHub: status and title first, then workflow, branch, date
* A blank line sets the last commit apart in the tree browser and file viewer
* Reference-style images, `![alt][ref]` and `![ref]`, render as images
* Linked images such as README badges, `[![CI](badge.svg)](url)`, render as images
* `C-c C-o` on a repository on its default branch opens the repository's page
* Long lines in diffs, logs and files are cut, with a button to show the rest
* The file viewer asks before showing a large file, and does not show binary files
* HTML tables in Markdown are drawn as tables, as on GitHub
* A table of images, such as before-and-after screenshots, shows them side by side
* Fix wrapped lines in Markdown quotes losing their `│` bars
* Resting point on a link in Markdown shows where it goes in the echo area
* Fix `RET` on a link whose text holds `#123`, a SHA or an `@mention` opening that instead
* Commits are laid out as on GitHub: subject, author and date first, the SHA last
* Fix relative links in a README opening a local file: they open in the file viewer
* `RET` on an image given by a relative path in a README shows it in place
* The file viewer renders Markdown files as GitHub does; `C-c C-v` shows the source
* The tree browser and file viewer share a top line: branch picker, path, last commit
* The commits page has the same top line, and shows how many commits there are
* `C-c C-l` in the file viewer opens the file's history, replacing the separate file log
* `RET` on an image in a README opens it in the file viewer; `C-c C-o` opens it in the browser
* Long branch names are cut in the middle in branch pickers (`octocat-ref-max-width`)
* Each branch of a file opens in its own buffer; `C-c C-b` switches to another branch
* A spinner shows while an image loads
* Image links have a face of their own
* Fix a blue line drawn across images shown in place
* The commit page reads like `git show --format=fuller`, with author, committer and parents
* The commits page's mode is now `octocat-commit-list-mode`; the old names still work
* Commit lists show when a commit was committed, not when it was written
* The SHA of the last commit above a repository's files is a `TAB` stop
* `g`/`gr` also resets the page's view: images, folds and `<details>` as first drawn

## [0.1.0] - 2026-10-23
* First release, and the first on MELPA Stable
* Fix the compare page failing to render its files with a wrong-number-of-arguments error
* Test on Emacs 29.1, the oldest release octocat supports, as well as 30.2 and 31.1
* `C-c C-j` searches the current repository; `C-u C-c C-j` jumps to another repository or user
* Drop `C-c C-s`: plain `C-c C-j` searches the repository now
* `C-c C-j` on the PR, issue and actions lists searches their repository, even without a clone
