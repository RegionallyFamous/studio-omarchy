#!/bin/bash -p

set -euo pipefail
unset BASH_ENV ENV
PATH=/usr/bin:/usr/sbin
readonly PATH
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
version=$(sed -n 's/^pkgver=//p' "$script_dir/PKGBUILD")
readonly upstream_commit='e234e9491adc7484ce8829e8d0f24c874a6e5487'
upstream_commit_file="$script_dir/upstream-commit"
cleanup_source="$repo_root/scripts/cleanup-user-trust.sh"

fail() {
  echo "$*" >&2
  exit 1
}

download_verified_member() {
  local base_url=$1 archive_name=$2 member_name=$3 output_path=$4
  local download_root=$5 max_archive_size=$6
  local shasums_path="$download_root/$archive_name.SHASUMS256.txt"
  local archive_path="$download_root/$archive_name"
  local expected_archive_hash actual_archive_hash member_hash

  /usr/bin/curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --cacert /etc/ssl/certs/ca-certificates.crt \
    --connect-timeout 10 --max-time 60 --max-filesize 2097152 \
    --output "$shasums_path" "$base_url/SHASUMS256.txt" ||
    fail "Unable to download the official checksums for $archive_name."
  expected_archive_hash=$(
    /usr/bin/awk -v archive="$archive_name" '
      $1 ~ /^[0-9a-f]{64}$/ && ($2 == archive || $2 == "*" archive) {
        count++
        hash=$1
      }
      END {
        if (count != 1) exit 1
        print hash
      }
    ' "$shasums_path"
  ) || fail "The official checksum list has no unique record for $archive_name."

  /usr/bin/curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --cacert /etc/ssl/certs/ca-certificates.crt \
    --connect-timeout 10 --max-time 600 --max-filesize "$max_archive_size" \
    --output "$archive_path" "$base_url/$archive_name" ||
    fail "Unable to download the official archive $archive_name."
  actual_archive_hash=$(/usr/bin/sha256sum -- "$archive_path")
  actual_archive_hash=${actual_archive_hash%% *}
  [[ $actual_archive_hash == "$expected_archive_hash" ]] ||
    fail "The official archive checksum does not match for $archive_name."

  [[ ! -e $output_path && ! -L $output_path ]] ||
    fail "The trusted runtime output already exists: $output_path"
  /usr/bin/bsdtar -xOf "$archive_path" "$member_name" >"$output_path" ||
    fail "Unable to extract $member_name from $archive_name."
  [[ -f $output_path && ! -L $output_path ]] ||
    fail "The trusted runtime member is not a regular file: $member_name"
  /usr/bin/chmod 0555 "$output_path"
  member_hash=$(/usr/bin/sha256sum -- "$output_path")
  member_hash=${member_hash%% *}
  [[ $member_hash =~ ^[0-9a-f]{64}$ ]] ||
    fail "Unable to hash the trusted runtime member: $member_name"
  printf '%s\n' "$member_hash"
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

for command_name in bsdtar curl git makepkg node npm sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
done

build_root=$(mktemp -d)
studio_root="$build_root/studio"
trusted_runtime_root="$build_root/trusted-runtime"
install -d -m 0700 "$trusted_runtime_root"
trap '/usr/bin/rm -rf -- "$build_root"' EXIT

git init --quiet "$studio_root"
git -C "$studio_root" remote add origin https://github.com/Automattic/studio.git
git -C "$studio_root" fetch --depth 1 origin e234e9491adc7484ce8829e8d0f24c874a6e5487
git -C "$studio_root" checkout --detach e234e9491adc7484ce8829e8d0f24c874a6e5487 ||
  fail 'Unable to check out the pinned Studio source.'
[[ $(git -C "$studio_root" rev-parse HEAD) == "$upstream_commit" ]] ||
  fail 'The checked-out Studio source does not match the pinned commit.'
git -C "$studio_root" apply --check "$repo_root/patches/studio-omarchy.patch" ||
  fail 'The Omarchy patch does not apply to the pinned Studio source.'
git -C "$studio_root" apply "$repo_root/patches/studio-omarchy.patch" ||
  fail 'Unable to apply the Omarchy patch.'

required_node_major=$(cut -d. -f1 "$studio_root/.nvmrc")
current_node_major=$(node -p "process.versions.node.split('.')[0]")
[[ $current_node_major == "$required_node_major" ]] ||
  fail 'The active Node major does not match the pinned Studio source.'
app_version=$(node -p "require('$studio_root/apps/studio/package.json').version")
[[ $app_version == "$version" ]] ||
  fail 'The Studio source version does not match PKGBUILD.'

electron_version=$(node -p \
  "require('$studio_root/package-lock.json').packages['node_modules/electron'].version")
[[ $electron_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Unsupported pinned Electron version: $electron_version"
node_version=$(<"$studio_root/.nvmrc")
node_version=${node_version#v}
[[ $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Unsupported pinned Node version: $node_version"

electron_archive="electron-v$electron_version-linux-x64.zip"
trusted_sandbox="$trusted_runtime_root/chrome-sandbox"
trusted_sandbox_hash=$(download_verified_member \
  "https://github.com/electron/electron/releases/download/v$electron_version" \
  "$electron_archive" 'chrome-sandbox' "$trusted_sandbox" \
  "$trusted_runtime_root" 314572800)

node_archive="node-v$node_version-linux-x64.tar.gz"
trusted_node="$trusted_runtime_root/node"
trusted_node_hash=$(download_verified_member \
  "https://nodejs.org/dist/v$node_version" "$node_archive" \
  "node-v$node_version-linux-x64/bin/node" "$trusted_node" \
  "$trusted_runtime_root" 209715200)

set +e
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
  SRCDEST="$repo_root/scripts" \
    STUDIO_SOURCE_ROOT="$studio_root" \
    STUDIO_CHROME_SANDBOX_SOURCE="$trusted_sandbox" \
    STUDIO_CHROME_SANDBOX_SHA256="$trusted_sandbox_hash" \
    STUDIO_NODE_SOURCE="$trusted_node" \
    STUDIO_NODE_SHA256="$trusted_node_hash" \
    makepkg --force --cleanbuild --clean
else
  SRCDEST="$repo_root/scripts" \
    STUDIO_SOURCE_ROOT="$studio_root" \
    STUDIO_CHROME_SANDBOX_SOURCE="$trusted_sandbox" \
    STUDIO_CHROME_SANDBOX_SHA256="$trusted_sandbox_hash" \
    STUDIO_NODE_SOURCE="$trusted_node" \
    STUDIO_NODE_SHA256="$trusted_node_hash" \
    makepkg --force --cleanbuild --clean --syncdeps
fi

STUDIO_EXPECTED_CHROME_SANDBOX_SHA256="$trusted_sandbox_hash" \
  STUDIO_EXPECTED_NODE_SHA256="$trusted_node_hash" \
  "$script_dir/verify-package.sh"

echo
echo 'Package created:'
find "$script_dir" -maxdepth 1 -name 'wordpress-studio-omarchy-*.pkg.tar.*' -print
