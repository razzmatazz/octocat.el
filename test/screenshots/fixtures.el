;;; fixtures.el --- Made-up GitHub data for screenshots.el  -*- lexical-binding: t; -*-
;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; What `gh' answers each call the pages of docs/screenshots/README.md
;; make, in GitHub's own JSON shapes.  All of it is invented: the acme
;; organization, its rocket repository, people and hashes.  Times are
;; seconds before `octocat-screenshots-now', so pages read the same
;; whenever they are shot.
;;
;; Each fixture is (NAME MATCH OUTPUT): it answers the `gh' call NAME,
;; as `octocat--run-gh' names it, whose arguments contain every string
;; of MATCH; the first that does wins.  OUTPUT is what `gh' prints: a
;; string, or a value `json-serialize' prints.
;;
;; To show a page with other data, change its fixtures here; to add a
;; page, add the calls `make screenshots' says it lacks.

;;; Code:

(require 'cl-lib)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

(defvar octocat-screenshots-now (encode-time (iso8601-parse "2026-10-23T12:00:00Z"))
  "The time the screenshots are taken at.")

(defconst octocat-screenshots--m 60)
(defconst octocat-screenshots--h 3600)
(defconst octocat-screenshots--d 86400)

(defun octocat-screenshots--ago (seconds)
  "Return the timestamp SECONDS before `octocat-screenshots-now', as GitHub's."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (time-subtract octocat-screenshots-now seconds) t))

(defun octocat-screenshots--sha (seed)
  "Return a made-up commit SHA, the same for the same SEED."
  (secure-hash 'sha1 seed))

(defun octocat-screenshots--base64 (text)
  "Return TEXT base64-encoded, as GitHub sends a blob."
  (base64-encode-string (encode-coding-string text 'utf-8)))

(defun octocat-screenshots--user (login &optional name)
  "Return user LOGIN, NAME optional, as GitHub's REST API gives one."
  `(:login ,login :id ,(abs (sxhash-equal login)) :type "User"
    :avatar_url ,(format "https://avatars.githubusercontent.com/u/%s" login)
    :html_url ,(format "https://github.com/%s" login)
    ,@(and name (list :name name))))

(defun octocat-screenshots--label (name color)
  "Return label NAME of COLOR, a hex string."
  `(:name ,name :color ,color :description ""))

(defconst octocat-screenshots--label-colors
  (mapcar (lambda (l) (cons (car l) (octocat-screenshots--label (car l) (cdr l))))
          '(("bug" . "d73a4a") ("enhancement" . "a2eeef") ("docs" . "0075ca")
            ("good first issue" . "7057ff") ("performance" . "fbca04")
            ("needs triage" . "ededed")))
  "The labels of acme/rocket, by name.")

(defun octocat-screenshots--labels (&rest names)
  "Return the labels NAMES, as a GraphQL connection."
  `(:nodes ,(vconcat (mapcar (lambda (n) (assoc-default n octocat-screenshots--label-colors))
                             names))))

;;;; acme/rocket

(defconst octocat-screenshots--head (octocat-screenshots--sha "head")
  "The commit at the tip of main.")

(defconst octocat-screenshots--commit "3f9c2a1e8b7d6c5f4a3b2c1d0e9f8a7b6c5d4e3f"
  "The commit whose page is shot.")

(defconst octocat-screenshots--pr-head (octocat-screenshots--sha "pr-128-head")
  "The head commit of pull request #128.")

(defconst octocat-screenshots--commits
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d))
    `((,octocat-screenshots--head "Render footnotes in Markdown pages (#131)" "mchen" "Mei Chen" ,(* 2 h))
      (,octocat-screenshots--commit "Cache parsed templates between builds (#128)" "srivera" "Sam Rivera" ,(* 6 h))
      (,(octocat-screenshots--sha "c3") "Bump toml from 0.8.12 to 0.8.19" nil "dependabot[bot]" ,(* 1 d))
      (,(octocat-screenshots--sha "c4") "Watch mode: rebuild only the pages that changed" "aokafor" "Ada Okafor" ,(* 2 d))
      (,(octocat-screenshots--sha "c5") "Fix broken links to pages with spaces in their names" "jlindqvist" "Johan Lindqvist" ,(* 3 d))
      (,(octocat-screenshots--sha "c6") "Document the [build] section of rocket.toml" "pnair" "Priya Nair" ,(* 4 d))
      (,(octocat-screenshots--sha "c7") "Serve the site over HTTP/2 in `rocket serve`" "mchen" "Mei Chen" ,(* 6 d))
      (,(octocat-screenshots--sha "c8") "Release 0.9.0" "srivera" "Sam Rivera" ,(* 8 d))
      (,(octocat-screenshots--sha "c9") "Sort the sitemap by date, newest first" "aokafor" "Ada Okafor" ,(* 9 d))
      (,(octocat-screenshots--sha "c10") "Add a --drafts flag to `rocket build`" "srivera" "Sam Rivera" ,(* 11 d))))
  "The history of main, newest first: (SHA HEADLINE LOGIN NAME AGO).")

(defun octocat-screenshots--history-node (commit)
  "Return COMMIT, of `octocat-screenshots--commits', as a GraphQL history node."
  (pcase-let ((`(,sha ,headline ,login ,name ,ago) commit))
    `(:oid ,sha :messageHeadline ,headline :authoredDate ,(octocat-screenshots--ago ago)
      :author (:name ,name :email ,(format "%s@example.com" (or login "bot"))
               :user ,(if login `(:login ,login) :null)))))

(defun octocat-screenshots--tree-entry (path type &optional size)
  "Return a tree entry PATH of TYPE, \"blob\" or \"tree\", of SIZE bytes."
  `(:path ,path :mode ,(if (equal type "tree") "040000" "100644") :type ,type
    :sha ,(octocat-screenshots--sha path) :size ,(or size 0)
    :url ,(format "https://api.github.com/repos/acme/rocket/git/%ss/%s"
                  type (octocat-screenshots--sha path))))

(defconst octocat-screenshots--root
  `[,(octocat-screenshots--tree-entry ".github" "tree")
    ,(octocat-screenshots--tree-entry "docs" "tree")
    ,(octocat-screenshots--tree-entry "examples" "tree")
    ,(octocat-screenshots--tree-entry "src" "tree")
    ,(octocat-screenshots--tree-entry ".gitignore" "blob" 41)
    ,(octocat-screenshots--tree-entry "CONTRIBUTING.md" "blob" 1204)
    ,(octocat-screenshots--tree-entry "Cargo.lock" "blob" 48211)
    ,(octocat-screenshots--tree-entry "Cargo.toml" "blob" 612)
    ,(octocat-screenshots--tree-entry "LICENSE" "blob" 1069)
    ,(octocat-screenshots--tree-entry "README.md" "blob" 1530)]
  "The entries of the repository's root.")

(defconst octocat-screenshots--readme
  "# rocket

A small, fast static site generator.  Write pages in Markdown, lay them
out with templates, and `rocket build` turns them into a site.

## Install

```sh
cargo install rocket-ssg
```

## Usage

| Command        | What it does                                |
|----------------|---------------------------------------------|
| `rocket new`   | Start a site in a new directory             |
| `rocket build` | Build the site into `public/`               |
| `rocket serve` | Serve the site, rebuilding on every change  |

Pages live in `content/`, templates in `templates/`.  See the
[docs](docs/) for the `rocket.toml` settings.

## License

MIT
"
  "The README of acme/rocket.")

(defconst octocat-screenshots--guide
  "# Writing pages

A page is a Markdown file in `content/`, with a TOML header between
`+++` lines that names its title and template.

![A page and the site it builds](images/page.png)

`rocket serve` rebuilds a page as soon as you save it.  The header's
settings are in [the configuration](configuration.md).
"
  "The docs/guide.md of acme/rocket.")

(defconst octocat-screenshots--src
  `[,(octocat-screenshots--tree-entry "src/build.rs" "blob" 8120)
    ,(octocat-screenshots--tree-entry "src/cache.rs" "blob" 2304)
    ,(octocat-screenshots--tree-entry "src/main.rs" "blob" 1802)
    ,(octocat-screenshots--tree-entry "src/markdown.rs" "blob" 6410)
    ,(octocat-screenshots--tree-entry "src/serve.rs" "blob" 3022)
    ,(octocat-screenshots--tree-entry "src/template.rs" "blob" 5530)]
  "The entries of src/.")

(defun octocat-screenshots--rollup (state &optional success failure pending)
  "Return a commit's check rollup in STATE, of SUCCESS FAILURE PENDING runs."
  `(:nodes [(:commit (:statusCheckRollup
                      (:state ,state
                       :contexts (:checkRunCountsByState
                                  [(:state "SUCCESS" :count ,(or success 0))
                                   (:state "FAILURE" :count ,(or failure 0))
                                   (:state "IN_PROGRESS" :count ,(or pending 0))]
                                  :statusContextCountsByState []))))]))

(defun octocat-screenshots--pr-node (number title author ago &rest fields)
  "Return pull request NUMBER as the list's GraphQL query gives it.
TITLE, AUTHOR and AGO are its own; FIELDS, a plist, override the rest."
  (let ((node (copy-tree `(:number ,number :title ,title :state "OPEN" :isDraft :false
                :reviewDecision "REVIEW_REQUIRED" :createdAt ,(octocat-screenshots--ago ago)
                :author (:login ,author) :labels (:nodes []) :comments (:totalCount 0)
                :commits ,(octocat-screenshots--rollup "SUCCESS" 4)))))
    (while fields
      (setq node (plist-put node (pop fields) (pop fields))))
    node))

(defconst octocat-screenshots--prs
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d))
    (list
     (octocat-screenshots--pr-node 133 "Incremental builds: skip pages whose inputs are unchanged" "srivera" (* 3 h)
                                   :labels (octocat-screenshots--labels "performance" "enhancement")
                                   :comments '(:totalCount 4)
                                   :commits (octocat-screenshots--rollup "PENDING" 2 0 2))
     (octocat-screenshots--pr-node 132 "Add RSS and Atom feeds for each section" "pnair" (* 9 h)
                                   :reviewDecision "APPROVED" :comments '(:totalCount 2)
                                   :labels (octocat-screenshots--labels "enhancement"))
     (octocat-screenshots--pr-node 130 "Fix: `rocket serve` drops changes saved twice in a second" "jlindqvist" (* 1 d)
                                   :labels (octocat-screenshots--labels "bug")
                                   :commits (octocat-screenshots--rollup "FAILURE" 3 1)
                                   :reviewDecision "CHANGES_REQUESTED" :comments '(:totalCount 6))
     (octocat-screenshots--pr-node 128 "Cache parsed templates between builds" "srivera" (* 2 d)
                                   :labels (octocat-screenshots--labels "performance")
                                   :reviewDecision "APPROVED" :comments '(:totalCount 3))
     (octocat-screenshots--pr-node 125 "Docs: a guide to writing your first theme" "aokafor" (* 5 d)
                                   :isDraft t :reviewDecision :null
                                   :labels (octocat-screenshots--labels "docs"))
     (octocat-screenshots--pr-node 119 "Syntax-highlight code blocks at build time" "mchen" (* 12 d)
                                   :comments '(:totalCount 11)
                                   :commits (octocat-screenshots--rollup "SUCCESS" 4))))
  "The open pull requests of acme/rocket, newest first.")

(defun octocat-screenshots--issue-node (number title author ago &rest fields)
  "Return issue NUMBER as the list's GraphQL query gives it.
TITLE, AUTHOR and AGO are its own; FIELDS, a plist, override the rest."
  (let ((node (copy-tree `(:number ,number :title ,title :state "OPEN" :createdAt ,(octocat-screenshots--ago ago)
                :author (:login ,author) :labels (:nodes []) :comments (:totalCount 0)
                :closedByPullRequestsReferences (:nodes [])))))
    (while fields
      (setq node (plist-put node (pop fields) (pop fields))))
    node))

(defconst octocat-screenshots--issues
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d))
    (list
     (octocat-screenshots--issue-node 134 "Build fails when a page's front matter has a BOM" "tgarcia" (* 1 h)
                                      :labels (octocat-screenshots--labels "bug" "needs triage"))
     (octocat-screenshots--issue-node 129 "Live reload doesn't pick up changes to templates" "jlindqvist" (* 1 d)
                                      :labels (octocat-screenshots--labels "bug")
                                      :comments '(:totalCount 3)
                                      :closedByPullRequestsReferences
                                      '(:nodes [(:number 130 :repository (:name "rocket" :owner (:login "acme")))]))
     (octocat-screenshots--issue-node 97 "Builds of large sites are slow: templates are parsed for every page" "pnair" (* 9 d)
                                      :labels (octocat-screenshots--labels "performance")
                                      :comments '(:totalCount 5)
                                      :closedByPullRequestsReferences
                                      '(:nodes [(:number 128 :repository (:name "rocket" :owner (:login "acme")))]))
     (octocat-screenshots--issue-node 88 "Support a dark variant in the default theme" "kwong" (* 20 d)
                                      :labels (octocat-screenshots--labels "enhancement" "good first issue")
                                      :comments '(:totalCount 1))
     (octocat-screenshots--issue-node 74 "Explain how to deploy to GitHub Pages" "aokafor" (* 41 d)
                                      :labels (octocat-screenshots--labels "docs"))))
  "The open issues of acme/rocket, newest first.")

(defun octocat-screenshots--search (nodes)
  "Return the GraphQL search answer of NODES, a list."
  `(:data (:search (:nodes ,(vconcat nodes) :pageInfo (:hasNextPage :false :endCursor :null)))))

(defun octocat-screenshots--with-repo (node)
  "Return list NODE as the dashboard's search gives it, with its repository."
  (append node '(:repository (:nameWithOwner "acme/rocket"))))

;;;; Pull request #128

(defconst octocat-screenshots--pr-128
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d) (m octocat-screenshots--m))
    `(:number 128 :title "Cache parsed templates between builds"
      :author (:login "srivera" :name "Sam Rivera" :is_bot :false)
      :state "OPEN" :isDraft :false :createdAt ,(octocat-screenshots--ago (* 2 d))
      :mergedAt :null :closedAt :null
      :baseRefName "main" :headRefName "template-cache" :headRepositoryOwner (:login "acme")
      :mergeable "MERGEABLE" :mergeStateStatus "CLEAN" :changedFiles 3
      :url "https://github.com/acme/rocket/pull/128"
      :labels [,(assoc-default "performance" octocat-screenshots--label-colors)]
      :reviewDecision "APPROVED"
      :body "Templates were parsed again for every page, which is most of the build time on large sites.  This keeps each parsed template in a cache keyed by its path and modification time.

On the docs site (1,200 pages) a build goes from 9.8s to 2.1s.

Closes #97"
      :comments [(:id "IC_1" :author (:login "pnair") :createdAt ,(octocat-screenshots--ago (+ d (* 20 h)))
                  :body "Tried it on our docs site: 9.4s → 2.0s here too.  Lovely." :url "")
                 (:id "IC_2" :author (:login "mchen") :createdAt ,(octocat-screenshots--ago (+ d (* 2 h)))
                  :body "Does the cache notice a template that includes another one which changed?" :url "")
                 (:id "IC_3" :author (:login "srivera") :createdAt ,(octocat-screenshots--ago (+ d h))
                  :body "It does now: an entry also keeps the times of the templates it includes.  Added a test for it." :url "")]
      :reviews [(:id "R_1" :author (:login "mchen") :state "APPROVED" :body ""
                 :submittedAt ,(octocat-screenshots--ago (* 5 h)))]
      :latestReviews [(:id "R_1" :author (:login "mchen") :state "APPROVED" :body ""
                       :submittedAt ,(octocat-screenshots--ago (* 5 h)))]
      :reviewRequests [(:__typename "User" :login "jlindqvist")]
      :assignees [(:login "srivera" :name "Sam Rivera")]
      :milestone (:number 4 :title "0.10" :description "" :dueOn :null)
      :closingIssuesReferences [(:number 97 :url "https://github.com/acme/rocket/issues/97"
                                 :repository (:name "rocket" :owner (:login "acme")))]
      :commits [(:oid ,(octocat-screenshots--sha "pr-128-1") :messageHeadline "Cache parsed templates by path"
                 :messageBody "" :authoredDate ,(octocat-screenshots--ago (* 2 d)) :committedDate ,(octocat-screenshots--ago (* 2 d))
                 :authors [(:login "srivera" :name "Sam Rivera" :email "srivera@example.com" :id "U_1")])
                (:oid ,octocat-screenshots--pr-head :messageHeadline "Invalidate a template when one it includes changes"
                 :messageBody "" :authoredDate ,(octocat-screenshots--ago (+ d h)) :committedDate ,(octocat-screenshots--ago (+ d h))
                 :authors [(:login "srivera" :name "Sam Rivera" :email "srivera@example.com" :id "U_1")])]
      :statusCheckRollup
      [,@(mapcar (pcase-lambda (`(,name ,minutes))
                   `(:__typename "CheckRun" :name ,name :workflowName "CI" :status "COMPLETED"
                     :conclusion "SUCCESS" :startedAt ,(octocat-screenshots--ago (+ d h))
                     :completedAt ,(octocat-screenshots--ago (- (+ d h) (* minutes m)))
                     :detailsUrl "https://github.com/acme/rocket/actions/runs/9100200300/job/27100200300"))
                 '(("lint" 2) ("test (stable)" 6) ("test (beta)" 7) ("docs" 3)))]))
  "Pull request #128, as `gh pr view' gives it.")

(defconst octocat-screenshots--pr-128-events
  (let ((d octocat-screenshots--d) (h octocat-screenshots--h))
    `[[(:event "labeled" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 2 d))
        :label (:name "performance" :color "fbca04"))
       (:event "milestoned" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 2 d))
        :milestone (:title "0.10"))
       (:event "review_requested" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (- (* 2 d) 60))
        :requested_reviewer (:login "jlindqvist"))
       (:event "assigned" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (- (* 2 d) 60))
        :assignee (:login "srivera"))
       (:event "renamed" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 40 h))
        :rename (:from "Template cache" :to "Cache parsed templates between builds"))]])
  "The timeline events of pull request #128, as one page.")

(defconst octocat-screenshots--pr-128-files
  `[(:sha ,(octocat-screenshots--sha "f1") :filename "src/cache.rs" :status "added"
     :additions 18 :deletions 0 :changes 18
     :patch "@@ -0,0 +1,18 @@
+use std::collections::HashMap;
+use std::path::PathBuf;
+use std::time::SystemTime;
+
+use crate::template::Template;
+
+/// Parsed templates, kept between builds.
+#[derive(Default)]
+pub struct Cache {
+    entries: HashMap<PathBuf, (SystemTime, Template)>,
+}
+
+impl Cache {
+    pub fn get(&self, path: &PathBuf, modified: SystemTime) -> Option<&Template> {
+        let (at, template) = self.entries.get(path)?;
+        (*at == modified).then_some(template)
+    }
+}")
    (:sha ,(octocat-screenshots--sha "f2") :filename "src/build.rs" :status "modified"
     :additions 5 :deletions 2 :changes 7
     :patch "@@ -41,9 +41,12 @@ pub fn build(site: &Site, out: &Path) -> Result<()> {
     let pages = site.pages()?;
+    let mut cache = Cache::default();
     for page in &pages {
-        let template = Template::parse(&page.template_path())?;
-        let html = template.render(page)?;
+        let path = page.template_path();
+        let template = match cache.get(&path, modified(&path)?) {
+            Some(t) => t,
+            None => cache.insert(path.clone(), Template::parse(&path)?),
+        };
+        let html = template.render(page)?;
         write_page(out, page, &html)?;
     }
     Ok(())")
    (:sha ,(octocat-screenshots--sha "f3") :filename "src/main.rs" :status "modified"
     :additions 1 :deletions 0 :changes 1
     :patch "@@ -1,5 +1,6 @@
 mod build;
+mod cache;
 mod markdown;
 mod serve;
 mod template;")]
  "The files pull request #128 changes.")

(defconst octocat-screenshots--pr-128-review-comments
  `[(:id 501 :path "src/cache.rs" :line 16 :original_line 16 :side "RIGHT" :position 16
     :diff_hunk "@@ -0,0 +1,18 @@" :commit_id ,octocat-screenshots--pr-head
     :user ,(octocat-screenshots--user "mchen") :created_at ,(octocat-screenshots--ago (* 30 octocat-screenshots--h))
     :body "Comparing modification times is enough here: a build never runs while a template is half written.")]
  "The review comments of pull request #128.")

;;;; Issue #97

(defconst octocat-screenshots--issue-97
  (let ((d octocat-screenshots--d) (h octocat-screenshots--h))
    `(:number 97 :title "Builds of large sites are slow: templates are parsed for every page"
      :author (:login "pnair" :name "Priya Nair" :is_bot :false) :state "OPEN"
      :createdAt ,(octocat-screenshots--ago (* 9 d)) :closedAt :null
      :url "https://github.com/acme/rocket/issues/97"
      :labels [,(assoc-default "performance" octocat-screenshots--label-colors)]
      :assignees [(:login "srivera" :name "Sam Rivera")]
      :milestone (:number 4 :title "0.10" :description "" :dueOn :null)
      :closedByPullRequestsReferences [(:number 128 :url "https://github.com/acme/rocket/pull/128"
                                        :repository (:name "rocket" :owner (:login "acme")))]
      :body "Our docs site has about 1,200 pages and `rocket build` takes almost 10 seconds.

Profiling it, most of the time goes to `Template::parse`, which runs once per page even though there are only 6 templates.

**Steps to reproduce**

1. `rocket new big-site`
2. Generate 1,000 pages into `content/`
3. `time rocket build`"
      :comments [(:id "IC_10" :author (:login "srivera") :createdAt ,(octocat-screenshots--ago (* 8 d))
                  :body "Confirmed.  Parsing each template once per build should fix most of it; I'll take this." :url "")
                 (:id "IC_11" :author (:login "kwong") :createdAt ,(octocat-screenshots--ago (+ (* 7 d) (* 3 h)))
                  :body "Same here with a 600-page blog: 5.5s." :url "")]))
  "Issue #97, as `gh issue view' gives it.")

(defconst octocat-screenshots--issue-97-events
  (let ((d octocat-screenshots--d))
    `[[(:event "labeled" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 8 d))
        :label (:name "performance" :color "fbca04"))
       (:event "assigned" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 8 d))
        :assignee (:login "srivera"))
       (:event "milestoned" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 8 d))
        :milestone (:title "0.10"))
       (:event "cross-referenced" :actor (:login "srivera") :created_at ,(octocat-screenshots--ago (* 2 d))
        :source (:type "issue" :issue (:number 128 :title "Cache parsed templates between builds"
                                       :pull_request (:url "")
                                       :repository (:full_name "acme/rocket"))))]])
  "The timeline events of issue #97, as one page.")

;;;; Commit

(defconst octocat-screenshots--commit-rest
  (let ((at (octocat-screenshots--ago (* 6 octocat-screenshots--h))))
    `(:sha ,octocat-screenshots--commit
      :html_url ,(format "https://github.com/acme/rocket/commit/%s" octocat-screenshots--commit)
      :commit (:message "Cache parsed templates between builds (#128)

Templates were parsed again for every page.  Keep each parsed template
in a cache keyed by its path and modification time, and those of the
templates it includes.

Closes #97"
               :author (:name "Sam Rivera" :email "srivera@example.com" :date ,at)
               :committer (:name "GitHub" :email "noreply@github.com" :date ,at))
      :author ,(octocat-screenshots--user "srivera")
      :committer ,(octocat-screenshots--user "web-flow")
      :parents [(:sha ,(octocat-screenshots--sha "c3"))]
      :stats (:total 25 :additions 24 :deletions 2)
      :files ,octocat-screenshots--pr-128-files))
  "The commit that merged #128, as the REST API gives it.")

(defun octocat-screenshots--check-run (id name conclusion started minutes)
  "Return check run ID, NAME, ended in CONCLUSION, STARTED ago, lasting MINUTES."
  `(:id ,id :name ,name :status "completed" :conclusion ,conclusion
    :started_at ,(octocat-screenshots--ago started)
    :completed_at ,(octocat-screenshots--ago (- started (* minutes 60)))
    :html_url ,(format "https://github.com/acme/rocket/actions/runs/9100200300/job/%d" id)
    :details_url ,(format "https://github.com/acme/rocket/actions/runs/9100200300/job/%d" id)
    :app (:slug "github-actions" :name "GitHub Actions")
    :check_suite (:id 7100200300)
    :output (:title :null :summary :null :annotations_count 0)))

;;;; Actions

(defun octocat-screenshots--run (id title workflow branch status conclusion ago)
  "Return run ID, as `gh run list' gives it.
TITLE, WORKFLOW, BRANCH, STATUS, CONCLUSION and AGO are its own."
  `(:databaseId ,id :displayTitle ,title :workflowName ,workflow :headBranch ,branch
    :status ,status :conclusion ,conclusion :createdAt ,(octocat-screenshots--ago ago)))

(defconst octocat-screenshots--runs
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d) (m octocat-screenshots--m))
    (list
     (octocat-screenshots--run 9100200310 "Incremental builds: skip pages whose inputs are unchanged" "CI" "incremental" "in_progress" "" (* 4 m))
     (octocat-screenshots--run 9100200309 "Render footnotes in Markdown pages (#131)" "Deploy docs" "main" "completed" "success" (* 2 h))
     (octocat-screenshots--run 9100200308 "Render footnotes in Markdown pages (#131)" "CI" "main" "completed" "success" (* 2 h))
     (octocat-screenshots--run 9100200307 "Add RSS and Atom feeds for each section" "CI" "feeds" "completed" "success" (* 9 h))
     (octocat-screenshots--run 9100200306 "Fix: `rocket serve` drops changes saved twice in a second" "CI" "serve-debounce" "completed" "failure" (* 1 d))
     (octocat-screenshots--run 9100200300 "Cache parsed templates between builds" "CI" "template-cache" "completed" "success" (+ d h))
     (octocat-screenshots--run 9100200299 "Nightly" "Benchmarks" "main" "completed" "success" (+ d (* 12 h)))
     (octocat-screenshots--run 9100200298 "Bump toml from 0.8.12 to 0.8.19" "CI" "dependabot/cargo/toml-0.8.19" "completed" "success" (* 1 d))
     (octocat-screenshots--run 9100200297 "Docs: a guide to writing your first theme" "CI" "theme-guide" "completed" "cancelled" (* 5 d))))
  "The recent workflow runs of acme/rocket, newest first.")

(defun octocat-screenshots--step (number name minutes &optional conclusion)
  "Return step NUMBER, NAME, lasting MINUTES, ended in CONCLUSION."
  (let ((start (+ octocat-screenshots--d octocat-screenshots--h (* -2 number 60))))
    `(:number ,number :name ,name :status "completed" :conclusion ,(or conclusion "success")
      :startedAt ,(octocat-screenshots--ago start)
      :completedAt ,(octocat-screenshots--ago (- start (* minutes 60))))))

(defconst octocat-screenshots--run-jobs
  (let ((start (+ octocat-screenshots--d octocat-screenshots--h)))
    (mapcar
     (pcase-lambda (`(,id ,name ,minutes))
       `(:databaseId ,id :name ,name :status "completed" :conclusion "success"
         :startedAt ,(octocat-screenshots--ago start)
         :completedAt ,(octocat-screenshots--ago (- start (* minutes 60)))
         :url ,(format "https://github.com/acme/rocket/actions/runs/9100200300/job/%d" id)
         :steps [,(octocat-screenshots--step 1 "Set up job" 0)
                 ,(octocat-screenshots--step 2 "Check out" 0)
                 ,(octocat-screenshots--step 3 "Install Rust" 1)
                 ,(octocat-screenshots--step 4 "Run cargo" (- minutes 2))
                 ,(octocat-screenshots--step 5 "Complete job" 0)]))
     '((27100200297 "lint" 2) (27100200300 "test (stable)" 6)
       (27100200301 "test (beta)" 7) (27100200302 "docs" 3))))
  "The jobs of run 9100200300, as `gh run view' gives them.")

(defconst octocat-screenshots--job-log
  (let ((lines
         '(("Set up job" "Current runner version: '2.329.0'")
           ("Set up job" "Runner Image: ubuntu-24.04")
           ("Check out" "Syncing repository: acme/rocket")
           ("Check out" "HEAD is now at 1c0ffee Invalidate a template when one it includes changes")
           ("Install Rust" "info: installing component 'rustc'")
           ("Install Rust" "rustc 1.91.0 (f8297e351 2026-10-28)")
           ("Run cargo" "   Compiling rocket v0.10.0 (/home/runner/work/rocket/rocket)")
           ("Run cargo" "    Finished `test` profile [unoptimized + debuginfo] target(s) in 41.20s")
           ("Run cargo" "     Running unittests src/main.rs (target/debug/deps/rocket-3a1d)")
           ("Run cargo" "running 48 tests")
           ("Run cargo" "test cache::tests::hit_when_unchanged ... ok")
           ("Run cargo" "test cache::tests::miss_when_include_changed ... ok")
           ("Run cargo" "test markdown::tests::footnotes ... ok")
           ("Run cargo" "test result: ok. 48 passed; 0 failed; 0 ignored; finished in 1.84s")
           ("Complete job" "Cleaning up orphan processes")))
        (at (octocat-screenshots--ago (+ octocat-screenshots--d octocat-screenshots--h))))
    (mapconcat (pcase-lambda (`(,step ,text))
                 (format "test (stable)\t%s\t%s %s\n"
                         step (replace-regexp-in-string "Z\\'" ".1234567Z" at) text))
               lines ""))
  "The log of job 27100200300, as `gh run view --log' prints it.")

(defconst octocat-screenshots--artifacts
  `(:total_count 1
    :artifacts [(:id 4100200300 :name "coverage-report" :size_in_bytes 482113 :expired :false
                 :created_at ,(octocat-screenshots--ago (+ octocat-screenshots--d (* 50 octocat-screenshots--m)))
                 :expires_at ,(octocat-screenshots--ago (* -89 octocat-screenshots--d))
                 :archive_download_url "https://api.github.com/repos/acme/rocket/actions/artifacts/4100200300/zip")])
  "The artifacts of run 9100200300.")

;;;; People

(defun octocat-screenshots--repo-rest (name description language stars ago &rest fields)
  "Return repository NAME of acme, as the REST API lists it.
DESCRIPTION, LANGUAGE, STARS and AGO, since its last push, are its own;
FIELDS, a plist, override the rest."
  (let ((repo (copy-tree `(:id ,(abs (sxhash-equal name)) :name ,name :full_name ,(concat "acme/" name)
                :owner ,(octocat-screenshots--user "acme")
                :html_url ,(concat "https://github.com/acme/" name)
                :description ,description :language ,language :stargazers_count ,stars
                :forks_count ,(/ stars 8) :open_issues_count 3 :private :false :fork :false
                :archived :false :visibility "public" :default_branch "main"
                :pushed_at ,(octocat-screenshots--ago ago) :updated_at ,(octocat-screenshots--ago ago)))))
    (while fields
      (setq repo (plist-put repo (pop fields) (pop fields))))
    repo))

(defconst octocat-screenshots--repos
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d))
    (list
     (octocat-screenshots--repo-rest "rocket" "A small, fast static site generator" "Rust" 2481 (* 2 h))
     (octocat-screenshots--repo-rest "rocket-themes" "Themes for rocket sites" "CSS" 312 (* 3 d))
     (octocat-screenshots--repo-rest "launchpad" "Deploy static sites to any CDN with one command" "Go" 905 (* 6 d))
     (octocat-screenshots--repo-rest "orbit" "Tiny HTTP server for local previews" "Rust" 140 (* 15 d))
     (octocat-screenshots--repo-rest "dotfiles" "My editor and shell setup" "Emacs Lisp" 37 (* 22 d)
                                     :full_name "srivera/dotfiles" :owner (octocat-screenshots--user "srivera"))))
  "Repositories, most recently pushed first.")

(defun octocat-screenshots--event (id type actor repo ago payload)
  "Return feed event ID of TYPE by ACTOR in REPO, AGO seconds ago, with PAYLOAD."
  `(:id ,(number-to-string id) :type ,type :public t
    :actor (:login ,actor :display_login ,actor
            :avatar_url ,(format "https://avatars.githubusercontent.com/u/%s" actor))
    :repo (:name ,repo :url ,(concat "https://api.github.com/repos/" repo))
    :created_at ,(octocat-screenshots--ago ago) :payload ,payload))

(defconst octocat-screenshots--feed
  (let ((h octocat-screenshots--h) (d octocat-screenshots--d) (m octocat-screenshots--m))
    (vector
     (octocat-screenshots--event 5 "IssuesEvent" "tgarcia" "acme/rocket" (+ h (* 20 m))
                                 '(:action "opened" :issue (:number 134 :title "Build fails when a page's front matter has a BOM")))
     (octocat-screenshots--event 8 "PushEvent" "mchen" "acme/rocket" (* 2 h)
                                 `(:ref "refs/heads/main" :size 1 :head ,octocat-screenshots--head
                                   :commits [(:sha ,octocat-screenshots--head :message "Render footnotes in Markdown pages (#131)")]))
     (octocat-screenshots--event 9 "PullRequestEvent" "srivera" "acme/rocket" (* 3 h)
                                 '(:action "opened" :number 133
                                   :pull_request (:number 133 :title "Incremental builds: skip pages whose inputs are unchanged")))
     (octocat-screenshots--event 7 "IssueCommentEvent" "pnair" "acme/rocket" (* 5 h)
                                 '(:action "created" :issue (:number 129 :title "Live reload doesn't pick up changes to templates")
                                   :comment (:body "I can reproduce this on macOS too.")))
     (octocat-screenshots--event 6 "WatchEvent" "kwong" "acme/launchpad" (* 7 h) '(:action "started"))
     (octocat-screenshots--event 3 "CreateEvent" "jlindqvist" "acme/rocket" (* 1 d)
                                 '(:ref "serve-debounce" :ref_type "branch"))
     (octocat-screenshots--event 4 "ReleaseEvent" "aokafor" "acme/rocket-themes" (* 3 d)
                                 '(:action "published" :release (:tag_name "v2.1.0" :name "v2.1.0")))
     (octocat-screenshots--event 2 "ForkEvent" "kwong" "acme/rocket" (* 4 d)
                                 '(:forkee (:full_name "kwong/rocket")))))
  "The dashboard's feed, newest first.")

(defconst octocat-screenshots--srivera
  `(:login "srivera" :id 1001 :type "User" :name "Sam Rivera" :company "@acme"
    :blog "https://srivera.example.com" :location "Lisbon" :email :null
    :bio "Building rocket, a static site generator.  Emacs, Rust, and long walks."
    :twitter_username :null :public_repos 23 :followers 412 :following 38
    :avatar_url "https://avatars.githubusercontent.com/u/srivera"
    :html_url "https://github.com/srivera"
    :created_at "2014-03-02T10:00:00Z")
  "The user srivera, as the REST API gives one.")

(defconst octocat-screenshots--pinned
  `(:data (:repositoryOwner
           (:pinnedItems
            (:nodes [(:nameWithOwner "acme/rocket" :description "A small, fast static site generator"
                      :stargazerCount 2481 :primaryLanguage (:name "Rust")
                      :pushedAt ,(octocat-screenshots--ago (* 2 octocat-screenshots--h))
                      :isFork :false :isArchived :false)
                     (:nameWithOwner "acme/launchpad" :description "Deploy static sites to any CDN with one command"
                      :stargazerCount 905 :primaryLanguage (:name "Go")
                      :pushedAt ,(octocat-screenshots--ago (* 6 octocat-screenshots--d))
                      :isFork :false :isArchived :false)
                     (:nameWithOwner "srivera/dotfiles" :description "My editor and shell setup"
                      :stargazerCount 37 :primaryLanguage (:name "Emacs Lisp")
                      :pushedAt ,(octocat-screenshots--ago (* 22 octocat-screenshots--d))
                      :isFork :false :isArchived :false)]))))
  "The repositories srivera pinned.")

;;;; Fixtures

(defvar octocat-screenshots-fixtures
  (let ((d octocat-screenshots--d) (h octocat-screenshots--h))
    `(;; Dashboard
      ("dashboard-login" () "srivera\n")
      ("dashboard-repos" () ,(vconcat octocat-screenshots--repos))
      ("dashboard-pulls" ()
       ,(octocat-screenshots--search
         (mapcar #'octocat-screenshots--with-repo
                 (list (nth 0 octocat-screenshots--prs) (nth 3 octocat-screenshots--prs)
                       (nth 2 octocat-screenshots--prs)))))
      ("dashboard-issues" ()
       ,(octocat-screenshots--search
         (mapcar #'octocat-screenshots--with-repo
                 (list (nth 1 octocat-screenshots--issues) (nth 2 octocat-screenshots--issues)))))
      ("dashboard-feed" ("users/srivera/received_events") ,octocat-screenshots--feed)

      ;; Repository
      ("repo-summary" ("name=rocket")
       (:data (:repository (:defaultBranchRef (:name "main") :parent :null
                            :issues (:totalCount ,(length octocat-screenshots--issues))
                            :pullRequests (:totalCount ,(length octocat-screenshots--prs))))))
      ("repo-head" ("dir=HEAD:src")
       (:data (:repository (:object (:history (:totalCount 87 :nodes [,(octocat-screenshots--history-node
                                                                        (nth 1 octocat-screenshots--commits))]))
                            :dir (:__typename "Tree" :oid ,(octocat-screenshots--sha "src"))))))
      ("repo-head" ("dir=HEAD:")
       (:data (:repository (:object (:history (:totalCount 342 :nodes [,(octocat-screenshots--history-node
                                                                         (car octocat-screenshots--commits))]))
                            :dir (:__typename "Tree" :oid ,(octocat-screenshots--sha "root"))))))
      ("commits" ("ref=HEAD")
       (:data (:repository
               (:object (:history
                         (:totalCount 342
                          :edges ,(vconcat
                                   (seq-map-indexed
                                    (lambda (c i) `(:cursor ,(format "cursor-%d" i)
                                                    :node ,(octocat-screenshots--history-node c)))
                                    octocat-screenshots--commits))))))))
      ("repo-head" ("dir=main:docs/guide.md")
       (:data (:repository (:object (:history (:totalCount 12 :nodes [,(octocat-screenshots--history-node
                                                                        (nth 2 octocat-screenshots--commits))]))
                            :dir (:__typename "Blob" :oid ,(octocat-screenshots--sha "docs/guide.md"))))))
      (,(format "tree-blob-%s" (substring (octocat-screenshots--sha "docs/guide.md") 0 8)) ()
       ,(octocat-screenshots--base64 octocat-screenshots--guide))
      (,(format "tree-dir-%s" (substring (octocat-screenshots--sha "root") 0 8)) ()
       (:sha ,(octocat-screenshots--sha "root") :tree ,octocat-screenshots--root :truncated :false))
      (,(format "tree-dir-%s" (substring (octocat-screenshots--sha "src") 0 8)) ()
       (:sha ,(octocat-screenshots--sha "src") :tree ,octocat-screenshots--src :truncated :false))
      (,(format "tree-blob-%s" (substring (octocat-screenshots--sha "README.md") 0 8)) ()
       ,(octocat-screenshots--base64 octocat-screenshots--readme))

      ;; Pull requests
      ("counts" ("pullRequests(states:OPEN)")
       (:data (:repository (:open (:totalCount 6) :closed (:totalCount 14) :merged (:totalCount 108)))))
      ("pulls" ("repo:acme/rocket") ,(octocat-screenshots--search octocat-screenshots--prs))
      ("pr" ("128") ,octocat-screenshots--pr-128)
      ("timeline-events" ("issues/128/") ,octocat-screenshots--pr-128-events)
      ("awaiting-runs" () (:total_count 0 :workflow_runs []))
      ("pr-diff" ("pulls/128/files") ,octocat-screenshots--pr-128-files)
      ("pr-review-comments" ("pulls/128/comments") ,octocat-screenshots--pr-128-review-comments)

      ;; Issues
      ("counts" ("issues(states:OPEN)")
       (:data (:repository (:open (:totalCount 5) :closed (:totalCount 61)))))
      ("issues" ("repo:acme/rocket") ,(octocat-screenshots--search octocat-screenshots--issues))
      ("issue" ("97") ,octocat-screenshots--issue-97)
      ("timeline-events" ("issues/97/") ,octocat-screenshots--issue-97-events)

      ;; Commit
      ("commit" (,(concat "commits/" octocat-screenshots--commit)) ,octocat-screenshots--commit-rest)
      ("checks" ("check-runs")
       (:total_count 4
        :check_runs [,(octocat-screenshots--check-run 27100200310 "lint" "success" (* 6 h) 2)
                     ,(octocat-screenshots--check-run 27100200311 "test (stable)" "success" (* 6 h) 6)
                     ,(octocat-screenshots--check-run 27100200312 "test (beta)" "success" (* 6 h) 7)
                     ,(octocat-screenshots--check-run 27100200313 "docs" "success" (* 6 h) 3)]))
      ("commit-comments" () [])

      ;; Actions
      ("workflows" ()
       [(:id 4200 :name "CI" :state "active" :path ".github/workflows/ci.yml")
        (:id 4201 :name "Deploy docs" :state "active" :path ".github/workflows/docs.yml")
        (:id 4202 :name "Benchmarks" :state "active" :path ".github/workflows/bench.yml")
        (:id 4203 :name "Release" :state "disabled_manually" :path ".github/workflows/release.yml")])
      ("recent-runs" () ,(vconcat octocat-screenshots--runs))
      ("run-view" ("9100200300")
       (:databaseId 9100200300 :displayTitle "Cache parsed templates between builds"
        :workflowName "CI" :status "completed" :conclusion "success" :event "pull_request"
        :headBranch "template-cache" :headSha ,octocat-screenshots--pr-head
        :createdAt ,(octocat-screenshots--ago (+ d h))
        :updatedAt ,(octocat-screenshots--ago (- (+ d h) (* 7 60)))
        :jobs ,(vconcat octocat-screenshots--run-jobs)))
      ("run-artifacts" () ,octocat-screenshots--artifacts)
      ("job-artifacts" () ,octocat-screenshots--artifacts)
      ("job-detail" ("27100200300")
       ,(let ((job (nth 1 octocat-screenshots--run-jobs)))
          `(:id 27100200300 :run_id 9100200300 :name "test (stable)" :status "completed"
            :conclusion "success" :head_branch "template-cache" :head_sha ,octocat-screenshots--pr-head
            :started_at ,(plist-get job :startedAt) :completed_at ,(plist-get job :completedAt)
            :runner_name "GitHub Actions 41" :labels ["ubuntu-latest"]
            :html_url ,(plist-get job :url)
            :steps ,(vconcat
                     (mapcar (lambda (s)
                               `(:number ,(plist-get s :number) :name ,(plist-get s :name)
                                 :status "completed" :conclusion ,(plist-get s :conclusion)
                                 :started_at ,(plist-get s :startedAt)
                                 :completed_at ,(plist-get s :completedAt)))
                             (plist-get job :steps))))))
      ("job-log" ("27100200300") ,octocat-screenshots--job-log)
      ("job-annotations" () [])
      ("run-annotations" () [])
      ("workflow-detail" ("workflows/4200")
       (:id 4200 :name "CI" :state "active" :path ".github/workflows/ci.yml"
        :html_url "https://github.com/acme/rocket/actions/workflows/ci.yml"
        :badge_url "https://github.com/acme/rocket/workflows/CI/badge.svg"
        :created_at "2025-02-11T09:00:00Z" :updated_at ,(octocat-screenshots--ago (* 30 d))))
      ("workflow-runs" ("4200")
       ,(vconcat (mapcar (lambda (r) (cl-loop for (k v) on r by #'cddr
                                              unless (eq k :workflowName) append (list k v)))
                         (seq-filter (lambda (r) (equal (plist-get r :workflowName) "CI"))
                                     octocat-screenshots--runs))))

      ;; People
      ("user-profile" ("users/srivera") ,octocat-screenshots--srivera)
      ("user-pinned" ("login=srivera") ,octocat-screenshots--pinned)
      ("user-repos" ("users/srivera/repos") ,(vconcat octocat-screenshots--repos))))
  "The `gh' calls the shots make, and what `gh' answers: see the Commentary.")

(provide 'fixtures)
;;; fixtures.el ends here
