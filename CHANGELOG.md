# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* Fix relative links in a repository's README opening a local file, in an outside program: they open the linked file, at the branch shown, in octocat's file viewer
* `RET` on an image in a README, given by a relative path, shows it in place, as it does for images uploaded to GitHub
* The file viewer renders Markdown files, as GitHub does, with their relative links and images working as in a README; `C-c C-v` shows the source
* The tree browser and the file viewer share a top line, `owner/repo[main ▾]:/dir/file`: the branch picker, then the path, whose directories open the tree browser at them; under it, the last commit, then a rule
* The commits page has the same top line, with how many commits there are; a directory of the path shows its own history
* `C-c C-l` in the file viewer opens the file's history on the commits page, as `[N commits]` does, which replaces the separate file log
* `RET` on an image shown in a README opens its file in the file viewer, which shows image files; `C-c C-o` on a link or image opens it in the browser
* Long branch names are cut in the middle in branch pickers, keeping both ends; hovering shows the name in full (`octocat-ref-max-width`)
* Each branch of a file opens in a buffer of its own, named after both; `C-c C-b`, or `RET` on the picker, opens the file at another branch
* While an image loads, a spinner turns before its link, and the mode line shows `:loading`
* Image links have a face of their own, so they stand apart from other links
* Fix a blue line drawn across the middle of an image shown in place
* The commit page reads as `git show --format=fuller`: its author and committer with both dates, its parents and whether the default branch holds it, then its message; the top line, like the tree browser's, shows the full SHA and `[Browse files]`
* The commits page's mode is `octocat-commit-list-mode`, named as the PR and issue lists are; `octocat-commits-mode` and its hook and map remain as obsolete aliases
* Commit lists and last-commit lines show when a commit was committed, as "committed 2 days ago", not when it was written
* The SHA of the last commit atop the repository's files is a `TAB` stop
* `g`/`gr` also resets the page's view: images shown in place are links again, and `<details>`, folds and expanded entries are back as first drawn; an image shown again comes from memory, without fetching it again

## [0.1.0] - 2026-10-23
* First release, and the first on MELPA Stable
* Fix the compare page failing to render its files with a wrong-number-of-arguments error
* Test on Emacs 29.1, the oldest release octocat supports, as well as 30.2 and 31.1
* `C-c C-j` (`octocat-jump`) now searches the current repository's PRs, issues, commits and files; `C-u C-c C-j` jumps to another repository, or to a user with `@`, as `C-c C-j` did before. On a page with no repository, `C-c C-j` jumps to another repository or user
* Drop `C-c C-s`: plain `C-c C-j` searches the repository now
* Repository search (`C-c C-j`) on the PR, issue and actions lists now searches the list's repository, also when there is no local clone of it
