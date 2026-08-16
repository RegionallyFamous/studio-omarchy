#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
package_path=${1:-}

if [[ -z $package_path ]]; then
  package_path=$(find "$script_dir" -maxdepth 1 -name 'wordpress-studio-omarchy-*.pkg.tar.*' \
    -print -quit)
fi

if [[ -z $package_path || ! -f $package_path ]]; then
  echo 'No Studio for Omarchy package found.' >&2
  exit 1
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$script_dir/studio.desktop"
fi

required_paths=(
  'usr/bin/studio'
  'usr/bin/studio-omarchy-update'
  'usr/lib/studio/studio'
  'usr/lib/studio/resources/app.asar'
  'usr/lib/studio/resources/bin/node'
  'usr/share/applications/studio.desktop'
  'usr/share/icons/hicolor/512x512/apps/studio.png'
)

archive_listing=$(bsdtar -tf "$package_path")
for required_path in "${required_paths[@]}"; do
  if ! grep -qx "$required_path" <<<"$archive_listing"; then
    echo "Package is missing $required_path" >&2
    exit 1
  fi
done

echo "Verified package structure: $package_path"
