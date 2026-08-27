---
name: release
description: Execute a versioned release for the current repo using its .claude/release-profile.json (deriving and saving that profile on first run). Preflight gates, changelog freeze, version bump, archetype-specific publish (tag-CI, workflow-dispatch, local script, or push-deploy), and evidence-based verification. Use when asked to release, ship, publish, cut a version, or bump and tag.
---

# Release

Profile-driven release runbook. All repo-specific knowledge lives in one tracked file per repo: `.claude/release-profile.json`. This skill never invents missing facts: a required field that is absent or contradicts the repo state stops the release.

The profile checks below are read and applied by you, not by a program: the Python linter that used to enforce them was deleted with the rest of the Python in this repo, and no replacement has landed. Treat every check as blocking anyway.

## Phase 0 — Load or derive the profile

1. Read `.claude/release-profile.json` in the repo root.
2. Check it against the schema below (required fields present, `type` and `publish.trigger` from their enums) and against the repo: version file exists and parses, changelog path exists (unless `status: MISSING`), branches exist, referenced workflow files and npm scripts exist, tag prefix consistent. Any failure = stop, show it, fix profile or repo first.
3. **Present**: beyond the schema check, sanity-check judgment fields against reality (does the release-commit pattern match `git log` history, does the trigger archetype match how past releases actually shipped). Contradiction = stop, show the mismatch, ask whether to fix the profile or the repo.
4. **Absent**: derive it by surveying the repo (branches and their roles, CI workflows and triggers, version source file, changelog file and format, tag format and release-commit pattern from `git log`/`git tag`, deploy/publish mechanism, verification surfaces). Start from the schema below, write the profile, re-run the step 2 checks against it, show it to the user for review, and include it in the release commit. Never guess a field you could not evidence; leave it out and say so.
5. The repo's own CLAUDE.md overrides everything (e.g. "releases run only through CI: dispatch and monitor, never build locally").
6. **Live state beats cached notes.** Any profile field describing mutable remote state (a CI/CD variable, a store track, a feature switch) must carry the command that reads it live (convention: a `*_live_check` key). Run that command and act on the live value; a stale note about a release-gating switch is a safety bug, not a doc nit.

### Profile schema

```json
{
  "type": "flutter_play | npm_cli | astro_convex_netlify | electron_nsis | other",
  "targets": [{ "name": "", "paths": [], "trigger": "", "runbook": "" }],
  "versioning": {
    "scheme": "semver",
    "version_file": "package.json",
    "tag_format": "vX.Y.Z",
    "build_number": { "field": "", "monotonic": true, "never_reuse": true }
  },
  "changelog": {
    "path": "CHANGELOG.md",
    "format": "keep_a_changelog",
    "store_notes": { "path": "", "char_cap": 500 }
  },
  "git": {
    "release_from": "main",
    "integration": "develop",
    "release_commit_pattern": "chore(release): vX.Y.Z",
    "require": ["clean_tree", "ff_promotion", "ci_green_on_sha"]
  },
  "gates": { "pre_tag": [], "post_release": [], "evidence": [] },
  "publish": {
    "trigger": "tag_push | workflow_dispatch | local_script | push_to_main",
    "detail": {}
  },
  "rollback": {
    "steps": [],
    "never": ["unpublish", "retag", "reuse_version_or_build_number"]
  },
  "approval": { "human_before": ["tag_push", "publish", "store_promotion"] }
}
```

- `targets` is optional and for multi-surface repos only. The skill diffs each target's paths since the last release and orchestrates or explicitly flags EVERY touched target; never silently ship only one surface.
- `versioning.scheme`: pre-1.0, minor means features and patch means fixes; 1.0 is reserved for the first public release. `version_file` is the single source of truth (`pubspec.yaml` for Flutter). `tag_format` is an annotated tag on the exact release commit. `build_number` is store types only.
- `changelog.format` `keep_a_changelog` means drafted from conventional commits since the last tag, then polished by hand. `store_notes` is the per-build note path and its character cap (Play caps at 500).
- `git.integration` is omitted for trunk-based repos. `release_commit_pattern` is the repo's exact historical pattern, read from `git log`.
- `gates.pre_tag` and `gates.post_release` hold the repo's real commands (test, typecheck, e2e, pack --dry-run). `gates.evidence` names what proves success: `git_tag`, `ci_run_url`, `registry_version`, `play_track_presence`, `netlify_deploy_id`, `update_feed_yml`, `live_site_check`.
- `publish.detail` is archetype-specific: workflow file, script name, track, site, or feed.
- `rollback.steps` are exact commands or console actions, forward-fix first.

## Phase 1 — Preflight (every release)

Stop on any failure; fix upstream, never bypass.

0. Re-run the Phase 0 step 2 checks, plus: HEAD is not detached, and the tag this release would create does not exist yet.
1. Working tree clean; on a branch the profile allows (integration or release_from; starting from the integration branch is legitimate, so this one warns rather than blocks).
2. Integration and release branches synced (fetch both; report divergence, do not force).
3. CI green on the tip commit (`gh run list --branch <branch> --limit 1`) when the repo has CI. This is enforced, not advisory: red = pull the failure (`gh run view <id> --log-failed`), report it, and **block** — tagging into a red pipeline fires the expensive release job into the same failure.
4. Run the profile's `gates.pre_tag` commands **locally** (lint, typecheck, tests). Listing them in the profile is not running them; local execution catches what a divergent CI environment (line endings, platform deps) would only surface after the push.
5. Multi-target repos (`targets` in the profile): diff the paths since the last release tag and list which targets this release touches. Every touched target gets shipped or explicitly deferred with the user's sign-off; silence is not an option.
6. Version sanity: `version_file` value vs latest tag; the new version must be a valid increment and never reuse a tag or build number.
7. Changelog `[Unreleased]` has content. Empty: draft it from conventional commits since the last tag, show for polish, never release an empty section. `status: MISSING`: backfill a Keep-a-Changelog file from existing tags + `git log` before this release ships, then drop the MISSING marker.

## Phase 2 — Prepare

1. Freeze `[Unreleased]` into `## [X.Y.Z] - YYYY-MM-DD` per the repo's format; generate store notes when the profile defines them (respect caps).
2. Bump `version_file` (and lockfile when the ecosystem pairs them).
3. Commit using the repo's exact `release_commit_pattern`. Nothing else rides in the release commit except a newly derived profile on first run.

## Phase 3 — Execute, by archetype

**Human approval before every irreversible step** (push, tag push, publish, store promotion). Present what will run and wait.

- `tag_push` (CI releases on tag, e.g. Electron/NSIS or store upload): promote integration to release branch ff-only, land the bump commit on the release branch, **verify the target tag does not already exist** (`git tag --list <tag>` must be empty; the preflight tag check ran pre-bump and only covered the previous version), create the **annotated tag on that exact commit**, push branch then tag, then `gh run watch` the release workflow to completion. **Unsigned-build feed stop:** when a live auto-update feed is enabled (live-checked, never assumed) and builds are unsigned, the tag push auto-updates real users to an unsigned build; require explicit human confirmation that names exactly that consequence before pushing the tag.
- `workflow_dispatch` (repo owns its release workflow): `gh workflow run <workflow>` with the profile's inputs, monitor the produced PR/run, confirm the downstream tag and release workflow complete. Do not replicate the workflow's steps locally.
- `local_script` (e.g. npm publish script): run the repo's script only after commits are in place; afterwards sync the release branch so it does not drift behind; confirm registry state, never re-run a partially failed publish without checking what landed.
- `push_to_main` (host deploys on push, tag is metadata): merge the integration branch into the deploy branch first when the release content lives there, land the bump commit on the deploy branch, tag it, push, then watch the host deploy. If the host reports nothing headless (no CI status, no CLI token — Netlify posts nothing to GitHub by default), verify with a **live-site content marker**: a class name or string literal introduced by this release, grepped from the served CSS/JS bundles. After release, sync the integration branch back per the repo's flow.

## Phase 4 — Verify and report

1. Run every `gates.post_release` command; collect every `gates.evidence` item.
2. "Released" means the evidence bundle is complete: tag exists and points at the release commit, CI run green (when CI), artifact observable where users get it (registry version, store track, live site, update feed).
3. Report: version, evidence list with values, anything skipped and why, and the profile's rollback steps verbatim (the moment you need them is the wrong time to derive them).

## Failure and rollback posture

- Forward-fix first: a broken release gets a new patch version, never a reused or retagged one.
- npm: `npm deprecate` the bad version and point `latest` back; never unpublish.
- Play: halt the staged rollout, fix, ship next build number; staged rollout defaults 10 -> 50 -> 100 when the profile enables it.
- Netlify: lock auto-publish, publish the previous deploy, fix forward.
- Electron feed: pull/point the feed at the prior installer only if the app is unusable; otherwise forward-fix; never reuse a version the updater has seen.
- A release that fails mid-flight: report exactly which phase and step, what is already irreversible (pushed tag? published package?), and the safe continuation. Never retry blind.

## Usage

- `/release` — full flow for the current repo
- `/release --dry-run` — phases 0-2 plus a printed execution plan; nothing pushed, tagged, or published
- `/release --profile-only` - derive/refresh `.claude/release-profile.json` and stop
