#!/usr/bin/env bash
set -euo pipefail

repoUrl="https://github.com/johncwaters/claude-setup.git"
skipInstalls=0
profile=""
root="$HOME/.claude"
aptUpdated=0

usage() {
  cat <<'USAGE'
Usage: setup/install.sh [--skip-installs] [--profile personal|work|server] [--root <dir>] [--help]

Install git and curl if missing, clone or update claude-setup, then apply it.
USAGE
}

isRoot() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

runAsRoot() {
  if isRoot; then
    "$@"
    return $?
  fi
  sudo "$@"
}

detectPackageManager() {
  local manager
  for manager in apt-get dnf pacman zypper; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s\n' "$manager"
      return 0
    fi
  done
  return 1
}

installSystemPackage() {
  local manager="$1"
  local packageName="$2"
  case "$manager" in
    apt-get)
      if ((aptUpdated == 0)); then
        if ! runAsRoot apt-get update >/dev/null 2>&1; then
          return 1
        fi
        aptUpdated=1
      fi
      runAsRoot apt-get install -y "$packageName" >/dev/null 2>&1
      return $?
      ;;
    dnf)
      runAsRoot dnf install -y "$packageName" >/dev/null 2>&1
      return $?
      ;;
    pacman)
      runAsRoot pacman -S --noconfirm --needed "$packageName" >/dev/null 2>&1
      return $?
      ;;
    zypper)
      runAsRoot zypper --non-interactive install "$packageName" >/dev/null 2>&1
      return $?
      ;;
  esac
  return 1
}

# apply.sh owns the same detection, but it only exists after the clone this
# script has yet to make, so the bootstrap prerequisites install standalone.
ensurePrerequisite() {
  local commandName="$1"
  local manager
  if command -v "$commandName" >/dev/null 2>&1; then
    return 0
  fi
  if ! manager="$(detectPackageManager)"; then
    printf '\033[33m  %s is missing and no supported package manager was found\033[0m\n' "$commandName"
    return 1
  fi
  if ! isRoot && ! command -v sudo >/dev/null 2>&1; then
    printf '\033[33m  %s is missing and %s needs root or sudo\033[0m\n' "$commandName" "$manager"
    return 1
  fi
  printf '\033[36m  Installing %s via %s\033[0m\n' "$commandName" "$manager"
  if ! installSystemPackage "$manager" "$commandName"; then
    printf '\033[33m  %s install via %s failed\033[0m\n' "$commandName" "$manager"
    return 1
  fi
  hash -r
  command -v "$commandName" >/dev/null 2>&1
}

while (($# > 0)); do
  case "$1" in
    --skip-installs)
      skipInstalls=1
      shift
      ;;
    --profile)
      if (($# < 2)); then
        printf 'install.sh: --profile requires personal, work, or server\n' >&2
        exit 2
      fi
      profile="$2"
      shift 2
      ;;
    --root)
      if (($# < 2)); then
        printf 'install.sh: --root requires a directory\n' >&2
        exit 2
      fi
      root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$profile" in
  ""|personal|work|server) ;;
  *)
    printf 'install.sh: --profile must be personal, work, or server\n' >&2
    exit 2
    ;;
esac

printf '\n'
printf '\033[36m  +--------------------------------------------+\033[0m\n'
printf '\033[36m  |   claude-setup  ::  machine bootstrap      |\033[0m\n'
printf '\033[36m  +--------------------------------------------+\033[0m\n'

printf '\n'
if ! ensurePrerequisite git; then
  printf '\033[31m  git is required and could not be installed automatically. Install git with your distro package manager, then rerun.\033[0m\n'
  exit 1
fi
if ! ensurePrerequisite curl; then
  printf '\033[33m  curl is missing, so the Claude Code install step will warn until it is present.\033[0m\n'
fi

printf '\n'
if [[ -d "$root/.git" ]]; then
  printf '\033[36m  Repo found at %s, pulling latest\033[0m\n' "$root"
  if ! git -C "$root" pull --ff-only -q; then
    printf '\033[31m  git pull failed; resolve manually in %s then rerun\033[0m\n' "$root"
    exit 1
  fi
fi

if [[ ! -d "$root/.git" ]]; then
  printf '\033[36m  Cloning into %s (browser may open for GitHub sign-in)\033[0m\n' "$root"
  mkdir -p "$root"
  git -C "$root" init -q -b master
  git -C "$root" remote add origin "$repoUrl" 2>/dev/null || git -C "$root" remote set-url origin "$repoUrl"
  git -C "$root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$root" fetch -q origin
  if ! git -C "$root" checkout -q -f -B master origin/master; then
    printf '\033[31m  clone failed; check GitHub access then rerun\033[0m\n'
    exit 1
  fi
fi

printf '\033[90m  At commit %s\033[0m\n' "$(git -C "$root" rev-parse --short HEAD)"

applyArgs=()
if ((skipInstalls == 1)); then
  applyArgs+=(--skip-installs)
fi
if [[ -n "$profile" ]]; then
  applyArgs+=(--profile "$profile")
fi

exec bash "$root/setup/apply.sh" "${applyArgs[@]}"
