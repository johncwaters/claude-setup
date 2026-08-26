#!/usr/bin/env bash
# Acceptance suite for the Linux bootstrap scripts. Destructive by design: it
# writes to $HOME, installs system packages, and clones repos, so it must only
# ever run inside the throwaway container built by run-docker.sh.
#
# SUITE_MODE=fast  config, flags, idempotency, collect round trip (no installs)
# SUITE_MODE=full  everything above plus the install steps and the real hook run

set -uo pipefail

# Container guard: this suite overwrites $HOME/.gitconfig, $HOME/.glissa/config.json, and the
# setup/ collect copies. Running it on a real machine destroys live config (it did, 2026-08-16).
if [[ ! -f /.dockerenv && -z "${SUITE_ALLOW_HOST:-}" ]]; then
  printf 'suite.sh: refusing to run outside the run-docker.sh container (destructive to $HOME). Use setup/test/run-docker.sh, or set SUITE_ALLOW_HOST=1 if this really is a throwaway machine.\n' >&2
  exit 1
fi

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

installCurlFixture() {
  local fixtureBin="$1"
  cat >"$fixtureBin/curl" <<'STUB'
#!/usr/bin/env bash
url="${@: -1}"
printf '%s\n' "$url" >>"${CURL_LOG:-/tmp/curl.log}"
if [[ -n "${GLISSA_CURL_FAIL_CONTAINS:-}" && "$url" == *"$GLISSA_CURL_FAIL_CONTAINS"* ]]; then
  exit 7
fi
status="${GLISSA_CURL_STATUS:-200}"
if [[ "$url" == https://* && -n "${GLISSA_CURL_HTTPS_STATUS:-}" ]]; then
  status="$GLISSA_CURL_HTTPS_STATUS"
fi
if [[ "$url" == *":3000/"* && -n "${GLISSA_CURL_LOCAL_STATUS:-}" ]]; then
  status="$GLISSA_CURL_LOCAL_STATUS"
fi
if [[ "$url" == *":3001/"* && -n "${GLISSA_CURL_REMOTE_STATUS:-}" ]]; then
  status="$GLISSA_CURL_REMOTE_STATUS"
fi
printf '%s' "$status"
STUB
  chmod +x "$fixtureBin/curl"
}

installSystemdFixture() {
  local fixtureBin="$1"
  cat >"$fixtureBin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:-/tmp/systemctl.log}"
exit 0
STUB
  cat >"$fixtureBin/loginctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOGINCTL_LOG:-/tmp/loginctl.log}"
if [[ "${1:-}" == "show-user" ]]; then
  printf 'yes\n'
fi
exit 0
STUB
  chmod +x "$fixtureBin/systemctl" "$fixtureBin/loginctl"
  runSuiteRootCommand mkdir -p /run/systemd/system
}

installSoftwarePathStubs() {
  local fixtureBin="$1"
  local packageManager="${2:-}"
  local ydotoolMode="${3:-present}"
  local toolName
  mkdir -p "$fixtureBin"
  for toolName in bash basename cat chmod cp cut dirname grep head mkdir mktemp pwd rm sed sha256sum tail tr; do
    ln -sf "$(type -P "$toolName")" "$fixtureBin/$toolName"
  done
  for toolName in git gh python3 codium claude zed solaar ratbagd piper headsetcontrol flameshot wl-copy; do
    cat >"$fixtureBin/$toolName" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$fixtureBin/$toolName"
  done
  if [[ "$ydotoolMode" == "present" ]]; then
    for toolName in ydotool ydotoold; do
      cat >"$fixtureBin/$toolName" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
      chmod +x "$fixtureBin/$toolName"
    done
  fi
  if [[ "$ydotoolMode" == "missing" ]]; then
    rm -f "$fixtureBin/ydotool" "$fixtureBin/ydotoold"
  fi
  cat >"$fixtureBin/node" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  printf 'v99.0.0\n'
  exit 0
fi
exit 0
STUB
  cat >"$fixtureBin/flatpak" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
exit 0
STUB
  cat >"$fixtureBin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-nG" ]]; then
  printf 'input\n'
  exit 0
fi
exec /usr/bin/id "$@"
STUB
  if [[ "$packageManager" == "dnf" ]]; then
    cat >"$fixtureBin/dnf" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat >"$fixtureBin/sudo" <<'STUB'
#!/usr/bin/env bash
"$@"
STUB
    chmod +x "$fixtureBin/dnf" "$fixtureBin/sudo"
  fi
  cat >"$fixtureBin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "--user show-environment"|"--user is-enabled ydotoold.service"|"--user is-active ydotoold.service"|"--user daemon-reload"|"--user enable --now ydotoold.service"|"--user restart ydotoold.service")
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$fixtureBin/node" "$fixtureBin/flatpak" "$fixtureBin/id" "$fixtureBin/systemctl"
}

installScreenshotToolStubs() {
  installSoftwarePathStubs "$1"
}

runGlissaServerApply() {
  local fixtureHome="$1"
  local fixtureBin="$2"
  local promptInput="${CLAUDE_SETUP_TTY_INPUT:-}"
  local serveLog="${TAILSCALE_SERVE_LOG:-}"
  local curlLog="${CURL_LOG:-}"
  local curlStatus="${GLISSA_CURL_STATUS:-}"
  local curlHttpsStatus="${GLISSA_CURL_HTTPS_STATUS:-}"
  local curlLocalStatus="${GLISSA_CURL_LOCAL_STATUS:-}"
  local curlRemoteStatus="${GLISSA_CURL_REMOTE_STATUS:-}"
  local curlFailContains="${GLISSA_CURL_FAIL_CONTAINS:-}"
  local systemctlLog="${SYSTEMCTL_LOG:-}"
  local loginctlLog="${LOGINCTL_LOG:-}"
  shift 2
  HOME="$fixtureHome" GIT_CONFIG_GLOBAL="$fixtureHome/.gitconfig" PATH="$fixtureBin:/usr/bin:/bin" CLAUDE_SETUP_TTY_INPUT="$promptInput" TAILSCALE_SERVE_LOG="$serveLog" CURL_LOG="$curlLog" GLISSA_CURL_STATUS="$curlStatus" GLISSA_CURL_HTTPS_STATUS="$curlHttpsStatus" GLISSA_CURL_LOCAL_STATUS="$curlLocalStatus" GLISSA_CURL_REMOTE_STATUS="$curlRemoteStatus" GLISSA_CURL_FAIL_CONTAINS="$curlFailContains" SYSTEMCTL_LOG="$systemctlLog" LOGINCTL_LOG="$loginctlLog" bash "$fixtureHome/.claude/setup/apply.sh" --profile server "$@" 2>&1 | stripColor
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
glissaSeedConfig="$(cat "$HOME/.glissa/config.json" 2>/dev/null)"
assertMatch "rewrites glissa project roots for Linux" "$HOME/Projects" "$glissaSeedConfig"
assertNoMatch "glissa config has no Windows drive" 'C:\\' "$glissaSeedConfig"
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

phase "screenshot tooling"

screenshotHome="/tmp/screenshot-home"
screenshotBin="/tmp/screenshot-bin"
mkdir -p "$screenshotHome"
(
  export HOME="$screenshotHome"
  bootstrapCheckout "$screenshotHome/.claude"
) >/dev/null 2>&1
installScreenshotToolStubs "$screenshotBin"
printf '%s\n' '{ "steps": ["software"] }' > "$screenshotHome/.claude/profiles/personal/profile.json"
mkdir -p "$screenshotHome/.config/cosmic"

screenshotOutput="$(HOME="$screenshotHome" PATH="$screenshotBin:/usr/bin:/bin" bash "$screenshotHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
screenshotStatus="${PIPESTATUS[0]}"
assertOk "screenshot tooling apply completes" "$screenshotStatus"
assertFile "installs the Flameshot save-path wrapper" "$screenshotHome/.local/bin/flameshot-save-path"
assertFile "installs the Flameshot autostart entry" "$screenshotHome/.config/autostart/Flameshot.desktop"
assertFile "installs the ydotoold unit" "$screenshotHome/.config/systemd/user/ydotoold.service"
assertEquals "save-path wrapper matches the tracked copy" "$(sha256sum < "$screenshotHome/.claude/setup/screenshot/flameshot-save-path" | cut -d' ' -f1)" "$(sha256sum < "$screenshotHome/.local/bin/flameshot-save-path" | cut -d' ' -f1)"
assertEquals "autostart entry matches the tracked copy" "$(sha256sum < "$screenshotHome/.claude/setup/screenshot/Flameshot.desktop" | cut -d' ' -f1)" "$(sha256sum < "$screenshotHome/.config/autostart/Flameshot.desktop" | cut -d' ' -f1)"
assertEquals "ydotoold unit matches the tracked copy" "$(sha256sum < "$screenshotHome/.claude/setup/dictation/ydotoold.service" | cut -d' ' -f1)" "$(sha256sum < "$screenshotHome/.config/systemd/user/ydotoold.service" | cut -d' ' -f1)"
[[ -x "$screenshotHome/.local/bin/flameshot-save-path" ]]
assertOk "save-path wrapper is executable" $?
assertMatch "dictation input group already present" "input group +already present" "$screenshotOutput"
screenshotShortcuts="$screenshotHome/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom"
assertFile "creates COSMIC custom shortcuts" "$screenshotShortcuts"
assertMatch "creates the Print clipboard shortcut" 'key: "Print".*--clipboard' "$(cat "$screenshotShortcuts")"
assertMatch "creates the save-path shortcut with the fixture HOME" "$screenshotHome/.local/bin/flameshot-save-path" "$(cat "$screenshotShortcuts")"

chmod -x "$screenshotHome/.local/bin/flameshot-save-path"
screenshotExecutableRepairOutput="$(HOME="$screenshotHome" PATH="$screenshotBin:/usr/bin:/bin" bash "$screenshotHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
screenshotExecutableRepairStatus="${PIPESTATUS[0]}"
assertOk "screenshot executable repair apply completes" "$screenshotExecutableRepairStatus"
assertMatch "screenshot executable repair reports chmod" "flameshot save-path wrapper +marked executable" "$screenshotExecutableRepairOutput"
[[ -x "$screenshotHome/.local/bin/flameshot-save-path" ]]
assertOk "save-path wrapper is executable after repair" $?

screenshotTreeBefore="$(hashTree "$screenshotHome")"
screenshotRerunOutput="$(HOME="$screenshotHome" PATH="$screenshotBin:/usr/bin:/bin" bash "$screenshotHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
screenshotRerunStatus="${PIPESTATUS[0]}"
screenshotTreeAfter="$(hashTree "$screenshotHome")"
assertOk "second screenshot tooling apply completes" "$screenshotRerunStatus"
assertEquals "second screenshot tooling apply changes nothing" "$screenshotTreeBefore" "$screenshotTreeAfter"
assertMatch "second screenshot apply reports wrapper present" "flameshot save-path wrapper +up to date" "$screenshotRerunOutput"
assertMatch "second screenshot apply reports autostart present" "Flameshot autostart +up to date" "$screenshotRerunOutput"
assertMatch "second screenshot apply reports shortcuts present" "COSMIC screenshot shortcuts +already present" "$screenshotRerunOutput"
assertMatch "second screenshot apply reports ydotoold unit present" "ydotoold service +up to date" "$screenshotRerunOutput"
assertEquals "second screenshot apply keeps one Print shortcut" "1" "$(grep -Fc '(modifiers: [], key: "Print")' "$screenshotShortcuts")"
assertEquals "second screenshot apply keeps one save-path shortcut" "1" "$(grep -Fc '(modifiers: [Ctrl], key: "g")' "$screenshotShortcuts")"

screenshotMergeHome="/tmp/screenshot-merge-home"
screenshotMergeBin="/tmp/screenshot-merge-bin"
mkdir -p "$screenshotMergeHome"
(
  export HOME="$screenshotMergeHome"
  bootstrapCheckout "$screenshotMergeHome/.claude"
) >/dev/null 2>&1
installScreenshotToolStubs "$screenshotMergeBin"
printf '%s\n' '{ "steps": ["software"] }' > "$screenshotMergeHome/.claude/profiles/personal/profile.json"
screenshotMergeShortcuts="$screenshotMergeHome/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom"
mkdir -p "$(dirname -- "$screenshotMergeShortcuts")"
cat >"$screenshotMergeShortcuts" <<'RON'
{
    (modifiers: [Alt], key: "x"): Spawn("keep-me"),
    (modifiers: [], key: "Print"): Spawn("keep-existing-print"),
}
RON
screenshotMergeOutput="$(HOME="$screenshotMergeHome" PATH="$screenshotMergeBin:/usr/bin:/bin" bash "$screenshotMergeHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
screenshotMergeStatus="${PIPESTATUS[0]}"
screenshotMergeContent="$(cat "$screenshotMergeShortcuts")"
assertOk "screenshot shortcut merge apply completes" "$screenshotMergeStatus"
assertMatch "screenshot shortcut merge reports a merge" "COSMIC screenshot shortcuts +merged" "$screenshotMergeOutput"
assertMatch "screenshot shortcut merge keeps unrelated entries" 'key: "x".*keep-me' "$screenshotMergeContent"
assertMatch "screenshot shortcut merge keeps existing Print command" "keep-existing-print" "$screenshotMergeContent"
assertEquals "screenshot shortcut merge does not duplicate Print" "1" "$(grep -Fc '(modifiers: [], key: "Print")' "$screenshotMergeShortcuts")"
assertEquals "screenshot shortcut merge adds one save-path entry" "1" "$(grep -Fc '(modifiers: [Ctrl], key: "g")' "$screenshotMergeShortcuts")"

screenshotSkipHome="/tmp/screenshot-skip-home"
screenshotSkipBin="/tmp/screenshot-skip-bin"
mkdir -p "$screenshotSkipHome"
(
  export HOME="$screenshotSkipHome"
  bootstrapCheckout "$screenshotSkipHome/.claude"
) >/dev/null 2>&1
installScreenshotToolStubs "$screenshotSkipBin"
printf '%s\n' '{ "steps": ["software"] }' > "$screenshotSkipHome/.claude/profiles/personal/profile.json"
screenshotSkipOutput="$(HOME="$screenshotSkipHome" PATH="$screenshotSkipBin:/usr/bin:/bin" bash "$screenshotSkipHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
screenshotSkipStatus="${PIPESTATUS[0]}"
assertOk "non-COSMIC screenshot apply completes" "$screenshotSkipStatus"
assertMatch "non-COSMIC screenshot apply reports shortcuts skipped" "COSMIC screenshot shortcuts.*skipped \(personal profile\)" "$screenshotSkipOutput"
assertNoFile "non-COSMIC screenshot apply writes no shortcut file" "$screenshotSkipHome/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom"

dictationNoManagerHome="/tmp/dictation-no-manager-home"
dictationNoManagerBin="/tmp/dictation-no-manager-bin"
mkdir -p "$dictationNoManagerHome"
(
  export HOME="$dictationNoManagerHome"
  bootstrapCheckout "$dictationNoManagerHome/.claude"
) >/dev/null 2>&1
installScreenshotToolStubs "$dictationNoManagerBin"
printf '%s\n' '{ "steps": ["software"] }' > "$dictationNoManagerHome/.claude/profiles/personal/profile.json"
cat >"$dictationNoManagerBin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$dictationNoManagerBin/systemctl"
dictationNoManagerOutput="$(HOME="$dictationNoManagerHome" PATH="$dictationNoManagerBin:/usr/bin:/bin" bash "$dictationNoManagerHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
dictationNoManagerStatus="${PIPESTATUS[0]}"
assertOk "dictation no-user-manager apply completes" "$dictationNoManagerStatus"
assertFile "dictation no-user-manager installs unit" "$dictationNoManagerHome/.config/systemd/user/ydotoold.service"
assertEquals "dictation no-user-manager unit matches the tracked copy" "$(sha256sum < "$dictationNoManagerHome/.claude/setup/dictation/ydotoold.service" | cut -d' ' -f1)" "$(sha256sum < "$dictationNoManagerHome/.config/systemd/user/ydotoold.service" | cut -d' ' -f1)"
assertMatch "dictation no-user-manager warns" "ydotoold service +unit installed, systemctl --user unavailable" "$dictationNoManagerOutput"

dictationRestartHome="/tmp/dictation-restart-home"
dictationRestartBin="/tmp/dictation-restart-bin"
dictationRestartSystemctlLog="$dictationRestartHome/systemctl.log"
mkdir -p "$dictationRestartHome"
(
  export HOME="$dictationRestartHome"
  bootstrapCheckout "$dictationRestartHome/.claude"
) >/dev/null 2>&1
installScreenshotToolStubs "$dictationRestartBin"
printf '%s\n' '{ "steps": ["software"] }' > "$dictationRestartHome/.claude/profiles/personal/profile.json"
cat >"$dictationRestartBin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:-/tmp/systemctl.log}"
case "$*" in
  "--user show-environment"|"--user daemon-reload"|"--user enable --now ydotoold.service"|"--user restart ydotoold.service")
    exit 0
    ;;
esac
exit 1
STUB
chmod +x "$dictationRestartBin/systemctl"
dictationRestartOutput="$(HOME="$dictationRestartHome" PATH="$dictationRestartBin:/usr/bin:/bin" SYSTEMCTL_LOG="$dictationRestartSystemctlLog" bash "$dictationRestartHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
dictationRestartStatus="${PIPESTATUS[0]}"
assertOk "dictation changed unit apply completes" "$dictationRestartStatus"
assertMatch "dictation changed unit reports restart" "ydotoold service +enabled and restarted" "$dictationRestartOutput"
assertMatch "dictation changed unit reloads systemd" "--user daemon-reload" "$(cat "$dictationRestartSystemctlLog")"
assertMatch "dictation changed unit enables service" "--user enable --now ydotoold.service" "$(cat "$dictationRestartSystemctlLog")"
assertMatch "dictation changed unit restarts service" "--user restart ydotoold.service" "$(cat "$dictationRestartSystemctlLog")"
printf '' >"$dictationRestartSystemctlLog"
dictationUnchangedOutput="$(HOME="$dictationRestartHome" PATH="$dictationRestartBin:/usr/bin:/bin" SYSTEMCTL_LOG="$dictationRestartSystemctlLog" bash "$dictationRestartHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
dictationUnchangedStatus="${PIPESTATUS[0]}"
assertOk "dictation unchanged unit apply completes" "$dictationUnchangedStatus"
assertMatch "dictation unchanged unit reports start" "ydotoold service +enabled and started" "$dictationUnchangedOutput"
assertMatch "dictation unchanged unit enables service" "--user enable --now ydotoold.service" "$(cat "$dictationRestartSystemctlLog")"
assertNoMatch "dictation unchanged unit skips daemon reload" "--user daemon-reload" "$(cat "$dictationRestartSystemctlLog")"
assertNoMatch "dictation unchanged unit skips restart" "--user restart ydotoold.service" "$(cat "$dictationRestartSystemctlLog")"

dictationDnfHome="/tmp/dictation-dnf-home"
dictationDnfBin="/tmp/dictation-dnf-bin"
mkdir -p "$dictationDnfHome"
(
  export HOME="$dictationDnfHome"
  bootstrapCheckout "$dictationDnfHome/.claude"
) >/dev/null 2>&1
installSoftwarePathStubs "$dictationDnfBin" "dnf" "missing"
printf '%s\n' '{ "steps": ["software"] }' > "$dictationDnfHome/.claude/profiles/personal/profile.json"
dictationDnfOutput="$(HOME="$dictationDnfHome" PATH="$dictationDnfBin" /usr/bin/bash "$dictationDnfHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
dictationDnfStatus="${PIPESTATUS[0]}"
assertOk "dictation dnf apply completes" "$dictationDnfStatus"
assertMatch "dictation dnf installs ydotool once" "ydotool +installing via dnf" "$dictationDnfOutput"
assertEquals "dictation dnf makes one ydotool package call" "1" "$(grep -Ec 'ydotool +installing via dnf' <<<"$dictationDnfOutput")"
assertNoMatch "dictation dnf skips ydotoold install tool" "ydotoold +installing via dnf" "$dictationDnfOutput"

dictationNoPackageManagerHome="/tmp/dictation-no-package-manager-home"
dictationNoPackageManagerBin="/tmp/dictation-no-package-manager-bin"
mkdir -p "$dictationNoPackageManagerHome"
(
  export HOME="$dictationNoPackageManagerHome"
  bootstrapCheckout "$dictationNoPackageManagerHome/.claude"
) >/dev/null 2>&1
installSoftwarePathStubs "$dictationNoPackageManagerBin" "" "missing"
cat >"$dictationNoPackageManagerBin/ydotool" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$dictationNoPackageManagerBin/ydotool"
printf '%s\n' '{ "steps": ["software"] }' > "$dictationNoPackageManagerHome/.claude/profiles/personal/profile.json"
dictationNoPackageManagerOutput="$(HOME="$dictationNoPackageManagerHome" PATH="$dictationNoPackageManagerBin" /usr/bin/bash "$dictationNoPackageManagerHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
dictationNoPackageManagerStatus="${PIPESTATUS[0]}"
assertOk "dictation no package manager apply completes" "$dictationNoPackageManagerStatus"
assertMatch "dictation no package manager warns for ydotoold" "ydotoold +install manually" "$dictationNoPackageManagerOutput"

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
# A machine that still carries the retired oh-my-claudecode plugin: settings keys, both
# plugin registries, all four cached dirs, the npm shims, and both state dirs, plus a
# keeper plugin from another marketplace that every removal has to leave alone.
seedRetiredPluginFixture() {
  local homeRoot="$1"
  local shimDir="$2"
  local claudeRoot="$homeRoot/.claude"
  local shimName
  mkdir -p \
    "$claudeRoot/plugins/cache/omc/oh-my-claudecode/1.0.0" \
    "$claudeRoot/plugins/cache/keepmarket/keeper" \
    "$claudeRoot/plugins/marketplaces/omc" \
    "$claudeRoot/plugins/marketplaces/keepmarket" \
    "$claudeRoot/plugins/data/oh-my-claudecode-omc" \
    "$claudeRoot/plugins/data/keeper-keepmarket" \
    "$claudeRoot/plugins/oh-my-claudecode" \
    "$claudeRoot/plugins/keeper" \
    "$claudeRoot/.omc" \
    "$homeRoot/.omc" \
    "$homeRoot/.keep-state" \
    "$shimDir"
  printf 'cached\n' > "$claudeRoot/plugins/cache/omc/oh-my-claudecode/1.0.0/marker.txt"
  printf 'cached\n' > "$claudeRoot/plugins/cache/keepmarket/keeper/marker.txt"
  printf 'plugin\n' > "$claudeRoot/plugins/oh-my-claudecode/plugin.json"
  printf 'plugin\n' > "$claudeRoot/plugins/keeper/plugin.json"
  printf 'state\n' > "$claudeRoot/.omc/session.json"
  printf 'state\n' > "$homeRoot/.omc/session.json"
  printf 'state\n' > "$homeRoot/.keep-state/session.json"
  cat > "$claudeRoot/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "oh-my-claudecode@omc": [{ "version": "1.0.0" }],
    "keeper@keepmarket": [{ "version": "2.0.0" }]
  }
}
JSON
  cat > "$claudeRoot/plugins/known_marketplaces.json" <<'JSON'
{
  "omc": { "source": { "source": "github", "repo": "example/omc" } },
  "keepmarket": { "source": { "source": "github", "repo": "example/keepmarket" } }
}
JSON
  cat > "$claudeRoot/settings.json" <<'JSON'
{
  "enabledPlugins": {
    "oh-my-claudecode@omc": true,
    "keeper@keepmarket": true
  },
  "extraKnownMarketplaces": {
    "omc": { "source": { "source": "github", "repo": "example/omc" } },
    "keepmarket": { "source": { "source": "github", "repo": "example/keepmarket" } }
  },
  "statusLine": { "type": "command", "command": "node ~/.claude/hud/hud.mjs" }
}
JSON
  for shimName in omc omc-cli keep-tool; do
    printf '#!/bin/sh\n' > "$shimDir/$shimName"
    printf 'stub\n' > "$shimDir/$shimName.cmd"
    printf 'stub\n' > "$shimDir/$shimName.ps1"
  done
}

# Keeps the shim teardown inside the fixture home: apply.sh resolves the npm global bin
# dir from `npm prefix -g`, so a stub prefix is what stops it reaching real shims.
installNpmPrefixStub() {
  local stubDir="$1"
  local prefixDir="$2"
  mkdir -p "$stubDir"
  cat > "$stubDir/npm" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "prefix" ]]; then
  printf '%s\n' "$prefixDir"
  exit 0
fi
exit 0
STUB
  chmod +x "$stubDir/npm"
}

# node ships in the same directory as coreutils, so the only way to hide it from apply.sh
# is a PATH of symlinks to every other tool.
installNodelessPathDir() {
  local linkDir="$1"
  local toolPath
  local toolName
  mkdir -p "$linkDir"
  for toolPath in /usr/bin/* /bin/*; do
    toolName="$(basename -- "$toolPath")"
    if [[ "$toolName" == "node" || "$toolName" == "nodejs" ]]; then
      continue
    fi
    ln -sf "$toolPath" "$linkDir/$toolName" 2>/dev/null || true
  done
}

phase "retired plugin teardown"

pluginHome="/tmp/pluginhome"
pluginClaude="$pluginHome/.claude"
pluginStubBin="/tmp/pluginstubbin"
pluginShimDir="$pluginHome/.npm-sandbox/bin"
mkdir -p "$pluginHome"
(
  export HOME="$pluginHome"
  bootstrapCheckout "$pluginClaude"
) >/dev/null 2>&1
installNpmPrefixStub "$pluginStubBin" "$pluginHome/.npm-sandbox"
seedRetiredPluginFixture "$pluginHome" "$pluginShimDir"

pluginOutput="$(HOME="$pluginHome" PATH="$pluginStubBin:$PATH" bash "$pluginClaude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
pluginStatus="${PIPESTATUS[0]}"
assertOk "retired plugin apply completes" "$pluginStatus"
assertMatch "reports the retired plugin as removed" "oh-my-claudecode@omc +removed" "$pluginOutput"
# Marketplace-scoped removal needs node to prove the marketplace is unused, so nodeless runs keep it.
if command -v node >/dev/null 2>&1; then
  assertNoFile "removes the retired marketplace cache" "$pluginClaude/plugins/cache/omc"
  assertNoFile "removes the retired marketplace dir" "$pluginClaude/plugins/marketplaces/omc"
fi
assertNoFile "removes the retired plugin data dir" "$pluginClaude/plugins/data/oh-my-claudecode-omc"
assertNoFile "removes the retired plugin dir" "$pluginClaude/plugins/oh-my-claudecode"
assertDir "keeps another marketplace cache" "$pluginClaude/plugins/cache/keepmarket"
assertDir "keeps another marketplace dir" "$pluginClaude/plugins/marketplaces/keepmarket"
assertDir "keeps another plugin data dir" "$pluginClaude/plugins/data/keeper-keepmarket"
assertDir "keeps another plugin dir" "$pluginClaude/plugins/keeper"
assertNoFile "removes the omc shim" "$pluginShimDir/omc"
assertNoFile "removes the omc .cmd shim" "$pluginShimDir/omc.cmd"
assertNoFile "removes the omc .ps1 shim" "$pluginShimDir/omc.ps1"
assertNoFile "removes the omc-cli shim" "$pluginShimDir/omc-cli"
assertNoFile "removes the omc-cli .cmd shim" "$pluginShimDir/omc-cli.cmd"
assertFile "keeps an unrelated shim" "$pluginShimDir/keep-tool"
assertNoFile "removes the state dir under .claude" "$pluginClaude/.omc"
assertNoFile "removes the state dir under HOME" "$pluginHome/.omc"
assertDir "keeps an unrelated state dir" "$pluginHome/.keep-state"

if command -v node >/dev/null 2>&1; then
  pluginRegistry="$(cat "$pluginClaude/plugins/installed_plugins.json")"
  assertNoMatch "drops the plugin from installed_plugins.json" "oh-my-claudecode@omc" "$pluginRegistry"
  assertMatch "keeps another plugin in installed_plugins.json" "keeper@keepmarket" "$pluginRegistry"
  assertMatch "leaves installed_plugins.json parseable" "^\{" "$pluginRegistry"
  marketplaceRegistry="$(cat "$pluginClaude/plugins/known_marketplaces.json")"
  assertNoMatch "drops the marketplace from known_marketplaces.json" '"omc":' "$marketplaceRegistry"
  assertMatch "keeps another marketplace in known_marketplaces.json" '"keepmarket":' "$marketplaceRegistry"
  assertNoMatch "settings.json carries no retired plugin" "oh-my-claudecode@omc" "$(cat "$pluginClaude/settings.json")"
fi

pluginRerunOutput="$(HOME="$pluginHome" PATH="$pluginStubBin:$PATH" bash "$pluginClaude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
pluginRerunStatus="${PIPESTATUS[0]}"
assertOk "second retired plugin apply completes" "$pluginRerunStatus"
assertMatch "second apply finds nothing to remove" "plugin removals +none present" "$pluginRerunOutput"
assertNoMatch "second apply removes nothing again" "oh-my-claudecode@omc +removed" "$pluginRerunOutput"
# Without node the rerun still warns that the registries were left unchanged.
if command -v node >/dev/null 2>&1; then
  assertNoMatch "second apply warns about nothing" '\[warn\]' "$pluginRerunOutput"
fi
assertDir "second apply keeps the unrelated plugin dir" "$pluginClaude/plugins/keeper"
assertFile "second apply keeps the unrelated shim" "$pluginShimDir/keep-tool"

# Settings teardown needs a run where settings-render cannot rewrite settings.json anyway, so
# these two fixtures trim the profile to the plugins-remove step: one where the marketplace is
# left unused (everything goes) and one where a sibling plugin still needs it (only the
# plugin-scoped paths go).
if command -v node >/dev/null 2>&1; then
  soleHome="/tmp/pluginsolehome"
  soleClaude="$soleHome/.claude"
  soleStubBin="/tmp/pluginsolestubbin"
  soleShimDir="$soleHome/.npm-sandbox/bin"
  mkdir -p "$soleHome"
  (
    export HOME="$soleHome"
    bootstrapCheckout "$soleClaude"
  ) >/dev/null 2>&1
  installNpmPrefixStub "$soleStubBin" "$soleHome/.npm-sandbox"
  seedRetiredPluginFixture "$soleHome" "$soleShimDir"
  printf '{ "steps": ["plugins-remove"] }\n' > "$soleClaude/profiles/work/profile.json"
  soleOutput="$(HOME="$soleHome" PATH="$soleStubBin:$PATH" bash "$soleClaude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
  soleStatus="${PIPESTATUS[0]}"
  assertOk "unused marketplace apply completes" "$soleStatus"
  soleSettings="$(cat "$soleClaude/settings.json")"
  assertNoMatch "strips enabledPlugins of the retired plugin" "oh-my-claudecode@omc" "$soleSettings"
  assertNoMatch "strips extraKnownMarketplaces of an unused marketplace" '"omc":' "$soleSettings"
  assertMatch "keeps an unrelated enabledPlugins key" "keeper@keepmarket" "$soleSettings"
  assertMatch "keeps an unrelated settings key" "statusLine" "$soleSettings"
  assertNoFile "removes an unused marketplace cache dir" "$soleClaude/plugins/cache/omc"
  assertNoFile "removes an unused marketplace dir" "$soleClaude/plugins/marketplaces/omc"
  assertNoMatch "drops an unused marketplace from known_marketplaces.json" '"omc":' "$(cat "$soleClaude/plugins/known_marketplaces.json")"

  keeperHome="/tmp/pluginkeeperhome"
  keeperClaude="$keeperHome/.claude"
  keeperStubBin="/tmp/pluginkeeperstubbin"
  keeperShimDir="$keeperHome/.npm-sandbox/bin"
  mkdir -p "$keeperHome"
  (
    export HOME="$keeperHome"
    bootstrapCheckout "$keeperClaude"
  ) >/dev/null 2>&1
  installNpmPrefixStub "$keeperStubBin" "$keeperHome/.npm-sandbox"
  seedRetiredPluginFixture "$keeperHome" "$keeperShimDir"
  printf '{ "steps": ["plugins-remove"] }\n' > "$keeperClaude/profiles/work/profile.json"
  mkdir -p "$keeperClaude/plugins/cache/omc/sibling/3.0.0"
  printf 'cached\n' > "$keeperClaude/plugins/cache/omc/sibling/3.0.0/marker.txt"
  cat > "$keeperClaude/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "oh-my-claudecode@omc": [{ "version": "1.0.0" }],
    "sibling@omc": [{ "version": "3.0.0" }]
  }
}
JSON
  keeperOutput="$(HOME="$keeperHome" PATH="$keeperStubBin:$PATH" bash "$keeperClaude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
  keeperStatus="${PIPESTATUS[0]}"
  assertOk "marketplace keeper apply completes" "$keeperStatus"
  assertMatch "marketplace keeper still reports a removal" "oh-my-claudecode@omc +removed" "$keeperOutput"
  assertNoFile "removes the retired plugin's own cache dir" "$keeperClaude/plugins/cache/omc/oh-my-claudecode"
  assertNoFile "removes the retired plugin data dir" "$keeperClaude/plugins/data/oh-my-claudecode-omc"
  assertNoFile "removes the retired plugin dir" "$keeperClaude/plugins/oh-my-claudecode"
  assertDir "keeps a sibling plugin's cache dir" "$keeperClaude/plugins/cache/omc/sibling/3.0.0"
  assertDir "keeps a shared marketplace cache dir" "$keeperClaude/plugins/cache/omc"
  assertDir "keeps a shared marketplace dir" "$keeperClaude/plugins/marketplaces/omc"
  keeperSettings="$(cat "$keeperClaude/settings.json")"
  assertNoMatch "strips enabledPlugins even for a shared marketplace" "oh-my-claudecode@omc" "$keeperSettings"
  assertMatch "keeps the extraKnownMarketplaces entry a sibling still needs" '"omc":' "$keeperSettings"
  keeperRegistry="$(cat "$keeperClaude/plugins/installed_plugins.json")"
  assertNoMatch "drops only the retired plugin" "oh-my-claudecode@omc" "$keeperRegistry"
  assertMatch "keeps a sibling plugin from the same marketplace" "sibling@omc" "$keeperRegistry"
  assertMatch "keeps the marketplace a sibling plugin still needs" '"omc":' "$(cat "$keeperClaude/plugins/known_marketplaces.json")"
fi

# node is what edits the JSON registries, so without it the plugin-scoped dirs, shims, and
# state still have to go and the untouched registries have to be reported rather than silently
# skipped. Marketplace-scoped paths stay: their gate cannot be read without node, and the
# fail-safe answer is that some other plugin may still need the marketplace.
nodelessHome="/tmp/pluginnodelesshome"
nodelessClaude="$nodelessHome/.claude"
nodelessStubBin="/tmp/pluginnodelessstubbin"
nodelessShimDir="$nodelessHome/.npm-sandbox/bin"
mkdir -p "$nodelessHome"
(
  export HOME="$nodelessHome"
  bootstrapCheckout "$nodelessClaude"
) >/dev/null 2>&1
installNpmPrefixStub "$nodelessStubBin" "$nodelessHome/.npm-sandbox"
installNodelessPathDir "/tmp/pluginnodelessbin"
seedRetiredPluginFixture "$nodelessHome" "$nodelessShimDir"
nodelessOutput="$(HOME="$nodelessHome" PATH="$nodelessStubBin:/tmp/pluginnodelessbin" bash "$nodelessClaude/setup/apply.sh" --skip-installs --profile work 2>&1 | stripColor)"
nodelessStatus="${PIPESTATUS[0]}"
assertOk "apply without node completes" "$nodelessStatus"
assertMatch "warns that the registries need node" "plugin removals +node not on PATH" "$nodelessOutput"
assertMatch "still reports the retired plugin as removed" "oh-my-claudecode@omc +removed" "$nodelessOutput"
assertNoFile "removes the plugin dir without node" "$nodelessClaude/plugins/oh-my-claudecode"
assertNoFile "removes the plugin cache without node" "$nodelessClaude/plugins/cache/omc/oh-my-claudecode"
assertDir "keeps the marketplace cache dir without node" "$nodelessClaude/plugins/cache/omc"
assertDir "keeps the marketplace dir without node" "$nodelessClaude/plugins/marketplaces/omc"
assertNoFile "removes the shims without node" "$nodelessShimDir/omc"
assertNoFile "removes the state dirs without node" "$nodelessHome/.omc"
assertMatch "leaves installed_plugins.json alone without node" "oh-my-claudecode@omc" "$(cat "$nodelessClaude/plugins/installed_plugins.json")"

# ---------------------------------------------------------------------------
phase "VSCodium extension sync"

extensionHome="/tmp/vscodium-extension-home"
extensionBin="/tmp/vscodium-extension-bin"
extensionLog="$extensionHome/codium.log"
mkdir -p "$extensionHome" "$extensionBin"
(
  export HOME="$extensionHome"
  bootstrapCheckout "$extensionHome/.claude"
) >/dev/null 2>&1
printf '%s\n' '{ "steps": ["vscodium-extensions"], "vscodiumExtensionSync": "exact" }' > "$extensionHome/.claude/profiles/personal/profile.json"
printf 'vendor.tracked\n' > "$extensionHome/.claude/setup/vscodium/extensions.txt"
cat >"$extensionBin/codium" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CODIUM_LOG:?}"
if [[ "${1:-}" == "--list-extensions" ]]; then
  printf 'vendor.extra\n'
  exit 0
fi
exit 0
STUB
chmod +x "$extensionBin/codium"

extensionOutput="$(HOME="$extensionHome" CODIUM_LOG="$extensionLog" PATH="$extensionBin:/usr/bin:/bin" bash "$extensionHome/.claude/setup/apply.sh" --profile personal 2>&1 | stripColor)"
extensionStatus="${PIPESTATUS[0]}"
assertOk "VSCodium extension apply completes" "$extensionStatus"
assertMatch "installs a tracked VSCodium extension" "vendor.tracked +installed" "$extensionOutput"
assertMatch "removes an extra VSCodium extension" "vendor.extra +removed" "$extensionOutput"
assertMatch "codium installs the tracked extension" "--install-extension vendor.tracked" "$(cat "$extensionLog" 2>/dev/null)"
assertMatch "codium uninstalls the extra extension" "--uninstall-extension vendor.extra" "$(cat "$extensionLog" 2>/dev/null)"

# ---------------------------------------------------------------------------
phase "collect.sh round trip"

testRepo="$HOME/work/testrepo"
git clone -q "$originRepo" "$testRepo"
mkdir -p "$HOME/nonrepo"

codiumUser="$HOME/.config/VSCodium/User"
printf '{"editor.fontSize": 42}\n' > "$codiumUser/settings.json"
printf '[{"key": "ctrl+k"}]\n' > "$codiumUser/keybindings.json"
mkdir -p "$HOME/.local/bin" "$HOME/.config/autostart"
printf '#!/usr/bin/env bash\nprintf screenshot\n' > "$HOME/.local/bin/flameshot-save-path"
chmod +x "$HOME/.local/bin/flameshot-save-path"
printf '[Desktop Entry]\nName=flameshot-test\n' > "$HOME/.config/autostart/Flameshot.desktop"
mkdir -p "$HOME/.config/systemd/user"
printf '[Unit]\nDescription=ydotoold-test\n' > "$HOME/.config/systemd/user/ydotoold.service"

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
assertMatch "collects the Flameshot save-path wrapper" "printf screenshot" "$(cat "$claudeHome/setup/screenshot/flameshot-save-path")"
assertMatch "collects the Flameshot autostart entry" "flameshot-test" "$(cat "$claudeHome/setup/screenshot/Flameshot.desktop")"
assertMatch "collects the ydotoold service" "ydotoold-test" "$(cat "$claudeHome/setup/dictation/ydotoold.service")"

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
  installCurlFixture "$autoBin"
  autoOutput="$(TAILSCALE_SERVE_LOG="$autoServeLog" runGlissaServerApply "$autoHome" "$autoBin")"
  autoConfig="$autoHome/.glissa/config.json"
  assertMatch "auto-detect reports the public host" "glissa remote config +publicHost server.machine.tailnet.ts.net \(auto-detected\)" "$autoOutput"
  assertEquals "auto-detect writes publicHost" "server.machine.tailnet.ts.net" "$(jsonField "$autoConfig" 'config.remote.publicHost')"
  assertEquals "auto-detect writes allowedOrigins" '["https://server.machine.tailnet.ts.net"]' "$(jsonField "$autoConfig" 'JSON.stringify(config.remote.allowedOrigins)')"
  assertNoMatch "auto-detect removes CHANGEME" "CHANGEME" "$(cat "$autoConfig")"
  assertEquals "auto-detect keeps config private" "600" "$(stat -c %a "$autoConfig")"
  assertEquals "tailscale serve targets remote.port" "serve --bg 3001" "$(cat "$autoServeLog")"
  assertNoMatch "server profile runs the repos step" "Repos +skipped" "$autoOutput"
  assertMatch "a server with no repos.txt falls back to the example list" "repos +no repos.txt, using repos.example.txt" "$autoOutput"

  autoConfigDigestBefore="$(sha256sum < "$autoConfig" | cut -d' ' -f1)"
  autoRerunOutput="$(TAILSCALE_SERVE_LOG="$autoServeLog" runGlissaServerApply "$autoHome" "$autoBin")"
  autoConfigDigestAfter="$(sha256sum < "$autoConfig" | cut -d' ' -f1)"
  assertMatch "configured rerun reports present remote config" "glissa remote config +configured" "$autoRerunOutput"
  assertNoMatch "configured rerun prompts nothing" "Enable remote access|Remote hostname|listener port" "$autoRerunOutput"
  assertEquals "configured rerun leaves config byte-identical" "$autoConfigDigestBefore" "$autoConfigDigestAfter"

  manualHome="$(mktemp -d)"
  manualBin="$(mktemp -d)"
  prepareGlissaServerFixture "$manualHome" "$manualBin"
  installCurlFixture "$manualBin"
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
  installCurlFixture "$disabledBin"
  # Every glissa fixture answer file starts with two blank lines: the server
  # profile runs the gitconfig step first, and with GIT_CONFIG_GLOBAL pointed at
  # the fixture's absent ~/.gitconfig its name/email prompts consume two answers
  # (tailscale auth and gh auth do not prompt, their stubs report already-authed).
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
  installCurlFixture "$portsBin"
  printf '\n\nY\n2\nBoxOfHolding\ncustom.tailnet.ts.net\nabc\n3000\n3000\n3000\n4444\n3000\nn\n' > "$portsAnswers"
  portsOutput="$(CLAUDE_SETUP_TTY_INPUT="$portsAnswers" runGlissaServerApply "$portsHome" "$portsBin")"
  portsConfig="$portsHome/.glissa/config.json"
  assertMatch "dotless menu hostname is rejected" "pairing and TLS need the full name" "$portsOutput"
  assertMatch "invalid remote port is rejected" "remote port must be 1-65535" "$portsOutput"
  assertMatch "equal ports are rejected" "remote.port must differ from port" "$portsOutput"
  assertEquals "valid remote port is accepted" "4444" "$(jsonField "$portsConfig" 'config.remote.port')"
  assertEquals "valid local port is accepted" "3000" "$(jsonField "$portsConfig" 'config.port')"
  assertEquals "typed hostname is accepted" "custom.tailnet.ts.net" "$(jsonField "$portsConfig" 'config.remote.publicHost')"

  noDetectHostHome="$(mktemp -d)"
  noDetectHostBin="$(mktemp -d)"
  noDetectHostAnswers="$noDetectHostHome/answers.txt"
  prepareGlissaServerFixture "$noDetectHostHome" "$noDetectHostBin"
  installCurlFixture "$noDetectHostBin"
  printf '\n\nY\nBoxOfHolding\nbox.tailnet-name.ts.net\n\n\nn\n' > "$noDetectHostAnswers"
  noDetectHostOutput="$(CLAUDE_SETUP_TTY_INPUT="$noDetectHostAnswers" runGlissaServerApply "$noDetectHostHome" "$noDetectHostBin")"
  assertMatch "dotless no-detection hostname is rejected" "pairing and TLS need the full name" "$noDetectHostOutput"
  assertEquals "valid no-detection hostname is accepted" "box.tailnet-name.ts.net" "$(jsonField "$noDetectHostHome/.glissa/config.json" 'config.remote.publicHost')"

  dotlessOnlyHome="$(mktemp -d)"
  dotlessOnlyBin="$(mktemp -d)"
  dotlessOnlyAnswers="$dotlessOnlyHome/answers.txt"
  prepareGlissaServerFixture "$dotlessOnlyHome" "$dotlessOnlyBin"
  installCurlFixture "$dotlessOnlyBin"
  printf '\n\nY\nBoxOne\nBoxTwo\nBoxThree\n' > "$dotlessOnlyAnswers"
  dotlessOnlyOutput="$(CLAUDE_SETUP_TTY_INPUT="$dotlessOnlyAnswers" runGlissaServerApply "$dotlessOnlyHome" "$dotlessOnlyBin")"
  assertMatch "three dotless hostnames warn about CHANGEME" "publicHost/allowedOrigins still say CHANGEME" "$dotlessOnlyOutput"
  assertMatch "three dotless hostnames preserve CHANGEME" "CHANGEME" "$(cat "$dotlessOnlyHome/.glissa/config.json")"

  wordNoHome="$(mktemp -d)"
  wordNoBin="$(mktemp -d)"
  wordNoAnswers="$wordNoHome/answers.txt"
  prepareGlissaServerFixture "$wordNoHome" "$wordNoBin"
  installTailscaleFixture "$wordNoBin" "wordno.machine.tailnet.ts.net"
  installCurlFixture "$wordNoBin"
  printf '\n\nno\n' > "$wordNoAnswers"
  wordNoOutput="$(CLAUDE_SETUP_TTY_INPUT="$wordNoAnswers" runGlissaServerApply "$wordNoHome" "$wordNoBin")"
  assertMatch "a typed word no disables remote access" "glissa remote config +remote access disabled" "$wordNoOutput"
  assertEquals "a typed word no writes enabled false" "false" "$(jsonField "$wordNoHome/.glissa/config.json" 'config.remote.enabled')"

  badChoiceHome="$(mktemp -d)"
  badChoiceBin="$(mktemp -d)"
  badChoiceAnswers="$badChoiceHome/answers.txt"
  prepareGlissaServerFixture "$badChoiceHome" "$badChoiceBin"
  installTailscaleFixture "$badChoiceBin" "badchoice.machine.tailnet.ts.net"
  installCurlFixture "$badChoiceBin"
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
  installCurlFixture "$mintBin"
  printf '\n\nY\n1\n\n\ny\n' > "$mintAnswers"
  mintOutput="$(CLAUDE_SETUP_TTY_INPUT="$mintAnswers" runGlissaServerApply "$mintHome" "$mintBin")"
  assertMatch "minting prints the pairing URL" "https://paired.example/pair" "$mintOutput"
  assertMatch "minting without credentials warns about claude login" "claude +run claude login on the box" "$mintOutput"

  customPortHome="$(mktemp -d)"
  customPortBin="$(mktemp -d)"
  customPortAnswers="$customPortHome/answers.txt"
  prepareGlissaServerFixture "$customPortHome" "$customPortBin"
  installTailscaleFixture "$customPortBin" "customport.machine.tailnet.ts.net"
  installCurlFixture "$customPortBin"
  mkdir -p "$customPortHome/.glissa"
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.port = 8080; fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2));' "$customPortHome/.claude/setup/glissa/config.server.example.json" "$customPortHome/.glissa/config.json"
  printf '\n\nn\n' > "$customPortAnswers"
  CLAUDE_SETUP_TTY_INPUT="$customPortAnswers" runGlissaServerApply "$customPortHome" "$customPortBin" >/dev/null
  assertEquals "declining remote keeps a customized local port" "8080" "$(jsonField "$customPortHome/.glissa/config.json" 'config.port')"

  driftHome="$(mktemp -d)"
  driftBin="$(mktemp -d)"
  prepareGlissaServerFixture "$driftHome" "$driftBin"
  installTailscaleFixture "$driftBin" "fresh.machine.tailnet.ts.net"
  installCurlFixture "$driftBin"
  mkdir -p "$driftHome/.glissa"
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.port = 9090; config.remote.enabled = true; config.remote.port = 9091; config.remote.publicHost = "old.machine.tailnet.ts.net"; config.remote.allowedOrigins = ["https://old.machine.tailnet.ts.net"]; fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2));' "$driftHome/.claude/setup/glissa/config.server.example.json" "$driftHome/.glissa/config.json"
  driftOutput="$(runGlissaServerApply "$driftHome" "$driftBin")"
  assertMatch "non-interactive drift warns" "publicHost old.machine.tailnet.ts.net but the tailnet reports fresh.machine.tailnet.ts.net" "$driftOutput"
  assertEquals "non-interactive drift leaves publicHost untouched" "old.machine.tailnet.ts.net" "$(jsonField "$driftHome/.glissa/config.json" 'config.remote.publicHost')"
  assertEquals "non-interactive drift leaves origins untouched" '["https://old.machine.tailnet.ts.net"]' "$(jsonField "$driftHome/.glissa/config.json" 'JSON.stringify(config.remote.allowedOrigins)')"

  driftYesHome="$(mktemp -d)"
  driftYesBin="$(mktemp -d)"
  driftYesAnswers="$driftYesHome/answers.txt"
  prepareGlissaServerFixture "$driftYesHome" "$driftYesBin"
  installTailscaleFixture "$driftYesBin" "new.machine.tailnet.ts.net"
  installCurlFixture "$driftYesBin"
  mkdir -p "$driftYesHome/.glissa"
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.port = 9090; config.remote.enabled = true; config.remote.port = 9091; config.remote.publicHost = "old.machine.tailnet.ts.net"; config.remote.allowedOrigins = ["https://old.machine.tailnet.ts.net"]; fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2));' "$driftYesHome/.claude/setup/glissa/config.server.example.json" "$driftYesHome/.glissa/config.json"
  printf '\n\ny\nn\n' > "$driftYesAnswers"
  driftYesOutput="$(CLAUDE_SETUP_TTY_INPUT="$driftYesAnswers" runGlissaServerApply "$driftYesHome" "$driftYesBin")"
  assertMatch "interactive drift repair reports update" "publicHost new.machine.tailnet.ts.net \(tailnet drift repaired\)" "$driftYesOutput"
  assertEquals "interactive drift rewrites publicHost" "new.machine.tailnet.ts.net" "$(jsonField "$driftYesHome/.glissa/config.json" 'config.remote.publicHost')"
  assertEquals "interactive drift rewrites origins" '["https://new.machine.tailnet.ts.net"]' "$(jsonField "$driftYesHome/.glissa/config.json" 'JSON.stringify(config.remote.allowedOrigins)')"
  assertEquals "interactive drift preserves local port" "9090" "$(jsonField "$driftYesHome/.glissa/config.json" 'config.port')"
  assertEquals "interactive drift preserves remote port" "9091" "$(jsonField "$driftYesHome/.glissa/config.json" 'config.remote.port')"

  # A config rewrite must restart the service even when the unit file is
  # unchanged: run once to install the unit, reintroduce drift, run again.
  installSystemdFixture "$driftYesBin"
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.port = 3000; config.remote.port = 3001; fs.writeFileSync(process.argv[1], JSON.stringify(config, null, 2));' "$driftYesHome/.glissa/config.json"
  driftYesUnitLog="$driftYesHome/systemctl-install.log"
  printf '\n\nn\n' > "$driftYesAnswers"
  SYSTEMCTL_LOG="$driftYesUnitLog" GLISSA_CURL_LOCAL_STATUS=200 GLISSA_CURL_REMOTE_STATUS=401 CLAUDE_SETUP_TTY_INPUT="$driftYesAnswers" runGlissaServerApply "$driftYesHome" "$driftYesBin" >/dev/null
  node -e 'const fs = require("fs"); const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); config.remote.publicHost = "old.machine.tailnet.ts.net"; config.remote.allowedOrigins = ["https://old.machine.tailnet.ts.net"]; fs.writeFileSync(process.argv[1], JSON.stringify(config, null, 2));' "$driftYesHome/.glissa/config.json"
  driftYesRestartLog="$driftYesHome/systemctl-rewrite.log"
  printf '\n\ny\nn\n' > "$driftYesAnswers"
  driftRestartOutput="$(SYSTEMCTL_LOG="$driftYesRestartLog" GLISSA_CURL_LOCAL_STATUS=200 GLISSA_CURL_REMOTE_STATUS=401 CLAUDE_SETUP_TTY_INPUT="$driftYesAnswers" runGlissaServerApply "$driftYesHome" "$driftYesBin")"
  assertMatch "unchanged unit is reported up to date" "glissa service +up to date" "$driftRestartOutput"
  assertMatch "config rewrite restarts the running service" "restart glissa" "$(cat "$driftYesRestartLog" 2>/dev/null)"

  tlsFailHome="$(mktemp -d)"
  tlsFailBin="$(mktemp -d)"
  tlsFailServeLog="$tlsFailHome/tailscale-serve.log"
  prepareGlissaServerFixture "$tlsFailHome" "$tlsFailBin"
  installTailscaleFixture "$tlsFailBin" "tlsfail.machine.tailnet.ts.net"
  installCurlFixture "$tlsFailBin"
  tlsFailOutput="$(TAILSCALE_SERVE_LOG="$tlsFailServeLog" GLISSA_CURL_FAIL_CONTAINS="https://tlsfail.machine.tailnet.ts.net/" runGlissaServerApply "$tlsFailHome" "$tlsFailBin")"
  assertMatch "https probe failure names tailscale certificate fix" "enable MagicDNS and HTTPS Certificates in the Tailscale admin console" "$tlsFailOutput"

  tlsOkHome="$(mktemp -d)"
  tlsOkBin="$(mktemp -d)"
  tlsOkServeLog="$tlsOkHome/tailscale-serve.log"
  prepareGlissaServerFixture "$tlsOkHome" "$tlsOkBin"
  installTailscaleFixture "$tlsOkBin" "tlsok.machine.tailnet.ts.net"
  installCurlFixture "$tlsOkBin"
  tlsOkOutput="$(TAILSCALE_SERVE_LOG="$tlsOkServeLog" GLISSA_CURL_HTTPS_STATUS=401 runGlissaServerApply "$tlsOkHome" "$tlsOkBin")"
  assertMatch "https probe accepts 401 as verified TLS" "remote access +TLS verified.*HTTP 401" "$tlsOkOutput"

  servicePathHome="$(mktemp -d)"
  servicePathBin="$(mktemp -d)"
  servicePathSystemctlLog="$servicePathHome/systemctl.log"
  servicePathLoginctlLog="$servicePathHome/loginctl.log"
  prepareGlissaServerFixture "$servicePathHome" "$servicePathBin"
  installCurlFixture "$servicePathBin"
  installSystemdFixture "$servicePathBin"
  SYSTEMCTL_LOG="$servicePathSystemctlLog" LOGINCTL_LOG="$servicePathLoginctlLog" GLISSA_CURL_LOCAL_STATUS=200 GLISSA_CURL_REMOTE_STATUS=401 runGlissaServerApply "$servicePathHome" "$servicePathBin" >/dev/null
  assertMatch "rendered unit PATH includes claude stub directory" "Environment=PATH=$servicePathBin:" "$(cat "$servicePathHome/.config/systemd/user/glissa.service")"
  assertMatch "changed unit restarts glissa" "restart glissa" "$(cat "$servicePathSystemctlLog")"

  claudeLoggedInHome="$(mktemp -d)"
  claudeLoggedInBin="$(mktemp -d)"
  prepareGlissaServerFixture "$claudeLoggedInHome" "$claudeLoggedInBin"
  mkdir -p "$claudeLoggedInHome/.claude"
  printf '{}\n' > "$claudeLoggedInHome/.claude/.credentials.json"
  claudeLoggedInOutput="$(runGlissaServerApply "$claudeLoggedInHome" "$claudeLoggedInBin")"
  assertMatch "claude credentials report logged in" "claude +installed and logged in" "$claudeLoggedInOutput"

  claudeLoginHome="$(mktemp -d)"
  claudeLoginBin="$(mktemp -d)"
  prepareGlissaServerFixture "$claudeLoginHome" "$claudeLoginBin"
  claudeLoginOutput="$(runGlissaServerApply "$claudeLoginHome" "$claudeLoginBin")"
  assertMatch "missing claude credentials warn to login" "claude +run claude login on the box" "$claudeLoginOutput"

  claudePathHome="$(mktemp -d)"
  claudePathBin="$(mktemp -d)"
  prepareGlissaServerFixture "$claudePathHome" "$claudePathBin"
  installCurlFixture "$claudePathBin"
  rm -f "$claudePathBin/claude"
  claudePathOutput="$(runGlissaServerApply "$claudePathHome" "$claudePathBin")"
  assertMatch "missing claude binary warns with PATH remedy" 'claude +not on PATH, run: export PATH="\$HOME/.local/bin:\$PATH" or re-run apply' "$claudePathOutput"

  healthOkHome="$(mktemp -d)"
  healthOkBin="$(mktemp -d)"
  prepareGlissaServerFixture "$healthOkHome" "$healthOkBin"
  installCurlFixture "$healthOkBin"
  installSystemdFixture "$healthOkBin"
  GLISSA_CURL_LOCAL_STATUS=200 GLISSA_CURL_REMOTE_STATUS=401 runGlissaServerApply "$healthOkHome" "$healthOkBin" >/dev/null
  assertMatch "health probe reports local listener" "glissa health +local listener serving" "$(GLISSA_CURL_LOCAL_STATUS=200 GLISSA_CURL_REMOTE_STATUS=401 runGlissaServerApply "$healthOkHome" "$healthOkBin")"

  healthFailHome="$(mktemp -d)"
  healthFailBin="$(mktemp -d)"
  prepareGlissaServerFixture "$healthFailHome" "$healthFailBin"
  installCurlFixture "$healthFailBin"
  installSystemdFixture "$healthFailBin"
  healthFailOutput="$(GLISSA_CURL_FAIL_CONTAINS="127.0.0.1" runGlissaServerApply "$healthFailHome" "$healthFailBin")"
  assertMatch "health probe failure gives journalctl hint" "journalctl --user -u glissa -n 20" "$healthFailOutput"
fi

# ---------------------------------------------------------------------------
phase "repos loop survives a bad repo"

# A production apply died here: an unborn HEAD made "git branch develop" exit 128
# under set -e, so every repo after it was silently never cloned.
reposHome="$(mktemp -d)"
reposBin="$(mktemp -d)"
reposOrigins="$reposHome/origins"
mkdir -p "$reposOrigins"
(
  export HOME="$reposHome"
  bootstrapCheckout "$reposHome/.claude"
) >/dev/null 2>&1
printf '%s\n' '{ "steps": ["repos"], "vscodiumExtensionSync": "exact" }' > "$reposHome/.claude/profiles/work/profile.json"

# Deterministic failing install, so the assertion does not depend on the image's npm.
cat >"$reposBin/npm" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "install" ]]; then
  printf 'gyp ERR! build error: native module failed to compile\n' >&2
  exit 1
fi
exit 0
STUB
chmod +x "$reposBin/npm"

# The ownership rule reads "git remote get-url", and a real github url cannot be cloned
# offline, so ONLY that lookup is faked and everything else is the real git. Ownership
# follows the directory name: foreign* belongs to someone else, everything else to us.
cat >"$reposBin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" && "${3:-}" == "remote" && "${4:-}" == "get-url" ]]; then
  case "$(basename -- "$2")" in
    foreign*) printf 'https://github.com/someoneelse/%s.git\n' "$(basename -- "$2")" ;;
    *) printf 'https://github.com/testowner/%s.git\n' "$(basename -- "$2")" ;;
  esac
  exit 0
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$reposBin/git"

git init -q --bare "$reposOrigins/emptyrepo.git"
for reposFixture in faildeps followrepo nodepsrepo badflagrepo ownedrepo foreignrepo; do
  git init -q --bare "$reposOrigins/$reposFixture.git"
  git init -q "$reposHome/src-$reposFixture"
  printf '{"name":"%s","version":"1.0.0"}\n' "$reposFixture" > "$reposHome/src-$reposFixture/package.json"
  git -C "$reposHome/src-$reposFixture" add -A
  git -C "$reposHome/src-$reposFixture" commit -qm init
  git -C "$reposHome/src-$reposFixture" push -q "$reposOrigins/$reposFixture.git" master
done

cat >"$reposHome/.claude/setup/repos.txt" <<REPOS
work/emptyrepo=$reposOrigins/emptyrepo.git
work/ownedrepo=$reposOrigins/ownedrepo.git
work/foreignrepo=$reposOrigins/foreignrepo.git
work/faildeps=$reposOrigins/faildeps.git
work/nodepsrepo=$reposOrigins/nodepsrepo.git nodeps
work/badflagrepo=$reposOrigins/badflagrepo.git no-deps
work/followrepo=$reposOrigins/followrepo.git
REPOS

reposOutput="$(HOME="$reposHome" PATH="$reposBin:$PATH" bash "$reposHome/.claude/setup/apply.sh" --profile work 2>&1 | stripColor)"
reposStatus="${PIPESTATUS[0]}"
assertOk "a bad repo does not abort apply" "$reposStatus"
assertMatch "an empty clone warns instead of dying" "emptyrepo develop +no commits yet" "$reposOutput"
assertMatch "a failing deps install warns" "faildeps deps +npm install failed" "$reposOutput"
assertDir "a repo listed after the failures is still cloned" "$reposHome/work/followrepo/.git"
assertMatch "the run still prints its summary" "Done in" "$reposOutput"
assertDir "a nodeps repo is still cloned" "$reposHome/work/nodepsrepo/.git"
assertMatch "a nodeps repo reports the skip" "nodepsrepo deps +skipped \(nodeps\)" "$reposOutput"
assertNoMatch "a nodeps repo attempts no install" "nodepsrepo deps +npm install" "$reposOutput"
assertMatch "an unrecognized flag warns" "badflagrepo +unknown repos.txt flag ignored: no-deps" "$reposOutput"
assertMatch "an unrecognized flag still installs deps" "badflagrepo deps +npm install failed" "$reposOutput"

# ---------------------------------------------------------------------------
phase "develop is never pushed to a repo the operator does not own"

# apply once created and pushed develop to two repos the operator merely had access to.
# "rev-parse --abbrev-ref develop" echoes "develop" even when the branch is missing, so
# absence is checked with "branch --list", which prints nothing when there is no match.
assertEquals "an owned repo still gets develop" "develop" "$(git -C "$reposHome/work/ownedrepo" branch --list --format='%(refname:short)' develop)"
assertMatch "an owned repo reports the push" "ownedrepo develop +created and pushed" "$reposOutput"
assertMatch "a foreign repo reports the skip" "foreignrepo develop +develop sync skipped \(not your repo\)" "$reposOutput"
assertEquals "a foreign repo gets no develop branch" "" "$(git -C "$reposHome/work/foreignrepo" branch --list develop)"
assertDir "a foreign repo is still cloned" "$reposHome/work/foreignrepo/.git"

ownerlessHome="$(mktemp -d)"
ownerlessOrigins="$ownerlessHome/origins"
mkdir -p "$ownerlessOrigins"
(
  export HOME="$ownerlessHome"
  bootstrapCheckout "$ownerlessHome/.claude"
) >/dev/null 2>&1
printf '%s\n' '{ "steps": ["repos"], "vscodiumExtensionSync": "exact" }' > "$ownerlessHome/.claude/profiles/work/profile.json"
git init -q --bare "$ownerlessOrigins/plainrepo.git"
git init -q "$ownerlessHome/src-plainrepo"
printf 'plain\n' > "$ownerlessHome/src-plainrepo/readme.md"
git -C "$ownerlessHome/src-plainrepo" add -A
git -C "$ownerlessHome/src-plainrepo" commit -qm init
git -C "$ownerlessHome/src-plainrepo" push -q "$ownerlessOrigins/plainrepo.git" master
printf 'work/plainrepo=%s\n' "$ownerlessOrigins/plainrepo.git" > "$ownerlessHome/.claude/setup/repos.txt"

# This checkout's origin is a local path, so the operator's owner cannot be read.
ownerlessOutput="$(HOME="$ownerlessHome" bash "$ownerlessHome/.claude/setup/apply.sh" --profile work 2>&1 | stripColor)"
assertMatch "an unreadable operator owner warns" "plainrepo develop +develop sync skipped \(cannot tell which GitHub owner is yours\)" "$ownerlessOutput"
assertEquals "an unreadable operator owner creates no develop" "" "$(git -C "$ownerlessHome/work/plainrepo" branch --list develop)"
assertDir "an unreadable operator owner still clones" "$ownerlessHome/work/plainrepo/.git"

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
if command -v apt-get >/dev/null 2>&1; then
  command -v codium >/dev/null 2>&1
  assertOk "installs VSCodium" $?
  assertMatch "reports VSCodium installed or present" "VSCodium +(installed|already installed)" "$fullOutput"
fi
if ! command -v apt-get >/dev/null 2>&1; then
  assertMatch "reports VSCodium as needing a manual install" "vscodium.com" "$fullOutput"
fi
assertDir "clones the repo listed in repos.txt" "$HOME/work/clonedrepo/.git"
# The suite's checkout origin is a local path, so the operator's owner is unreadable
# and the ownership rule fails safe: clone yes, develop no.
assertEquals "creates no develop when the owner is unreadable" "" "$(git -C "$HOME/work/clonedrepo" branch --list develop)"
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

emojiChar="$(printf '\xf0\x9f\x9a\x80')"
emojiWrite="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"a.md\",\"content\":\"one ${emojiChar} two\"}}"
assertMatch "a new emoji is denied" '"permissionDecision": *"deny"' "$(runHook "$emojiWrite")"

hookFixtureDir="$(mktemp -d)"
printf 'kept %s here\n' "$emojiChar" > "$hookFixtureDir/has-emoji.md"
emojiKept="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$hookFixtureDir/has-emoji.md\",\"content\":\"kept ${emojiChar} here and ${emojiChar}\"}}"
assertEquals "an emoji is allowed in a file that already has one" "" "$(runHook "$emojiKept")"

# The size cap only applies at a repo root or in ~/.claude, so the fixture needs
# a .git marker and a nested dir to prove both sides of that scoping.
mkdir -p "$hookFixtureDir/.git" "$hookFixtureDir/nested"
oversized="$(printf 'y%.0s' {1..20000})"
printf '%s' "$oversized" > "$hookFixtureDir/AGENTS.md"
grown="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$hookFixtureDir/AGENTS.md\",\"content\":\"${oversized}y\"}}"
assertMatch "growing AGENTS.md past its cap is denied" '"permissionDecision": *"deny"' "$(runHook "$grown")"

shrunk="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$hookFixtureDir/AGENTS.md\",\"content\":\"${oversized:0:19000}\"}}"
assertEquals "shrinking an oversized AGENTS.md is allowed" "" "$(runHook "$shrunk")"

nested="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$hookFixtureDir/nested/AGENTS.md\",\"content\":\"$oversized\"}}"
assertEquals "a nested AGENTS.md is not capped" "" "$(runHook "$nested")"
rm -rf "$hookFixtureDir"

printf '\n%s passed, %s failed (full mode)\n' "$passCount" "$failCount"
if ((failCount > 0)); then
  exit 1
fi
exit 0
