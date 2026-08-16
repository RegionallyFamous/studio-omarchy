#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
version=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")
build_root=$(mktemp -d)
studio_root="$build_root/studio"
trap 'rm -rf "$build_root"' EXIT

if [[ $(uname -s) != 'Linux' || ! -f /etc/arch-release ]]; then
  echo 'This package must be built on Arch Linux or Omarchy.' >&2
  exit 1
fi

for command_name in git makepkg node npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

git clone --depth 1 --branch "v$version" https://github.com/Automattic/studio.git "$studio_root"
git -C "$studio_root" apply --check "$repo_root/patches/studio-omarchy.patch"
git -C "$studio_root" apply "$repo_root/patches/studio-omarchy.patch"

required_node_major=$(cut -d. -f1 "$studio_root/.nvmrc")
current_node_major=$(node -p "process.versions.node.split('.')[0]")
if [[ $current_node_major != "$required_node_major" ]]; then
  echo "Studio requires the Node major pinned upstream ($required_node_major)." >&2
  echo "Current Node major: $current_node_major" >&2
  exit 1
fi

app_version=$(node -p "require('$studio_root/apps/studio/package.json').version")
if [[ $app_version != "$version" ]]; then
  echo "Studio tag v$version contains app version $app_version." >&2
  exit 1
fi

cd "$studio_root"
npm ci
npm run package

cd "$script_dir"
STUDIO_SOURCE_ROOT="$studio_root" makepkg --force --cleanbuild --clean --syncdeps

"$script_dir/verify-package.sh"

echo
echo 'Package created:'
find "$script_dir" -maxdepth 1 -name 'wordpress-studio-omarchy-*.pkg.tar.*' -print
