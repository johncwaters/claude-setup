# Personal machine migration: adopt machine profiles

Audience: an AI agent (Claude Code) running on one of the owner's personal machines, where `~/.claude` is this repo's checkout on `master`. This is a one-time migration per personal machine. The work PC is already migrated and runs the `machine-profiles` branch.

## Context

Branch `machine-profiles` (commits `c0c49b6`, `7447fc2`) restructured this repo:

- `CLAUDE.md`, `settings.json`, and `commands/commit.md` are no longer tracked. `setup/apply.ps1` renders them from `profiles/<profile>/` (the markdown files are copied; `settings.json` is deep-merged from `settings.base.json` plus the profile overlay by `setup/render-settings.mjs`, with `{{HOME}}` substituted for the machine home path).
- Each machine declares its profile once in an untracked `.machine-profile` marker at the repo root. Profiles: `personal` (full behavior, identical to before) and `work` (workflow only).
- Extension sync direction is per profile: `personal` stays exact (uninstalls extras), `work` is additive.

The design guarantee for this machine: the `personal` profile is a behavior no-op. Your job is to prove that, then merge the branch to `master`.

## Preconditions (stop and report if any fail)

1. `git -C $env:USERPROFILE\.claude status --porcelain` shows no modified tracked files (untracked local state is fine).
2. Current branch is `master` and `git -C $env:USERPROFILE\.claude pull --ff-only` succeeds.
3. `node --version` works (needed by the settings renderer).

## Step 1: snapshot the current rendered surface

Copy these three files to a temp directory before touching anything. They are the baseline for the exit test:

```powershell
$snap = Join-Path $env:TEMP "profile-migration-snapshot"
New-Item -ItemType Directory -Force $snap | Out-Null
Copy-Item "$env:USERPROFILE\.claude\CLAUDE.md" $snap
Copy-Item "$env:USERPROFILE\.claude\settings.json" $snap
Copy-Item "$env:USERPROFILE\.claude\commands\commit.md" $snap
```

## Step 2: check out the branch and apply

```powershell
git -C $env:USERPROFILE\.claude fetch origin
git -C $env:USERPROFILE\.claude checkout -B machine-profiles origin/machine-profiles
powershell -NoProfile -File $env:USERPROFILE\.claude\setup\apply.ps1 -Profile personal
```

Expected and normal: the checkout deletes the three formerly tracked files from the working tree (they left the index); apply immediately re-renders all three and writes the `.machine-profile` marker. Because the files were deleted at render time, no `*.pre-profile.bak` backups appear; the snapshot from step 1 is the safety copy. The apply summary must end with `0 warnings`.

## Step 3: exit test (the point of this migration)

All three comparisons must pass. Do not rationalize a diff away; a mismatch means stop, restore per Rollback, and report the diff verbatim.

```powershell
$snap = Join-Path $env:TEMP "profile-migration-snapshot"
fc.exe /b "$snap\CLAUDE.md" "$env:USERPROFILE\.claude\CLAUDE.md"
fc.exe /b "$env:USERPROFILE\.claude\profiles\personal\commit.md" "$env:USERPROFILE\.claude\commands\commit.md"
```

Both must report no differences. `CLAUDE.md` is compared against the snapshot byte for byte. `commit.md` is compared against its profile source instead of the snapshot because the branch intentionally added a frontmatter `description` block to the command after the pre-migration baseline; against the snapshot, that leading frontmatter block is the only acceptable difference, and any other diff fails the test. `settings.json` is compared semantically because key order changes:

```powershell
node -e "const f=require('fs');const eq=(a,b)=>{if(typeof a!==typeof b)return false;if(a===null||typeof a!=='object')return a===b;const ka=Object.keys(a).sort(),kb=Object.keys(b).sort();if(JSON.stringify(ka)!==JSON.stringify(kb))return false;return ka.every(k=>eq(a[k],b[k]))};const s=JSON.parse(f.readFileSync(process.env.TEMP+'/profile-migration-snapshot/settings.json','utf8'));const r=JSON.parse(f.readFileSync(process.env.USERPROFILE+'/.claude/settings.json','utf8'));console.log(eq(s,r)?'settings MATCH':'settings DIFFER')"
```

Then confirm the machine still guards writes (expect a JSON deny decision, not silence):

```powershell
echo '{"tool_name":"Write","tool_input":{"file_path":"x.json","content":"{bad}"}}' | node "$env:USERPROFILE\.claude\hooks\validate-file.mjs"
```

Finally rerun apply once more; it must be a pure no-op (`up to date` everywhere, nothing updated or installed, 0 warnings).

## Step 4: merge to master and push

Only after every exit-test check passed:

```powershell
git -C $env:USERPROFILE\.claude checkout master
git -C $env:USERPROFILE\.claude merge --ff-only machine-profiles
git -C $env:USERPROFILE\.claude push origin master
```

If the merge is not a fast-forward, stop and report; do not force or resolve silently. Stay on `master` afterward. Leave the `machine-profiles` branch on the remote; the work PC still tracks it until it is switched over (that step happens on the work PC, not here: `git checkout master` there after this merge lands).

## Step 5: report

Report: each step's outcome, the three exit-test results, the apply summary line, and the merge commit. If anything was skipped or failed, say so explicitly.

## Rollback (only if the exit test fails)

```powershell
git -C $env:USERPROFILE\.claude checkout -f master
Remove-Item "$env:USERPROFILE\.claude\.machine-profile" -Force -ErrorAction SilentlyContinue
powershell -NoProfile -File $env:USERPROFILE\.claude\setup\apply.ps1 -SkipInstalls
```

Checkout of `master` restores the three tracked originals. Verify they match the step 1 snapshot, then report the exit-test diff that triggered the rollback.

## Other personal machines, after the merge

Later personal machines need no exit test; the branch is already proven and merged. Run once:

```powershell
powershell -File $env:USERPROFILE\.claude\setup\install.ps1 -Profile personal
```

## Cleanup

Once every machine (including the work PC) is on `master` with a marker file in place, delete this document and commit the removal.
