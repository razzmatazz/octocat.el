# Plan: Front Page Major Mode — PR Listing

## Goal

Implement `octocat-mode`, the main entry-point buffer for `octocat.el`. When
invoked, it opens a dedicated Emacs buffer scoped to the current Git repository
and displays a live list of open Pull Requests, rendered as collapsible
`magit-section` entries.

---

## User-Facing Behaviour

- `M-x octocat` opens (or switches to) the `*octocat: <repo>*` buffer.
- The buffer shows a **Pull Requests** section listing all open PRs for the
  detected GitHub repo.
- Each PR entry shows: number, title, author, and CI status at a glance.
- Pressing `RET` on a PR opens a detail view (out of scope for this plan).
- `g` refreshes the list by re-running `gh`.
- `q` buries the buffer.

---

## Implementation Steps

### 1. Package scaffolding

- [ ] Create `octocat.el` as the main entry file.
- [ ] Declare `Package-Requires` header: `emacs "27.1"`, `magit-section`,
  `transient`.
- [ ] Add `(require ...)` statements for `magit-section` and `cl-lib`.

### 2. Repo detection

- [ ] Write helper `octocat--current-repo` that:
  - Reads the `origin` remote URL via `git remote get-url origin`.
  - Parses both SSH (`git@github.com:owner/repo.git`) and HTTPS
    (`https://github.com/owner/repo`) forms.
  - Returns a `"owner/repo"` string, or signals an error if not a GitHub repo.

### 3. `gh` integration

- [ ] Write `octocat--list-prs (repo)` that:
  - Calls `gh pr list --repo REPO --json number,title,author,statusCheckRollup`
    asynchronously via `make-process`.
  - Parses the JSON response with `json-parse-string` (built-in, Emacs 27+).
  - Returns a list of alists, one per PR.

### 4. Major mode definition

- [ ] Define `octocat-mode` with `define-derived-mode` inheriting from
  `magit-section-mode` (gives section folding for free).
- [ ] Set `buffer-read-only t`, `truncate-lines t`.
- [ ] Bind keys in `octocat-mode-map`:
  - `g` → `octocat-refresh`
  - `q` → `quit-window`
  - `RET` → `octocat-visit-pr` (stub for now)

### 5. Buffer rendering

- [ ] Write `octocat--render (prs)` that uses `magit-insert-section` to build:
  ```
  Pull Requests (owner/repo)
  ├── #42  Fix login bug               @alice   ✓
  ├── #41  Add dark mode               @bob     ✗
  └── #38  Refactor auth layer         @carol   ●
  ```
- [ ] Use `magit-section-insert-heading` for the top-level "Pull Requests" heading.
- [ ] Each PR is a child `magit-section` with a `pr` type and the PR alist as
  its `value` (enables `RET` dispatch later).
- [ ] Apply faces:
  - PR number: `magit-hash`
  - Title: default
  - Author: `magit-log-author`
  - CI pass/fail/pending: green / red / yellow via custom faces.

### 6. Entry point

- [ ] Write `octocat` interactive command that:
  - Detects repo via `octocat--current-repo`.
  - Gets-or-creates buffer `*octocat: owner/repo*`.
  - Switches to buffer, sets mode, triggers `octocat-refresh`.

### 7. Async refresh

- [ ] `octocat-refresh` fetches PRs asynchronously, then calls
  `octocat--render` in the process sentinel once data arrives.
- [ ] Show a `"Loading…"` placeholder while the `gh` process runs.
- [ ] Handle `gh` errors (not authenticated, no network) with a user-friendly
  `message`.

---

## File Layout

```
octocat.el              ← main package file (all of the above)
plans/              ← planning documents
README.md
LICENSE
```

---

## Out of Scope (this plan)

- PR detail / diff view
- Creating / merging PRs
- Issues, Actions, or other GitHub resources
- `transient` command dispatcher (separate plan)
