---
name: qa-swarm
description: Multi-perspective review of a diff. A cheap router pass rates danger and complexity, delegates only the reviewer lanes the change earns, then converges every lane into one deduplicated finding list with a deterministic verdict. Optionally posts inline comments and one sticky summary to a PR. Use for large, cross-cutting, security-sensitive, or pre-merge changes; use /code-review for the ordinary case.
---

# QA Swarm

Router first, delegation second, convergence third. Every lane emits the same structured finding format so the merge is mechanical instead of eyeball work.

## When this runs instead of code-review

`code-review` is the default and stays the default. Reach for qa-swarm only when at least one holds:

- the diff is large (roughly 500+ changed lines) or spans 3+ subsystems
- the change is security-sensitive, destructive, or touches money, auth, or PII
- it is the last gate before a merge or release, and a missed defect is expensive
- the carbon unit asked for a swarm, a multi-perspective review, or a second and third opinion

Never run it by habit. It costs a router pass plus one pass per delegated lane.

## Step 1: Gather scope once

```
git status --short
git rev-parse HEAD
git diff --stat                 # working tree
git diff --cached --stat        # staged
gh pr view --json number,headRefOid,baseRefName 2>/dev/null || true
```

Pin the review target to an immutable object, not to a live tree. Lanes run concurrently and take minutes; `git diff --cached` re-reads the index on every call, so an edit or a `git add` mid-review silently hands later lanes a different diff and the synthesis merges findings from two different changes.

- staged: `TREE=$(git write-tree)`, then `REVIEW_CMD="git diff HEAD $TREE"`. `write-tree` freezes the current index as a tree object without touching the index, the refs, or the stash stack
- working tree: snapshot through a throwaway index so the live one is never mutated. Never `git add -A` against the real index to set up a review; that stages whatever the carbon unit had deliberately left unstaged, and the next commit quietly carries it

```
TMP_DIR=$(mktemp -d)
cp "$(git rev-parse --git-dir)/index" "$TMP_DIR/index"
GIT_INDEX_FILE="$TMP_DIR/index" git add -A
TREE=$(GIT_INDEX_FILE="$TMP_DIR/index" git write-tree)
rm -rf "$TMP_DIR"
REVIEW_CMD="git diff HEAD $TREE"
```

`mktemp -d` and not `mktemp -u`: the `-u` form only reserves a name, so another local process can land a symlink there first and have the `cp` overwrite its target.

- branch or PR: resolve `BASE_SHA` and `HEAD_SHA`, then `REVIEW_CMD="git diff <BASE_SHA>..<HEAD_SHA>"`

Hand delegates the command, not the diff text. An immutable pin keeps every lane on identical input while keeping the diff out of prompt tokens. A lane scoped to a subset appends `-- <paths>` to its own copy.

Record file count, changed-line count, and the touched subsystems. That is the router's input.

## Step 2: Router pass

One cheap pass produces both a first-pass review and the delegation plan.

Route it per `~/.claude/ROUTING.md` rule 1: Codex `gpt-5.6-terra`, prompt written to a temp file, dispatched with `codex exec --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-terra < <file>`. Codex quota exhausted or the CLI errors: step down to `gpt-5.6-luna`, then fall back to a `sonnet` agent. The delegation plan survives either way; only the cost of the first pass changes.

The router prompt asks for:

1. **Danger rating** LOW / MEDIUM / HIGH, with the one fact that set it
2. **Complexity rating** LOW / MEDIUM / HIGH
3. **File classification**: which touched files are logic, security surface, structural, config, test, or docs
4. **Delegation plan**: which lanes from the table below should run, one clause of justification each
5. Its own findings, in the structured format below, tagged `router`

The router never spawns anything. It returns a plan; the main loop decides and dispatches.

## Step 3: Delegate the lanes the router earned

| Lane tag | Target | Model | Triggers when |
|---|---|---|---|
| `code` | `code-reviewer` agent | sonnet | Always. Logic defects, correctness, contracts |
| `security` | `security-reviewer` agent | opus | Diff touches auth, input handling, crypto, payments, PII, secrets, infrastructure, or destructive operations |
| `structure` | `structure-reviewer` agent | sonnet | Diff is a refactor, establishes a new module or boundary, or moves responsibilities across existing ones |
| `external` | Codex CLI | `gpt-5.6-sol`, effort `high` | Danger or complexity is HIGH. An independent frontier read of the same diff |
| `tiebreak` | Grok CLI | default | Two lanes disagree on whether a specific finding is real, and the disagreement blocks the verdict |

`code` always runs. Spawn every triggered lane in **one message, multiple calls**, so they run concurrently. `tiebreak` is the exception: it runs in Step 4, after a contradiction actually exists, and only on the contested findings.

Every delegation prompt carries, per the delegation contract in `~/.claude/ROUTING.md`:

- the repo path and the exact `REVIEW_CMD` (plus any `-- <paths>` scope restriction for this lane)
- what changed and why, in 2 to 4 sentences the agent cannot derive from the diff
- facts already verified live, so the lane does not re-flag settled ground
- the router's danger and complexity ratings and which files it classified into this lane
- the ask: real defects with a concrete failure scenario, severity-tagged, no nits
- the structured output requirement below, **appended to** the agent's own native output contract, not replacing it

Do not restate standing rules from AGENTS.md; every target already reads them.

## Reviewer output format

Every lane ends its response with:

```
STRUCTURED_FINDINGS:
- file: <path> | line: <number or "general"> | severity: <CRITICAL|HIGH|MEDIUM|LOW|NIT> | reviewer: <tag> | body: <finding text>
- file: ...

OVERALL_SUMMARY:
<one paragraph>
```

No findings:

```
STRUCTURED_FINDINGS:
(none)

OVERALL_SUMMARY:
<one paragraph>
```

**Tags** are `<lane>` or `<lane>/<category>` where the category is the finding's own lowercased, hyphenated kind: `security/idor`, `security/sql-injection`, `code/logic`, `structure/duplication`. Sub-tagging keeps each lane's taxonomy readable once findings converge; fall back to the flat lane tag when no category fits.

**`body`** is compact: what is wrong, the failure scenario, the fix, and a confidence clause when the lane could not fully verify it. One finding per line, pipes escaped or rephrased out of the body.

**NIT** exists only for lanes that produce style-tier observations. `security` never emits it.

## Step 4: Synthesize

Collect the router's findings and every delegated lane's findings.

**Lane death is blocking, for the three agent lanes.** `code`, `security`, or `structure` triggered and spawned, then erroring, returning empty, or producing no parseable `STRUCTURED_FINDINGS` block, is a failed review. Stop and report. Never fall through to a verdict on a dead lane.

`router`, `external`, and `tiebreak` are exempt at every stage, before or after dispatch: they run on an external CLI with its own quota, and none of them is ever the sole coverage for a concern. Their failure degrades, never blocks:

- Codex router unavailable: fall back down the tier ladder, then to a `sonnet` agent (Step 2)
- Codex `external` lane unavailable: run the review without it and say so in the report. If the router had routed a specific concern there, re-route that concern to `code` or `security`. If no lane can safely cover it, surface it as a HIGH finding naming the lane that was unavailable
- Grok `tiebreak` unavailable: leave the contested finding in the report as unresolved, with both lanes' positions stated, and let the carbon unit call it

**Deduplication.** Two findings merge when they name the same file within 5 lines of each other, or are clearly the same concern in different words. Merged findings carry the tag `convergent: <tag> + <tag>`. Convergence means independent lanes reached the same conclusion, so it promotes a finding's confidence: a merged finding is treated as confirmed even when one lane marked it low-confidence. Convergence does **not** by itself raise severity; keep the highest severity any lane assigned and say which lane assigned it.

**Contradiction.** One lane asserts a defect, another explicitly verified it as safe: that is a `tiebreak` case, not a merge. Run the Grok lane on those findings alone, with both positions in the prompt.

**Risk rollup.** The tier is the highest severity surviving in the deduplicated list, counting NIT as LOW:

| Tier | Verdict | Condition |
|---|---|---|
| CRITICAL | BLOCKED | any CRITICAL finding |
| HIGH | REQUEST CHANGES | any HIGH finding, no CRITICAL |
| MEDIUM | APPROVE WITH NITS | any MEDIUM finding, nothing above |
| LOW | APPROVE | only LOW, NIT, or nothing |

Highest-severity-wins, rather than a count-weighted score, because CRITICAL and HIGH are already blocking here as they are in `code-review`: fix upstream before commit, fix the source rather than the symptom, no ignore comments or disabled rules to clear a flag. A scheme where two HIGH findings block and one does not would contradict that gate. Report the count per severity in the summary, where it informs the carbon unit without moving the gate.

## Step 5: Report to terminal

The terminal report is the deliverable. Most runs are local code with no PR attached, and those runs end here.

```
## QA Swarm: <VERDICT> (risk <TIER>)
Target: <REVIEW_CMD>   Files: N   Lines: N
Router: danger <X>, complexity <Y>
Lanes: <tag> (<why>), <tag> (<why>)   Skipped: <tag> (<reason>)
Findings: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW, <n> NIT (after dedup)

### Findings
- path:line [SEVERITY] [<tag>] problem. fix.
(most severe first; convergent findings marked; omit section if none)

### Unresolved
(optional: contradictions the tiebreak lane could not settle)

### Recommendation
(one sentence)
```

## Step 6: Post to a PR

Only when a PR was detected, and only after asking. Posting is outward-facing and hard to retract, so ask on every run, even a re-run against a PR already commented on. No PR, or the carbon unit declines: Step 5 was the whole output.

PR comment bodies are written in normal prose for the humans reading them, per the AGENTS.md output boundary for issue and PR text.

### 6a: Inline comments

Post every finding that has a real file and line as one batched review, not one API call per comment:

`gh api -f` only sets flat string fields, so the comment array has to arrive as a real JSON body through `--input`. Build the body in a file, then post it:

```
cat > <body.json> <<'JSON'
{
  "event": "COMMENT",
  "body": "QA Swarm review complete. See inline comments.",
  "commit_id": "<HEAD_SHA>",
  "comments": [
    { "path": "<file>", "line": <line>, "side": "RIGHT", "body": "<comment body>" }
  ]
}
JSON
gh api repos/{owner}/{repo}/pulls/{pr}/reviews --method POST --input <body.json>
```

`side` is not optional in practice: it selects which half of the diff the line number indexes. A finding about an added line is `RIGHT`; a finding about a line the diff removes is `LEFT`, and its `line` is the number in the pre-change file. Carry that distinction through synthesis, because a `LEFT` finding posted as `RIGHT` either lands on unrelated code or is rejected outright. Apply it to the per-comment fallback below too.

Write that JSON with a script (`jq`, or `json.dumps` over the finding list), never by hand-splicing finding text into the template. Finding bodies contain quotes, backticks, and newlines, and a hand-built body will produce invalid JSON or a mangled comment.

Batching is not cosmetic: one review posts one notification, while N individual comments post N. If the batched call fails, fall back to `gh api repos/{owner}/{repo}/pulls/{pr}/comments` per finding and say in the report that the fallback was used.

Each inline body:

```
> [!NOTE]
> Automated comment by **QA Swarm**. Not written by a human.

**[<tag>] <SEVERITY>**

<body>
```

Convergent findings use `**[convergent: <tag> + <tag>] <SEVERITY>**` and the merged body.

### 6b: Summary comment, one per PR, upserted

Exactly one top-level summary comment per PR, marked `<!-- qa-swarm-summary -->`. Re-runs update it in place. Several bot comments on one PR is the noise this exists to prevent.

```
gh api "repos/{owner}/{repo}/issues/{pr}/comments" --paginate \
  --jq '[.[] | select(.body | contains("<!-- qa-swarm-summary -->"))][0].id'
```

Body shape, current verdict on top and prior rounds folded away:

```
<!-- qa-swarm-summary -->
> [!NOTE]
> Automated comment by **QA Swarm**. Not written by a human.
>
> Multi-perspective review: a router pass plus the reviewer lanes the change warranted.

## Verdict: <VERDICT> (round <N> at <short_sha>)

<1 to 2 sentences>

### Key findings
<top findings grouped by severity, current round only>

### Convergence
<findings two or more lanes reached independently, highest confidence>

### Lane summaries
| Lane | Assessment |
| --- | --- |
| router | <one sentence, plus danger and complexity, plus what it delegated> |
<one row per lane that actually ran this round>

<details>
<summary>Previous rounds (<n>)</summary>

round <N> at <short_sha> - <verdict>: <one-line disposition>

</details>
```

When updating, derive the history lines from the existing comment's own verdict header plus its existing history block. The previous round collapses to one line; it is never carried over verbatim.

```
gh api "repos/{owner}/{repo}/issues/comments/{id}" -X PATCH -F body=@<file>   # update
gh pr comment {pr} --body-file <file>                                        # create
```

Inline comments from 6a are untouched by the upsert. They are threaded, per-finding, and resolvable; only the top-level summary is deduplicated.

## Token discipline

- Floor is a router pass plus one `code` lane. Every extra lane is another full pass, and `security` is opus.
- Never paste diff text into a prompt. Hand over `REVIEW_CMD` and let the lane run git itself.
- Diffs over roughly 2000 changed lines: tell each lane to prioritize by risk within its scope. Do not answer size by adding lanes.
- The router exists to keep lanes off work they do not need. A plan that delegates everything every time means the router prompt is wrong.
