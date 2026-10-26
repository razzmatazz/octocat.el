# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
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
