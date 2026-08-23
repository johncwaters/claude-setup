#!/usr/bin/env bash
# Run the Linux acceptance suite against a throwaway container.
#
#   bash setup/test/run-docker.sh                  fast suite on Debian
#   bash setup/test/run-docker.sh --full           adds the install steps and the hook run
#   bash setup/test/run-docker.sh --distro fedora  same suite against the dnf branch
#   bash setup/test/run-docker.sh --distro arch    same suite against the pacman branch
#   bash setup/test/run-docker.sh --distro ubuntu  same suite against Ubuntu 24.04
#   bash setup/test/run-docker.sh --distro ubuntu22 same suite against Ubuntu 22.04
#
# Works from Git Bash on Windows and from any Linux shell. The container gets a
# snapshot of the current working tree (tracked and not-yet-committed files
# both), served as a local git origin, so the suite exercises the real bootstrap
# path without touching GitHub or this machine.
set -euo pipefail

suiteMode="fast"
distro="debian"
keepWorkDir=0

usage() {
  cat <<'USAGE'
Usage: setup/test/run-docker.sh [--full] [--distro debian|fedora|arch|ubuntu|ubuntu22] [--keep] [--help]
USAGE
}

while (($# > 0)); do
  case "$1" in
    --full)
      suiteMode="full"
      shift
      ;;
    --distro)
      if (($# < 2)); then
        printf 'run-docker.sh: --distro requires debian, fedora, arch, ubuntu, or ubuntu22\n' >&2
        exit 2
      fi
      distro="$2"
      shift 2
      ;;
    --keep)
      keepWorkDir=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'run-docker.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$distro" in
  debian|fedora|arch|ubuntu|ubuntu22) ;;
  *)
    printf 'run-docker.sh: --distro must be debian, fedora, arch, ubuntu, or ubuntu22\n' >&2
    exit 2
    ;;
esac

dockerfileDistro="$distro"
dockerBuildArgs=()
case "$distro" in
  ubuntu)
    dockerfileDistro="ubuntu"
    dockerBuildArgs+=(--build-arg UBUNTU_IMAGE=ubuntu:24.04)
    ;;
  ubuntu22)
    dockerfileDistro="ubuntu"
    dockerBuildArgs+=(--build-arg UBUNTU_IMAGE=ubuntu:22.04)
    ;;
esac

testDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repoRoot="$(cd -- "$testDir/../.." && pwd)"
workDir="$(mktemp -d)"

cleanup() {
  if ((keepWorkDir == 1)); then
    printf 'work dir kept at %s\n' "$workDir"
    return 0
  fi
  rm -rf "$workDir"
}
trap cleanup EXIT

runDocker() {
  # Container-side paths only: MSYS would otherwise rewrite them into Windows
  # paths. Scoped to docker so git keeps its own MSYS path translation.
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
}

hostPath() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
    return 0
  fi
  printf '%s\n' "$1"
}

printf 'snapshotting the working tree\n'
mkdir -p "$workDir/src" "$workDir/context"
(
  cd "$repoRoot"
  git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' trackedFile; do
    mkdir -p "$workDir/src/$(dirname -- "$trackedFile")"
    cp -- "$trackedFile" "$workDir/src/$trackedFile"
  done
)
(
  cd "$workDir/src"
  git init -q -b master
  git add -A
  git -c user.name="Suite Snapshot" -c user.email="suite@example.com" commit -q -m "working tree snapshot"
)
git clone -q --bare "$workDir/src" "$workDir/origin.git"

# bash reads a script incrementally, so a live mount would let an edit during a
# long run corrupt the copy the container is still parsing.
cp "$testDir/suite.sh" "$workDir/suite.sh"

imageTag="claude-setup-test:$distro"
printf 'building %s\n' "$imageTag"
runDocker build -q -f "$(hostPath "$testDir/Dockerfile.$dockerfileDistro")" "${dockerBuildArgs[@]}" -t "$imageTag" "$(hostPath "$workDir/context")" >/dev/null

printf 'running the %s suite\n' "$suiteMode"
runDocker run --rm \
  -e "SUITE_MODE=$suiteMode" \
  -v "$(hostPath "$workDir/origin.git"):/origin.git:ro" \
  -v "$(hostPath "$workDir/src"):/suite/src:ro" \
  -v "$(hostPath "$workDir/suite.sh"):/suite/suite.sh:ro" \
  "$imageTag"
