#!/usr/bin/env bash
set -euo pipefail

repoUrl="https://github.com/johncwaters/claude-setup.git"
skipInstalls=0
profile=""
root="$HOME/.claude"

usage() {
  cat <<'USAGE'
Usage: setup/install.sh [--skip-installs] [--profile personal|work|server] [--root <dir>] [--help]

Clone or update claude-setup, then apply it.
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

if ! command -v git >/dev/null 2>&1; then
  printf '\n'
  printf '\033[31m  git is required. Install git with your distro package manager, then rerun.\033[0m\n'
  exit 1
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
