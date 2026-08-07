#!/usr/bin/env bash
set -euo pipefail

setupDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repoRoot="$(cd -- "$setupDir/.." && pwd)"
markerPath="$repoRoot/.machine-profile"
machineProfile="personal"

usage() {
  cat <<'USAGE'
Usage: setup/collect.sh

Collect live machine config into this repo.
USAGE
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'collect.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# case-folded because the PowerShell scripts compare the marker with -eq, which is
# case-insensitive; a hand-edited "Work" must not quietly collect personal config
if [[ -f "$markerPath" ]]; then
  machineProfile="$(tr -d '\r\n[:space:]' < "$markerPath" | tr '[:upper:]' '[:lower:]')"
fi
if [[ ! -f "$markerPath" ]]; then
  printf 'WARNING: no .machine-profile marker, assuming personal\n' >&2
fi

copyIfExists() {
  local src="$1"
  local dest="$2"
  if [[ ! -f "$src" ]]; then
    printf 'WARNING: missing: %s\n' "$src" >&2
    return 0
  fi
  mkdir -p "$(dirname -- "$dest")"
  cp -f "$src" "$dest"
  printf 'collected: %s\n' "$src"
}

# A tracked list is replaced only when the probe actually produced entries. An
# empty result means the tool is missing or printed an unexpected shape, and
# truncating the file would silently drop the machine state the repo already has.
replaceListFile() {
  local label="$1"
  local dest="$2"
  local candidate="$3"
  if [[ ! -s "$candidate" ]]; then
    rm -f "$candidate"
    printf 'WARNING: no %s found, keeping existing %s\n' "$label" "$(basename -- "$dest")" >&2
    return 0
  fi
  mkdir -p "$(dirname -- "$dest")"
  mv -f "$candidate" "$dest"
  printf 'collected: %s\n' "$label"
}

collectVscodium() {
  local codiumUser="$HOME/.config/VSCodium/User"
  local extensionList
  copyIfExists "$codiumUser/settings.json" "$setupDir/vscodium/settings.json"
  copyIfExists "$codiumUser/keybindings.json" "$setupDir/vscodium/keybindings.json"
  copyIfExists "$codiumUser/mcp.json" "$setupDir/vscodium/mcp.json"
  if ! command -v codium >/dev/null 2>&1; then
    return 0
  fi
  extensionList="$(mktemp "${TMPDIR:-/tmp}/claude-extensions.XXXXXX")"
  codium --list-extensions 2>/dev/null | sort > "$extensionList" || true
  replaceListFile "extension list" "$setupDir/vscodium/extensions.txt" "$extensionList"
}

collectGlissaRepos() {
  local glissaConfig="$HOME/.glissa/config.json"
  local repoEntries
  local projectPath
  local originUrl
  local relativeProjectPath
  if [[ ! -f "$glissaConfig" ]]; then
    return 0
  fi
  repoEntries="$(mktemp "${TMPDIR:-/tmp}/claude-repos.XXXXXX")"
  while IFS= read -r projectPath; do
    if [[ ! -d "$projectPath/.git" ]]; then
      continue
    fi
    originUrl="$(git -C "$projectPath" config --get remote.origin.url || true)"
    if [[ -z "$originUrl" ]]; then
      printf 'WARNING: no origin remote, skipping: %s\n' "$projectPath" >&2
      continue
    fi
    relativeProjectPath="$projectPath"
    if [[ "$projectPath" == "$HOME/"* ]]; then
      relativeProjectPath="${projectPath#"$HOME/"}"
    fi
    if [[ "$projectPath" == "$HOME" ]]; then
      relativeProjectPath="."
    fi
    # Leave Linux-collected paths with / separators; both installers accept them.
    printf '%s=%s\n' "$relativeProjectPath" "$originUrl" >> "$repoEntries"
  done < <(
    grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$glissaConfig" |
      sed 's/^[^"]*"path"[[:space:]]*:[[:space:]]*"//; s/"$//' |
      sort -u
  )
  sort -o "$repoEntries" "$repoEntries"
  replaceListFile "glissa repos" "$setupDir/repos.txt" "$repoEntries"
}

collectGitConfig() {
  local gitConfigSrc="$HOME/.gitconfig"
  local gitConfigDest="$setupDir/git/.gitconfig"
  local section=""
  local line
  if [[ ! -f "$gitConfigSrc" ]]; then
    printf 'WARNING: missing: %s\n' "$gitConfigSrc" >&2
    return 0
  fi
  mkdir -p "$(dirname -- "$gitConfigDest")"
  {
    printf '# Placeholder identity. Edit these two values before running the apply script: while the\n'
    printf '# placeholders are present the gitconfig step refuses to copy this file to ~/.gitconfig,\n'
    printf '# so nobody commits under someone else'\''s name.\n'
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*\[[[:space:]]*([^][:space:]]+) ]]; then
        section="${BASH_REMATCH[1],,}"
      fi
      if [[ "$section" == "user" && "$line" =~ ^[[:space:]]*name[[:space:]]*= ]]; then
        printf '\tname = Your Name\n'
        continue
      fi
      if [[ "$section" == "user" && "$line" =~ ^[[:space:]]*email[[:space:]]*= ]]; then
        printf '\temail = you@example.com\n'
        continue
      fi
      printf '%s\n' "$line"
    done < "$gitConfigSrc"
  } > "$gitConfigDest"
  printf 'collected (identity scrubbed): %s\n' "$gitConfigSrc"
}

collectNpmGlobals() {
  local packageNames
  if ! command -v npm >/dev/null 2>&1; then
    return 0
  fi
  packageNames="$(mktemp "${TMPDIR:-/tmp}/claude-npm-globals.XXXXXX")"
  # print only lines the strip actually shortened: the first parseable line is the
  # global root itself, which contains node_modules with nothing after it
  npm ls -g --depth=0 --parseable 2>/dev/null |
    awk '{ if (sub(/^.*node_modules\//, "")) print }' |
    sed '/^npm$/d; /^[[:space:]]*$/d' |
    sort -u > "$packageNames" || true
  replaceListFile "npm globals" "$setupDir/npm-globals.txt" "$packageNames"
}

collectVscodium

if [[ "$machineProfile" == "work" ]]; then
  printf 'note: glissa, repos, gitconfig, terminal, and npm-globals collection are personal-profile only; workflow edits (CLAUDE.md, settings.json, commit.md) are committed directly from ~/.claude, not collected.\n'
  exit 0
fi

copyIfExists "$HOME/.glissa/config.json" "$setupDir/glissa/config.json"
collectGlissaRepos
collectGitConfig

printf 'Windows Terminal: not applicable on Linux\n'

collectNpmGlobals

printf 'done. Review changes with: git -C "%s/.claude" status\n' "$HOME"
