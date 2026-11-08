# Plan: simpler model and sync

## Goal

**First: a person new to octocat can understand how data is fetched,
stored and changed.**  Reading `octocat-model.el`, they should be able
to tell what a resource fetches and what a mutation does to the screen
and to GitHub, without opening `octocat-sync.el` or tracing a function.
Shorter code, fewer helpers and less machinery serve that aim and are
not goals of their own: sync may grow if the definitions get clearer,
as its machinery is written once and the definitions many times.

Pages stay out of it: they read resources and submit mutations, and
know nothing of how either is fetched, stored or changed.

### How a change is judged

- **A definition says what, not how.**  A mutation reads as what it
  changes ("append this comment to the issue's comments"), not as code
  that copies tables and rebuilds vectors.
- **One place to learn each concept.**  Every property of a resource
  or mutation is explained in one docstring, and the model's
  commentary says how to read a definition.
- **Nothing implicit.**  A rule a definition must follow, such as an
  entity field having one shape, is written down and checked by a test,
  not left to be inferred from the code.
- **No new vocabulary without a gain.**  An operation or macro is added
  only when it makes many definitions plainer; one used twice is not.

The steps are independent commits, ordered by how much they help a
reader.

## 1. Keep a mutation's change until the refetch

Today a mutation's `:edits` is called twice: before GitHub answers,
for the change shown while it runs, and after, with GitHub's answer,
for the change written to the store.  A reader has to follow both
paths through every edit, and the answer is turned into the stored
shape by hand (`octocat-model--rest-comment`, the `(cons review
thread)` answers of the review drafts).

**Change:** `:edits` is called once, with no arguments, for the change
to show.  On success sync no longer writes an answer: it keeps the
mutation's edits applied and refetches the resources they change.
Once each has been fetched after the answer, the edits are dropped;
the fetched data now has the change, as GitHub has it.

- An edit is applied only to data fetched before the answer, so an
  appended comment never shows twice.
- A removal is applied for a short while longer (say 10 s) to fresh
  data too: GitHub may still return a deleted comment for a moment.
  Removing what is gone already is harmless.
- If the refetch fails, the edits stay until the next fetch succeeds,
  or a minute has passed.
- Entity changes (`:optimistic`) are written on success as today:
  they need no answer.

**Cost:** one more fetch per mutation, and a comment just posted can't
be edited until the refetch lands (about a second), as it has no id
until then.

**Model:** `:edits` loses its `answered` and `answer` arguments and
every branch on them.  `octocat-model--rest-comment` and the answer
parsing of `review-draft-add` and `review-draft-reply` go.

**Tests:** in `test/octocat-sync-tests.el`, an edit shows until the
refetch after the answer lands and is gone after it; an append doesn't
show twice; a removal holds over a refetch within its grace time; a
failed refetch keeps the edit.

## 2. Edits as operations, not functions

After step 1, ten of the twelve `:edits` do one of four things to a
resource's data.  Sync gets those four, and a mutation lists them:

```elisp
:edit `((append ,spec ("comments") ,comment)
        (set    ,spec ("threads" ("id" . ,thread-id) "isResolved") t)
        (remove ,spec ("threads" * "comments" "nodes" ("id" . ,node-id))))
```

A path is read left to right: a string is a key of a table, `*` every
item of a vector, and `(FIELD . VALUE)` the items of a vector whose
FIELD is VALUE.  `set` sets what the path ends at, `append` adds to the
vector it ends at, and `remove` drops the items it ends at.  A
function, `(call SPEC FUNCTION)`, stays for the rest.

| Mutation | Operation |
|---|---|
| `comment`, `review-draft-add`, `review-draft-reply`, `review-reply-now` | `append` |
| `edit-body`, `edit-comment`, `review-comment-edit`, `review-thread-resolve` | `set` |
| `review-comment-delete`, `review-discard` | `remove` |
| `review-pr` | `set` on the drafts, `("state" . "PENDING")` |
| `react` | `call`: it toggles a count |

The helpers that walk and patch the data go:
`octocat-model--put-comment`, `-set-comment-body`,
`-review-map-threads`, `-review-map-comments`, `-review-add-reply`,
`-review-set-pending`, `-review-drop-drafts`, and the two `-edit`
wrappers.

**Open questions:**

- `edit-comment` finds a comment by the numeric id in its URL
  (`octocat--comment-numeric-id`).  Either the page passes the node id,
  or a path step may be a function of an item.
- `review-comment-delete` drops a thread left with no comment.  Either
  `remove` does that for an emptied `"nodes"`, or the mutation adds a
  second `remove` of threads with none.

**Tests:** each operation and path step in `test/octocat-sync-tests.el`;
the mutations' existing tests pass unchanged.

## 3. A guide to reading the model

Once steps 1 and 2 have settled what a definition looks like, write it
down where a reader starts:

- **The model's commentary** walks through one resource and one
  mutation, property by property: what is fetched, what is shared as an
  entity, what shows while a mutation runs, and what is refetched after.
  It names the sections of the file, in order.
- **The macros' docstrings** are the reference for every property:
  `octocat-sync-define-resource`'s set out as an aligned list, as
  `octocat-sync-define-mutation`'s already are.
- **`octocat-sync-read`'s docstring** gathers the snapshot's keys into
  one list.
- **`docs/using-vui.md`** links to the commentary instead of repeating
  it.

## 4. One shape per entity field

The store keeps each issue, PR, user, label, repo and run once, and
merges every fetch's copy into it field by field.  That is only right
if a field means the same in every query that fetches it: if a list
fetched `labels(first: 5)` and the PR page all of them, each list
refetch would cut the page's labels to five.  Today the rule is
implicit: a reader adding a resource has no way to know it.

The model already keeps to it in places:

- the lists fetch all labels and assignees, as the entity holds the
  whole set;
- a page's connections (comments, reviews, commits) stay with its
  resource (`octocat-model-detail`), and only their count is on the
  entity;
- a user keeps only its login;
- linked issues and PRs keep only the fields both queries have;
- review requests are `requestedReviewers` in the lists and
  `reviewRequests` on the page.

**Do:** for each entity builder (`octocat-model-item`, `-user`,
`-label`, `-repo`, `-repo-rest`, `-run`), list every query or `gh
--json` call that produces it and compare each field's shape.  Fix a
mismatch by trimming the field to one shape, renaming it, or keeping
it with the resource.

**Test:** run every resource's parser over the fixtures in
`test/screenshots/fixtures.el`, collect each entity type's fields, and
check that a field has one shape (type, and for a vector its element
type) across all of them.  A new resource that breaks the rule then
fails a test that names the field.

**Document:** the rule, in the model's commentary from step 3.

## Not doing

- **Entity declarations** in place of the builders: they are short
  plain functions a reader follows at a glance; the test of step 4
  enforces their shapes instead.
- **GraphQL as s-expressions:** a reader who knows GraphQL would have
  to learn a second notation for it.
- **Finding entities by id**, as Apollo does: `gh --json` and the REST
  API don't give an object's type, and labels and users don't always
  carry an id.
- **One spelling of issue and PR in every file:** most of the pages'
  `"pr"` and `"issue"` are `gh` subcommands, and `octocat-model.el`
  converts them in one place (`octocat-model--item-type`).
- **Moving resources into the pages that read them:** pages must not
  know how data is fetched.
