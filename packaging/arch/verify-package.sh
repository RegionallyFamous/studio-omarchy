#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
pkgver=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")
pkgrel=$(sed -n 's/^pkgrel=//p' "$script_dir/PKGBUILD")
package_path=${1:-}

fail() {
  echo "$*" >&2
  exit 1
}

[[ $pkgver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid PKGBUILD version: $pkgver"
[[ $pkgrel =~ ^[1-9][0-9]*$ ]] || fail "Invalid PKGBUILD revision: $pkgrel"

expected_name="wordpress-studio-omarchy-$pkgver-$pkgrel-x86_64.pkg.tar.zst"
if [[ -z $package_path ]]; then
  package_path="$script_dir/$expected_name"
fi

[[ ${package_path##*/} == "$expected_name" ]] ||
  fail "Unexpected package filename: ${package_path##*/}"
[[ -f $package_path && ! -L $package_path ]] ||
  fail "No safe Studio for Omarchy package found at $package_path"

archive_listing=$(bsdtar -tf "$package_path") || fail 'Package archive is unreadable.'
if awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ { found=1 } END { exit found ? 0 : 1 }' \
  <<<"$archive_listing"; then
  fail 'Package contains an unsafe absolute or parent-traversal path.'
fi
required_paths=(
  '.BUILDINFO'
  '.INSTALL'
  '.MTREE'
  '.PKGINFO'
  'usr/bin/studio'
  'usr/bin/studio-omarchy-cleanup-user-trust'
  'usr/bin/studio-omarchy-update'
  'usr/lib/studio/chrome-sandbox'
  'usr/lib/studio/resources/app.asar'
  'usr/lib/studio/resources/bin/node'
  'usr/lib/studio/resources/bin/studio-cli.sh'
  'usr/lib/studio/resources/cli/main.mjs'
  'usr/lib/studio/studio'
  'usr/share/applications/studio.desktop'
  'usr/share/icons/hicolor/512x512/apps/studio.png'
  'usr/share/licenses/wordpress-studio-omarchy/LICENSE.md'
)

for required_path in "${required_paths[@]}"; do
  count=$(grep -Fxc -- "$required_path" <<<"$archive_listing" || true)
  (( count == 1 )) || fail "Package must contain $required_path exactly once."
done

pkginfo=$(bsdtar -xOf "$package_path" .PKGINFO) || fail 'Package has no readable .PKGINFO.'
pkginfo_value() {
  local key=$1

  awk -v key="$key" '
    index($0, key " = ") == 1 { count++; value=substr($0, length(key) + 4) }
    END { if (count != 1) exit 1; print value }
  ' <<<"$pkginfo"
}

actual_pkgname=$(pkginfo_value pkgname) || fail 'Package must contain exactly one pkgname.'
actual_pkgver=$(pkginfo_value pkgver) || fail 'Package must contain exactly one pkgver.'
actual_arch=$(pkginfo_value arch) || fail 'Package must contain exactly one arch.'
[[ $actual_pkgname == "wordpress-studio-omarchy" ]] || fail "Unexpected pkgname: $actual_pkgname"
[[ $actual_pkgver == "$pkgver-$pkgrel" ]] || fail "Unexpected pkgver: $actual_pkgver"
[[ $actual_arch == "x86_64" ]] || fail "Unexpected package architecture: $actual_arch"

verification_root=$(mktemp -d)
trap 'rm -rf -- "$verification_root"' EXIT
bsdtar -xpf "$package_path" -C "$verification_root" -- \
  .INSTALL \
  usr/bin/studio \
  usr/bin/studio-omarchy-cleanup-user-trust \
  usr/bin/studio-omarchy-update \
  usr/lib/studio/chrome-sandbox \
  usr/lib/studio/resources/app.asar \
  usr/lib/studio/resources/bin/node \
  usr/lib/studio/resources/bin/studio-cli.sh \
  usr/lib/studio/resources/cli/main.mjs \
  usr/lib/studio/studio \
  usr/share/applications/studio.desktop \
  usr/share/icons/hicolor/512x512/apps/studio.png \
  usr/share/licenses/wordpress-studio-omarchy/LICENSE.md ||
  fail 'Unable to extract package members for verification.'

verify_mode() {
  local relative_path=$1 expected_mode=$2
  local extracted_path="$verification_root/$relative_path" actual_mode

  [[ -f $extracted_path && ! -L $extracted_path ]] ||
    fail "Packaged $relative_path is not a regular file."
  actual_mode=$(stat -c '%a' -- "$extracted_path")
  [[ $actual_mode == "$expected_mode" ]] ||
    fail "Packaged $relative_path must have mode $expected_mode, not $actual_mode."
}

verify_mode '.INSTALL' '644'
verify_mode 'usr/bin/studio' '755'
verify_mode 'usr/bin/studio-omarchy-cleanup-user-trust' '755'
verify_mode 'usr/bin/studio-omarchy-update' '755'
verify_mode 'usr/lib/studio/chrome-sandbox' '4755'
verify_mode 'usr/lib/studio/resources/app.asar' '644'
verify_mode 'usr/lib/studio/resources/bin/node' '755'
verify_mode 'usr/lib/studio/resources/bin/studio-cli.sh' '755'
verify_mode 'usr/lib/studio/resources/cli/main.mjs' '644'
verify_mode 'usr/lib/studio/studio' '755'
verify_mode 'usr/share/applications/studio.desktop' '644'
verify_mode 'usr/share/icons/hicolor/512x512/apps/studio.png' '644'
verify_mode 'usr/share/licenses/wordpress-studio-omarchy/LICENSE.md' '644'

cmp -s "$verification_root/usr/bin/studio" "$script_dir/studio-launcher" ||
  fail 'Packaged Studio launcher differs from its source.'
cmp -s "$verification_root/usr/bin/studio-omarchy-cleanup-user-trust" \
  "$repo_root/scripts/cleanup-user-trust.sh" ||
  fail 'Packaged browser trust cleanup helper differs from its source.'
cmp -s "$verification_root/usr/bin/studio-omarchy-update" "$script_dir/studio-omarchy-update" ||
  fail 'Packaged Studio updater differs from its source.'
cmp -s "$verification_root/.INSTALL" "$script_dir/studio.install" ||
  fail 'Packaged install hook differs from its source.'
cmp -s "$verification_root/usr/share/applications/studio.desktop" "$script_dir/studio.desktop" ||
  fail 'Packaged desktop entry differs from its source.'
cmp -s "$verification_root/usr/share/licenses/wordpress-studio-omarchy/LICENSE.md" \
  "$repo_root/LICENSE.md" || fail 'Packaged license differs from its source.'

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$verification_root/usr/share/applications/studio.desktop"
fi

LC_ALL=C bsdtar -tvf "$package_path" | awk '
  {
    mode=$1
    path=$NF
    if ((substr(mode, 4, 1) ~ /[sS]/ || substr(mode, 7, 1) ~ /[sS]/) &&
        path != "usr/lib/studio/chrome-sandbox") {
      print "Unexpected set-id package member: " path > "/dev/stderr"
      bad=1
    }
    if ((substr(mode, 1, 1) == "-" || substr(mode, 1, 1) == "d") &&
        substr(mode, 9, 1) == "w") {
      print "World-writable package member: " path > "/dev/stderr"
      bad=1
    }
  }
  END { exit bad ? 1 : 0 }
' || fail 'Package contains unsafe file modes.'

echo "Verified package metadata, structure, bytes, and modes: $package_path"
