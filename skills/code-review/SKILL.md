---
name: code-review
description: Internal review engine. Pins a diff to an immutable object, calls qa-swarm to find defects, gives every finding one disposition, and returns a verdict plus a dispositioned findings block. Strictly read-only, so it never edits a file, never touches git history, never posts anywhere, and never re-runs itself. Invoked by /commit and /pr-review, never as a direct entry point.
---

# Code Review

One pass. Pin, find, triage, judge, return. Every cycle in the review ladder lives one layer above this skill.

## Contract with the caller

**Required input.** A target, in one of three forms: `staged`, `working` (a local tree), or a base and head ref (a branch or a pull request). Plus 2 to 4 sentences of context that the diff does not carry.

**Optional input.** A `-- <paths>` scope restriction, and the previous round's findings block plus the writer's receipt, so this pass can tell settled ground from ground that was supposedly repaired.

**Guaranteed output.** A `VERDICT` line, one `STRUCTURED_FINDINGS` block carrying a `disposition` field per finding, and one `OVERALL_SUMMARY`. Nothing after them.

**Never.** No file edits. No `git add`, `commit`, `push`, or branch operations. No PR comments (that is `/pr-review`). No second round: this skill has no opinion about whether it should run again, and a caller that wants another pass invokes it again with the previous findings in hand.

**Not a direct entry point.** Asked to review something conversationally, route it: local work goes through `/commit`, a pull request goes through `/pr-review`. Both call this skill with a proper target.

## Step 1: Pin the target

Pin to an immutable object, never a live tree. `qa-swarm` runs lanes concurrently for minutes, and `git diff --cached` re-reads the index on every call, so an edit or a `git add` mid-review silently hands later lanes a different diff.

- **staged**: `TREE=$(git write-tree)`, then `REVIEW_CMD="git diff HEAD $TREE"`. `write-tree` freezes the current index as a tree object without touching the index, the refs, or the stash stack

- **working**: snapshot through a throwaway index so the live one is never mutated. Never `git add -A` against the real index to set up a review; that stages whatever the carbon unit deliberately left unstaged, and the next commit quietly carries it

```
TMP_DIR=$(mktemp -d)
cp "$(git rev-parse --git-dir)/index" "$TMP_DIR/index"
GIT_INDEX_FILE="$TMP_DIR/index" git add -A
TREE=$(GIT_INDEX_FILE="$TMP_DIR/index" git write-tree)
rm -rf "$TMP_DIR"
REVIEW_CMD="git diff HEAD $TREE"
```

`mktemp -d` and not `mktemp -u`: the `-u` form only reserves a name, so another local process can land a symlink there first and have the `cp` overwrite its target.

- **branch or pull request**: resolve `BASE_SHA` and `HEAD_SHA`, then `REVIEW_CMD="git diff <BASE_SHA>..<HEAD_SHA>"`. Both are already immutable

Record the file count, the changed-line count, and the touched subsystems. Report the pin in the summary so the caller can prove which tree was judged.

## Step 2: Call qa-swarm

Invoke `/qa-swarm` with the pinned `REVIEW_CMD`, the repo path, the caller's context verbatim, any scope restriction, and any findings already dispositioned in an earlier round.

Do not spawn a reviewer agent directly from here. All finding goes through `qa-swarm`, so there is exactly one place that knows which lanes exist and when they trigger.

`qa-swarm` reporting a blocking lane death is a failed review. Return `VERDICT: FAILED` with whatever findings did arrive and a summary naming the dead lane. Never fall through to APPROVE on a dead lane, and never omit the `VERDICT` line: a caller parsing for it would hang or guess.

## Step 3: Triage

Every finding leaves this step with exactly one disposition. A finding with none is a bug in the run, not an acceptable outcome.

| Disposition | Assign when | What the caller does with it |
|---|---|---|
| `ACTIONABLE` | The defect is clear, the fix is bounded, and the finding was verified against real code | Hands it to a writer. The only disposition a writer ever sees |
| `NIT` | Style, preference, a duplicate of another finding, or plainly out of the change's scope | Records it. Never fixed, never blocks |
| `AMBIGUOUS` | Contested between lanes, cross-cutting enough that the fix is a design decision, or the intent behind the code is unclear | Stops and asks the carbon unit, with both readings stated |

Rules that decide the hard cases:

- A finding whose `body` carries `Confidence: low` is never `ACTIONABLE`. It is `AMBIGUOUS` if it would block, `NIT` if it would not.
- A `convergent:` finding is `ACTIONABLE` if its fix is bounded, even when one contributing lane was low-confidence. Independent agreement is what clears the confidence bar.
- A CRITICAL or HIGH finding is never `NIT`. If it cannot be `ACTIONABLE`, it is `AMBIGUOUS`.
- Severity and disposition are independent axes. A LOW finding with an obvious one-line fix is `ACTIONABLE`; a CRITICAL one needing an architecture call is `AMBIGUOUS`.

Carried-in findings are handled by disposition, not uniformly:

- Previously `NIT`: suppressed. It keeps that disposition unless the new round raises its severity.
- Previously `AMBIGUOUS`, with no answer from the carbon unit: suppressed, still `AMBIGUOUS`. Asking twice for the same answer is noise.
- Previously `AMBIGUOUS`, with an answer supplied by the caller: **re-dispositioned by the answer**, `ACTIONABLE` when the answer says fix it, `NIT` when the answer says leave it. `AMBIGUOUS` is the only disposition with no way out of its own accord, so a caller that supplies an answer must see it consumed; leaving it `AMBIGUOUS` makes the caller's loop ask forever.
- Previously `ACTIONABLE`, whatever the writer's receipt says: **never suppressed**. A `FIXED` receipt is a claim, not a verification, and this pass is the verification. If the same finding comes back, the fix did not work, and it stays `ACTIONABLE` with that fact in its body. A `DECLINED` receipt makes it `AMBIGUOUS`, because the writer already refused it once and a second identical attempt will refuse again.

## Step 4: Verdict

The tier is the highest severity still standing after triage and dedup, counting `NIT` as `LOW`:

| Highest severity | Verdict |
|---|---|
| CRITICAL | `BLOCKED` |
| HIGH | `REQUEST CHANGES` |
| MEDIUM | `APPROVE WITH NITS` |
| LOW, NIT, or nothing | `APPROVE` |

Highest-severity-wins rather than a count-weighted score, because CRITICAL and HIGH block outright; a scheme where two HIGH findings block and one does not would contradict that. Counts go in the summary, where they inform without moving the gate.

A fifth value, `FAILED`, means the review could not be completed: `qa-swarm` reported a blocking lane death, or the target could not be pinned. It is not a judgement about the code and never means APPROVE. A caller treats it exactly as it treats `BLOCKED`, except that re-running is worth trying once because the cause is usually a dead process rather than a defect.

**The verdict is not the loop's exit condition.** A LOW or MEDIUM finding dispositioned `ACTIONABLE` is a verified defect with a bounded fix, and it maps to a passing verdict; a caller that exits on the verdict alone would commit it unfixed. State both facts on their own line in the summary: the verdict, and the count of surviving `ACTIONABLE` findings. Callers that loop gate on the second one.

## Step 5: Return

```
VERDICT: <APPROVE|APPROVE WITH NITS|REQUEST CHANGES|BLOCKED|FAILED>
ACTIONABLE: <count>

STRUCTURED_FINDINGS:
- file: <path> | line: <number or "general"> | side: <RIGHT|LEFT> | severity: <CRITICAL|HIGH|MEDIUM|LOW|NIT> | reviewer: <tag> | disposition: <ACTIONABLE|NIT|AMBIGUOUS> | body: <the review comment text>

OVERALL_SUMMARY:
<one paragraph>
```

Nothing found:

```
VERDICT: APPROVE
ACTIONABLE: 0

STRUCTURED_FINDINGS:
(none)

OVERALL_SUMMARY:
<one paragraph>
```

`VERDICT` and `ACTIONABLE` come first so a caller can gate on two lines without parsing the block. A looping caller gates on `ACTIONABLE`; a landing caller gates on `VERDICT`; both are needed because they can disagree.

The summary states: the pinned tree or SHA range, file and line counts, which lanes ran and which degraded, the count per severity, and the count per disposition. Then stop. No recommendation about what to do next, and no offer to fix anything.

## Token discipline

This is the deliberately expensive layer, but expense should land on lanes rather than on this skill's own reasoning. Everything here is bookkeeping over a block `qa-swarm` already produced: pinning, one classification per finding, one table lookup. Re-reading the diff to second-guess a lane means the lane prompt was wrong.
