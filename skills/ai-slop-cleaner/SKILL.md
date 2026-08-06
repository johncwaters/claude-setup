---
name: ai-slop-cleaner
description: Clean AI-generated code slop with a regression-safe, deletion-first workflow. Use when the user says deslop, anti-slop, or AI slop, or asks to clean up code that feels bloated, repetitive, over-abstracted, or weakly tested. Bounded cleanup, not feature work. Supports a reviewer-only pass via --review.
---

# AI Slop Cleaner

Clean AI-generated code slop without drifting scope or changing intended behavior. This is the bounded cleanup workflow for code that works but feels bloated, repetitive, weakly tested, or over-abstracted.

## When to Use

- The user explicitly says `deslop`, `anti-slop`, or `AI slop`
- The request is to clean up or refactor code that feels noisy, repetitive, or overly abstract
- Follow-up implementation left duplicate logic, dead code, wrapper layers, boundary leaks, or weak regression coverage
- The user wants a reviewer-only anti-slop pass via `--review`
- The goal is simplification and cleanup, not new feature delivery
- The /commit workflow invokes it as its mandatory pre-review cleanup pass

## When Not to Use

- The task is mainly a new feature build or product change
- The user wants a broad redesign instead of an incremental cleanup pass
- The request is a generic refactor with no simplification or anti-slop intent
- Behavior is too unclear to protect with tests or a concrete verification plan

## Execution Posture

- Preserve behavior unless the user explicitly asks for behavior changes.
- Lock behavior with focused regression tests first whenever practical.
- Write a cleanup plan before editing code.
- Prefer deletion over addition.
- Reuse existing utilities and patterns before introducing new ones.
- Avoid new dependencies unless the user explicitly requests them.
- Keep diffs small, reversible, and smell-focused.
- Stay concise and evidence-dense: inspect, edit, verify, and report.
- Treat new user instructions as local scope updates without dropping earlier non-conflicting constraints.

## Scoped File-List Usage

The pass can be bounded to an explicit file list or changed-file scope when the caller already knows the safe cleanup surface (for example, the files changed in the current commit).

- Good fit: `/ai-slop-cleaner src/auth/session.ts src/auth/token.ts`
- Good fit: the /commit workflow handing off only the files staged for that commit
- Preserve the same regression-safe workflow even when the scope is a short file list
- Do not silently expand a changed-file scope into broader cleanup work unless the user explicitly asks for it

## Review Mode (`--review`)

`--review` is a reviewer-only pass after cleanup work is drafted. It preserves explicit writer/reviewer separation for anti-slop work.

- **Writer pass**: make the cleanup changes with behavior locked by tests.
- **Reviewer pass**: inspect the cleanup plan, changed files, and verification evidence.
- The same pass must not both write and self-approve high-impact cleanup without a separate review step.

In review mode:
1. Do **not** start by editing files.
2. Review the cleanup plan, changed files, and regression coverage.
3. Check specifically for:
   - leftover dead code or unused exports
   - duplicate logic that should have been consolidated
   - needless wrappers or abstractions that still blur boundaries
   - missing tests or weak verification for preserved behavior
   - cleanup that appears to have changed behavior without intent
4. Produce a reviewer verdict with required follow-ups.
5. Hand needed changes back to a separate writer pass instead of fixing and approving in one step.

## Workflow

1. **Protect current behavior first**
   - Identify what must stay the same.
   - Add or run the narrowest regression tests needed before editing.
   - If tests cannot come first, record the verification plan explicitly before touching code.

2. **Write a cleanup plan before code**
   - Bound the pass to the requested files or feature area.
   - List the concrete smells to remove.
   - Order the work from safest deletion to riskier consolidation.

3. **Classify the slop before editing**
   - **Duplication**: repeated logic, copy-paste branches, redundant helpers
   - **Dead code**: unused code, unreachable branches, stale flags, debug leftovers
   - **Needless abstraction**: pass-through wrappers, speculative indirection, single-use helper layers
   - **Boundary violations**: hidden coupling, misplaced responsibilities, wrong-layer imports or side effects
   - **Missing tests**: behavior not locked, weak regression coverage, edge-case gaps
   - **UI/design defaults**: generic visual patterns that make an AI-built interface feel unreviewed

### UI/Design Reviewer Checklist

Use these as review prompts, not absolute bans. Keep intentional brand, accessibility, product-density, or design-system choices when they have a clear rationale.

- **Small body text:** flag body copy set around 11-12px; body text generally needs at least 14px unless a validated dense-data exception applies.
- **Shadow restraint:** question box shadows on every surface, logo, background, card, or icon; keep shadows only where they clarify elevation or interaction.
- **Content hierarchy:** remove repetitive eyebrow/title/description/extra `<p>` stuffing when the title already carries the message; avoid generic emoji badges unless they are part of the product voice.
- **Palette rationale:** challenge default AI blue/purple palettes, especially Tailwind-like `#3B82F6`, when no brand or system rationale exists.
- **Layout rhythm:** avoid overly perfect 3- or 4-column uniform grids when the product context benefits from rhythm, emphasis, asymmetry, or varied card weights.
- **Gradient restraint:** tone down extreme gradients unless the brand deliberately owns that visual language.

4. **Run one smell-focused pass at a time**
   - **Pass 1: Dead code deletion**
   - **Pass 2: Duplicate removal**
   - **Pass 3: Naming and error-handling cleanup**
   - **Pass 4: Test reinforcement**
   - Re-run targeted verification after each pass.
   - Do not bundle unrelated refactors into the same edit set.

5. **Run the quality gates**
   - Keep regression tests green.
   - Run the relevant lint, typecheck, and unit/integration tests for the touched area.
   - Run existing static or security checks when available.
   - If a gate fails, fix the issue or back out the risky cleanup instead of forcing it through. Never silence a gate with ignore comments, disabled rules, or skipped tests.

6. **Close with an evidence-dense report**
   Always report:
   - **Changed files**
   - **Simplifications**
   - **Behavior lock / verification run**
   - **Remaining risks**

## Usage

- `/ai-slop-cleaner <target>`
- `/ai-slop-cleaner <target> --review`
- `/ai-slop-cleaner <file-a> <file-b> <file-c>`
- From /commit: run on the commit's changed files only, then return to the commit workflow for review

## Good Fits

**Good:** `deslop this module: too many wrappers, duplicate helpers, and dead code`

**Good:** `cleanup the AI slop in src/auth and tighten boundaries without changing behavior`

**Bad:** `refactor auth to support SSO`

**Bad:** `clean up formatting`
