# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* `C-c C-j` (`octocat-jump`) now searches the current repository's PRs, issues, commits and files; `C-u C-c C-j` jumps to another repository, or to a user with `@`, as `C-c C-j` did before. On a page with no repository, `C-c C-j` jumps to another repository or user
* Drop `C-c C-s`: plain `C-c C-j` searches the repository now
* Repository search (`C-c C-j`) on the PR, issue and actions lists now searches the list's repository, also when there is no local clone of it
