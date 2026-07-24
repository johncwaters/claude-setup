---
name: release
description: Execute a versioned release for the current repo using its .claude/release-profile.yml (deriving and saving that profile on first run). Preflight gates, changelog freeze, version bump, archetype-specific publish (tag-CI, workflow-dispatch, local script, or push-deploy), and evidence-based verification. Use when asked to release, ship, publish, cut a version, or bump and tag.
---

# Release

Profile-driven release runbook. All repo-specific knowledge lives in one tracked file per repo: `.claude/release-profile.yml` (reference template: `profile-template.yml` next to this skill). This skill never invents missing facts: a required field that is absent or contradicts the repo state stops the release.

Deterministic checks run through the bundled linter, never through AI judgment:

```
python <skill-dir>/lint-profile.py <repo-root>              # schema + profile-vs-repo cross-checks
python <skill-dir>/lint-profile.py <repo-root> --preflight  # adds clean-tree, detached-HEAD, branch, tag-exists checks
```

The linter validates schema (required fields, trigger/type enums), and cross-checks the repo: version file exists and parses, changelog path exists (unless `status: MISSING`), branches exist, referenced workflow files and npm scripts exist, tag-prefix consistency. Exit 1 = do not proceed.

## Phase 0 — Load or derive the profile

1. Read `.claude/release-profile.yml` in the repo root.
2. Run the linter. Errors = stop, show them, fix profile or repo first.
3. **Present**: beyond the linter, sanity-check judgment fields against reality (does the release-commit pattern match `git log` history, does the trigger archetype match how past releases actually shipped). Contradiction = stop, show the mismatch, ask whether to fix the profile or the repo.
4. **Absent**: derive it by surveying the repo (branches and their roles, CI workflows and triggers, version source file, changelog file and format, tag format and release-commit pattern from `git log`/`git tag`, deploy/publish mechanism, verification surfaces). Start from `profile-template.yml`, write the profile, run the linter on it, show it to the user for review, and include it in the release commit. Never guess a field you could not evidence; leave it out and say so.
5. The repo's own CLAUDE.md overrides everything (e.g. "releases run only through CI: dispatch and monitor, never build locally").

### Profile schema

```yaml
type: flutter_play | npm_cli | astro_convex_netlify | electron_nsis | other
versioning:
  scheme: semver              # pre-1.0: minor = features, patch = fixes; 1.0 reserved for first public release
  version_file: package.json  # or pubspec.yaml; single source of truth
  tag_format: vX.Y.Z          # annotated tag, created on the exact release commit
  build_number: optional      # store types only: field, monotonic: true, never_reuse: true
changelog:
  path: CHANGELOG.md
  format: keep_a_changelog    # draft from conventional commits since last tag, then human-polish
  store_notes: optional       # e.g. Play per-build note path + 500-char cap
git:
  release_from: main          # branch releases ship from
  integration: develop        # branch work lands on; omit if trunk-based
  release_commit_pattern: "chore(release): vX.Y.Z"   # the repo's exact historical pattern
  require: [clean_tree, ff_promotion, ci_green_on_sha]
gates:
  pre_tag: []                 # repo's real commands: test, typecheck, e2e, pack --dry-run
  post_release: []            # evidence commands run after publish
  evidence: []                # what proves success: git_tag, ci_run_url, registry_version,
                              # play_track_presence, netlify_deploy_id, update_feed_yml, live_site_check
publish:
  trigger: tag_push | workflow_dispatch | local_script | push_to_main
  detail: {}                  # archetype-specific: workflow file, script name, track, site, feed
rollback:
  steps: []                   # exact commands or console actions, forward-fix first
  never: [unpublish, retag, reuse_version_or_build_number]
approval:
  human_before: [tag_push, publish, store_promotion]
```

## Phase 1 — Preflight (every release)

Stop on any failure; fix upstream, never bypass.

0. `python <skill-dir>/lint-profile.py <repo-root> --preflight` — deterministic gate before any judgment steps.
1. Working tree clean; on a branch the profile allows (integration or release_from; the linter warns rather than blocks here since releases legitimately start from the integration branch).
2. Integration and release branches synced (fetch both; report divergence, do not force).
3. CI green on the tip commit (`gh run list --branch <branch> --limit 1`) when the repo has CI.
4. Version sanity: `version_file` value vs latest tag; the new version must be a valid increment and never reuse a tag or build number.
5. Changelog `[Unreleased]` has content. Empty: draft it from conventional commits since the last tag, show for polish, never release an empty section.

## Phase 2 — Prepare

1. Freeze `[Unreleased]` into `## [X.Y.Z] - YYYY-MM-DD` per the repo's format; generate store notes when the profile defines them (respect caps).
2. Bump `version_file` (and lockfile when the ecosystem pairs them).
3. Commit using the repo's exact `release_commit_pattern`. Nothing else rides in the release commit except a newly derived profile on first run.

## Phase 3 — Execute, by archetype

**Human approval before every irreversible step** (push, tag push, publish, store promotion). Present what will run and wait.

- `tag_push` (CI releases on tag, e.g. Electron/NSIS or store upload): promote integration to release branch ff-only, land the bump commit on the release branch, **verify the target tag does not already exist** (`git tag --list <tag>` must be empty; the preflight tag check ran pre-bump and only covered the previous version), create the **annotated tag on that exact commit**, push branch then tag, then `gh run watch` the release workflow to completion.
- `workflow_dispatch` (repo owns its release workflow): `gh workflow run <workflow>` with the profile's inputs, monitor the produced PR/run, confirm the downstream tag and release workflow complete. Do not replicate the workflow's steps locally.
- `local_script` (e.g. npm publish script): run the repo's script only after commits are in place; afterwards sync the release branch so it does not drift behind; confirm registry state, never re-run a partially failed publish without checking what landed.
- `push_to_main` (host deploys on push, tag is metadata): land the bump commit on the deploy branch, tag it, push, then watch the host deploy (deploy log or live-site check).

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
- `/release --profile-only` — derive/refresh `.claude/release-profile.yml` and stop
