# octocat.el

A GitHub client for Emacs, powered by the [`gh`](https://cli.github.com/) command-line tool.

## Overview

`octocat.el` integrates GitHub workflows directly into Emacs by leveraging the official GitHub CLI (`gh`). It provides a convenient Emacs interface for common GitHub operations without leaving your editor.

## Requirements

- [Emacs](https://www.gnu.org/software/emacs/) 27.1 or later
- [GitHub CLI (`gh`)](https://cli.github.com/) — must be installed and authenticated

### Installing `gh`

```bash
# macOS
brew install gh

# Linux (Debian/Ubuntu)
sudo apt install gh

# Windows
winget install --id GitHub.cli
```

Then authenticate:

```bash
gh auth login
```

## Installation

Clone the repository and add it to your Emacs load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/octocat.el")
(require 'octocat)
```

## Usage

_Usage instructions and key bindings will be documented here as the project develops._

## License

This project is licensed under the [MIT License](LICENSE).
