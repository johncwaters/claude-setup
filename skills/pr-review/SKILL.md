---
name: pr-review
description: Review a GitHub pull request and optionally post the result to it. Resolves the PR to a base and head SHA without touching the working tree, runs one code-review pass over that range, then asks before posting inline comments and one sticky summary. Never fixes anything, never loops, never pushes. Use when asked to review a PR, review somebody's changes, or leave review comments on GitHub.
---

# PR Review

The pull request entry point of the review ladder. It reviews somebody's work and leaves a record; it never changes the work.

## When to use

- Reviewing another carbon unit's pull request, which is the case this exists for
- Leaving an audit record on a pull request the local flow already opened, when asked

Reviewing your own uncommitted work is not this skill. That is `/commit`, which loops a review against a writer until the tree is clean. This skill has no writer and therefore no loop.

## Step 1: Resolve the pull request

Accept a PR number, a PR URL, or nothing (meaning the PR for the current branch).

```
gh pr view <pr-or-blank> --json number,url,title,body,baseRefName,headRefName,headRefOid,author,isDraft
```

Fetch the refs so the lanes can run git locally, without checking anything out. Never `gh pr checkout`: it mutates the working tree, and the tree may belong to work in progress that is not yours.

```
git fetch origin "pull/<number>/head:refs/remotes/pr/<number>"
git fetch origin "<baseRefName>"
BASE_SHA=$(git merge-base "origin/<baseRefName>" "refs/remotes/pr/<number>")
HEAD_SHA=<headRefOid>
```

`merge-base` and not the base branch tip: diffing against the tip includes every commit that landed on the base since the PR forked, and those are not this PR's changes to review.

No PR found: say so and stop. Do not silently fall back to reviewing the working tree; that reviews a different thing than the carbon unit asked about.

## Step 2: Review

Invoke `/code-review` with the base and head SHAs, the repo path, and context assembled from the PR itself: title, body, author, and target branch. That context is the only thing standing in for the intent behind a change you did not write, so pass it verbatim rather than summarized.

`/code-review` returns a `VERDICT`, an `ACTIONABLE` count, a dispositioned `STRUCTURED_FINDINGS` block, and a summary. That is the whole review.

`VERDICT: FAILED` means the review did not complete. Re-run it once, since the usual cause is a dead lane process rather than anything about the code. Failing twice: report the failure and post nothing. Posting a partial review as though it were a complete one misrepresents how much of the pull request was actually looked at.

**The `ACTIONABLE` count and disposition change nothing here.** They gate a loop, and this skill has no loop: no writer runs, nothing is fixed, and no round two happens. A disposition on somebody else's pull request is advice about what the author should do, and it becomes the tone of the comment rather than an instruction to this session.

`AMBIGUOUS` findings still get posted, phrased as the open question they are, with both readings stated. They are frequently the most useful comment on a pull request.

## Step 3: Ask before posting

Posting is outward-facing, attributed, and hard to retract. Ask every run, including a re-review of a PR already commented on, and including a PR the local flow just opened.

Show the verdict and the finding counts by severity first, so the answer is informed. Declined: the terminal report from Step 5 is the whole output.

Never post on a draft PR without saying it is a draft and asking anyway.

## Step 4a: Inline comments

Post every finding with a real file and line as one batched review, not one API call per finding. Batching is not cosmetic: one review sends one notification, N individual comments send N.

`gh api -f` only sets flat string fields, so the comment array must arrive as a real JSON body through `--input`:

```
cat > <body.json> <<'JSON'
{
  "event": "COMMENT",
  "body": "Automated review. See inline comments.",
  "commit_id": "<HEAD_SHA>",
  "comments": [
    { "path": "<file>", "line": <line>, "side": "<RIGHT or LEFT, from the finding>", "body": "<comment body>" }
  ]
}
JSON
gh api repos/{owner}/{repo}/pulls/{number}/reviews --method POST --input <body.json>
```

`side` is copied straight from the finding's own `side` field, never inferred here: by the time a finding reaches this step the diff is no longer in hand, and guessing puts a comment about deleted code onto whatever unrelated line now occupies that number. A finding with no `side` is `RIGHT`. A finding whose `line` is `general` has no anchor at all and belongs in the summary comment.

Build that JSON with a script (`jq`, or `json.dumps` over the finding list), never by hand-splicing finding text into the template. Bodies contain quotes, backticks, and newlines, and a hand-built body produces invalid JSON or a mangled comment.

`event` stays `COMMENT`. Never `APPROVE` or `REQUEST_CHANGES`: those are the carbon unit's call to make under their own name, and an automated pass must not spend a human's review approval.

Failure of the batched call falls back to `gh api repos/{owner}/{repo}/pulls/{number}/comments` per finding, and the report says the fallback was used.

Each inline body:

```
> [!NOTE]
> Automated review. Not written by a human.

**[<reviewer tag>] <SEVERITY>**

<the finding body>
```

Convergent findings use `**[convergent: <tag> + <tag>] <SEVERITY>**`.

Findings with `line: general` have no anchor and belong in the summary comment instead.

## Step 4b: Sticky summary, one per PR

Exactly one top-level summary comment per pull request, marked `<!-- pr-review-summary -->`, updated in place on every re-review. Several bot comments on one PR is the noise this exists to prevent.

```
gh api "repos/{owner}/{repo}/issues/{number}/comments" --paginate \
  --jq '[.[] | select((.body | contains("<!-- pr-review-summary -->")) or (.body | contains("<!-- qa-swarm-summary -->")))][0].id'
```

Both sides of the `or` are parenthesized because `|` binds loosest in jq: unparenthesized, the filter parses as `.body | (contains(A) or .body) | contains(B)` and dies with `Cannot index string with "body"` on the first comment that does not match.

The second marker is the one `qa-swarm` used before summary posting moved here. Matching it means an older summary is updated in place rather than joined by a second one; write the new marker when you update it, so each PR converges on one.

Body shape, current verdict on top and prior rounds folded away:

```
<!-- pr-review-summary -->
> [!NOTE]
> Automated review. Not written by a human.

## Verdict: <VERDICT> (round <N> at <short_sha>)

<1 to 2 sentences>

### Findings
<grouped by severity, current round only, with the unanchored ones spelled out here>

### Convergence
<findings two or more lanes reached independently, the highest confidence ones>

### Lanes
| Lane | Assessment |
| --- | --- |
| <tag> | <one sentence> |

<details>
<summary>Previous rounds (<n>)</summary>

round <N> at <short_sha> - <verdict>: <one-line disposition>

</details>
```

When updating, derive the history lines from the existing comment's own verdict header plus its existing history block. The previous round collapses to one line; it is never carried over verbatim.

```
gh api "repos/{owner}/{repo}/issues/comments/{id}" -X PATCH -F body=@<file>   # update
gh pr comment {number} --body-file <file>                                     # create
```

Inline comments from Step 4a are untouched by the upsert. They are threaded, per-finding, and resolvable by the author; only the top-level summary is deduplicated.

## Step 5: Report

Terminal report regardless of whether anything was posted:

```
## PR #<n> <title>
Verdict: <VERDICT>   Actionable: <n>   Range: <BASE_SHA>..<HEAD_SHA>   Files: N   Lines: N
Lanes: <tag>, <tag>   Degraded: <tag> (<reason>)
Findings: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW, <n> NIT
Posted: <yes, N inline + summary | no, declined>

### Findings
- path:line [SEVERITY] [<tag>] problem. fix.
(most severe first; convergent findings marked)
```

## Never

- No file edits, no writer, no fix loop. Reviewing somebody's work does not include doing it
- No `git` writes beyond `fetch`, and no checkout
- No `APPROVE` or `REQUEST_CHANGES` review events
- No posting without asking first
