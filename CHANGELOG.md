# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* Fix relative links in a repository's README opening a local file, in an outside program: they open the linked file, at the branch shown, in octocat's file viewer
* `RET` on an image in a README, given by a relative path, shows it in place, as it does for images uploaded to GitHub

## [0.1.0] - 2026-10-23
* First release, and the first on MELPA Stable
* Fix the compare page failing to render its files with a wrong-number-of-arguments error
* Test on Emacs 29.1, the oldest release octocat supports, as well as 30.2 and 31.1
* `C-c C-j` (`octocat-jump`) now searches the current repository's PRs, issues, commits and files; `C-u C-c C-j` jumps to another repository, or to a user with `@`, as `C-c C-j` did before. On a page with no repository, `C-c C-j` jumps to another repository or user
* Drop `C-c C-s`: plain `C-c C-j` searches the repository now
* Repository search (`C-c C-j`) on the PR, issue and actions lists now searches the list's repository, also when there is no local clone of it
