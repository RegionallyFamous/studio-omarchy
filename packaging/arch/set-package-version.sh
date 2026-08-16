#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Usage: set-package-version.sh <major.minor.patch>' >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
version=$1
current_version=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")

if [[ $current_version != "$version" ]]; then
  sed -i "s/^pkgver=.*/pkgver=$version/" "$script_dir/PKGBUILD"
  sed -i 's/^pkgrel=.*/pkgrel=1/' "$script_dir/PKGBUILD"
fi

grep -qxF "pkgver=$version" "$script_dir/PKGBUILD"
grep -Eq '^pkgrel=[1-9][0-9]*$' "$script_dir/PKGBUILD"
