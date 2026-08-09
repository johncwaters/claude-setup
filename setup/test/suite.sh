#!/usr/bin/env bash
# Acceptance suite for the Linux bootstrap scripts. Destructive by design: it
# writes to $HOME, installs system packages, and clones repos, so it must only
# ever run inside the throwaway container built by run-docker.sh.
#
# SUITE_MODE=fast  config, flags, idempotency, collect round trip (no installs)
# SUITE_MODE=full  everything above plus the install steps and the real hook run

set -uo pipefail

suiteMode="${SUITE_MODE:-fast}"
originRepo="/tmp/origin.git"
passCount=0
failCount=0

pass() {
  passCount=$((passCount + 1))
  printf '  PASS  %s\n' "$1"
}

fail() {
  failCount=$((failCount + 1))
  printf '  FAIL  %s\n' "$1"
}

phase() {
  printf '\n=== %s ===\n' "$1"
}

assertOk() {
  local label="$1"
  local status="$2"
  if ((status == 0)); then
    pass "$label"
    return 0
  fi
  fail "$label (exit $status)"
}

assertStatus() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if ((expected == actual)); then
    pass "$label"
    return 0
  fi
  fail "$label (expected exit $expected, got $actual)"
}

assertFile() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
    return 0
  fi
  fail "$label (missing $path)"
}

assertNoFile() {
  local label="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$label"
    return 0
  fi
  fail "$label (unexpected $path)"
}

assertDir() {
  local label="$1"
  local path="$2"
  if [[ -d "$path" ]]; then
    pass "$label"
    return 0
  fi
  fail "$label (missing dir $path)"
}

assertMinimum() {
  local label="$1"
  local minimum="$2"
  local actual="$3"
  if [[ "$actual" =~ ^[0-9]+$ ]] && ((actual >= minimum)); then
    pass "$label"
    return 0
  fi
  fail "$label (expected at least $minimum, got '${actual:-none}')"
}

assertEquals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
    return 0
  fi
  fail "$label (expected '$expected', got '$actual')"
}

assertMatch() {
  local label="$1"
  local pattern="$2"
  local text="$3"
  if grep -Eq -- "$pattern" <<<"$text"; then
    pass "$label"
    return 0
  fi
  fail "$label (no match for /$pattern/)"
}

assertNoMatch() {
  local label="$1"
  local pattern="$2"
  local text="$3"
  if ! grep -Eq -- "$pattern" <<<"$text"; then
    pass "$label"
    return 0
  fi
  fail "$label (unexpected match for /$pattern/)"
}

stripColor() {
  sed 's/\x1b\[[0-9;]*m//g'
}

isSuiteRoot() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

runSuiteRootCommand() {
  if isSuiteRoot; then
    "$@"
    return $?
  fi
  sudo "$@"
}

hashTree() {
  local root="$1"
  local relativePath
  find "$root" -type f -printf '%P\n' 2>/dev/null | sort | while IFS= read -r relativePath; do
    printf '%s %s\n' "$(md5sum < "$root/$relativePath" | cut -d' ' -f1)" "$relativePath"
  done | md5sum | cut -d' ' -f1
}

installNodeForRender() {
  if command -v node >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    runSuiteRootCommand apt-get update -qq >/dev/null 2>&1
    runSuiteRootCommand apt-get install -y -qq nodejs >/dev/null 2>&1
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    runSuiteRootCommand dnf -y -q install nodejs >/dev/null 2>&1
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    runSuiteRootCommand pacman -Sy --noconfirm --needed nodejs npm >/dev/null 2>&1
    return 0
  fi
}

assertRenderedSettings() {
  local settingsPath="$1"
  assertFile "renders settings.json" "$settingsPath"
  local rendered
  rendered="$(cat "$settingsPath" 2>/dev/null)"
  assertNoMatch "substitutes every HOME token" '\{\{HOME\}\}' "$rendered"
  assertMatch "substitutes the real home directory" "$HOME/.claude" "$rendered"
  assertMatch "renders parseable JSON" "^\{" "$rendered"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$settingsPath" 2>/dev/null
  assertOk "settings.json parses as JSON" $?
}

bootstrapCheckout() {
  local target="$1"
  mkdir -p "$target"
  git -C "$target" init -q -b master
  git -C "$target" config remote.origin.url "$originRepo"
  git -C "$target" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$target" fetch -q origin
  git -C "$target" checkout -q -f -B master origin/master
}

jsonField() {
  local path="$1"
  local expression="$2"
  node -e "const config = require(process.argv[1]); console.log($expression);" "$path"
}

prepareGlissaServerFixture() {
  local fixtureHome="$1"
  local fixtureBin="$2"
  mkdir -p "$fixtureHome" "$fixtureBin" "$fixtureHome/Projects/glissa/.git" "$fixtureHome/Projects/glissa/bin" "$fixtureHome/.npm-global/lib/node_modules"
  (
    export HOME="$fixtureHome"
    bootstrapCheckout "$fixtureHome/.claude"
  ) >/dev/null 2>&1
  cat >"$fixtureHome/Projects/glissa/bin/glissa.js" <<'GLISSA'
#!/usr/bin/env node
if (process.argv[2] === "pair") {
  console.log("https://paired.example/pair");
}
GLISSA
  chmod +x "$fixtureHome/Projects/glissa/bin/glissa.js"
  cat >"$fixtureBin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" && "${3:-}" == "pull" ]]; then
  exit 0
fi
exec /usr/bin/git "$@"
STUB
  cat >"$fixtureBin/node" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  printf 'v99.0.0\n'
  exit 0
fi
exec /usr/bin/node "$@"
STUB
  cat >"$fixtureBin/npm" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  root)
    printf '%s/.npm-global/lib/node_modules\n' "$HOME"
    exit 0
    ;;
  ls)
    printf '%s/.npm-global/lib\n' "$HOME"
    exit 0
    ;;
  pack)
    printf 'fixture.tgz\n'
    touch fixture.tgz
    exit 0
    ;;
  ci|run|install|config)
    exit 0
    ;;
esac
exit 0
STUB
  cat >"$fixtureBin/python3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$fixtureBin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$fixtureBin/codium" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$fixtureBin/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fixtureBin/git" "$fixtureBin/node" "$fixtureBin/npm" "$fixtureBin/python3" "$fixtureBin/gh" "$fixtureBin/codium" "$fixtureBin/claude"
}

installTailscaleFixture() {
  local fixtureBin="$1"
  local dnsName="$2"
  cat >"$fixtureBin/tailscale" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" && "\${2:-}" == "--json" ]]; then
  printf '{"Self":{"DNSName":"$dnsName."}}\n'
  exit 0
fi
if [[ "\${1:-}" == "status" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "serve" ]]; then
  printf '%s\n' "\$*" >>"\${TAILSCALE_SERVE_LOG:-/tmp/tailscale-serve.log}"
  exit 0
fi
exit 0
STUB
  chmod +x "$fixtureBin/tailscale"
}

runGlissaServerApply() {
  local fixtureHome="$1"
  local fixtureBin="$2"
  local promptInput="${CLAUDE_SETUP_TTY_INPUT:-}"
  local serveLog="${TAILSCALE_SERVE_LOG:-}"
  shift 2
  HOME="$fixtureHome" GIT_CONFIG_GLOBAL="$fixtureHome/.gitconfig" PATH="$fixtureBin:/usr/bin:/bin" CLAUDE_SETUP_TTY_INPUT="$promptInput" TAILSCALE_SERVE_LOG="$serveLog" bash "$fixtureHome/.claude/setup/apply.sh" --profile server "$@" 2>&1 | stripColor
}

printf 'suite mode: %s\n' "$suiteMode"
printf 'distro: %s\n' "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)"

# Keep the suite's own git identity out of ~/.gitconfig: apply.sh is supposed to
# be the only thing that ever writes that file, and one assertion checks it does
# not while the tracked identity is still a placeholder.
export GIT_CONFIG_GLOBAL=/tmp/suite-gitconfig
git config --global init.defaultBranch master
git config --global user.name "Suite Runner"
git config --global user.email "suite@example.com"
git config --global --add safe.directory '*'

cp -a /origin.git "$originRepo"

# ---------------------------------------------------------------------------
phase "argument handling"

installOutput="$(bash /suite/src/setup/install.sh --profile bogus 2>&1)"
assertStatus "install.sh rejects an unknown profile" 2 $?
assertMatch "install.sh names the valid profiles" "personal, work, or server" "$installOutput"

bash /suite/src/setup/install.sh --nonsense >/dev/null 2>&1
assertStatus "install.sh rejects an unknown flag" 2 $?

installHelpOutput="$(bash /suite/src/setup/install.sh --help 2>&1)"
assertStatus "install.sh --help exits clean" 0 $?
assertMatch "install.sh --help prints usage" "Usage: setup/install.sh" "$installHelpOutput"

bash /suite/src/setup/apply.sh --profile >/dev/null 2>&1
assertStatus "apply.sh rejects a valueless --profile" 2 $?

bash /suite/src/setup/apply.sh --nonsense >/dev/null 2>&1
assertStatus "apply.sh rejects an unknown flag" 2 $?

applyHelpOutput="$(bash /suite/src/setup/apply.sh --help 2>&1)"
assertStatus "apply.sh --help exits clean" 0 $?
assertMatch "apply.sh --help prints usage" "Usage: setup/apply.sh" "$applyHelpOutput"
assertNoMatch "apply.sh --help applies nothing" "ok ]" "$applyHelpOutput"

nonInteractiveOutput="$(bash /suite/src/setup/apply.sh --skip-installs < /dev/null 2>&1)"
assertStatus "apply.sh refuses to guess a profile without a tty" 1 $?
assertMatch "apply.sh says how to supply the profile" "Re-run with --profile" "$nonInteractiveOutput"

bash /suite/src/setup/collect.sh --nonsense >/dev/null 2>&1
assertStatus "collect.sh rejects an unknown flag" 2 $?

collectHelpOutput="$(bash /suite/src/setup/collect.sh --help 2>&1)"
assertStatus "collect.sh --help exits clean" 0 $?
assertMatch "collect.sh --help prints usage" "Usage: setup/collect.sh" "$collectHelpOutput"
assertNoMatch "collect.sh --help collects nothing" "collected:" "$collectHelpOutput"

# ---------------------------------------------------------------------------
# The container already ships git, so the prerequisite bootstrap is exercised
# against a stub PATH where git is absent rather than by uninstalling it.
phase "prerequisite bootstrap"

prereqStubDir="$(mktemp -d)"
prereqRoot="$prereqStubDir/root"

noManagerOutput="$(PATH="$prereqStubDir" /bin/bash /suite/src/setup/install.sh --root "$prereqRoot" 2>&1 | stripColor)"
noManagerStatus="${PIPESTATUS[0]}"
assertStatus "install.sh stops when git cannot be installed" 1 "$noManagerStatus"
assertMatch "install.sh reports the missing package manager" "no supported package manager" "$noManagerOutput"
assertNoFile "install.sh clones nothing without git" "$prereqRoot"

cat >"$prereqStubDir/apt-get" <<'STUB'
#!/bin/bash
exit 1
STUB
cat >"$prereqStubDir/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
chmod +x "$prereqStubDir/apt-get" "$prereqStubDir/sudo"

failedInstallOutput="$(PATH="$prereqStubDir" /bin/bash /suite/src/setup/install.sh --root "$prereqRoot" 2>&1 | stripColor)"
failedInstallStatus="${PIPESTATUS[0]}"
assertStatus "install.sh stops when the package manager fails" 1 "$failedInstallStatus"
assertMatch "install.sh reports the install attempt" "Installing git via apt-get" "$failedInstallOutput"
assertMatch "install.sh reports the failed install" "git install via apt-get failed" "$failedInstallOutput"

# ---------------------------------------------------------------------------
phase "bootstrap (README one-liner path, personal)"

claudeHome="$HOME/.claude"
bootstrapCheckout "$claudeHome"
bootstrapOutput="$(bash "$claudeHome/setup/install.sh" --skip-installs --profile personal 2>&1 | stripColor)"
bootstrapStatus="${PIPESTATUS[0]}"
printf '%s\n' "$bootstrapOutput" | sed 's/^/    | /'

assertOk "install.sh completes" "$bootstrapStatus"
assertMatch "install.sh reports the repo it updated" "Repo found at" "$bootstrapOutput"
assertFile "renders CLAUDE.md" "$claudeHome/CLAUDE.md"
assertFile "renders commands/commit.md" "$claudeHome/commands/commit.md"
assertFile "writes the profile marker" "$claudeHome/.machine-profile"
assertEquals "marker records the chosen profile" "personal" "$(cat "$claudeHome/.machine-profile")"
assertFile "copies VSCodium settings" "$HOME/.config/VSCodium/User/settings.json"
assertFile "copies VSCodium keybindings" "$HOME/.config/VSCodium/User/keybindings.json"
assertFile "copies Codex AGENTS.md" "$HOME/.codex/AGENTS.md"
assertFile "seeds the glissa config" "$HOME/.glissa/config.json"
assertNoFile "refuses to install the placeholder gitconfig" "$HOME/.gitconfig"
# The suite exports GIT_CONFIG_GLOBAL with its own identity above, so this run
# legitimately reports the identity as already configured instead of warning.
assertMatch "reports the suite git identity as configured" "identity already configured" "$bootstrapOutput"
assertMatch "reports Windows Terminal as not applicable" "not applicable on Linux" "$bootstrapOutput"
assertMatch "stops before the install steps" "Installs skipped" "$bootstrapOutput"
assertMatch "defers the settings render until node exists" "node not on PATH, will retry" "$bootstrapOutput"
assertNoFile "writes no settings.json before node exists" "$claudeHome/settings.json"

commitDoc="$(cat "$claudeHome/commands/commit.md")"
assertNoMatch "commit.md carries no Windows separators in the runner path" 'compiled-commit\\runner' "$commitDoc"
assertMatch "commit.md points at the portable runner path" 'compiled-commit/runner\.py' "$commitDoc"

phase "gitconfig prompt"

gitPromptHome="/tmp/gitprompt-home"
mkdir -p "$gitPromptHome"
(
  export HOME="$gitPromptHome"
  bootstrapCheckout "$gitPromptHome/.claude"
) >/dev/null 2>&1
gitPromptRaw="$(mktemp)"
gitPromptAnswers="$(mktemp)"
printf 'Prompt Carbon\nprompt@example.com\n' > "$gitPromptAnswers"
HOME="$gitPromptHome" GIT_CONFIG_GLOBAL="$gitPromptHome/.gitconfig" CLAUDE_SETUP_TTY_INPUT="$gitPromptAnswers" bash "$gitPromptHome/.claude/setup/apply.sh" --skip-installs --profile personal >"$gitPromptRaw" 2>&1
gitPromptStatus="$?"
gitPromptOutput="$(stripColor < "$gitPromptRaw")"
rm -f "$gitPromptRaw" "$gitPromptAnswers"
assertOk "gitconfig prompt apply completes" "$gitPromptStatus"
assertFile "gitconfig prompt writes ~/.gitconfig" "$gitPromptHome/.gitconfig"
assertMatch "gitconfig prompt writes the entered name" "name = Prompt Carbon" "$(cat "$gitPromptHome/.gitconfig" 2>/dev/null)"
assertMatch "gitconfig prompt writes the entered email" "email = prompt@example.com" "$(cat "$gitPromptHome/.gitconfig" 2>/dev/null)"
assertNoMatch "gitconfig prompt removes the placeholder header" "Placeholder identity" "$(cat "$gitPromptHome/.gitconfig" 2>/dev/null)"

blankGitPromptHome="/tmp/gitprompt-blank-home"
mkdir -p "$blankGitPromptHome"
(
  export HOME="$blankGitPromptHome"
  bootstrapCheckout "$blankGitPromptHome/.claude"
) >/dev/null 2>&1
blankGitPromptRaw="$(mktemp)"
blankGitPromptAnswers="$(mktemp)"
printf '\nblank@example.com\n' > "$blankGitPromptAnswers"
HOME="$blankGitPromptHome" GIT_CONFIG_GLOBAL="$blankGitPromptHome/.gitconfig" CLAUDE_SETUP_TTY_INPUT="$blankGitPromptAnswers" bash "$blankGitPromptHome/.claude/setup/apply.sh" --skip-installs --profile personal >"$blankGitPromptRaw" 2>&1
blankGitPromptStatus="$?"
blankGitPromptOutput="$(stripColor < "$blankGitPromptRaw")"
rm -f "$blankGitPromptRaw" "$blankGitPromptAnswers"
assertOk "blank gitconfig prompt apply completes" "$blankGitPromptStatus"
assertNoFile "blank gitconfig prompt writes no ~/.gitconfig" "$blankGitPromptHome/.gitconfig"
assertMatch "blank gitconfig prompt keeps the placeholder warning" "placeholder identity, edit setup/git/.gitconfig first" "$blankGitPromptOutput"

configuredGitPromptHome="/tmp/gitprompt-configured-home"
mkdir -p "$configuredGitPromptHome"
(
  export HOME="$configuredGitPromptHome"
  bootstrapCheckout "$configuredGitPromptHome/.claude"
) >/dev/null 2>&1
printf '[user]\n\tname = Existing Carbon\n\temail = existing@example.com\n\t; keep = custom\n' > "$configuredGitPromptHome/.gitconfig"
configuredGitDigestBefore="$(sha256sum < "$configuredGitPromptHome/.gitconfig" | cut -d' ' -f1)"
configuredGitPromptRaw="$(mktemp)"
configuredGitPromptAnswers="$(mktemp)"
printf 'Should Never\nbe.read@example.com\n' > "$configuredGitPromptAnswers"
HOME="$configuredGitPromptHome" GIT_CONFIG_GLOBAL="$configuredGitPromptHome/.gitconfig" CLAUDE_SETUP_TTY_INPUT="$configuredGitPromptAnswers" bash "$configuredGitPromptHome/.claude/setup/apply.sh" --skip-installs --profile personal >"$configuredGitPromptRaw" 2>&1
configuredGitPromptStatus="$?"
configuredGitPromptOutput="$(stripColor < "$configuredGitPromptRaw")"
rm -f "$configuredGitPromptRaw" "$configuredGitPromptAnswers"
configuredGitDigestAfter="$(sha256sum < "$configuredGitPromptHome/.gitconfig" | cut -d' ' -f1)"
assertOk "configured identity apply completes" "$configuredGitPromptStatus"
assertMatch "configured identity is reported present" "gitconfig +identity already configured" "$configuredGitPromptOutput"
assertNoMatch "configured identity is never prompted" "Git commit name" "$configuredGitPromptOutput"
assertEquals "configured identity leaves ~/.gitconfig untouched" "$configuredGitDigestBefore" "$configuredGitDigestAfter"

# ---------------------------------------------------------------------------
# Full mode installs node through apply.sh itself, so only the fast suite has to
# put it there by hand to reach the deferred render.
if [[ "$suiteMode" != "full" ]]; then
  phase "settings render once node is present"

  installNodeForRender
  renderOutput="$(bash "$claudeHome/setup/apply.sh" --skip-installs 2>&1 | stripColor)"
  renderStatus="${PIPESTATUS[0]}"
  assertOk "apply after node install completes" "$renderStatus"
  assertRenderedSettings "$claudeHome/settings.json"
fi

# ---------------------------------------------------------------------------
phase "idempotency"

rerunOutput="$(bash "$claudeHome/setup/apply.sh" --skip-installs 2>&1 | stripColor)"
rerunStatus="${PIPESTATUS[0]}"
printf '%s\n' "$rerunOutput" | sed 's/^/    | /'
assertOk "second apply completes" "$rerunStatus"
assertMatch "second apply changes nothing" "Done in [0-9]+s: 0 updated" "$rerunOutput"
assertNoMatch "second apply installs nothing" '\[ \+\+ \]' "$rerunOutput"
assertMatch "second apply reuses the stored profile" "not applicable on Linux" "$rerunOutput"
assertNoFile "no backup on an unchanged rerun" "$claudeHome/CLAUDE.md.pre-profile.bak"

# ---------------------------------------------------------------------------
phase "dry run"

beforeHash="$(hashTree "$claudeHome")"
dryRunOutput="$(bash "$claudeHome/setup/apply.sh" --dry-run 2>&1 | stripColor)"
dryRunStatus="${PIPESTATUS[0]}"
afterHash="$(hashTree "$claudeHome")"
assertOk "dry run completes" "$dryRunStatus"
assertMatch "dry run says it wrote nothing" "nothing written" "$dryRunOutput"
assertMatch "dry run lists a planned step" "vscodium-config +run" "$dryRunOutput"
assertEquals "dry run leaves the tree untouched" "$beforeHash" "$afterHash"

# ---------------------------------------------------------------------------
phase "work profile"

workHome="/tmp/workhome"
mkdir -p "$workHome"
(
  export HOME="$workHome"
  bootstrapCheckout "$workHome/.claude"
) >/dev/null 2>&1
workOutput="$(HOME="$workHome" bash "$workHome/.claude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
workStatus="${PIPESTATUS[0]}"
assertOk "work profile apply completes" "$workStatus"
assertMatch "work profile skips glissa" "glissa config.*skipped \(work profile\)" "$workOutput"
assertMatch "work profile skips gitconfig" "gitconfig.*skipped \(work profile\)" "$workOutput"
assertMatch "work profile skips the terminal step" "Windows Terminal.*skipped \(work profile\)" "$workOutput"
assertNoFile "work profile writes no glissa config" "$workHome/.glissa/config.json"
assertNoFile "work profile installs no gitconfig" "$workHome/.gitconfig"

workCollectOutput="$(HOME="$workHome" bash "$workHome/.claude/setup/collect.sh" 2>&1)"
assertOk "work profile collect completes" $?
assertMatch "work profile collect stops after VSCodium" "personal-profile only" "$workCollectOutput"

# ---------------------------------------------------------------------------
phase "collect.sh round trip"

testRepo="$HOME/work/testrepo"
git clone -q "$originRepo" "$testRepo"
mkdir -p "$HOME/nonrepo"

codiumUser="$HOME/.config/VSCodium/User"
printf '{"editor.fontSize": 42}\n' > "$codiumUser/settings.json"
printf '[{"key": "ctrl+k"}]\n' > "$codiumUser/keybindings.json"

fakeCodiumScript="$(mktemp)"
cat > "$fakeCodiumScript" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-extensions" ]]; then
  printf 'vendor.second\nvendor.first\n'
  exit 0
fi
exit 0
FAKE
runSuiteRootCommand mkdir -p /usr/local/bin
runSuiteRootCommand install -m 755 "$fakeCodiumScript" /usr/local/bin/codium
rm -f "$fakeCodiumScript"

cat > "$HOME/.glissa/config.json" <<GLISSA
{
  "projects": [
    { "id": "a", "path": "$testRepo" },
    { "id": "b", "path": "$HOME/nonrepo" }
  ]
}
GLISSA

cat > "$HOME/.gitconfig" <<'GITCONFIG'
[user]
	name = Real Person
	email = real@person.example
[alias]
	name = rev-parse --abbrev-ref HEAD
[core]
	autocrlf = false
GITCONFIG

collectOutput="$(bash "$claudeHome/setup/collect.sh" 2>&1)"
collectStatus=$?
printf '%s\n' "$collectOutput" | sed 's/^/    | /'
assertOk "collect.sh completes" "$collectStatus"

assertMatch "collects VSCodium settings" '"editor.fontSize": 42' "$(cat "$claudeHome/setup/vscodium/settings.json")"
assertEquals "sorts the extension list" "vendor.first
vendor.second" "$(cat "$claudeHome/setup/vscodium/extensions.txt")"
assertEquals "derives repos.txt from the glissa project list" "work/testrepo=$originRepo" "$(cat "$claudeHome/setup/repos.txt")"

collectedGitConfig="$(cat "$claudeHome/setup/git/.gitconfig")"
assertNoMatch "scrubs the real name" "Real Person" "$collectedGitConfig"
assertNoMatch "scrubs the real email" "real@person.example" "$collectedGitConfig"
assertMatch "writes the placeholder name" "name = Your Name" "$collectedGitConfig"
assertMatch "writes the placeholder email" "email = you@example.com" "$collectedGitConfig"
assertMatch "leaves an alias called name alone" "name = rev-parse" "$collectedGitConfig"
assertMatch "keeps unrelated sections" "autocrlf = false" "$collectedGitConfig"
assertMatch "keeps the placeholder header" "before running the apply script" "$collectedGitConfig"

fakeCodiumScript="$(mktemp)"
cat > "$fakeCodiumScript" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
runSuiteRootCommand install -m 755 "$fakeCodiumScript" /usr/local/bin/codium
rm -f "$fakeCodiumScript"
emptyProbeOutput="$(bash "$claudeHome/setup/collect.sh" 2>&1)"
assertMatch "warns when a probe returns nothing" "keeping existing extensions.txt" "$emptyProbeOutput"
assertEquals "keeps the tracked list on an empty probe" "vendor.first
vendor.second" "$(cat "$claudeHome/setup/vscodium/extensions.txt")"
runSuiteRootCommand rm -f /usr/local/bin/codium

# ---------------------------------------------------------------------------
phase "profile marker is case insensitive"

printf 'Work\n' > "$claudeHome/.machine-profile"
markerOutput="$(bash "$claudeHome/setup/apply.sh" --skip-installs 2>&1 | stripColor)"
assertMatch "a capitalised marker still selects the work profile" "skipped \(work profile\)" "$markerOutput"
markerCollectOutput="$(bash "$claudeHome/setup/collect.sh" 2>&1)"
assertMatch "collect.sh reads the marker the same way" "personal-profile only" "$markerCollectOutput"
printf 'personal\n' > "$claudeHome/.machine-profile"

if [[ "$suiteMode" != "full" ]]; then
  phase "glissa server remote config"

  autoHome="$(mktemp -d)"
  autoBin="$(mktemp -d)"
  autoServeLog="$autoHome/tailscale-serve.log"
  prepareGlissaServerFixture "$autoHome" "$autoBin"
  installTailscaleFixture "$autoBin" "server.machine.tailnet.ts.net"
  autoOutput="$(TAILSCALE_SERVE_LOG="$autoServeLog" runGlissaServerApply "$autoHome" "$autoBin")"
  autoConfig="$autoHome/.glissa/config.json"
  assertMatch "auto-detect reports the public host" "glissa remote config +publicHost server.machine.tailnet.ts.net \(auto-detected\)" "$autoOutput"
  assertEquals "auto-detect writes publicHost" "server.machine.tailnet.ts.net" "$(jsonField "$autoConfig" 'config.remote.publicHost')"
  assertEquals "auto-detect writes allowedOrigins" '["https://server.machine.tailnet.ts.net"]' "$(jsonField "$autoConfig" 'JSON.stringify(config.remote.allowedOrigins)')"
  assertNoMatch "auto-detect removes CHANGEME" "CHANGEME" "$(cat "$autoConfig")"
  assertEquals "auto-detect keeps config private" "600" "$(stat -c %a "$autoConfig")"
  assertEquals "tailscale serve targets remote.port" "serve --bg 3001" "$(cat "$autoServeLog")"

  autoConfigDigestBefore="$(sha256sum < "$autoConfig" | cut -d' ' -f1)"
  autoRerunOutput="$(TAILSCALE_SERVE_LOG="$autoServeLog" runGlissaServerApply "$autoHome" "$autoBin")"
  autoConfigDigestAfter="$(sha256sum < "$autoConfig" | cut -d' ' -f1)"
  assertMatch "configured rerun reports present remote config" "glissa remote config +configured" "$autoRerunOutput"
  assertNoMatch "configured rerun prompts nothing" "Enable remote access|Remote hostname|listener port" "$autoRerunOutput"
  assertEquals "configured rerun leaves config byte-identical" "$autoConfigDigestBefore" "$autoConfigDigestAfter"

  manualHome="$(mktemp -d)"
  manualBin="$(mktemp -d)"
  prepareGlissaServerFixture "$manualHome" "$manualBin"
  cat >"$manualBin/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$manualBin/curl"
  manualOutput="$(runGlissaServerApply "$manualHome" "$manualBin")"
  manualConfig="$manualHome/.glissa/config.json"
  assertMatch "missing tailscale keeps the checklist warning" "publicHost/allowedOrigins still say CHANGEME" "$manualOutput"
  assertMatch "missing tailscale preserves CHANGEME" "CHANGEME" "$(cat "$manualConfig")"

  disabledHome="$(mktemp -d)"
  disabledBin="$(mktemp -d)"
  disabledAnswers="$disabledHome/answers.txt"
  disabledServeLog="$disabledHome/tailscale-serve.log"
  prepareGlissaServerFixture "$disabledHome" "$disabledBin"
  installTailscaleFixture "$disabledBin" "disabled.machine.tailnet.ts.net"
  printf '\n\nn\n' > "$disabledAnswers"
  disabledOutput="$(CLAUDE_SETUP_TTY_INPUT="$disabledAnswers" TAILSCALE_SERVE_LOG="$disabledServeLog" runGlissaServerApply "$disabledHome" "$disabledBin")"
  disabledConfig="$disabledHome/.glissa/config.json"
  assertMatch "disabled remote reports config update" "glissa remote config +remote access disabled" "$disabledOutput"
  assertEquals "disabled remote writes enabled false" "false" "$(jsonField "$disabledConfig" 'config.remote.enabled')"
  assertMatch "disabled remote skips tailscale serve" "Tailscale serve +skipped, glissa remote disabled" "$disabledOutput"
  assertNoFile "disabled remote does not call tailscale serve" "$disabledServeLog"

  portsHome="$(mktemp -d)"
  portsBin="$(mktemp -d)"
  portsAnswers="$portsHome/answers.txt"
  prepareGlissaServerFixture "$portsHome" "$portsBin"
  installTailscaleFixture "$portsBin" "ports.machine.tailnet.ts.net"
  printf '\n\nY\n2\ncustom.tailnet.ts.net\nabc\n3000\n3000\n3000\n4444\n3000\nn\n' > "$portsAnswers"
  portsOutput="$(CLAUDE_SETUP_TTY_INPUT="$portsAnswers" runGlissaServerApply "$portsHome" "$portsBin")"
  portsConfig="$portsHome/.glissa/config.json"
  assertMatch "invalid remote port is rejected" "remote port must be 1-65535" "$portsOutput"
  assertMatch "equal ports are rejected" "remote.port must differ from port" "$portsOutput"
  assertEquals "valid remote port is accepted" "4444" "$(jsonField "$portsConfig" 'config.remote.port')"
  assertEquals "valid local port is accepted" "3000" "$(jsonField "$portsConfig" 'config.port')"
  assertEquals "typed hostname is accepted" "custom.tailnet.ts.net" "$(jsonField "$portsConfig" 'config.remote.publicHost')"

  wordNoHome="$(mktemp -d)"
  wordNoBin="$(mktemp -d)"
  wordNoAnswers="$wordNoHome/answers.txt"
  prepareGlissaServerFixture "$wordNoHome" "$wordNoBin"
  installTailscaleFixture "$wordNoBin" "wordno.machine.tailnet.ts.net"
  printf '\n\nno\n' > "$wordNoAnswers"
  wordNoOutput="$(CLAUDE_SETUP_TTY_INPUT="$wordNoAnswers" runGlissaServerApply "$wordNoHome" "$wordNoBin")"
  assertMatch "a typed word no disables remote access" "glissa remote config +remote access disabled" "$wordNoOutput"
  assertEquals "a typed word no writes enabled false" "false" "$(jsonField "$wordNoHome/.glissa/config.json" 'config.remote.enabled')"

  badChoiceHome="$(mktemp -d)"
  badChoiceBin="$(mktemp -d)"
  badChoiceAnswers="$badChoiceHome/answers.txt"
  prepareGlissaServerFixture "$badChoiceHome" "$badChoiceBin"
  installTailscaleFixture "$badChoiceBin" "badchoice.machine.tailnet.ts.net"
  printf '\n\nY\n4\n' > "$badChoiceAnswers"
  badChoiceOutput="$(CLAUDE_SETUP_TTY_INPUT="$badChoiceAnswers" runGlissaServerApply "$badChoiceHome" "$badChoiceBin")"
  badChoiceConfig="$badChoiceHome/.glissa/config.json"
  assertMatch "an unrecognized hostname choice warns about CHANGEME" "publicHost/allowedOrigins still say CHANGEME" "$badChoiceOutput"
  assertMatch "an unrecognized hostname choice preserves CHANGEME" "CHANGEME" "$(cat "$badChoiceConfig")"
  assertNoMatch "an unrecognized hostname choice claims no publicHost" "glissa remote config +publicHost" "$badChoiceOutput"

  mintHome="$(mktemp -d)"
  mintBin="$(mktemp -d)"
  mintAnswers="$mintHome/answers.txt"
  prepareGlissaServerFixture "$mintHome" "$mintBin"
  installTailscaleFixture "$mintBin" "mint.machine.tailnet.ts.net"
  printf '\n\nY\n1\n\n\ny\n' > "$mintAnswers"
  mintOutput="$(CLAUDE_SETUP_TTY_INPUT="$mintAnswers" runGlissaServerApply "$mintHome" "$mintBin")"
  assertMatch "minting prints the pairing URL" "https://paired.example/pair" "$mintOutput"
  assertMatch "minting still reminds about claude login" "glissa checklist +claude login on the box" "$mintOutput"

  customPortHome="$(mktemp -d)"
  customPortBin="$(mktemp -d)"
  customPortAnswers="$customPortHome/answers.txt"
  prepareGlissaServerFixture "$customPortHome" "$customPortBin"
  installTailscaleFixture "$customPortBin" "customport.machine.tailnet.ts.net"
  mkdir -p "$customPortHome/.glissa"
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.port = 8080; fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2));' "$customPortHome/.claude/setup/glissa/config.server.example.json" "$customPortHome/.glissa/config.json"
  printf '\n\nn\n' > "$customPortAnswers"
  CLAUDE_SETUP_TTY_INPUT="$customPortAnswers" runGlissaServerApply "$customPortHome" "$customPortBin" >/dev/null
  assertEquals "declining remote keeps a customized local port" "8080" "$(jsonField "$customPortHome/.glissa/config.json" 'config.port')"
fi

if [[ "$suiteMode" != "full" ]]; then
  printf '\n%s passed, %s failed (fast mode)\n' "$passCount" "$failCount"
  if ((failCount > 0)); then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
phase "full apply (installs enabled)"

git -C "$claudeHome" checkout -q -- setup/vscodium setup/git
printf 'work/clonedrepo=%s\n' "$originRepo" > "$claudeHome/setup/repos.txt"

fullOutput="$(bash "$claudeHome/setup/apply.sh" 2>&1 | stripColor)"
fullStatus="${PIPESTATUS[0]}"
printf '%s\n' "$fullOutput" | sed 's/^/    | /'
assertOk "full apply completes" "$fullStatus"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
hash -r

command -v node >/dev/null 2>&1
assertOk "installs node" $?
command -v npm >/dev/null 2>&1
assertOk "installs npm" $?
assertMinimum "installs a node the glissa build can run" 20 "$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')"
assertRenderedSettings "$claudeHome/settings.json"
assertMatch "reports VSCodium as needing a manual install" "vscodium.com" "$fullOutput"
assertDir "clones the repo listed in repos.txt" "$HOME/work/clonedrepo/.git"
assertEquals "creates develop in the cloned repo" "develop" "$(git -C "$HOME/work/clonedrepo" rev-parse --abbrev-ref develop 2>/dev/null)"
assertFile "installs the fonts" "$HOME/.local/share/fonts/CommitMono-400-Regular.otf"
assertNoMatch "biome never reports installed and failed together" 'biome +npm install failed' "$fullOutput"

npmGlobalList="$(npm ls -g --depth=0 --parseable 2>/dev/null)"
assertMatch "installs the tracked npm globals" "node_modules/typescript" "$npmGlobalList"
assertMatch "installs glissa from GitHub source" "glissa +npm install -g github:johncwaters/glissa" "$fullOutput"
assertNoMatch "no npm package is reported as a plain failure" "npm install failed" "$fullOutput"

command -v python3 >/dev/null 2>&1
assertOk "installs python3" $?
python3 -m pip --version >/dev/null 2>&1
assertOk "installs pip alongside python3" $?
python3 -c "import ruff" >/dev/null 2>&1
assertOk "installs ruff for the python gate" $?
python3 -c "import yaml" >/dev/null 2>&1
assertOk "installs pyyaml" $?

phase "full apply is idempotent"

secondFullOutput="$(bash "$claudeHome/setup/apply.sh" 2>&1 | stripColor)"
secondFullStatus="${PIPESTATUS[0]}"
assertOk "second full apply completes" "$secondFullStatus"
assertMatch "second full apply installs nothing" "Done in [0-9]+s: 0 updated, 0 installed" "$secondFullOutput"

# ---------------------------------------------------------------------------
phase "validate-file hook on real Linux"

hookScript="$claudeHome/hooks/validate-file.mjs"
node --check "$hookScript"
assertOk "hook parses" $?

runHook() {
  printf '%s' "$1" | node "$hookScript" 2>&1
}

goodJson='{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{\"a\":1}"}}'
badJson='{"tool_name":"Write","tool_input":{"file_path":"a.json","content":"{bad}"}}'
goodTs='{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const x: number = 1;"}}'
badTs='{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"const x: number = ;"}}'
goodPy='{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f():\n    return 1\n"}}'
badPy='{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"def f(:\n"}}'
jsonc='{"tool_name":"Write","tool_input":{"file_path":"tsconfig.json","content":"{\n  // comment\n  \"compilerOptions\": {}\n}"}}'
# Built from raw bytes so this file stays pure ASCII, which its own hook requires.
longDashChar="$(printf '\xe2\x80\x94')"
dashed="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"a.md\",\"content\":\"one ${longDashChar} two\"}}"

assertEquals "valid JSON is allowed" "" "$(runHook "$goodJson")"
assertEquals "valid TS is allowed" "" "$(runHook "$goodTs")"
assertEquals "valid Python is allowed" "" "$(runHook "$goodPy")"
assertEquals "JSONC in tsconfig.json is allowed" "" "$(runHook "$jsonc")"

badJsonResult="$(runHook "$badJson")"
assertMatch "invalid JSON is denied" '"permissionDecision": *"deny"' "$badJsonResult"

badTsResult="$(runHook "$badTs")"
assertMatch "invalid TS is denied" '"permissionDecision": *"deny"' "$badTsResult"
assertMatch "the TS denial locates the error" "line 1, column 19" "$badTsResult"
assertMatch "the TS denial explains the error" "Expected an expression" "$badTsResult"

badPyResult="$(runHook "$badPy")"
assertMatch "invalid Python is denied" '"permissionDecision": *"deny"' "$badPyResult"
assertMatch "the Python denial locates the error" "line 1" "$badPyResult"

assertMatch "a long dash is denied" '"permissionDecision": *"deny"' "$(runHook "$dashed")"

printf '\n%s passed, %s failed (full mode)\n' "$passCount" "$failCount"
if ((failCount > 0)); then
  exit 1
fi
exit 0
