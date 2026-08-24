#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
version=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")
readonly upstream_commit='121b18d77f96e4362c7d22bdcd4c428022503f8b'
upstream_commit_file="$script_dir/upstream-commit"
cleanup_source="$repo_root/scripts/cleanup-user-trust.sh"

fail() {
  echo "$*" >&2
  exit 1
}

if [[ $(uname -s) != 'Linux' || ! -f /etc/arch-release ]]; then
  echo 'This package must be built on Arch Linux or Omarchy.' >&2
  exit 1
fi

[[ -f $upstream_commit_file && ! -L $upstream_commit_file ]] ||
  fail 'The pinned upstream commit file is missing or unsafe.'
recorded_upstream_commit=$(<"$upstream_commit_file")
[[ $recorded_upstream_commit =~ ^[0-9a-f]{40}$ ]] ||
  fail 'The pinned upstream commit must be a full lowercase Git commit.'
[[ $recorded_upstream_commit == "$upstream_commit" ]] ||
  fail 'The build helper and upstream commit file disagree.'
[[ -f $cleanup_source && ! -L $cleanup_source ]] ||
  fail 'The canonical browser trust cleanup source is missing or unsafe.'
[[ ! -e $script_dir/cleanup-user-trust.sh && ! -L $script_dir/cleanup-user-trust.sh ]] ||
  fail 'A packaging-directory file shadows the canonical browser trust cleanup source.'

ci_build=false
if [[ ${1:-} == '--ci' ]]; then
  [[ $# -eq 1 ]] || fail 'Usage: build-omarchy-package.sh [--ci]'
  ci_build=true
elif [[ $# -ne 0 ]]; then
  fail 'Usage: build-omarchy-package.sh [--ci]'
fi

for command_name in git makepkg node npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
done

build_root=$(mktemp -d)
studio_root="$build_root/studio"
trap 'rm -rf "$build_root"' EXIT

git init --quiet "$studio_root"
git -C "$studio_root" remote add origin https://github.com/Automattic/studio.git
git -C "$studio_root" fetch --depth 1 origin 121b18d77f96e4362c7d22bdcd4c428022503f8b
set +e
git -C "$studio_root" checkout --detach 121b18d77f96e4362c7d22bdcd4c428022503f8b &&
  [[ $(git -C "$studio_root" rev-parse HEAD) == "$upstream_commit" ]] &&
  git -C "$studio_root" apply --check "$repo_root/patches/studio-omarchy.patch" &&
  git -C "$studio_root" apply "$repo_root/patches/studio-omarchy.patch" &&
  required_node_major=$(cut -d. -f1 "$studio_root/.nvmrc") &&
  current_node_major=$(node -p "process.versions.node.split('.')[0]") &&
  [[ $current_node_major == "$required_node_major" ]] &&
  app_version=$(node -p "require('$studio_root/apps/studio/package.json').version") &&
  [[ $app_version == "$version" ]] &&
  npm --prefix "$studio_root" ci &&
  npm --prefix "$studio_root" run lint &&
  npm --prefix "$studio_root" run typecheck &&
  npm --prefix "$studio_root" test -- --maxWorkers=1 &&
  npm --prefix "$studio_root" run package
pinned_build_status=$?
set -e
(( pinned_build_status == 0 )) || fail 'Pinned Studio validation or build failed.'

cd "$script_dir"
if [[ $ci_build == true ]]; then
  SRCDEST="$repo_root/scripts" STUDIO_SOURCE_ROOT="$studio_root" \
    makepkg --force --cleanbuild --clean
else
  SRCDEST="$repo_root/scripts" STUDIO_SOURCE_ROOT="$studio_root" \
    makepkg --force --cleanbuild --clean --syncdeps
fi

"$script_dir/verify-package.sh"

echo
echo 'Package created:'
find "$script_dir" -maxdepth 1 -name 'wordpress-studio-omarchy-*.pkg.tar.*' -print
