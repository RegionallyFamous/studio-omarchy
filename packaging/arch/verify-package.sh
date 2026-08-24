#!/bin/bash -p

set -euo pipefail

PATH=/usr/bin:/usr/sbin
export PATH

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
archive_details=$(LC_ALL=C bsdtar --numeric-owner -tvf "$package_path") ||
  fail 'Package archive ownership and modes are unreadable.'
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
  'usr/lib/studio/'
  'usr/lib/studio/.omarchy-runtime-integrity'
  'usr/lib/studio/chrome-sandbox'
  'usr/lib/studio/resources/'
  'usr/lib/studio/resources/app.asar'
  'usr/lib/studio/resources/bin/'
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

awk '
  NF < 4 || $3 != "0" || $4 != "0" {
    print "Package member is not archived as root:root: " $0 > "/dev/stderr"
    bad=1
  }
  END { exit bad ? 1 : 0 }
' <<<"$archive_details" || fail 'Package archive contains non-root ownership metadata.'

verification_root=$(mktemp -d)
trap 'rm -rf -- "$verification_root"' EXIT
bsdtar -xpf "$package_path" -C "$verification_root" -- \
  .INSTALL \
  usr/bin/studio \
  usr/bin/studio-omarchy-cleanup-user-trust \
  usr/bin/studio-omarchy-update \
  usr/lib/studio/.omarchy-runtime-integrity \
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
  local relative_path=$1 expected_mode=$2 max_size=${3:-0}
  local extracted_path="$verification_root/$relative_path" actual_mode metadata
  local file_type uid gid links size

  [[ -f $extracted_path && ! -L $extracted_path ]] ||
    fail "Packaged $relative_path is not a regular file."
  metadata=$(LC_ALL=C stat -c '%F|%u|%g|%a|%h|%s' -- "$extracted_path") ||
    fail "Unable to inspect packaged $relative_path."
  IFS='|' read -r file_type uid gid actual_mode links size <<<"$metadata"
  [[ $file_type == "regular file" ]] ||
    fail "Packaged $relative_path is not a regular file."
  [[ $actual_mode == "$expected_mode" ]] ||
    fail "Packaged $relative_path must have mode $expected_mode, not $actual_mode."
  (( links == 1 && size > 0 )) ||
    fail "Packaged $relative_path has unsafe link-count or size metadata."
  if (( EUID == 0 && (uid != 0 || gid != 0) )); then
    fail "Extracted $relative_path did not preserve root ownership."
  fi
  if (( max_size > 0 && size > max_size )); then
    fail "Packaged $relative_path is unexpectedly large."
  fi
}

verify_archive_regular_root_file() {
  local relative_path=$1 expected_mode=$2
  local archive_record archive_mode archive_uid archive_gid

  archive_record=$(
    awk -v path="$relative_path" '
      $NF == path { count++; record=$1 "|" $3 "|" $4 }
      END { if (count != 1) exit 1; print record }
    ' <<<"$archive_details"
  ) || fail "Package must contain one mode record for $relative_path."
  IFS='|' read -r archive_mode archive_uid archive_gid <<<"$archive_record"
  [[ $archive_mode == "$expected_mode" ]] ||
    fail "Packaged $relative_path must have archived mode $expected_mode, not $archive_mode."
  [[ ${archive_mode:0:1} == "-" && $archive_uid == "0" && $archive_gid == "0" ]] ||
    fail "Packaged $relative_path must be a root-owned regular archive member."
}

verify_archive_root_directory() {
  local relative_path=$1 archive_record archive_mode archive_uid archive_gid

  archive_record=$(
    awk -v path="$relative_path" '
      $NF == path { count++; record=$1 "|" $3 "|" $4 }
      END { if (count != 1) exit 1; print record }
    ' <<<"$archive_details"
  ) || fail "Package must contain one mode record for $relative_path."
  IFS='|' read -r archive_mode archive_uid archive_gid <<<"$archive_record"
  [[ $archive_mode == "drwxr-xr-x" && $archive_uid == "0" && $archive_gid == "0" ]] ||
    fail "Packaged $relative_path must be a root-owned, non-writable directory."
}

verify_mode '.INSTALL' '644'
verify_mode 'usr/bin/studio' '755'
verify_mode 'usr/bin/studio-omarchy-cleanup-user-trust' '755'
verify_mode 'usr/bin/studio-omarchy-update' '755'
verify_archive_root_directory 'usr/lib/studio/'
verify_archive_root_directory 'usr/lib/studio/resources/'
verify_archive_root_directory 'usr/lib/studio/resources/bin/'
verify_mode 'usr/lib/studio/.omarchy-runtime-integrity' '644' 4096
verify_archive_regular_root_file 'usr/lib/studio/.omarchy-runtime-integrity' '-rw-r--r--'
verify_archive_regular_root_file 'usr/lib/studio/chrome-sandbox' '-rwsr-xr-x'
verify_archive_regular_root_file 'usr/lib/studio/resources/bin/node' '-rwxr-xr-x'
if (( EUID == 0 )); then
  extracted_sandbox_mode=4755
else
  # libarchive deliberately strips setuid bits when a non-root caller extracts.
  extracted_sandbox_mode=755
fi
verify_mode 'usr/lib/studio/chrome-sandbox' "$extracted_sandbox_mode" 5242880
verify_mode 'usr/lib/studio/resources/app.asar' '644'
verify_mode 'usr/lib/studio/resources/bin/node' '755' 209715200
verify_mode 'usr/lib/studio/resources/bin/studio-cli.sh' '755'
verify_mode 'usr/lib/studio/resources/cli/main.mjs' '644'
verify_mode 'usr/lib/studio/studio' '755'
verify_mode 'usr/share/applications/studio.desktop' '644'
verify_mode 'usr/share/icons/hicolor/512x512/apps/studio.png' '644'
verify_mode 'usr/share/licenses/wordpress-studio-omarchy/LICENSE.md' '644'

mapfile -t runtime_integrity_records \
  <"$verification_root/usr/lib/studio/.omarchy-runtime-integrity"
(( ${#runtime_integrity_records[@]} == 2 )) ||
  fail 'The runtime integrity manifest must have exactly two records.'
(( ${#runtime_integrity_records[0]} == 80 &&
  ${#runtime_integrity_records[1]} == 84 )) ||
  fail 'The runtime integrity manifest records have unexpected lengths.'
[[ $(stat -c '%s' -- "$verification_root/usr/lib/studio/.omarchy-runtime-integrity") == "166" ]] ||
  fail 'The runtime integrity manifest has unexpected byte length.'
[[ ${runtime_integrity_records[0]:64:2} == "  " &&
  ${runtime_integrity_records[0]:66} == "chrome-sandbox" ]] ||
  fail 'The runtime integrity manifest has an invalid chrome-sandbox record.'
[[ ${runtime_integrity_records[1]:64:2} == "  " &&
  ${runtime_integrity_records[1]:66} == "resources/bin/node" ]] ||
  fail 'The runtime integrity manifest has an invalid Node record.'
declared_sandbox_hash=${runtime_integrity_records[0]:0:64}
declared_node_hash=${runtime_integrity_records[1]:0:64}
[[ $declared_sandbox_hash =~ ^[0-9a-f]{64}$ &&
  $declared_node_hash =~ ^[0-9a-f]{64}$ ]] ||
  fail 'The runtime integrity manifest contains an invalid SHA-256 value.'

actual_sandbox_hash=$(sha256sum -- "$verification_root/usr/lib/studio/chrome-sandbox")
actual_sandbox_hash=${actual_sandbox_hash%% *}
actual_node_hash=$(sha256sum -- "$verification_root/usr/lib/studio/resources/bin/node")
actual_node_hash=${actual_node_hash%% *}
[[ $actual_sandbox_hash == "$declared_sandbox_hash" ]] ||
  fail 'The packaged chrome-sandbox does not match its integrity record.'
[[ $actual_node_hash == "$declared_node_hash" ]] ||
  fail 'The packaged Node runtime does not match its integrity record.'

expected_sandbox_hash=${STUDIO_EXPECTED_CHROME_SANDBOX_SHA256:-}
expected_node_hash=${STUDIO_EXPECTED_NODE_SHA256:-}
if [[ -n $expected_sandbox_hash || -n $expected_node_hash ]]; then
  [[ $expected_sandbox_hash =~ ^[0-9a-f]{64}$ &&
    $expected_node_hash =~ ^[0-9a-f]{64}$ ]] ||
    fail 'Both independent runtime hashes must be supplied as lowercase SHA-256 values.'
  [[ $declared_sandbox_hash == "$expected_sandbox_hash" ]] ||
    fail 'The packaged chrome-sandbox differs from the independently verified runtime.'
  [[ $declared_node_hash == "$expected_node_hash" ]] ||
    fail 'The packaged Node runtime differs from the independently verified runtime.'
fi

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

awk '
  {
    mode=$1
    path=$NF
    if ((substr(mode, 4, 1) ~ /[sS]/ || substr(mode, 7, 1) ~ /[sS]/) &&
        path != "usr/lib/studio/chrome-sandbox") {
      print "Unexpected set-id package member: " path > "/dev/stderr"
      bad=1
    }
    if ((substr(mode, 1, 1) == "-" || substr(mode, 1, 1) == "d") &&
        (substr(mode, 6, 1) == "w" || substr(mode, 9, 1) == "w")) {
      print "Group/world-writable package member: " path > "/dev/stderr"
      bad=1
    }
  }
  END { exit bad ? 1 : 0 }
' <<<"$archive_details" || fail 'Package contains unsafe file modes.'

echo "Verified package metadata, structure, bytes, and modes: $package_path"
