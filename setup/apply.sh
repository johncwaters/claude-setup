#!/usr/bin/env bash
set -euo pipefail

skipInstalls=0
profile=""
dryRun=0
countsApplied=0
countsInstalled=0
countsPresent=0
countsWarned=0
retrySettingsRender=0
retryRemoveRetiredPlugins=0
aptUpdated=0
operatorGitHubOwner=""
detectedPackageManager=""
minimumNodeMajor=20
nodeSourceMajor=22
dpkgLockWaitSeconds=180
packageInstallLog=""
scriptStartSeconds="$SECONDS"
promptInputOpen=0
glissaRemoteSettingsRewritten=0
glissaServeStarted=0

setupDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repoRoot="$(cd -- "$setupDir/.." && pwd)"
glissaServerRepoDir="$HOME/Projects/glissa"

colorCyan=$'\033[36m'
colorGreen=$'\033[32m'
colorYellow=$'\033[33m'
colorRed=$'\033[31m'
colorDarkGray=$'\033[90m'
colorReset=$'\033[0m'

usage() {
  cat <<'USAGE'
Usage: setup/apply.sh [--skip-installs] [--profile personal|work|server] [--dry-run] [--help]

Apply repo config to this machine.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --skip-installs)
      skipInstalls=1
      shift
      ;;
    --profile)
      if (($# < 2)); then
        printf 'apply.sh: --profile requires personal, work, or server\n' >&2
        exit 2
      fi
      profile="$2"
      shift 2
      ;;
    --dry-run)
      dryRun=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'apply.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$profile" in
  ""|personal|work|server) ;;
  *)
    printf 'apply.sh: --profile must be personal, work, or server\n' >&2
    exit 2
    ;;
esac

writeSection() {
  local title="$1"
  printf '\n'
  printf '%s  %s%s\n' "$colorCyan" "$title" "$colorReset"
}

writeLine() {
  local mark="$1"
  local color="$2"
  local label="$3"
  local note="$4"
  printf '    %s[%s]%s %-26s %s%s%s\n' "$color" "$mark" "$colorReset" "$label" "$colorDarkGray" "$note" "$colorReset"
}

noteApplied() {
  local label="$1"
  local note="$2"
  writeLine " ok " "$colorGreen" "$label" "$note"
  countsApplied=$((countsApplied + 1))
}

noteInstalled() {
  local label="$1"
  local note="$2"
  writeLine " ++ " "$colorYellow" "$label" "$note"
  countsInstalled=$((countsInstalled + 1))
}

notePresent() {
  local label="$1"
  local note="$2"
  writeLine " -- " "$colorDarkGray" "$label" "$note"
  countsPresent=$((countsPresent + 1))
}

noteWarned() {
  local label="$1"
  local note="$2"
  writeLine "warn" "$colorRed" "$label" "$note"
  countsWarned=$((countsWarned + 1))
}

noteSkipped() {
  local label="$1"
  writeLine " -- " "$colorDarkGray" "$label" "skipped ($profile profile)"
}

stepEnabled() {
  local stepName="$1"
  local enabledStep
  for enabledStep in "${steps[@]}"; do
    if [[ "$enabledStep" == "$stepName" ]]; then
      return 0
    fi
  done
  return 1
}

refreshSessionPath() {
  local userLocalBin="$HOME/.local/bin"
  local npmGlobalBin="$HOME/.npm-global/bin"
  if [[ -d "$userLocalBin" && ":$PATH:" != *":$userLocalBin:"* ]]; then
    PATH="$userLocalBin:$PATH"
  fi
  if [[ -d "$npmGlobalBin" && ":$PATH:" != *":$npmGlobalBin:"* ]]; then
    PATH="$npmGlobalBin:$PATH"
  fi
  export PATH
  hash -r 2>/dev/null || true
}

# Test-only pty substitute for the container suite.
hasPromptInputFixture() {
  [[ -n "${CLAUDE_SETUP_TTY_INPUT:-}" && -r "${CLAUDE_SETUP_TTY_INPUT:-}" ]]
}

canPromptUser() {
  if hasPromptInputFixture; then
    return 0
  fi
  [[ -r /dev/tty && -t 1 ]]
}

openPromptInput() {
  if ((promptInputOpen == 1)); then
    return 0
  fi
  if hasPromptInputFixture; then
    exec 9< "$CLAUDE_SETUP_TTY_INPUT"
    promptInputOpen=1
    return 0
  fi
  exec 9< /dev/tty
  promptInputOpen=1
}

promptValue() {
  local question="$1"
  local answer=""
  local renderedPrompt="$question"
  if [[ ! "$renderedPrompt" =~ [[:space:]]$ ]]; then
    renderedPrompt="$renderedPrompt "
  fi
  if hasPromptInputFixture; then
    printf '%s\n' "$renderedPrompt" >&2
  fi
  if ! hasPromptInputFixture; then
    printf '%s' "$renderedPrompt" > /dev/tty
  fi
  IFS= read -r answer <&9 || answer=""
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  printf '%s\n' "$answer"
}

promptYesNo() {
  local question="$1"
  local answer
  answer="$(promptValue "$question (y/N)")"
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

# cmp lives in diffutils, which minimal images (Fedora, openSUSE) do not ship. A
# missing cmp used to read as "files differ", so every run rewrote every file.
# sha256sum is coreutils, so it is present wherever cp and mkdir are.
filesAreIdentical() {
  local left="$1"
  local right="$2"
  if [[ ! -f "$left" || ! -f "$right" ]]; then
    return 1
  fi
  local leftDigest
  local rightDigest
  leftDigest="$(sha256sum < "$left" | cut -d' ' -f1)"
  rightDigest="$(sha256sum < "$right" | cut -d' ' -f1)"
  [[ "$leftDigest" == "$rightDigest" ]]
}

copyConfig() {
  local label="$1"
  local src="$2"
  local dest="$3"
  if [[ ! -f "$src" ]]; then
    noteWarned "$label" "not in repo"
    return 0
  fi
  mkdir -p "$(dirname -- "$dest")"
  if filesAreIdentical "$src" "$dest"; then
    notePresent "$label" "up to date"
    return 0
  fi
  cp -f "$src" "$dest"
  noteApplied "$label" "updated"
}

copyGlissaSeedConfig() {
  local src="$1"
  local dest="$2"
  local tempConfig
  local seedContent
  local homeForJson
  if [[ ! -f "$src" ]]; then
    noteWarned "glissa config" "not in repo"
    return 0
  fi
  tempConfig="$(mktemp "${TMPDIR:-/tmp}/claude-glissa-config.XXXXXX")"
  trap 'rm -f "$tempConfig"' RETURN
  seedContent="$(<"$src")"
  homeForJson="${HOME//\\/\/}"
  seedContent="${seedContent//C:\\\\Users\\\\YOUR_USERNAME/$homeForJson}"
  seedContent="${seedContent//\\\\//}"
  printf '%s\n' "$seedContent" >"$tempConfig"
  copyConfig "glissa config" "$tempConfig" "$dest"
}

backupIfFirstRun() {
  local dest="$1"
  local src="$2"
  if ((markerExisted == 1)); then
    return 0
  fi
  if [[ ! -f "$dest" ]]; then
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    return 0
  fi
  if filesAreIdentical "$src" "$dest"; then
    return 0
  fi
  cp -f "$dest" "$dest.pre-profile.bak"
  noteApplied "$(basename -- "$dest") backup" "saved .pre-profile.bak"
}

invokeSettingsRender() {
  local base="$repoRoot/settings.base.json"
  local overlay="$repoRoot/profiles/$profile/settings.overlay.json"
  local dest="$repoRoot/settings.json"
  local render="$setupDir/render-settings.mjs"
  local existed=0
  local tempDest
  local renderErr
  local madeBackup=0
  if ! command -v node >/dev/null 2>&1; then
    noteWarned "settings.json" "node not on PATH, will retry after installs"
    retrySettingsRender=1
    return 0
  fi
  retrySettingsRender=0
  if [[ -f "$dest" ]]; then
    existed=1
  fi
  tempDest="$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")"
  renderErr="$(mktemp "${TMPDIR:-/tmp}/claude-settings-render.XXXXXX")"
  if ! node "$render" "$base" "$overlay" "$tempDest" 2>"$renderErr"; then
    local firstErrLine
    firstErrLine="$(head -n 1 "$renderErr" 2>/dev/null || true)"
    rm -f "$tempDest" "$renderErr"
    if [[ -n "$firstErrLine" ]]; then
      noteWarned "settings.json" "render failed: $firstErrLine"
      return 0
    fi
    noteWarned "settings.json" "render failed"
    return 0
  fi
  rm -f "$renderErr"
  if ((existed == 1)) && filesAreIdentical "$tempDest" "$dest"; then
    rm -f "$tempDest"
    notePresent "settings.json" "up to date"
    return 0
  fi
  if ((markerExisted == 0)) && ((existed == 1)); then
    cp -f "$dest" "$dest.pre-profile.bak"
    madeBackup=1
  fi
  mv -f "$tempDest" "$dest"
  if ((madeBackup == 1)); then
    noteApplied "settings.json backup" "saved .pre-profile.bak"
  fi
  noteApplied "settings.json" "rendered"
}

detectPackageManager() {
  if [[ -n "$detectedPackageManager" ]]; then
    printf '%s\n' "$detectedPackageManager"
    return 0
  fi
  local manager
  for manager in apt-get dnf pacman zypper; do
    if command -v "$manager" >/dev/null 2>&1; then
      detectedPackageManager="$manager"
      printf '%s\n' "$detectedPackageManager"
      return 0
    fi
  done
  return 1
}

isRoot() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

canInstallSystemPackages() {
  if isRoot; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

runPackageManagerCommand() {
  if isRoot; then
    "$@"
    return $?
  fi
  sudo "$@"
}

# A desktop packagekitd or an unattended-upgrades run holds the dpkg lock for
# minutes at a time, and apt fails outright rather than waiting for it.
installSystemPackages() {
  local manager="$1"
  shift
  local outputSink="${packageInstallLog:-/dev/null}"
  case "$manager" in
    apt-get)
      if ((aptUpdated == 0)); then
        if ! runPackageManagerCommand apt-get -o DPkg::Lock::Timeout="$dpkgLockWaitSeconds" update >>"$outputSink" 2>&1; then
          return 1
        fi
        aptUpdated=1
      fi
      runPackageManagerCommand apt-get -o DPkg::Lock::Timeout="$dpkgLockWaitSeconds" install -y "$@" >>"$outputSink" 2>&1
      return $?
      ;;
    dnf)
      runPackageManagerCommand dnf install -y "$@" >>"$outputSink" 2>&1
      return $?
      ;;
    pacman)
      runPackageManagerCommand pacman -S --noconfirm --needed "$@" >>"$outputSink" 2>&1
      return $?
      ;;
    zypper)
      runPackageManagerCommand zypper --non-interactive install "$@" >>"$outputSink" 2>&1
      return $?
      ;;
  esac
  return 1
}

# Third-party installers run their own apt-get, so the lock timeout above cannot
# reach them. Blocking on a lock-taking no-op first hands them a free lock.
waitForPackageManagerLock() {
  local manager
  if ! manager="$(detectPackageManager)"; then
    return 0
  fi
  if [[ "$manager" != "apt-get" ]]; then
    return 0
  fi
  if ! canInstallSystemPackages; then
    return 0
  fi
  runPackageManagerCommand apt-get -o DPkg::Lock::Timeout="$dpkgLockWaitSeconds" check >/dev/null 2>&1 || true
}

lastLogLine() {
  local logPath="$1"
  grep -v '^[[:space:]]*$' "$logPath" 2>/dev/null | tail -n 1 | cut -c1-100
}

npmGlobalRootWritable() {
  local npmGlobalRoot
  npmGlobalRoot="$(npm root -g 2>/dev/null || true)"
  if [[ -z "$npmGlobalRoot" ]]; then
    return 1
  fi
  if [[ -d "$npmGlobalRoot" ]]; then
    [[ -w "$npmGlobalRoot" ]]
    return $?
  fi
  local npmGlobalRootParent
  npmGlobalRootParent="$(dirname -- "$npmGlobalRoot")"
  [[ -d "$npmGlobalRootParent" && -w "$npmGlobalRootParent" ]]
}

# npm as root (or via sudo) breaks native lifecycle builds (node-pty dies with
# uv_cwd ENOENT), so an unwritable global root gets a per-account prefix instead.
userNpmPrefixEnsured=0
ensureUserNpmPrefix() {
  if ((userNpmPrefixEnsured == 1)); then
    return 0
  fi
  userNpmPrefixEnsured=1
  if isRoot; then
    return 0
  fi
  if npmGlobalRootWritable; then
    return 0
  fi
  if ! npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1; then
    noteWarned "npm prefix" "npm config set prefix failed; global installs may hit EACCES"
    return 0
  fi
  mkdir -p "$HOME/.npm-global/bin"
  refreshSessionPath
  if [[ ! -f "$HOME/.bashrc" ]] || ! grep -q '\.npm-global/bin' "$HOME/.bashrc"; then
    printf 'export PATH="$HOME/.npm-global/bin:$PATH"\n' >>"$HOME/.bashrc"
  fi
  writeLine " ok " "$colorGreen" "npm prefix" "global root not writable, using ~/.npm-global"
}

# Pop!_OS ~/.profile adds ~/.local/bin only if it exists at login; the installer creates it later this run.
persistUserLocalBinOnPath() {
  if [[ -f "$HOME/.bashrc" ]] && grep -q '\.local/bin' "$HOME/.bashrc"; then
    return 0
  fi
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.bashrc"
  noteApplied "~/.bashrc PATH" "added ~/.local/bin"
}

# Global installs straight from a git spec run native postinstalls (glissa's
# node-pty) in a directory npm has already moved, dying with ENOENT uv_cwd
# (github.com/emiasims/tree-sitter-org/issues/37), so pack first and install
# the tarball, which takes the ordinary registry-style path.
installGlobalNpmPackage() {
  local packageSource="$1"
  if [[ "$packageSource" != github:* && "$packageSource" != git+* && "$packageSource" != git:* ]]; then
    npm install -g "$packageSource" --loglevel=error
    return $?
  fi
  local packDir tarball status
  packDir="$(mktemp -d "${TMPDIR:-/tmp}/claude-npm-pack.XXXXXX")"
  if ! (cd "$packDir" && npm pack "$packageSource" --loglevel=error >/dev/null); then
    rm -rf "$packDir"
    return 1
  fi
  tarball="$(find "$packDir" -maxdepth 1 -name '*.tgz' | head -n 1)"
  if [[ -z "$tarball" ]]; then
    rm -rf "$packDir"
    return 1
  fi
  npm install -g "$tarball" --loglevel=error
  status=$?
  rm -rf "$packDir"
  return $status
}

npmFailureReason() {
  local npmLogFile="$1"
  local reason
  reason="$(grep -E -m1 'EACCES|EPERM|E404|ENOTFOUND|EAI_AGAIN|uv_cwd|code E' "$npmLogFile" 2>/dev/null || true)"
  if [[ -z "$reason" ]]; then
    reason="$(grep -v 'A complete log of this run' "$npmLogFile" 2>/dev/null | awk 'NF { line=$0 } END { print line }')"
  fi
  reason="$(sed -E 's/^npm (error|ERR!) //' <<<"$reason")"
  printf '%.120s\n' "$reason"
}

packageNamesForTool() {
  local manager="$1"
  local toolKey="$2"
  case "$toolKey:$manager" in
    git:apt-get|git:dnf|git:pacman|git:zypper)
      printf 'git\n'
      return 0
      ;;
    node:apt-get|node:dnf|node:pacman|node:zypper)
      printf 'nodejs\nnpm\n'
      return 0
      ;;
    python:apt-get|python:dnf|python:zypper)
      printf 'python3\npython3-pip\n'
      return 0
      ;;
    python:pacman)
      printf 'python\npython-pip\n'
      return 0
      ;;
    gh:dnf)
      printf 'gh\n'
      return 0
      ;;
    gh:apt-get)
      printf 'gh\n'
      return 0
      ;;
    gh:pacman)
      printf 'github-cli\n'
      return 0
      ;;
    solaar:apt-get)
      printf 'solaar\n'
      return 0
      ;;
    ratbagd:apt-get)
      printf 'ratbagd\n'
      return 0
      ;;
    piper:apt-get)
      printf 'piper\n'
      return 0
      ;;
  esac
  return 1
}

pythonHasPip() {
  local python
  if ! python="$(pythonCommandName)"; then
    return 1
  fi
  "$python" -m pip --version >/dev/null 2>&1
}

nodeMajorVersion() {
  local versionText
  if ! versionText="$(node -v 2>/dev/null)"; then
    return 1
  fi
  versionText="${versionText#v}"
  versionText="${versionText%%.*}"
  if [[ ! "$versionText" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$versionText"
}

# Debian bookworm ships Node 18, which the glissa build (Vite) refuses to run
# under, so an old node counts as absent rather than as "already installed".
nodeIsCurrentEnough() {
  local major
  if ! major="$(nodeMajorVersion)"; then
    return 1
  fi
  ((major >= minimumNodeMajor))
}

# python3 usually arrives as a dependency of something else while pip does not,
# and a python without pip cannot install ruff, which the validate-file hook
# needs for its Python gate. Treat pip as part of what "python is present" means.
toolIsPresent() {
  local toolKey="$1"
  local commandName="$2"
  if [[ "$toolKey" == "python" ]]; then
    pythonHasPip
    return $?
  fi
  if [[ "$toolKey" == "node" ]]; then
    nodeIsCurrentEnough
    return $?
  fi
  command -v "$commandName" >/dev/null 2>&1
}

vscodiumDebArchitecture() {
  local architecture
  if ! command -v dpkg >/dev/null 2>&1; then
    return 1
  fi
  architecture="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ "$architecture" == "amd64" || "$architecture" == "arm64" ]]; then
    printf '%s\n' "$architecture"
    return 0
  fi
  return 1
}

installVscodiumAptDeb() {
  local label="$1"
  local architecture
  local downloadDir
  local releaseJson
  local assetUrl
  local debFile
  local installLog
  refreshSessionPath
  if command -v codium >/dev/null 2>&1; then
    notePresent "$label" "already installed"
    return 0
  fi
  if ! canInstallSystemPackages; then
    noteWarned "$label" "apt-get needs root or sudo, install from https://vscodium.com"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "$label" "curl not on PATH, install from https://vscodium.com"
    return 0
  fi
  if ! architecture="$(vscodiumDebArchitecture)"; then
    noteWarned "$label" "unsupported architecture for .deb install, install from https://vscodium.com"
    return 0
  fi
  writeLine " .. " "$colorYellow" "$label" "installing .deb from GitHub releases"
  downloadDir="$(mktemp -d "${TMPDIR:-/tmp}/claude-vscodium.XXXXXX")"
  releaseJson="$downloadDir/release.json"
  local apiAuthArgs=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    apiAuthArgs=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  if ! curl -fsSL ${apiAuthArgs[@]+"${apiAuthArgs[@]}"} https://api.github.com/repos/VSCodium/vscodium/releases/latest -o "$releaseJson"; then
    noteWarned "$label" "release lookup failed, install from https://vscodium.com"
    rm -rf "$downloadDir"
    return 0
  fi
  assetUrl="$(grep -E '"browser_download_url": "https://[^"]+\.deb"' "$releaseJson" | grep -E "(${architecture})\\.deb\"" | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/' | head -n 1 || true)"
  if [[ -z "$assetUrl" ]]; then
    noteWarned "$label" "no matching .deb asset, install from https://vscodium.com"
    rm -rf "$downloadDir"
    return 0
  fi
  debFile="$(basename -- "$assetUrl")"
  if ! curl -fL "$assetUrl" -o "$downloadDir/$debFile"; then
    noteWarned "$label" "download failed, install from https://vscodium.com"
    rm -rf "$downloadDir"
    return 0
  fi
  installLog="$(mktemp "${TMPDIR:-/tmp}/claude-vscodium-install.XXXXXX")"
  packageInstallLog="$installLog"
  if ! (cd "$downloadDir" && installSystemPackages apt-get "./$debFile"); then
    packageInstallLog=""
    noteWarned "$label" "apt-get install failed: $(lastLogLine "$installLog"), install from https://vscodium.com"
    rm -rf "$downloadDir"
    rm -f "$installLog"
    return 0
  fi
  packageInstallLog=""
  rm -rf "$downloadDir"
  rm -f "$installLog"
  refreshSessionPath
  if command -v codium >/dev/null 2>&1; then
    noteInstalled "$label" "installed"
    return 0
  fi
  noteWarned "$label" "installed, but open a new shell for PATH"
}

installPackageTool() {
  local label="$1"
  local commandName="$2"
  local toolKey="$3"
  local manager
  local packageNameArgs=()
  refreshSessionPath
  if toolIsPresent "$toolKey" "$commandName"; then
    notePresent "$label" "already installed"
    return 0
  fi
  if ! manager="$(detectPackageManager)"; then
    noteWarned "$label" "no supported package manager, install manually"
    return 0
  fi
  mapfile -t packageNameArgs < <(packageNamesForTool "$manager" "$toolKey" || true)
  if ((${#packageNameArgs[@]} == 0)); then
    if [[ "$toolKey" == "vscodium" ]]; then
      if [[ "$manager" == "apt-get" ]]; then
        installVscodiumAptDeb "$label"
        return 0
      fi
      noteWarned "$label" "not in default repos, install from https://vscodium.com/#install"
      return 0
    fi
    if [[ "$toolKey" == "gh" ]]; then
      noteWarned "$label" "not in this distro's repos, install from https://cli.github.com"
      return 0
    fi
    noteWarned "$label" "not available via $manager, install manually"
    return 0
  fi
  if ! canInstallSystemPackages; then
    noteWarned "$label" "$manager needs root or sudo, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "$label" "installing via $manager"
  if ! installSystemPackages "$manager" "${packageNameArgs[@]}"; then
    if [[ "$toolKey" == "gh" && "$manager" == "apt-get" ]]; then
      noteWarned "$label" "$manager install failed, install from https://cli.github.com"
      return 0
    fi
    noteWarned "$label" "$manager install failed"
    return 0
  fi
  refreshSessionPath
  if toolIsPresent "$toolKey" "$commandName"; then
    noteInstalled "$label" "installed"
    return 0
  fi
  noteWarned "$label" "installed, but open a new shell for PATH"
}

installLogitechTools() {
  local solaarWasPresent=0
  if command -v solaar >/dev/null 2>&1; then
    solaarWasPresent=1
  fi
  installPackageTool "Solaar" "solaar" "solaar"
  if ((solaarWasPresent == 0)) && command -v solaar >/dev/null 2>&1; then
    printf '%s        Replug the Logitech receiver so Solaar can see it; its udev rule fires only on device add.%s\n' "$colorDarkGray" "$colorReset"
  fi
  installPackageTool "ratbagd" "ratbagd" "ratbagd"
  installPackageTool "Piper" "piper" "piper"
}

installHeadsetControlBuildDeps() {
  local manager
  local installLog
  if ! manager="$(detectPackageManager)"; then
    noteWarned "headsetcontrol" "no supported package manager, install build deps manually"
    return 1
  fi
  if [[ "$manager" != "apt-get" ]]; then
    noteWarned "headsetcontrol" "build deps not mapped for $manager"
    return 1
  fi
  if ! canInstallSystemPackages; then
    noteWarned "headsetcontrol" "$manager needs root or sudo, install manually"
    return 1
  fi
  writeLine " .. " "$colorYellow" "headsetcontrol" "installing build deps via $manager"
  installLog="$(mktemp "${TMPDIR:-/tmp}/headsetcontrol-deps.XXXXXX")"
  packageInstallLog="$installLog"
  if installSystemPackages "$manager" cmake libhidapi-dev pkg-config build-essential; then
    packageInstallLog=""
    rm -f "$installLog"
    return 0
  fi
  packageInstallLog=""
  noteWarned "headsetcontrol" "build deps failed: $(lastLogLine "$installLog")"
  rm -f "$installLog"
  return 1
}

runWarnStep() {
  local label="$1"
  local reason="$2"
  local logFile="$3"
  shift 3
  if "$@" >>"$logFile" 2>&1; then
    return 0
  fi
  noteWarned "$label" "$reason: $(lastLogLine "$logFile")"
  return 1
}

installHeadsetControlUdevRules() {
  local binaryPath="$1"
  local rulesFile rulesLog
  local generated=0
  if [[ ! -x "$binaryPath" ]]; then
    noteWarned "headsetcontrol udev" "built binary missing, skipping rules"
    return 0
  fi
  if ! command -v udevadm >/dev/null 2>&1; then
    noteWarned "headsetcontrol udev" "udevadm not on PATH, skipping rules"
    return 0
  fi
  rulesFile="$(mktemp "${TMPDIR:-/tmp}/headsetcontrol-rules.XXXXXX")"
  rulesLog="$(mktemp "${TMPDIR:-/tmp}/headsetcontrol-udev.XXXXXX")"
  if "$binaryPath" -u >"$rulesFile" 2>"$rulesLog" && [[ -s "$rulesFile" ]]; then
    generated=1
  fi
  if ((generated == 0)); then
    noteWarned "headsetcontrol udev" "rules generation failed: $(lastLogLine "$rulesLog")"
  fi
  if ((generated == 1)) \
    && runWarnStep "headsetcontrol udev" "rules install failed" "$rulesLog" runPackageManagerCommand install -m 0644 "$rulesFile" /etc/udev/rules.d/70-headset.rules \
    && runWarnStep "headsetcontrol udev" "reload failed" "$rulesLog" runPackageManagerCommand udevadm control --reload-rules \
    && runWarnStep "headsetcontrol udev" "trigger failed" "$rulesLog" runPackageManagerCommand udevadm trigger; then
    noteApplied "headsetcontrol udev" "rules installed"
  fi
  rm -f "$rulesFile" "$rulesLog"
}

installHeadsetControl() {
  local cloneDir
  local installLog
  refreshSessionPath
  if command -v headsetcontrol >/dev/null 2>&1; then
    notePresent "headsetcontrol" "already installed"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    noteWarned "headsetcontrol" "git not on PATH, install manually"
    return 0
  fi
  if ! installHeadsetControlBuildDeps; then
    return 0
  fi
  refreshSessionPath
  if ! command -v cmake >/dev/null 2>&1; then
    noteWarned "headsetcontrol" "cmake not on PATH, install manually"
    return 0
  fi
  cloneDir="$(mktemp -d "${TMPDIR:-/tmp}/headsetcontrol.XXXXXX")"
  installLog="$(mktemp "${TMPDIR:-/tmp}/headsetcontrol-build.XXXXXX")"
  writeLine " .. " "$colorYellow" "headsetcontrol" "building from source"
  local built=0
  if runWarnStep "headsetcontrol" "clone failed" "$installLog" git clone --depth 1 https://github.com/Sapd/HeadsetControl.git "$cloneDir" \
    && runWarnStep "headsetcontrol" "configure failed" "$installLog" cmake -S "$cloneDir" -B "$cloneDir/build" -DCMAKE_BUILD_TYPE=Release \
    && runWarnStep "headsetcontrol" "build failed" "$installLog" cmake --build "$cloneDir/build" \
    && runWarnStep "headsetcontrol" "install failed" "$installLog" runPackageManagerCommand cmake --install "$cloneDir/build"; then
    built=1
  fi
  if ((built == 1)); then
    installHeadsetControlUdevRules "$cloneDir/build/headsetcontrol"
  fi
  rm -rf "$cloneDir"
  rm -f "$installLog"
  if ((built == 0)); then
    return 0
  fi
  refreshSessionPath
  if command -v headsetcontrol >/dev/null 2>&1; then
    noteInstalled "headsetcontrol" "installed"
    return 0
  fi
  noteWarned "headsetcontrol" "installed, but open a new shell for PATH"
}

nodeSourceSetupUrl() {
  local manager="$1"
  if [[ "$manager" == "dnf" ]]; then
    printf 'https://rpm.nodesource.com/setup_%s.x\n' "$nodeSourceMajor"
    return 0
  fi
  printf 'https://deb.nodesource.com/setup_%s.x\n' "$nodeSourceMajor"
}

# The NodeSource package provides npm itself and conflicts with the distro npm,
# which apt will not resolve on its own, so drop that one package and retry.
installNodeSourcePackage() {
  local manager="$1"
  local logPath="$2"
  if installSystemPackages "$manager" nodejs; then
    return 0
  fi
  if [[ "$manager" != "apt-get" ]]; then
    return 1
  fi
  if ! grep -qi 'conflict' "$logPath"; then
    return 1
  fi
  printf 'retrying without the distro npm package\n' >>"$logPath"
  if ! runPackageManagerCommand apt-get -o DPkg::Lock::Timeout="$dpkgLockWaitSeconds" remove -y npm >>"$logPath" 2>&1; then
    return 1
  fi
  installSystemPackages "$manager" nodejs
}

installNodeJs() {
  local manager
  local setupLog
  refreshSessionPath
  if nodeIsCurrentEnough; then
    notePresent "Node.js" "already installed"
    return 0
  fi
  if ! manager="$(detectPackageManager)"; then
    noteWarned "Node.js" "no supported package manager, install manually"
    return 0
  fi
  if [[ "$manager" != "apt-get" && "$manager" != "dnf" ]]; then
    installPackageTool "Node.js" "node" "node"
    return 0
  fi
  if ! canInstallSystemPackages; then
    noteWarned "Node.js" "$manager needs root or sudo, install manually"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "Node.js" "curl not on PATH, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "Node.js" "installing Node $nodeSourceMajor from NodeSource"
  setupLog="$(mktemp "${TMPDIR:-/tmp}/claude-nodesource.XXXXXX")"
  waitForPackageManagerLock
  if ! curl -fsSL "$(nodeSourceSetupUrl "$manager")" | runPackageManagerCommand bash - >"$setupLog" 2>&1; then
    noteWarned "Node.js" "NodeSource setup failed: $(lastLogLine "$setupLog")"
    rm -f "$setupLog"
    return 0
  fi
  aptUpdated=0
  packageInstallLog="$setupLog"
  if ! installNodeSourcePackage "$manager" "$setupLog"; then
    packageInstallLog=""
    noteWarned "Node.js" "NodeSource install failed: $(lastLogLine "$setupLog")"
    rm -f "$setupLog"
    return 0
  fi
  packageInstallLog=""
  rm -f "$setupLog"
  refreshSessionPath
  if nodeIsCurrentEnough; then
    noteInstalled "Node.js" "Node $(nodeMajorVersion) installed"
    return 0
  fi
  noteWarned "Node.js" "still older than Node $minimumNodeMajor, upgrade manually"
}

installClaudeCode() {
  refreshSessionPath
  persistUserLocalBinOnPath
  if command -v claude >/dev/null 2>&1; then
    notePresent "Claude Code" "already installed"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "Claude Code" "curl not on PATH, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "Claude Code" "running native installer"
  local installerLog
  installerLog="$(mktemp "${TMPDIR:-/tmp}/claude-code-install.XXXXXX")"
  if ! curl -fsSL https://claude.ai/install.sh | bash >"$installerLog" 2>&1; then
    noteWarned "Claude Code" "native installer failed: $(lastLogLine "$installerLog")"
    rm -f "$installerLog"
    return 0
  fi
  rm -f "$installerLog"
  refreshSessionPath
  if command -v claude >/dev/null 2>&1; then
    noteInstalled "Claude Code" "installed"
    return 0
  fi
  noteWarned "Claude Code" "not on PATH yet, open a new shell"
}

isZedInstalled() {
  if command -v zed >/dev/null 2>&1; then
    return 0
  fi
  [[ -x "$HOME/.local/bin/zed" ]]
}

installZed() {
  refreshSessionPath
  persistUserLocalBinOnPath
  if isZedInstalled; then
    notePresent "Zed" "already installed"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "Zed" "curl not on PATH, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "Zed" "running official installer"
  local installerLog installerScript
  installerLog="$(mktemp "${TMPDIR:-/tmp}/zed-install.XXXXXX")"
  installerScript="$(mktemp "${TMPDIR:-/tmp}/zed-install-script.XXXXXX")"
  if ! curl -fsSL https://zed.dev/install.sh -o "$installerScript" 2>"$installerLog"; then
    noteWarned "Zed" "installer download failed: $(lastLogLine "$installerLog")"
    rm -f "$installerLog" "$installerScript"
    return 0
  fi
  if ! sh "$installerScript" >"$installerLog" 2>&1; then
    noteWarned "Zed" "official installer failed: $(lastLogLine "$installerLog")"
    rm -f "$installerLog" "$installerScript"
    return 0
  fi
  rm -f "$installerLog" "$installerScript"
  refreshSessionPath
  if isZedInstalled; then
    noteInstalled "Zed" "installed"
    return 0
  fi
  noteWarned "Zed" "installed, but not on PATH yet"
}

refreshUserDesktopAssets() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || noteWarned "desktop database" "refresh failed"
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || noteWarned "icon cache" "refresh failed"
  fi
}

exportFlatpakLauncherAssets() {
  local label="$1"
  local appId="$2"
  local exportShare="$HOME/.local/share/flatpak/exports/share"
  local desktopSrc="$exportShare/applications/$appId.desktop"
  local desktopDest="$HOME/.local/share/applications/$appId.desktop"
  local iconSrc
  local iconDest
  local iconRelativePath
  local exported=0
  local iconCount=0
  if [[ ! -f "$desktopSrc" ]]; then
    noteWarned "$label launcher" "flatpak desktop export missing"
    return 0
  fi
  mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor"
  if ! filesAreIdentical "$desktopSrc" "$desktopDest"; then
    cp -f "$desktopSrc" "$desktopDest"
    exported=1
  fi
  local iconRoot="$exportShare/icons/hicolor"
  local -a iconFiles=()
  mapfile -t iconFiles < <(find -L "$iconRoot" -type f -path "*/apps/$appId.*" 2>/dev/null)
  if ((${#iconFiles[@]} == 0)); then
    iconRoot="$HOME/.local/share/flatpak/app/$appId/current/active/files/share/icons/hicolor"
    mapfile -t iconFiles < <(find -L "$iconRoot" -type f -path "*/apps/$appId.*" 2>/dev/null)
  fi
  for iconSrc in "${iconFiles[@]}"; do
    iconCount=$((iconCount + 1))
    iconRelativePath="hicolor/${iconSrc#"$iconRoot/"}"
    iconDest="$HOME/.local/share/icons/$iconRelativePath"
    mkdir -p "$(dirname -- "$iconDest")"
    if filesAreIdentical "$iconSrc" "$iconDest"; then
      continue
    fi
    cp -f "$iconSrc" "$iconDest"
    exported=1
  done
  if ((iconCount == 0)); then
    noteWarned "$label icons" "flatpak icon export missing"
  fi
  refreshUserDesktopAssets
  if ((exported == 1)); then
    noteApplied "$label launcher" "exported"
    return 0
  fi
  notePresent "$label launcher" "already exported"
}

installFlatpakApp() {
  local label="$1"
  local appId="$2"
  if ! command -v flatpak >/dev/null 2>&1; then
    noteWarned "$label" "flatpak not on PATH, install manually"
    return 0
  fi
  if flatpak info "$appId" >/dev/null 2>&1; then
    notePresent "$label" "already installed"
    exportFlatpakLauncherAssets "$label" "$appId"
    return 0
  fi
  writeLine " .. " "$colorYellow" "$label" "installing via flatpak"
  if ! flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1; then
    noteWarned "$label" "flathub remote setup failed"
    return 0
  fi
  if ! flatpak install --user -y flathub "$appId" >/dev/null 2>&1; then
    noteWarned "$label" "flatpak install failed"
    return 0
  fi
  noteInstalled "$label" "installed"
  exportFlatpakLauncherAssets "$label" "$appId"
}

isTailscaleAuthed() {
  tailscale status >/dev/null 2>&1
}

detectGlissaTailnetHostname() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi
  if ! isTailscaleAuthed; then
    return 0
  fi
  tailscale status --json 2>/dev/null | node -e 'try { const status = JSON.parse(require("fs").readFileSync(0, "utf8")); const dnsName = String((status.Self || {}).DNSName || "").replace(/\.$/, ""); if (dnsName) process.stdout.write(dnsName); } catch {}' 2>/dev/null || true
}

warnUnlessTailscaleAuthed() {
  if isTailscaleAuthed; then
    return 0
  fi
  if canPromptUser && openPromptInput && promptYesNo "Authenticate Tailscale now (sudo tailscale up)?"; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      tailscale up || true
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo tailscale up || true
    fi
    if isTailscaleAuthed; then
      noteApplied "Tailscale auth" "authenticated"
      return 0
    fi
  fi
  noteWarned "Tailscale auth" "checklist: run sudo tailscale up once"
}

ensureGithubAuth() {
  refreshSessionPath
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if gh auth status >/dev/null 2>&1; then
    notePresent "GitHub auth" "logged in"
    return 0
  fi
  if canPromptUser && openPromptInput && promptYesNo "Log in to GitHub now (gh auth login)?"; then
    printf '%s        Ctrl-C skips login and setup continues. If no browser opens, enter the code at https://github.com/login/device%s\n' "$colorDarkGray" "$colorReset"
    local priorIntTrap
    priorIntTrap="$(trap -p INT)"
    trap ':' INT
    gh auth login || true
    trap - INT
    if [[ -n "$priorIntTrap" ]]; then
      eval "$priorIntTrap"
    fi
    if gh auth status >/dev/null 2>&1; then
      noteApplied "GitHub auth" "logged in"
      return 0
    fi
    noteWarned "GitHub auth" "gh auth login did not complete, run it again later"
    return 0
  fi
  noteWarned "GitHub auth" "checklist: run gh auth login"
}

installTailscaleLinux() {
  refreshSessionPath
  if command -v tailscale >/dev/null 2>&1; then
    notePresent "Tailscale" "already installed"
    warnUnlessTailscaleAuthed
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "Tailscale" "curl not on PATH, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "Tailscale" "running official installer"
  local installerLog
  installerLog="$(mktemp "${TMPDIR:-/tmp}/claude-tailscale-install.XXXXXX")"
  waitForPackageManagerLock
  if ! curl -fsSL https://tailscale.com/install.sh | sh >"$installerLog" 2>&1; then
    noteWarned "Tailscale" "official installer failed: $(lastLogLine "$installerLog")"
    rm -f "$installerLog"
    return 0
  fi
  rm -f "$installerLog"
  refreshSessionPath
  if ! command -v tailscale >/dev/null 2>&1; then
    noteWarned "Tailscale" "installed, but not on PATH yet"
    return 0
  fi
  noteInstalled "Tailscale" "installed"
  warnUnlessTailscaleAuthed
}

renderGlissaService() {
  local template="$1"
  local dest="$2"
  local nodePath="$3"
  local servicePath="$4"
  local escapedNode
  local escapedHome
  local escapedPath
  local claudePath
  local claudeDir
  escapedNode="$(printf '%s' "$nodePath" | sed 's/[\/&]/\\&/g')"
  escapedHome="$(printf '%s' "$HOME" | sed 's/[\/&]/\\&/g')"
  claudePath="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$claudePath" ]]; then
    claudeDir="$(dirname -- "$claudePath")"
    servicePath="$claudeDir:$servicePath"
  fi
  if [[ -z "$claudePath" && -d "$HOME/.local/bin" ]]; then
    servicePath="$HOME/.local/bin:$servicePath"
  fi
  escapedPath="$(printf '%s' "$servicePath" | sed 's/[\/&]/\\&/g')"
  sed \
    -e "s/__NODE__/$escapedNode/g" \
    -e "s/__HOME__/$escapedHome/g" \
    -e "s/__PATH__/$escapedPath/g" \
    "$template" > "$dest"
}

installGlissaService() {
  local serviceTemplate="$setupDir/glissa/glissa.service"
  local systemdUserDir="$HOME/.config/systemd/user"
  local serviceDest="$systemdUserDir/glissa.service"
  local nodePath
  local servicePath
  local tempService
  local didInstallService=0
  if ! command -v systemctl >/dev/null 2>&1; then
    noteWarned "glissa service" "systemctl not on PATH, skipping service"
    return 0
  fi
  if [[ ! -d /run/systemd/system ]]; then
    noteWarned "glissa service" "systemd not running, skipping service"
    return 0
  fi
  if [[ ! -f "$serviceTemplate" ]]; then
    noteWarned "glissa service" "template not in repo"
    return 0
  fi
  if ! nodePath="$(command -v node)"; then
    noteWarned "glissa service" "node not on PATH"
    return 0
  fi
  servicePath="$PATH"
  if command -v dirname >/dev/null 2>&1; then
    servicePath="$(dirname -- "$nodePath"):$servicePath"
  fi
  mkdir -p "$systemdUserDir"
  tempService="$(mktemp "${TMPDIR:-/tmp}/glissa-service.XXXXXX")"
  renderGlissaService "$serviceTemplate" "$tempService" "$nodePath" "$servicePath"
  if filesAreIdentical "$tempService" "$serviceDest"; then
    rm -f "$tempService"
    notePresent "glissa service" "up to date"
  fi
  if [[ -f "$tempService" ]]; then
    mv -f "$tempService" "$serviceDest"
    noteApplied "glissa service" "installed"
    didInstallService=1
  fi
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    noteWarned "glissa service" "systemctl --user daemon-reload failed"
    return 0
  fi
  if ! systemctl --user enable --now glissa >/dev/null 2>&1; then
    noteWarned "glissa service" "enable/start failed"
    return 0
  fi
  # A rewritten remote config needs a restart even when the unit is unchanged:
  # the server reads config.remote only at boot.
  local serviceStateNote="enabled and started"
  if ((didInstallService == 1)) || ((glissaRemoteSettingsRewritten == 1)); then
    if ! systemctl --user restart glissa >/dev/null 2>&1; then
      noteWarned "glissa service" "restart failed"
      return 0
    fi
    serviceStateNote="restarted"
  fi
  notePresent "glissa service" "$serviceStateNote"
  probeGlissaServiceHealth
  if ! command -v loginctl >/dev/null 2>&1; then
    noteWarned "glissa linger" "loginctl not on PATH"
    return 0
  fi
  if loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -qx yes; then
    notePresent "glissa linger" "enabled"
    return 0
  fi
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    noteApplied "glissa linger" "enabled"
    return 0
  fi
  noteWarned "glissa linger" "enable-linger failed"
}

readGlissaRemotePort() {
  node -p "String((require(process.argv[1]).remote || {}).port || '')" "$HOME/.glissa/config.json" 2>/dev/null
}

readGlissaLocalPort() {
  node -p "String((require(process.argv[1]) || {}).port || '')" "$HOME/.glissa/config.json" 2>/dev/null
}

readGlissaPublicHost() {
  node -p "String(((require(process.argv[1]) || {}).remote || {}).publicHost || '')" "$HOME/.glissa/config.json" 2>/dev/null
}

readGlissaRemoteEnabled() {
  node -p "String(((require(process.argv[1]) || {}).remote || {}).enabled !== false)" "$HOME/.glissa/config.json" 2>/dev/null
}

isGlissaRemoteEnabled() {
  [[ "$(readGlissaRemoteEnabled)" == "true" ]]
}

hasDottedGlissaHost() {
  local publicHost="$1"
  [[ "$publicHost" == *.* && "$publicHost" != *CHANGEME* ]]
}

# Callers gate on curl being present before probing.
probeHttpStatus() {
  local url="$1"
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url")" || return 1
  printf '%s\n' "$status"
}

probeGlissaRemoteTls() {
  local publicHost
  local httpStatus
  if ((glissaServeStarted == 0)); then
    return 0
  fi
  publicHost="$(readGlissaPublicHost)"
  if ! hasDottedGlissaHost "$publicHost"; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if ! httpStatus="$(probeHttpStatus "https://$publicHost/")"; then
    noteWarned "remote access" "TLS probe failed for https://$publicHost/: enable MagicDNS and HTTPS Certificates in the Tailscale admin console at login.tailscale.com, DNS tab, then re-run"
    return 0
  fi
  if [[ "$httpStatus" =~ ^[234][0-9][0-9]$ ]]; then
    notePresent "remote access" "TLS verified for https://$publicHost/ (HTTP $httpStatus)"
    return 0
  fi
  noteWarned "remote access" "TLS probe returned HTTP $httpStatus for https://$publicHost/"
}

probeGlissaLocalHttp() {
  local label="$1"
  local url="$2"
  local expectedStatus="$3"
  local hint="$4"
  local attempt
  local httpStatus
  for attempt in {1..20}; do
    if httpStatus="$(probeHttpStatus "$url")"; then
      if [[ "$httpStatus" == "$expectedStatus" ]]; then
        notePresent "$label" "$hint"
        return 0
      fi
    fi
    sleep 0.5
  done
  noteWarned "$label" "no expected HTTP $expectedStatus from $url, run: journalctl --user -u glissa -n 20"
}

probeGlissaServiceHealth() {
  local localPort
  local remotePort
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  localPort="$(readGlissaLocalPort)"
  if [[ ! "$localPort" =~ ^[0-9]+$ ]]; then
    localPort=3000
  fi
  probeGlissaLocalHttp "glissa health" "http://127.0.0.1:$localPort/" "200" "local listener serving"
  if ! isGlissaRemoteEnabled; then
    return 0
  fi
  remotePort="$(readGlissaRemotePort)"
  if [[ ! "$remotePort" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  probeGlissaLocalHttp "glissa remote health" "http://127.0.0.1:$remotePort/" "401" "remote listener auth-gated"
}

configureGlissaServe() {
  local remotePort
  if ! command -v tailscale >/dev/null 2>&1; then
    noteWarned "Tailscale serve" "tailscale not on PATH"
    return 0
  fi
  if [[ ! -f "$HOME/.glissa/config.json" ]]; then
    noteWarned "Tailscale serve" "could not read remote.port from ~/.glissa/config.json, skipping serve"
    return 0
  fi
  # An operator who declined remote access must not get a serve proxy pointed at
  # a listener glissa will refuse to open.
  if ! isGlissaRemoteEnabled; then
    notePresent "Tailscale serve" "skipped, glissa remote disabled"
    return 0
  fi
  # Serve must target remote.port (the auth-gated listener), never Glissa's local port:
  # serving the local port exposes the unauthenticated dashboard to the whole tailnet.
  remotePort="$(readGlissaRemotePort)" || remotePort=""
  if [[ ! "$remotePort" =~ ^[0-9]+$ ]]; then
    noteWarned "Tailscale serve" "could not read remote.port from ~/.glissa/config.json, skipping serve"
    return 0
  fi
  if ! isTailscaleAuthed; then
    noteWarned "Tailscale serve" "checklist: run sudo tailscale up once, then tailscale serve --bg $remotePort"
    return 0
  fi
  if tailscale serve --bg "$remotePort" >/dev/null 2>&1; then
    noteApplied "Tailscale serve" "remote port $remotePort"
    glissaServeStarted=1
    return 0
  fi
  noteWarned "Tailscale serve" "serve failed, run: tailscale serve --bg $remotePort"
}

warnGlissaRemotePlaceholder() {
  noteWarned "glissa server config" "publicHost/allowedOrigins still say CHANGEME, edit ~/.glissa/config.json before remote access works"
}

warnGlissaDottedHostRequired() {
  local typedHost="$1"
  noteWarned "glissa remote config" "publicHost '$typedHost' is not the full tailnet name; pairing and TLS need the full name, for example host.tailnet-name.ts.net"
}

promptGlissaDottedHost() {
  local question="$1"
  local attempt
  local typedHost
  glissaChosenHost=""
  for attempt in 1 2 3; do
    typedHost="$(promptValue "$question ")"
    if [[ -z "$typedHost" ]]; then
      return 1
    fi
    if hasDottedGlissaHost "$typedHost"; then
      glissaChosenHost="$typedHost"
      return 0
    fi
    warnGlissaDottedHostRequired "$typedHost"
  done
  return 1
}

isValidGlissaPort() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  ((port >= 1 && port <= 65535))
}

writeGlissaRemoteSettings() {
  local configPath="$1"
  local remoteEnabled="$2"
  local localPort="$3"
  local remotePort="$4"
  local publicHost="$5"
  local nodeStatus=0
  node - "$configPath" "$remoteEnabled" "$localPort" "$remotePort" "$publicHost" <<'NODE' || nodeStatus=$?
const fs = require("fs");
const path = require("path");

const [configPath, remoteEnabledText, localPortText, remotePortText, publicHost] = process.argv.slice(2);
let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, "utf8"));
} catch {
  process.exit(2);
}

config.port = Number(localPortText);
config.remote = config.remote && typeof config.remote === "object" ? config.remote : {};
config.remote.enabled = remoteEnabledText === "true";
config.remote.port = Number(remotePortText);
if (!config.remote.enabled) {
  config.remote.publicHost = "";
  config.remote.allowedOrigins = [];
}
if (publicHost) {
  config.remote.publicHost = publicHost;
  config.remote.allowedOrigins = [`https://${publicHost}`];
}

const dir = path.dirname(configPath);
const tempPath = path.join(dir, `.config.json.${process.pid}.tmp`);
fs.writeFileSync(tempPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(tempPath, configPath);
NODE
  if ((nodeStatus == 0)); then
    chmod 600 "$configPath" 2>/dev/null || noteWarned "glissa config perms" "chmod 600 failed"
    return 0
  fi
  if ((nodeStatus == 2)); then
    noteWarned "glissa remote config" "config JSON is unreadable, leaving it unchanged"
    return 1
  fi
  noteWarned "glissa remote config" "update failed, leaving it unchanged"
  return 1
}

promptGlissaPorts() {
  local defaultRemotePort="$1"
  local defaultLocalPort="$2"
  local attempt
  local remoteAnswer
  local localAnswer
  glissaChosenRemotePort="$defaultRemotePort"
  glissaChosenLocalPort="$defaultLocalPort"
  for attempt in 1 2 3; do
    remoteAnswer="$(promptValue "Remote listener port [$defaultRemotePort] ")"
    localAnswer="$(promptValue "Local dashboard port [$defaultLocalPort] ")"
    if [[ -z "$remoteAnswer" ]]; then
      remoteAnswer="$defaultRemotePort"
    fi
    if [[ -z "$localAnswer" ]]; then
      localAnswer="$defaultLocalPort"
    fi
    if ! isValidGlissaPort "$remoteAnswer"; then
      noteWarned "glissa remote config" "remote port must be 1-65535"
      continue
    fi
    if ! isValidGlissaPort "$localAnswer"; then
      noteWarned "glissa remote config" "local port must be 1-65535"
      continue
    fi
    if [[ "$remoteAnswer" == "$localAnswer" ]]; then
      noteWarned "glissa remote config" "remote.port must differ from port"
      continue
    fi
    glissaChosenRemotePort="$remoteAnswer"
    glissaChosenLocalPort="$localAnswer"
    return 0
  done
  noteWarned "glissa remote config" "invalid ports, using defaults"
}

handleGlissaRemoteDrift() {
  local configPath="$1"
  local detectedHost="$2"
  local configuredHost
  local configuredHostLower
  local detectedHostLower
  local localPort
  local remotePort
  local remoteEnabled
  if [[ -z "$detectedHost" ]]; then
    notePresent "glissa remote config" "configured"
    return 0
  fi
  configuredHost="$(readGlissaPublicHost)"
  configuredHostLower="${configuredHost,,}"
  detectedHostLower="${detectedHost,,}"
  if [[ -z "$configuredHost" || "$configuredHostLower" == "$detectedHostLower" ]]; then
    notePresent "glissa remote config" "configured"
    return 0
  fi
  noteWarned "glissa remote config" "publicHost $configuredHost but the tailnet reports $detectedHost"
  if ! canPromptUser; then
    return 0
  fi
  if ! openPromptInput; then
    return 0
  fi
  if ! promptYesNo "Update glissa publicHost to $detectedHost?"; then
    return 0
  fi
  localPort="$(readGlissaLocalPort)"
  if [[ ! "$localPort" =~ ^[0-9]+$ ]]; then
    localPort=3000
  fi
  remotePort="$(readGlissaRemotePort)"
  if [[ ! "$remotePort" =~ ^[0-9]+$ ]]; then
    remotePort=3001
  fi
  remoteEnabled="$(readGlissaRemoteEnabled)"
  if [[ "$remoteEnabled" != "true" && "$remoteEnabled" != "false" ]]; then
    remoteEnabled="true"
  fi
  writeGlissaRemoteSettings "$configPath" "$remoteEnabled" "$localPort" "$remotePort" "$detectedHost" || return 0
  glissaRemoteSettingsRewritten=1
  noteApplied "glissa remote config" "publicHost $detectedHost (tailnet drift repaired)"
}

configureGlissaRemoteSettings() {
  local configPath="$HOME/.glissa/config.json"
  local detectedHost
  local enableAnswer
  local hostChoice
  local chosenHost=""
  local defaultLocalPort
  local defaultRemotePort
  if [[ ! -f "$configPath" ]]; then
    return 0
  fi
  detectedHost="$(detectGlissaTailnetHostname)"
  if ! grep -q "CHANGEME" "$configPath"; then
    handleGlissaRemoteDrift "$configPath" "$detectedHost"
    return 0
  fi
  # A pre-customized port survives the guided fill: existing config values are
  # the defaults, the seeded 3000/3001 only back them up.
  defaultLocalPort="$(readGlissaLocalPort)"
  if [[ ! "$defaultLocalPort" =~ ^[0-9]+$ ]]; then
    defaultLocalPort=3000
  fi
  defaultRemotePort="$(readGlissaRemotePort)"
  if [[ ! "$defaultRemotePort" =~ ^[0-9]+$ ]]; then
    defaultRemotePort=3001
  fi
  if ! canPromptUser; then
    if [[ -n "$detectedHost" ]]; then
      writeGlissaRemoteSettings "$configPath" "true" "$defaultLocalPort" "$defaultRemotePort" "$detectedHost" || return 0
      glissaRemoteSettingsRewritten=1
      noteApplied "glissa remote config" "publicHost $detectedHost (auto-detected)"
      return 0
    fi
    warnGlissaRemotePlaceholder
    return 0
  fi
  if ! openPromptInput; then
    warnGlissaRemotePlaceholder
    return 0
  fi
  enableAnswer="$(promptValue "Enable remote access over Tailscale? [Y/n] ")"
  if [[ "$enableAnswer" =~ ^[Nn][Oo]?$ ]]; then
    writeGlissaRemoteSettings "$configPath" "false" "$defaultLocalPort" "$defaultRemotePort" "" || return 0
    glissaRemoteSettingsRewritten=1
    noteApplied "glissa remote config" "remote access disabled"
    return 0
  fi
  if [[ -n "$detectedHost" ]]; then
    printf '[1] %s\n[2] type a different hostname\n[3] skip for now\n' "$detectedHost"
    hostChoice="$(promptValue "Remote hostname [1] ")"
    if [[ -z "$hostChoice" || "$hostChoice" == "1" ]]; then
      chosenHost="$detectedHost"
    fi
    if [[ "$hostChoice" == "2" ]]; then
      if promptGlissaDottedHost "Remote hostname"; then
        chosenHost="$glissaChosenHost"
      fi
    fi
    if [[ "$hostChoice" == "3" ]]; then
      warnGlissaRemotePlaceholder
      return 0
    fi
  fi
  if [[ -z "$detectedHost" ]]; then
    if promptGlissaDottedHost "Remote hostname"; then
      chosenHost="$glissaChosenHost"
    fi
  fi
  # Covers an empty typed hostname and any unrecognized menu choice: the config
  # must never be written enabled with the CHANGEME placeholder still in place.
  if [[ -z "$chosenHost" ]]; then
    warnGlissaRemotePlaceholder
    return 0
  fi
  promptGlissaPorts "$defaultRemotePort" "$defaultLocalPort"
  writeGlissaRemoteSettings "$configPath" "true" "$glissaChosenLocalPort" "$glissaChosenRemotePort" "$chosenHost" || return 0
  glissaRemoteSettingsRewritten=1
  noteApplied "glissa remote config" "publicHost $chosenHost"
}

glissaPublicHostIsConfigured() {
  [[ "$(node -p "const remote = (require(process.argv[1]).remote || {}); const host = String(remote.publicHost || ''); String(Boolean(host && !host.includes('CHANGEME')))" "$HOME/.glissa/config.json" 2>/dev/null)" == "true" ]]
}

offerGlissaPairingUrl() {
  local pairAnswer
  if ! canPromptUser; then
    noteWarned "glissa checklist" "glissa pair per device"
    return 0
  fi
  if ! openPromptInput; then
    noteWarned "glissa checklist" "glissa pair per device"
    return 0
  fi
  if ! glissaPublicHostIsConfigured; then
    noteWarned "glissa checklist" "glissa pair per device"
    return 0
  fi
  pairAnswer="$(promptValue "Mint a pairing URL for your first device now? [y/N] ")"
  if [[ ! "$pairAnswer" =~ ^[Yy]$ ]]; then
    noteWarned "glissa checklist" "glissa pair per device"
    return 0
  fi
  if ! node "$glissaServerRepoDir/bin/glissa.js" pair; then
    noteWarned "glissa pair" "pairing URL mint failed"
    noteWarned "glissa checklist" "glissa pair per device"
    return 0
  fi
}

checkGlissaClaudeState() {
  if ! command -v claude >/dev/null 2>&1; then
    noteWarned "claude" "not on PATH, run: export PATH=\"\$HOME/.local/bin:\$PATH\" or re-run apply"
    return 0
  fi
  if [[ ! -f "$HOME/.claude/.credentials.json" ]]; then
    noteWarned "claude" "run claude login on the box"
    return 0
  fi
  notePresent "claude" "installed and logged in"
}

installGlissaServer() {
  local glissaConfigDir="$HOME/.glissa"
  local glissaConfigDest="$glissaConfigDir/config.json"
  local glissaConfigSrc="$setupDir/glissa/config.server.example.json"
  if ! command -v git >/dev/null 2>&1; then
    noteWarned "glissa server" "git not on PATH"
    return 0
  fi
  if [[ ! -e "$glissaServerRepoDir" ]]; then
    writeLine " .. " "$colorYellow" "glissa server" "cloning"
    mkdir -p "$(dirname -- "$glissaServerRepoDir")"
    if ! git clone -q https://github.com/johncwaters/glissa.git "$glissaServerRepoDir"; then
      noteWarned "glissa server" "clone failed"
      return 0
    fi
    noteInstalled "glissa server" "cloned"
  fi
  if [[ ! -d "$glissaServerRepoDir/.git" ]]; then
    noteWarned "glissa server" "exists but is not a git repo"
    return 0
  fi
  if ! git -C "$glissaServerRepoDir" pull --ff-only -q; then
    noteWarned "glissa server" "pull failed (dirty or diverged), resolve manually"
    return 0
  fi
  notePresent "glissa server" "synced"
  if ! command -v npm >/dev/null 2>&1; then
    noteWarned "glissa server" "npm not on PATH"
    return 0
  fi
  local npmLog
  npmLog="$(mktemp "${TMPDIR:-/tmp}/claude-glissa-npm.XXXXXX")"
  writeLine " .. " "$colorYellow" "glissa deps" "npm ci"
  if ! (cd "$glissaServerRepoDir" && npm ci --no-audit --no-fund --loglevel=error >"$npmLog" 2>&1); then
    noteWarned "glissa deps" "npm ci failed: $(lastLogLine "$npmLog")"
    rm -f "$npmLog"
    return 0
  fi
  notePresent "glissa deps" "installed"
  writeLine " .. " "$colorYellow" "glissa build" "npm run build"
  if ! (cd "$glissaServerRepoDir" && npm run build >"$npmLog" 2>&1); then
    noteWarned "glissa build" "build failed: $(lastLogLine "$npmLog")"
    rm -f "$npmLog"
    return 0
  fi
  rm -f "$npmLog"
  notePresent "glissa build" "built"
  if [[ -f "$glissaConfigDest" ]]; then
    notePresent "glissa server config" "exists, runtime state kept"
  fi
  if [[ ! -f "$glissaConfigDest" ]]; then
    copyConfig "glissa server config" "$glissaConfigSrc" "$glissaConfigDest"
  fi
  if [[ -d "$glissaConfigDir" ]]; then
    chmod 700 "$glissaConfigDir" 2>/dev/null || noteWarned "glissa config perms" "chmod 700 failed"
  fi
  if [[ -f "$glissaConfigDest" ]]; then
    chmod 600 "$glissaConfigDest" 2>/dev/null || noteWarned "glissa config perms" "chmod 600 failed"
  fi
  glissaRemoteSettingsRewritten=0
  glissaServeStarted=0
  configureGlissaRemoteSettings
  installGlissaService
  configureGlissaServe
  probeGlissaRemoteTls
  checkGlissaClaudeState
  offerGlissaPairingUrl
}

syncDevelopBranch() {
  local label="$1"
  local dest="$2"
  local hasLocalDevelopBranch=0
  local hasRemoteDevelopBranch=0
  local repoOwner
  # Never create or push a branch in a repo the operator does not own. The develop
  # first workflow is meaningless on a repo whose main they cannot promote to, and
  # apply once pushed develop to two repos that merely happened to be clonable.
  if [[ -z "$operatorGitHubOwner" ]]; then
    noteWarned "$label develop" "develop sync skipped (cannot tell which GitHub owner is yours)"
    return 0
  fi
  repoOwner="$(parseGitHubOwner "$(git -C "$dest" remote get-url origin 2>/dev/null)")" || repoOwner=""
  if [[ "$repoOwner" != "$operatorGitHubOwner" ]]; then
    notePresent "$label develop" "develop sync skipped (not your repo)"
    return 0
  fi
  # An empty clone has an unborn HEAD, and "git branch develop" against it exits
  # 128, which used to take the whole apply down with it under set -e.
  if ! git -C "$dest" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    noteWarned "$label develop" "no commits yet, skipping branch sync"
    return 0
  fi
  if git -C "$dest" rev-parse --verify -q refs/heads/develop >/dev/null; then
    hasLocalDevelopBranch=1
  fi
  if git -C "$dest" rev-parse --verify -q refs/remotes/origin/develop >/dev/null; then
    hasRemoteDevelopBranch=1
  fi
  if ((hasLocalDevelopBranch == 0)) && ((hasRemoteDevelopBranch == 1)); then
    if ! git -C "$dest" branch -q --track develop origin/develop; then
      noteWarned "$label develop" "could not track origin/develop"
      return 0
    fi
    noteInstalled "$label develop" "tracking origin/develop"
    return 0
  fi
  if ((hasLocalDevelopBranch == 0)); then
    if ! git -C "$dest" branch -q develop; then
      noteWarned "$label develop" "could not create develop"
      return 0
    fi
    if ! git -C "$dest" push -q -u origin develop; then
      noteWarned "$label develop" "created locally, push failed"
      return 0
    fi
    noteInstalled "$label develop" "created and pushed"
    return 0
  fi
  if ((hasRemoteDevelopBranch == 0)); then
    if ! git -C "$dest" push -q -u origin develop; then
      noteWarned "$label develop" "local only, push failed"
      return 0
    fi
    noteApplied "$label develop" "pushed to origin"
    return 0
  fi
  if [[ "$(git -C "$dest" symbolic-ref --short -q HEAD)" == "develop" ]]; then
    return 0
  fi
  if ! git -C "$dest" fetch -q origin develop:develop; then
    noteWarned "$label develop" "diverged from origin, resolve manually"
  fi
}

installRepoDeps() {
  local label="$1"
  local dest="$2"
  local packageManager="npm"
  local installArgs=()
  local installOk=0
  local electronDir
  if [[ ! -f "$dest/package.json" ]]; then
    return 0
  fi
  if [[ -f "$dest/pnpm-lock.yaml" ]]; then
    packageManager="pnpm"
  fi
  if [[ -f "$dest/yarn.lock" ]]; then
    packageManager="yarn"
  fi
  if ! command -v "$packageManager" >/dev/null 2>&1; then
    noteWarned "$label deps" "$packageManager not on PATH"
    return 0
  fi
  case "$packageManager" in
    npm)
      installArgs=(install --no-audit --no-fund --loglevel=error)
      ;;
    pnpm)
      installArgs=(install --reporter=silent)
      ;;
    yarn)
      installArgs=(install --silent)
      ;;
  esac
  writeLine " .. " "$colorYellow" "$label deps" "$packageManager install"
  if (cd "$dest" && "$packageManager" "${installArgs[@]}" >/dev/null); then
    installOk=1
  fi
  if ((installOk == 0)); then
    noteWarned "$label deps" "$packageManager install failed"
    return 0
  fi
  notePresent "$label deps" "installed"
  electronDir="$dest/node_modules/electron"
  if [[ ! -d "$electronDir" ]]; then
    return 0
  fi
  if [[ -f "$electronDir/dist/electron" ]]; then
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    noteWarned "$label electron" "node not on PATH"
    return 0
  fi
  writeLine " .. " "$colorYellow" "$label electron" "downloading binary"
  if node "$electronDir/install.js" >/dev/null && [[ -f "$electronDir/dist/electron" ]]; then
    noteInstalled "$label electron" "binary installed"
    return 0
  fi
  noteWarned "$label electron" "binary download failed, run: node node_modules/electron/install.js"
}

repoEntryWantsDeps() {
  local label="$1"
  local entryFlags="$2"
  local entryFlag
  local sawNoDepsFlag=0
  for entryFlag in $entryFlags; do
    if [[ "$entryFlag" == "nodeps" ]]; then
      sawNoDepsFlag=1
      continue
    fi
    # a typo like "no-deps" would otherwise install deps against the author's intent
    noteWarned "$label" "unknown repos.txt flag ignored: $entryFlag"
  done
  if ((sawNoDepsFlag == 1)); then
    return 1
  fi
  return 0
}

installRepoDepsUnlessSkipped() {
  local label="$1"
  local dest="$2"
  local entryFlags="$3"
  if ! repoEntryWantsDeps "$label" "$entryFlags"; then
    notePresent "$label deps" "skipped (nodeps)"
    return 0
  fi
  installRepoDeps "$label" "$dest"
}

parseGitHubOwner() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/([^/]+)/. ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$url" =~ ^ssh://git@github\.com/([^/]+)/. ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$url" =~ ^git@github\.com:([^/]+)/. ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# This checkout's own origin is by definition the operator's, so its owner is who we
# are allowed to push to. Anything unparseable or non-github yields nothing, and the
# caller treats "nothing" as "own no repos" rather than as "own them all".
resolveOperatorGitHubOwner() {
  local originUrl
  originUrl="$(git -C "$repoRoot" remote get-url origin 2>/dev/null)" || return 1
  parseGitHubOwner "$originUrl"
}

# Returns non-zero when this entry did not get through clone or pull. Branch sync
# and dependency install report their own warnings and do not fail the entry.
syncOneRepo() {
  local repoLine="$1"
  local relPath
  local cloneField
  local cloneUrl
  local entryFlags
  local dest
  local label
  relPath="${repoLine%%=*}"
  cloneField="${repoLine#*=}"
  relPath="${relPath#"${relPath%%[![:space:]]*}"}"
  relPath="${relPath%"${relPath##*[![:space:]]}"}"
  relPath="${relPath//\\//}"
  # anything after the url is a space separated flag list, currently just "nodeps"
  read -r cloneUrl entryFlags <<< "$cloneField"
  if [[ -z "$cloneUrl" ]]; then
    noteWarned "repos" "entry has no clone url: $repoLine"
    return 1
  fi
  dest="$HOME/$relPath"
  label="$(basename -- "$dest")"
  if [[ ! -e "$dest" ]]; then
    writeLine " .. " "$colorYellow" "$label" "cloning"
    if ! mkdir -p "$(dirname -- "$dest")"; then
      noteWarned "$label" "could not create parent directory"
      return 1
    fi
    if ! git clone -q "$cloneUrl" "$dest"; then
      noteWarned "$label" "clone failed"
      return 1
    fi
    noteInstalled "$label" "cloned"
    syncDevelopBranch "$label" "$dest"
    installRepoDepsUnlessSkipped "$label" "$dest" "$entryFlags"
    return 0
  fi
  if [[ ! -d "$dest/.git" ]]; then
    noteWarned "$label" "exists but is not a git repo"
    return 1
  fi
  if ! git -C "$dest" pull --ff-only -q; then
    noteWarned "$label" "pull failed (dirty or diverged), resolve manually"
    return 1
  fi
  notePresent "$label" "synced"
  syncDevelopBranch "$label" "$dest"
  installRepoDepsUnlessSkipped "$label" "$dest" "$entryFlags"
  return 0
}

readPackageList() {
  local packageFile="$1"
  if [[ ! -f "$packageFile" ]]; then
    return 0
  fi
  sed '1s/^\xEF\xBB\xBF//' "$packageFile" | sed '/^[[:space:]]*$/d'
}

npmPackageName() {
  local packageEntry="$1"
  if [[ "$packageEntry" == *=* ]]; then
    printf '%s\n' "${packageEntry%%=*}"
    return 0
  fi
  printf '%s\n' "$packageEntry"
}

npmPackageSource() {
  local packageEntry="$1"
  if [[ "$packageEntry" == *=* ]]; then
    printf '%s\n' "${packageEntry#*=}"
    return 0
  fi
  printf '%s\n' "$packageEntry"
}

listGlobalNpmPackages() {
  # print only lines the strip actually shortened: on POSIX the first parseable
  # line is the global root itself, which contains node_modules with nothing after it
  npm ls -g --depth=0 --parseable 2>/dev/null |
    awk '{ if (sub(/^.*node_modules[\\/]/, "")) { gsub(/\\/, "/"); print } }'
}

pythonCommandName() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf 'python\n'
    return 0
  fi
  return 1
}

ensurePythonPackage() {
  local python="$1"
  local moduleName="$2"
  local packageName="$3"
  if "$python" -c "import $moduleName" >/dev/null 2>&1; then
    notePresent "$packageName" "already installed"
    return 0
  fi
  writeLine " .. " "$colorYellow" "$packageName" "pip install"
  if "$python" -m pip install --quiet "$packageName" >/dev/null 2>&1; then
    noteInstalled "$packageName" "installed"
    return 0
  fi
  # PEP 668 marks many distro Python installs as externally managed, so retry in the user site.
  if "$python" -m pip install --quiet --user --break-system-packages "$packageName" >/dev/null 2>&1; then
    noteInstalled "$packageName" "installed"
    return 0
  fi
  noteWarned "$packageName" "pip install failed"
}

removePathIfPresent() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    return 1
  fi
  rm -rf -- "$target"
  return 0
}

# The prefix in effect can be the per-account one ensureUserNpmPrefix moved to, so ask npm
# rather than assuming /usr/local. Without npm the ~/.npm-global guess is the only prefix
# this repo ever writes to; nothing is created, so a wrong guess just finds nothing.
npmGlobalBinDir() {
  local npmPrefix
  if ! command -v npm >/dev/null 2>&1; then
    printf '%s\n' "$HOME/.npm-global/bin"
    return 0
  fi
  npmPrefix="$(npm prefix -g 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  if [[ -n "$npmPrefix" ]]; then
    printf '%s\n' "$npmPrefix/bin"
    return 0
  fi
  printf '%s\n' "$HOME/.npm-global/bin"
}

splitCsvField() {
  local csvText="$1"
  if [[ -z "$csvText" ]]; then
    return 0
  fi
  printf '%s\n' "$csvText" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
}

# A marketplace can host more than one plugin, so anything scoped to the marketplace rather
# than to this plugin survives while another installed plugin still needs it. The question has
# to be answered before installed_plugins.json is rewritten, and a machine without node cannot
# read that file at all, so this is never called there: the caller then assumes the marketplace
# is still in use and deletes less rather than nuking a marketplace a sibling plugin shares.
retiredMarketplaceIsUnused() {
  local pluginId="$1"
  local marketplace="$2"
  node - "$repoRoot/plugins/installed_plugins.json" "$pluginId" "$marketplace" <<'NODE'
const fs = require("fs");

const [installedPath, pluginId, marketplace] = process.argv.slice(2);
let installed;
try {
  installed = JSON.parse(fs.readFileSync(installedPath, "utf8"));
} catch {
  process.exit(0);
}

const plugins = installed == null ? null : installed.plugins;
const installedPluginIds = plugins && typeof plugins === "object" ? Object.keys(plugins) : [];
const otherPluginIds = installedPluginIds.filter((id) => id !== pluginId && id.endsWith(`@${marketplace}`));
process.exit(otherPluginIds.length === 0 ? 0 : 3);
NODE
}

removeRetiredPluginSettings() {
  local pluginId="$1"
  local marketplace="$2"
  local marketplaceUnused="$3"
  local settingsPath="$repoRoot/settings.json"
  local nodeStatus=0
  node - "$settingsPath" "$pluginId" "$marketplace" "$marketplaceUnused" <<'NODE' || nodeStatus=$?
const fs = require("fs");
const path = require("path");

const [settingsPath, pluginId, marketplace, marketplaceUnused] = process.argv.slice(2);
let settings;
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
} catch {
  process.exit(3);
}

const removeKey = (holder, key) => {
  if (!holder || typeof holder !== "object") {
    return false;
  }
  if (!Object.prototype.hasOwnProperty.call(holder, key)) {
    return false;
  }
  delete holder[key];
  return true;
};

const strippedPlugin = removeKey(settings.enabledPlugins, pluginId);
let strippedMarket = false;
if (marketplaceUnused === "1") {
  strippedMarket = removeKey(settings.extraKnownMarketplaces, marketplace);
}
if (!strippedPlugin && !strippedMarket) {
  process.exit(3);
}

const tempPath = path.join(path.dirname(settingsPath), `.settings.json.${process.pid}.tmp`);
fs.writeFileSync(tempPath, `${JSON.stringify(settings, null, 2)}\n`);
fs.renameSync(tempPath, settingsPath);
NODE
  if ((nodeStatus == 0)); then
    return 0
  fi
  if ((nodeStatus != 3)); then
    noteWarned "plugin removals" "settings.json update failed"
  fi
  return 1
}

removeRetiredPluginRegistries() {
  local pluginId="$1"
  local marketplace="$2"
  local marketplaceUnused="$3"
  local nodeStatus=0
  node - "$repoRoot/plugins" "$pluginId" "$marketplace" "$marketplaceUnused" <<'NODE' || nodeStatus=$?
const fs = require("fs");
const path = require("path");

const [pluginsDir, pluginId, marketplace, marketplaceUnused] = process.argv.slice(2);

const readJson = (filePath) => {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
};

const writeJson = (filePath, value) => {
  const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.tmp`);
  fs.writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(tempPath, filePath);
};

const hasKey = (holder, key) =>
  Boolean(holder) && typeof holder === "object" && Object.prototype.hasOwnProperty.call(holder, key);

let changed = false;
const installedPath = path.join(pluginsDir, "installed_plugins.json");
const installed = readJson(installedPath);
if (installed && hasKey(installed.plugins, pluginId)) {
  delete installed.plugins[pluginId];
  writeJson(installedPath, installed);
  changed = true;
}

if (marketplaceUnused === "1") {
  const marketplacesPath = path.join(pluginsDir, "known_marketplaces.json");
  const marketplaces = readJson(marketplacesPath);
  if (hasKey(marketplaces, marketplace)) {
    delete marketplaces[marketplace];
    writeJson(marketplacesPath, marketplaces);
    changed = true;
  }
}

process.exit(changed ? 0 : 3);
NODE
  if ((nodeStatus == 0)); then
    return 0
  fi
  if ((nodeStatus != 3)); then
    noteWarned "plugin removals" "plugin registry update failed"
  fi
  return 1
}

removeRetiredPluginDirs() {
  local pluginName="$1"
  local marketplace="$2"
  local marketplaceUnused="$3"
  local pluginsDir="$repoRoot/plugins"
  local targets=(
    "$pluginsDir/cache/$marketplace/$pluginName"
    "$pluginsDir/data/$pluginName-$marketplace"
    "$pluginsDir/$pluginName"
  )
  local removedAny=1
  local target
  if [[ "$marketplaceUnused" == "1" ]]; then
    targets+=("$pluginsDir/cache/$marketplace" "$pluginsDir/marketplaces/$marketplace")
  fi
  for target in "${targets[@]}"; do
    if removePathIfPresent "$target"; then
      removedAny=0
    fi
  done
  return $removedAny
}

# .cmd and .ps1 are dead weight on Linux, but deleting them keeps both ports symmetric
# for anyone whose home directory is shared between Windows and WSL.
removeRetiredPluginShims() {
  local shimList="$1"
  local binDir
  local shimName
  local suffix
  local removedAny=1
  if [[ -z "$shimList" ]]; then
    return 1
  fi
  binDir="$(npmGlobalBinDir)"
  while IFS= read -r shimName; do
    for suffix in "" ".cmd" ".ps1"; do
      if removePathIfPresent "$binDir/$shimName$suffix"; then
        removedAny=0
      fi
    done
  done < <(splitCsvField "$shimList")
  return $removedAny
}

removeRetiredPluginState() {
  local stateList="$1"
  local stateDir
  local removedAny=1
  if [[ -z "$stateList" ]]; then
    return 1
  fi
  while IFS= read -r stateDir; do
    if removePathIfPresent "$HOME/$stateDir"; then
      removedAny=0
    fi
  done < <(splitCsvField "$stateList")
  return $removedAny
}

# Retired plugins listed in plugins-remove.txt are torn down on every apply so machines
# converge, mirroring how npm-globals-remove.txt retires global npm tools. Every removal
# is present-only, so a second run on a clean machine is a no-op.
removeRetiredPlugins() {
  local listPath="$setupDir/plugins-remove.txt"
  local entries=()
  local entry
  local tokens=()
  local token
  local pluginId
  local pluginName
  local marketplace
  local shimList
  local stateList
  local nodeCanEditJson=0
  local marketplaceUnused
  local entryChanged
  local removedCount=0
  if [[ ! -f "$listPath" ]]; then
    noteWarned "plugin removals" "plugins-remove.txt not in repo"
    return 0
  fi
  mapfile -t entries < <(readPackageList "$listPath" | sed '/^[[:space:]]*#/d')
  if ((${#entries[@]} == 0)); then
    notePresent "plugin removals" "none listed"
    return 0
  fi
  retryRemoveRetiredPlugins=0
  if command -v node >/dev/null 2>&1; then
    nodeCanEditJson=1
  fi
  if ((nodeCanEditJson == 0)); then
    noteWarned "plugin removals" "node not on PATH, will retry after installs (settings.json and plugin registries unchanged)"
    retryRemoveRetiredPlugins=1
  fi
  for entry in "${entries[@]}"; do
    read -r -a tokens <<<"$entry"
    pluginId="${tokens[0]}"
    if [[ ! "$pluginId" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
      noteWarned "plugin removals" "cannot parse '$pluginId'"
      continue
    fi
    pluginName="${pluginId%@*}"
    marketplace="${pluginId#*@}"
    shimList=""
    stateList=""
    for token in "${tokens[@]:1}"; do
      if [[ "$token" == shims=* ]]; then
        shimList="${token#shims=}"
      fi
      if [[ "$token" == state=* ]]; then
        stateList="${token#state=}"
      fi
    done
    marketplaceUnused=0
    if ((nodeCanEditJson == 1)) && retiredMarketplaceIsUnused "$pluginId" "$marketplace"; then
      marketplaceUnused=1
    fi
    entryChanged=1
    if ((nodeCanEditJson == 1)) && removeRetiredPluginSettings "$pluginId" "$marketplace" "$marketplaceUnused"; then
      entryChanged=0
    fi
    if ((nodeCanEditJson == 1)) && removeRetiredPluginRegistries "$pluginId" "$marketplace" "$marketplaceUnused"; then
      entryChanged=0
    fi
    if removeRetiredPluginDirs "$pluginName" "$marketplace" "$marketplaceUnused"; then
      entryChanged=0
    fi
    if removeRetiredPluginShims "$shimList"; then
      entryChanged=0
    fi
    if removeRetiredPluginState "$stateList"; then
      entryChanged=0
    fi
    if ((entryChanged == 1)); then
      continue
    fi
    noteApplied "$pluginId" "removed"
    removedCount=$((removedCount + 1))
  done
  if ((removedCount == 0)); then
    notePresent "plugin removals" "none present"
  fi
}

markerPath="$repoRoot/.machine-profile"
markerExisted=0
if [[ -f "$markerPath" ]]; then
  markerExisted=1
fi

writeMarker=0
if [[ -n "$profile" ]]; then
  writeMarker=1
fi
if [[ -z "$profile" && -f "$markerPath" ]]; then
  # case-folded to match the PowerShell scripts, whose -eq compare ignores case
  fromMarker="$(tr -d '\r\n[:space:]' < "$markerPath" | tr '[:upper:]' '[:lower:]')"
  if [[ "$fromMarker" == "personal" || "$fromMarker" == "work" || "$fromMarker" == "server" ]]; then
    profile="$fromMarker"
  fi
  if [[ -z "$profile" ]]; then
    printf '%s  .machine-profile has invalid content, ignoring%s\n' "$colorYellow" "$colorReset"
  fi
fi
while [[ -z "$profile" ]]; do
  if [[ ! -t 0 ]]; then
    printf 'Cannot prompt for a machine profile on a non-interactive host. Re-run with --profile personal, --profile work, or --profile server.\n' >&2
    exit 1
  fi
  read -r -p "Machine profile (personal/work/server) " answer
  answer="${answer//[$'\r\n\t ']}"
  answer="${answer,,}"
  if [[ "$answer" == "personal" || "$answer" == "work" || "$answer" == "server" ]]; then
    profile="$answer"
    writeMarker=1
  fi
  if [[ -z "$profile" ]]; then
    printf '%s  Enter '\''personal'\'', '\''work'\'', or '\''server'\''.%s\n' "$colorYellow" "$colorReset"
  fi
done

profileJsonPath="$repoRoot/profiles/$profile/profile.json"
if [[ ! -f "$profileJsonPath" ]]; then
  printf 'Profile definition not found: %s\n' "$profileJsonPath" >&2
  exit 1
fi
profileJson="$(tr -d '\r\n' < "$profileJsonPath")"
stepsText="$(printf '%s\n' "$profileJson" | sed -n 's/.*"steps"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')"
if [[ -z "$stepsText" ]]; then
  printf 'Cannot read profile definition %s: missing steps array\n' "$profileJsonPath" >&2
  exit 1
fi
mapfile -t steps < <(printf '%s\n' "$stepsText" | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//; /^[[:space:]]*$/d')
if ((${#steps[@]} == 0)); then
  printf 'Cannot read profile definition %s: empty steps array\n' "$profileJsonPath" >&2
  exit 1
fi
vscodiumExtensionSync="$(printf '%s\n' "$profileJson" | sed -n 's/.*"vscodiumExtensionSync"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ -z "$vscodiumExtensionSync" ]]; then
  vscodiumExtensionSync="exact"
fi

knownSteps=(
  "vscodium-config" "glissa" "glissa-server" "gitconfig" "codex-agents" "terminal"
  "plugins-remove" "workflow-config" "settings-render" "software" "fonts" "biome"
  "tailscale" "repos" "npm-globals" "python-tools" "vscodium-extensions"
)

if ((dryRun == 1)); then
  writeSection "Dry run"
  printf '%s    profile: %s%s\n' "$colorCyan" "$profile" "$colorReset"
  for knownStep in "${knownSteps[@]}"; do
    stepState="skip"
    if stepEnabled "$knownStep"; then
      stepState="run"
    fi
    writeLine " -- " "$colorDarkGray" "$knownStep" "$stepState"
    if [[ "$knownStep" == "workflow-config" ]]; then
      printf '%s        CLAUDE.md: %s -> %s%s\n' "$colorDarkGray" "$repoRoot/profiles/$profile/CLAUDE.md" "$repoRoot/CLAUDE.md" "$colorReset"
      printf '%s        commit.md: %s -> %s%s\n' "$colorDarkGray" "$repoRoot/profiles/$profile/commit.md" "$repoRoot/commands/commit.md" "$colorReset"
    fi
    if [[ "$knownStep" == "settings-render" ]]; then
      printf '%s        %s + %s -> %s%s\n' "$colorDarkGray" "$repoRoot/settings.base.json" "$repoRoot/profiles/$profile/settings.overlay.json" "$repoRoot/settings.json" "$colorReset"
    fi
  done
  printf '\n'
  printf '%s  Dry run only, nothing written.%s\n' "$colorCyan" "$colorReset"
  exit 0
fi

if ((writeMarker == 1)); then
  printf '%s\n' "$profile" > "$markerPath"
fi

writeSection "Config"
if stepEnabled "vscodium-config"; then
  codiumUser="$HOME/.config/VSCodium/User"
  copyConfig "VSCodium settings" "$setupDir/vscodium/settings.json" "$codiumUser/settings.json"
  copyConfig "VSCodium keybindings" "$setupDir/vscodium/keybindings.json" "$codiumUser/keybindings.json"
  copyConfig "VSCodium mcp.json" "$setupDir/vscodium/mcp.json" "$codiumUser/mcp.json"
fi
if ! stepEnabled "vscodium-config"; then
  noteSkipped "VSCodium config"
fi
if stepEnabled "glissa"; then
  glissaDest="$HOME/.glissa/config.json"
  glissaExists=0
  if [[ -f "$glissaDest" ]]; then
    glissaExists=1
  fi
  if ((glissaExists == 1)); then
    notePresent "glissa config" "exists, runtime state kept"
  fi
  if ((glissaExists == 0)); then
    glissaSrc="$setupDir/glissa/config.json"
    if [[ ! -f "$glissaSrc" ]]; then
      glissaSrc="$setupDir/glissa/config.example.json"
      noteWarned "glissa config" "no config.json, seeding from config.example.json (edit project paths)"
    fi
    copyGlissaSeedConfig "$glissaSrc" "$glissaDest"
  fi
fi
if ! stepEnabled "glissa"; then
  noteSkipped "glissa config"
fi
if stepEnabled "gitconfig"; then
  gitConfigSrc="$setupDir/git/.gitconfig"
  gitConfigIsPlaceholder=0
  if [[ -f "$gitConfigSrc" ]] && grep -Eq 'you@example\.com|Your Name' "$gitConfigSrc"; then
    gitConfigIsPlaceholder=1
  fi
  gitIdentityName=""
  gitIdentityEmail=""
  if command -v git >/dev/null 2>&1; then
    gitIdentityName="$(git config --global user.name 2>/dev/null || true)"
    gitIdentityEmail="$(git config --global user.email 2>/dev/null || true)"
  fi
  gitIdentityConfigured=0
  if [[ -n "$gitIdentityName" && -n "$gitIdentityEmail" ]]; then
    gitIdentityConfigured=1
  fi
  # A machine whose global git identity is already set is not asked again, and
  # its ~/.gitconfig is never overwritten from the placeholder template.
  if ((gitConfigIsPlaceholder == 1)) && ((gitIdentityConfigured == 1)); then
    notePresent "gitconfig" "identity already configured"
  fi
  if ((gitConfigIsPlaceholder == 1)) && ((gitIdentityConfigured == 0)); then
    gitCommitName=""
    gitCommitEmail=""
    if canPromptUser && openPromptInput; then
      gitCommitName="$(promptValue "Git commit name")"
      gitCommitEmail="$(promptValue "Git commit email")"
    fi
    if [[ -n "$gitCommitName" && -n "$gitCommitEmail" ]]; then
      tempGitConfig="$(mktemp "${TMPDIR:-/tmp}/claude-gitconfig.XXXXXX")"
      awk -v gitCommitName="$gitCommitName" -v gitCommitEmail="$gitCommitEmail" '
        BEGIN { inHeader = 1 }
        inHeader && /^#/ { next }
        { inHeader = 0 }
        /^[[:space:]]*name[[:space:]]*=[[:space:]]*Your Name[[:space:]]*$/ { print "\tname = " gitCommitName; next }
        /^[[:space:]]*email[[:space:]]*=[[:space:]]*you@example\.com[[:space:]]*$/ { print "\temail = " gitCommitEmail; next }
        { print }
      ' "$gitConfigSrc" > "$tempGitConfig"
      copyConfig "gitconfig" "$tempGitConfig" "$HOME/.gitconfig"
      rm -f "$tempGitConfig"
    fi
    if [[ -z "$gitCommitName" || -z "$gitCommitEmail" ]]; then
      noteWarned "gitconfig" "placeholder identity, edit setup/git/.gitconfig first"
    fi
  fi
  if ((gitConfigIsPlaceholder == 0)); then
    copyConfig "gitconfig" "$gitConfigSrc" "$HOME/.gitconfig"
  fi
fi
if ! stepEnabled "gitconfig"; then
  noteSkipped "gitconfig"
fi
if stepEnabled "codex-agents"; then
  copyConfig "Codex AGENTS.md" "$repoRoot/AGENTS.md" "$HOME/.codex/AGENTS.md"
fi
if ! stepEnabled "codex-agents"; then
  noteSkipped "Codex AGENTS.md"
fi
if stepEnabled "terminal"; then
  notePresent "Windows Terminal" "not applicable on Linux"
fi
if ! stepEnabled "terminal"; then
  noteSkipped "Windows Terminal"
fi

writeSection "Retired plugins"
if ! stepEnabled "plugins-remove"; then
  noteSkipped "plugin removals"
fi
if stepEnabled "plugins-remove"; then
  removeRetiredPlugins
fi

writeSection "Workflow"
if stepEnabled "workflow-config"; then
  claudeSrc="$repoRoot/profiles/$profile/CLAUDE.md"
  claudeDest="$repoRoot/CLAUDE.md"
  backupIfFirstRun "$claudeDest" "$claudeSrc"
  copyConfig "CLAUDE.md" "$claudeSrc" "$claudeDest"
  commitSrc="$repoRoot/profiles/$profile/commit.md"
  commitDest="$repoRoot/commands/commit.md"
  backupIfFirstRun "$commitDest" "$commitSrc"
  copyConfig "commit.md" "$commitSrc" "$commitDest"
fi
if ! stepEnabled "workflow-config"; then
  noteSkipped "workflow config"
fi
if stepEnabled "settings-render"; then
  invokeSettingsRender
fi
if ! stepEnabled "settings-render"; then
  noteSkipped "settings.json"
fi

if ((skipInstalls == 1)); then
  elapsedSeconds="$((SECONDS - scriptStartSeconds))"
  printf '\n'
  printf '%s  Done in %ss: %s updated, %s up to date, %s warnings. Installs skipped.%s\n' "$colorCyan" "$elapsedSeconds" "$countsApplied" "$countsPresent" "$countsWarned" "$colorReset"
  exit 0
fi

writeSection "Tools"
if ! stepEnabled "software"; then
  noteSkipped "Tools"
fi
if stepEnabled "software"; then
  installPackageTool "git" "git" "git"
  installPackageTool "GitHub CLI" "gh" "gh"
  ensureGithubAuth
  installNodeJs
  installPackageTool "Python" "python3" "python"
  installPackageTool "VSCodium" "codium" "vscodium"
  installClaudeCode
  installZed
  installFlatpakApp "Zen" "app.zen_browser.zen"
  installFlatpakApp "Bitwarden" "com.bitwarden.desktop"
  installFlatpakApp "Discord" "com.discordapp.Discord"
  installFlatpakApp "Remmina" "org.remmina.Remmina"
  if [[ "$profile" == "personal" ]]; then
    installLogitechTools
    installHeadsetControl
  fi
  if [[ "$profile" != "personal" ]]; then
    noteSkipped "peripheral tools"
  fi
fi
if ! stepEnabled "tailscale"; then
  noteSkipped "Tailscale"
fi
if stepEnabled "tailscale"; then
  installTailscaleLinux
fi

if ((retrySettingsRender == 1)); then
  invokeSettingsRender
fi

if ((retryRemoveRetiredPlugins == 1)); then
  removeRetiredPlugins
fi

writeSection "Glissa server"
if ! stepEnabled "glissa-server"; then
  noteSkipped "glissa server"
fi
if stepEnabled "glissa-server"; then
  installGlissaServer
fi

writeSection "Fonts"
if ! stepEnabled "fonts"; then
  noteSkipped "Fonts"
fi
if stepEnabled "fonts"; then
  fontDir="$HOME/.local/share/fonts"
  installedAnyFont=0
  mkdir -p "$fontDir"
  shopt -s nullglob
  for font in "$setupDir"/fonts/*; do
    target="$fontDir/$(basename -- "$font")"
    fontLabel="$(basename -- "$font")"
    fontLabel="${fontLabel%.*}"
    if filesAreIdentical "$font" "$target"; then
      notePresent "$fontLabel" "installed"
      continue
    fi
    cp -f "$font" "$target"
    installedAnyFont=1
    noteInstalled "$fontLabel" "installed"
  done
  shopt -u nullglob
  if ((installedAnyFont == 1)); then
    if command -v fc-cache >/dev/null 2>&1; then
      fc-cache -f >/dev/null || noteWarned "font cache" "fc-cache failed"
    fi
    if ! command -v fc-cache >/dev/null 2>&1; then
      noteWarned "font cache" "fc-cache missing"
    fi
  fi
fi

writeSection "Hook deps"
if ! stepEnabled "biome"; then
  noteSkipped "biome"
fi
if stepEnabled "biome"; then
  if command -v biome >/dev/null 2>&1; then
    notePresent "biome" "already installed"
  fi
  if ! command -v biome >/dev/null 2>&1; then
    if ! command -v npm >/dev/null 2>&1; then
      noteWarned "biome" "npm not on PATH"
    fi
    if command -v npm >/dev/null 2>&1; then
      ensureUserNpmPrefix
      writeLine " .. " "$colorYellow" "biome" "npm install -g @biomejs/biome"
      biomeInstallOk=0
      biomeInstallLog="$(mktemp "${TMPDIR:-/tmp}/claude-npm-install.XXXXXX")"
      if npm install -g @biomejs/biome --loglevel=error >"$biomeInstallLog" 2>&1; then
        biomeInstallOk=1
      fi
      refreshSessionPath
      if ((biomeInstallOk == 1)); then
        rm -f "$biomeInstallLog"
        noteInstalled "biome" "installed"
      fi
      if ((biomeInstallOk == 0)); then
        biomeFailureReason="$(npmFailureReason "$biomeInstallLog")"
        rm -f "$biomeInstallLog"
        noteWarned "biome" "npm install failed: $biomeFailureReason"
      fi
    fi
  fi
fi

writeSection "Repos"
if ! stepEnabled "repos"; then
  noteSkipped "Repos"
fi
if stepEnabled "repos"; then
  repoFile="$setupDir/repos.txt"
  if [[ ! -f "$repoFile" ]]; then
    repoFile="$setupDir/repos.example.txt"
    if [[ -f "$repoFile" ]]; then
      noteWarned "repos" "no repos.txt, using repos.example.txt"
    fi
  fi
  if [[ ! -f "$repoFile" ]]; then
    noteWarned "repos" "no repos.txt or repos.example.txt"
  fi
  if [[ -f "$repoFile" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      noteWarned "repos" "git not on PATH"
    fi
  fi
  if [[ -f "$repoFile" ]] && command -v git >/dev/null 2>&1; then
    operatorGitHubOwner="$(resolveOperatorGitHubOwner)" || operatorGitHubOwner=""
    # read the list up front: git and npm inherit stdin, and a credential prompt would
    # otherwise swallow the remaining repo lines
    mapfile -t repoLines < "$repoFile"
    for repoLine in "${repoLines[@]}"; do
      repoLine="${repoLine#$'\xef\xbb\xbf'}"
      if [[ ! "$repoLine" =~ = ]]; then
        continue
      fi
      if [[ "$repoLine" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      # The guarded call is what disables set -e for the whole entry and everything
      # it calls, so one bad repo cannot abort apply.
      warnedBeforeEntry="$countsWarned"
      # Safety net for a FUTURE stage that fails without warning; every current
      # failure path in syncOneRepo warns first, so this line is unreachable today.
      if ! syncOneRepo "$repoLine" && ((countsWarned == warnedBeforeEntry)); then
        noteWarned "repos" "entry failed, continuing: $repoLine"
      fi
    done
  fi
fi

writeSection "npm globals"
if ! stepEnabled "npm-globals"; then
  noteSkipped "npm globals"
fi
if stepEnabled "npm-globals"; then
  npmGlobals="$setupDir/npm-globals.txt"
  if ! command -v npm >/dev/null 2>&1; then
    noteWarned "npm" "not on PATH, skipping packages"
  fi
  if [[ -f "$npmGlobals" ]] && command -v npm >/dev/null 2>&1; then
    ensureUserNpmPrefix
    mapfile -t wantedPackages < <(readPackageList "$npmGlobals")
    mapfile -t installedPackages < <(listGlobalNpmPackages)
    missingPackages=()
    for packageEntry in "${wantedPackages[@]}"; do
      packageName="$(npmPackageName "$packageEntry")"
      packageFound=0
      for installedPackage in "${installedPackages[@]}"; do
        if [[ "$installedPackage" == "$packageName" ]]; then
          packageFound=1
        fi
      done
      if ((packageFound == 0)); then
        missingPackages+=("$packageEntry")
      fi
    done
    if ((${#missingPackages[@]} == 0)); then
      notePresent "packages" "all ${#wantedPackages[@]} present"
    fi
    for packageEntry in "${missingPackages[@]}"; do
      packageName="$(npmPackageName "$packageEntry")"
      packageSource="$(npmPackageSource "$packageEntry")"
      writeLine " .. " "$colorYellow" "$packageName" "npm install -g $packageSource"
      npmInstallLog="$(mktemp "${TMPDIR:-/tmp}/claude-npm-install.XXXXXX")"
      if installGlobalNpmPackage "$packageSource" >"$npmInstallLog" 2>&1; then
        rm -f "$npmInstallLog"
        noteInstalled "$packageName" "installed"
        continue
      fi
      # The tracked list is shared with Windows, where some of these publish a
      # win32-only package. That is a fact about the package, not a failure.
      if grep -q "EBADPLATFORM" "$npmInstallLog"; then
        rm -f "$npmInstallLog"
        notePresent "$packageName" "not published for this platform"
        continue
      fi
      npmInstallFailureReason="$(npmFailureReason "$npmInstallLog")"
      rm -f "$npmInstallLog"
      noteWarned "$packageName" "npm install failed: $npmInstallFailureReason"
    done
  fi
  npmRemovals="$setupDir/npm-globals-remove.txt"
  if [[ -f "$npmRemovals" ]] && command -v npm >/dev/null 2>&1; then
    ensureUserNpmPrefix
    mapfile -t unwantedPackages < <(readPackageList "$npmRemovals")
    mapfile -t installedPackages < <(listGlobalNpmPackages)
    presentPackages=()
    for packageName in "${unwantedPackages[@]}"; do
      packageFound=0
      for installedPackage in "${installedPackages[@]}"; do
        if [[ "$installedPackage" == "$packageName" ]]; then
          packageFound=1
        fi
      done
      if ((packageFound == 1)); then
        presentPackages+=("$packageName")
      fi
    done
    if ((${#presentPackages[@]} == 0)); then
      notePresent "npm removals" "none present"
    fi
    for packageName in "${presentPackages[@]}"; do
      writeLine " .. " "$colorYellow" "$packageName" "npm uninstall -g"
      if npm uninstall -g "$packageName" --loglevel=error >/dev/null; then
        noteApplied "$packageName" "removed"
        continue
      fi
      noteWarned "$packageName" "npm uninstall failed"
    done
  fi
fi

writeSection "Python tools"
if ! stepEnabled "python-tools"; then
  noteSkipped "Python tools"
fi
if stepEnabled "python-tools"; then
  if ! python="$(pythonCommandName)"; then
    noteWarned "python" "not on PATH, skipping pip tools"
  fi
  if [[ -n "${python:-}" ]]; then
    ensurePythonPackage "$python" "ruff" "ruff"
    ensurePythonPackage "$python" "yaml" "pyyaml"
  fi
fi

writeSection "VSCodium extensions"
if ! stepEnabled "vscodium-extensions"; then
  noteSkipped "VSCodium extensions"
fi
if stepEnabled "vscodium-extensions"; then
  extFile="$setupDir/vscodium/extensions.txt"
  if ! command -v codium >/dev/null 2>&1; then
    noteWarned "codium" "not on PATH, skipping extensions"
  fi
  if [[ -f "$extFile" ]] && command -v codium >/dev/null 2>&1; then
    mapfile -t wantedExtensions < <(sed '/^[[:space:]]*$/d' "$extFile")
    mapfile -t installedExtensions < <(codium --list-extensions)
    missingExtensions=()
    extraExtensions=()
    for extensionName in "${wantedExtensions[@]}"; do
      extensionFound=0
      for installedExtension in "${installedExtensions[@]}"; do
        if [[ "$installedExtension" == "$extensionName" ]]; then
          extensionFound=1
        fi
      done
      if ((extensionFound == 0)); then
        missingExtensions+=("$extensionName")
      fi
    done
    for installedExtension in "${installedExtensions[@]}"; do
      extensionWanted=0
      for extensionName in "${wantedExtensions[@]}"; do
        if [[ "$installedExtension" == "$extensionName" ]]; then
          extensionWanted=1
        fi
      done
      if ((extensionWanted == 0)); then
        extraExtensions+=("$installedExtension")
      fi
    done
    if [[ "$vscodiumExtensionSync" == "exact" ]] && ((${#missingExtensions[@]} == 0)) && ((${#extraExtensions[@]} == 0)); then
      notePresent "extensions" "all ${#wantedExtensions[@]} in sync"
    fi
    if [[ "$vscodiumExtensionSync" != "exact" ]] && ((${#missingExtensions[@]} == 0)); then
      notePresent "extensions" "all ${#wantedExtensions[@]} present"
    fi
    for extensionName in "${missingExtensions[@]}"; do
      writeLine " .. " "$colorYellow" "$extensionName" "installing"
      if codium --install-extension "$extensionName" >/dev/null; then
        noteInstalled "$extensionName" "installed"
        continue
      fi
      noteWarned "$extensionName" "install failed"
    done
    if [[ "$vscodiumExtensionSync" == "exact" ]]; then
      for extensionName in "${extraExtensions[@]}"; do
        writeLine " .. " "$colorYellow" "$extensionName" "uninstalling (not in extensions.txt)"
        if codium --uninstall-extension "$extensionName" >/dev/null; then
          noteApplied "$extensionName" "removed"
          continue
        fi
        noteWarned "$extensionName" "uninstall failed"
      done
    fi
    if [[ "$vscodiumExtensionSync" != "exact" ]] && ((${#extraExtensions[@]} > 0)); then
      notePresent "extensions extra" "${#extraExtensions[@]} kept (additive sync)"
    fi
  fi
fi

elapsedSeconds="$((SECONDS - scriptStartSeconds))"
summaryColor="$colorCyan"
if ((countsWarned > 0)); then
  summaryColor="$colorYellow"
fi
printf '\n'
printf '%s  Done in %ss: %s updated, %s installed, %s up to date, %s warnings.%s\n' "$summaryColor" "$elapsedSeconds" "$countsApplied" "$countsInstalled" "$countsPresent" "$countsWarned" "$colorReset"
