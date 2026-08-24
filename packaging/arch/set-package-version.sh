#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $2 =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Usage: set-package-version.sh <major.minor.patch> <full-lowercase-upstream-commit>' >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
version=$1
upstream_commit=$2
current_version=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")

if [[ $current_version != "$version" ]]; then
  sed -i "s/^pkgver=.*/pkgver=$version/" "$script_dir/PKGBUILD"
  sed -i 's/^pkgrel=.*/pkgrel=1/' "$script_dir/PKGBUILD"
fi

sed -i "0,/\"version\": \"[^\"]*\"/s//\"version\": \"$version\"/" \
  "$repo_root/manifest.json"
printf '%s\n' "$upstream_commit" >"$script_dir/upstream-commit"
sed -i -E \
  "s/^(readonly upstream_commit=)'[0-9a-f]{40}'$/\1'$upstream_commit'/" \
  "$script_dir/build-omarchy-package.sh"
sed -i -E \
  "s/(fetch --depth 1 origin )[0-9a-f]{40}/\1$upstream_commit/" \
  "$script_dir/build-omarchy-package.sh"
sed -i -E \
  "s/(checkout --detach )[0-9a-f]{40}/\1$upstream_commit/" \
  "$script_dir/build-omarchy-package.sh"

grep -qxF "pkgver=$version" "$script_dir/PKGBUILD"
grep -Eq '^pkgrel=[1-9][0-9]*$' "$script_dir/PKGBUILD"
grep -qxF "  \"version\": \"$version\"," "$repo_root/manifest.json"
grep -qxF "$upstream_commit" "$script_dir/upstream-commit"
grep -qxF "readonly upstream_commit='$upstream_commit'" \
  "$script_dir/build-omarchy-package.sh"
grep -qxF "git -C \"\$studio_root\" fetch --depth 1 origin $upstream_commit" \
  "$script_dir/build-omarchy-package.sh"
grep -qxF "git -C \"\$studio_root\" checkout --detach $upstream_commit ||" \
  "$script_dir/build-omarchy-package.sh"
