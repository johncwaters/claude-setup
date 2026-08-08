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
aptUpdated=0
detectedPackageManager=""
scriptStartSeconds="$SECONDS"

setupDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repoRoot="$(cd -- "$setupDir/.." && pwd)"

colorCyan=$'\033[36m'
colorGreen=$'\033[32m'
colorYellow=$'\033[33m'
colorRed=$'\033[31m'
colorDarkGray=$'\033[90m'
colorReset=$'\033[0m'

usage() {
  cat <<'USAGE'
Usage: setup/apply.sh [--skip-installs] [--profile personal|work] [--dry-run]

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
        printf 'apply.sh: --profile requires personal or work\n' >&2
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
  ""|personal|work) ;;
  *)
    printf 'apply.sh: --profile must be personal or work\n' >&2
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
    gh:pacman)
      printf 'github-cli\n'
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
  command -v "$commandName" >/dev/null 2>&1
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
      noteWarned "$label" "not in default repos, install from https://vscodium.com/#install"
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
  case "$manager" in
    apt-get)
      if ((aptUpdated == 0)); then
        if ! runPackageManagerCommand apt-get update >/dev/null; then
          noteWarned "$label" "apt-get update failed"
          return 0
        fi
        aptUpdated=1
      fi
      if ! runPackageManagerCommand apt-get install -y "${packageNameArgs[@]}" >/dev/null; then
        noteWarned "$label" "$manager install failed"
        return 0
      fi
      ;;
    dnf)
      if ! runPackageManagerCommand dnf install -y "${packageNameArgs[@]}" >/dev/null; then
        noteWarned "$label" "$manager install failed"
        return 0
      fi
      ;;
    pacman)
      if ! runPackageManagerCommand pacman -S --noconfirm --needed "${packageNameArgs[@]}" >/dev/null; then
        noteWarned "$label" "$manager install failed"
        return 0
      fi
      ;;
    zypper)
      if ! runPackageManagerCommand zypper --non-interactive install "${packageNameArgs[@]}" >/dev/null; then
        noteWarned "$label" "$manager install failed"
        return 0
      fi
      ;;
  esac
  refreshSessionPath
  if toolIsPresent "$toolKey" "$commandName"; then
    noteInstalled "$label" "installed"
    return 0
  fi
  noteWarned "$label" "installed, but open a new shell for PATH"
}

installClaudeCode() {
  refreshSessionPath
  if command -v claude >/dev/null 2>&1; then
    notePresent "Claude Code" "already installed"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    noteWarned "Claude Code" "curl not on PATH, install manually"
    return 0
  fi
  writeLine " .. " "$colorYellow" "Claude Code" "running native installer"
  if ! curl -fsSL https://claude.ai/install.sh | bash >/dev/null; then
    noteWarned "Claude Code" "native installer failed"
    return 0
  fi
  refreshSessionPath
  if command -v claude >/dev/null 2>&1; then
    noteInstalled "Claude Code" "installed"
    return 0
  fi
  noteWarned "Claude Code" "not on PATH yet, open a new shell"
}

syncDevelopBranch() {
  local label="$1"
  local dest="$2"
  local hasLocalDevelopBranch=0
  local hasRemoteDevelopBranch=0
  if git -C "$dest" rev-parse --verify -q refs/heads/develop >/dev/null; then
    hasLocalDevelopBranch=1
  fi
  if git -C "$dest" rev-parse --verify -q refs/remotes/origin/develop >/dev/null; then
    hasRemoteDevelopBranch=1
  fi
  if ((hasLocalDevelopBranch == 0)) && ((hasRemoteDevelopBranch == 1)); then
    git -C "$dest" branch -q --track develop origin/develop
    noteInstalled "$label develop" "tracking origin/develop"
    return 0
  fi
  if ((hasLocalDevelopBranch == 0)); then
    git -C "$dest" branch -q develop
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

readPackageList() {
  local packageFile="$1"
  if [[ ! -f "$packageFile" ]]; then
    return 0
  fi
  sed '1s/^\xEF\xBB\xBF//' "$packageFile" | sed '/^[[:space:]]*$/d'
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
  if [[ "$fromMarker" == "personal" || "$fromMarker" == "work" ]]; then
    profile="$fromMarker"
  fi
  if [[ -z "$profile" ]]; then
    printf '%s  .machine-profile has invalid content, ignoring%s\n' "$colorYellow" "$colorReset"
  fi
fi
while [[ -z "$profile" ]]; do
  if [[ ! -t 0 ]]; then
    printf 'Cannot prompt for a machine profile on a non-interactive host. Re-run with --profile personal or --profile work.\n' >&2
    exit 1
  fi
  read -r -p "Machine profile (personal/work) " answer
  answer="${answer//[$'\r\n\t ']}"
  answer="${answer,,}"
  if [[ "$answer" == "personal" || "$answer" == "work" ]]; then
    profile="$answer"
    writeMarker=1
  fi
  if [[ -z "$profile" ]]; then
    printf '%s  Enter '\''personal'\'' or '\''work'\''.%s\n' "$colorYellow" "$colorReset"
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
  "vscodium-config" "glissa" "gitconfig" "codex-agents" "terminal"
  "workflow-config" "settings-render" "software" "fonts" "biome"
  "repos" "npm-globals" "python-tools" "vscodium-extensions"
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
    copyConfig "glissa config" "$glissaSrc" "$glissaDest"
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
  if ((gitConfigIsPlaceholder == 1)); then
    noteWarned "gitconfig" "placeholder identity, edit setup/git/.gitconfig first"
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
  installPackageTool "Node.js" "node" "node"
  installPackageTool "Python" "python3" "python"
  installPackageTool "VSCodium" "codium" "vscodium"
  installClaudeCode
fi

if ((retrySettingsRender == 1)); then
  invokeSettingsRender
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
      writeLine " .. " "$colorYellow" "biome" "npm install -g @biomejs/biome"
      biomeInstallOk=0
      if npm install -g @biomejs/biome --loglevel=error >/dev/null; then
        biomeInstallOk=1
      fi
      refreshSessionPath
      if ((biomeInstallOk == 1)); then
        noteInstalled "biome" "installed"
      fi
      if ((biomeInstallOk == 0)); then
        noteWarned "biome" "npm install failed"
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
      relPath="${repoLine%%=*}"
      cloneUrl="${repoLine#*=}"
      relPath="${relPath#"${relPath%%[![:space:]]*}"}"
      relPath="${relPath%"${relPath##*[![:space:]]}"}"
      cloneUrl="${cloneUrl#"${cloneUrl%%[![:space:]]*}"}"
      cloneUrl="${cloneUrl%"${cloneUrl##*[![:space:]]}"}"
      relPath="${relPath//\\//}"
      dest="$HOME/$relPath"
      label="$(basename -- "$dest")"
      if [[ ! -e "$dest" ]]; then
        writeLine " .. " "$colorYellow" "$label" "cloning"
        mkdir -p "$(dirname -- "$dest")"
        if ! git clone -q "$cloneUrl" "$dest"; then
          noteWarned "$label" "clone failed"
          continue
        fi
        noteInstalled "$label" "cloned"
        syncDevelopBranch "$label" "$dest"
        installRepoDeps "$label" "$dest"
        continue
      fi
      if [[ ! -d "$dest/.git" ]]; then
        noteWarned "$label" "exists but is not a git repo"
        continue
      fi
      if ! git -C "$dest" pull --ff-only -q; then
        noteWarned "$label" "pull failed (dirty or diverged), resolve manually"
        continue
      fi
      notePresent "$label" "synced"
      syncDevelopBranch "$label" "$dest"
      installRepoDeps "$label" "$dest"
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
    mapfile -t wantedPackages < <(readPackageList "$npmGlobals")
    mapfile -t installedPackages < <(listGlobalNpmPackages)
    missingPackages=()
    for packageName in "${wantedPackages[@]}"; do
      packageFound=0
      for installedPackage in "${installedPackages[@]}"; do
        if [[ "$installedPackage" == "$packageName" ]]; then
          packageFound=1
        fi
      done
      if ((packageFound == 0)); then
        missingPackages+=("$packageName")
      fi
    done
    if ((${#missingPackages[@]} == 0)); then
      notePresent "packages" "all ${#wantedPackages[@]} present"
    fi
    for packageName in "${missingPackages[@]}"; do
      writeLine " .. " "$colorYellow" "$packageName" "npm install -g"
      npmInstallLog="$(mktemp "${TMPDIR:-/tmp}/claude-npm-install.XXXXXX")"
      if npm install -g "$packageName" --loglevel=error >"$npmInstallLog" 2>&1; then
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
      rm -f "$npmInstallLog"
      noteWarned "$packageName" "npm install failed"
    done
  fi
  npmRemovals="$setupDir/npm-globals-remove.txt"
  if [[ -f "$npmRemovals" ]] && command -v npm >/dev/null 2>&1; then
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
