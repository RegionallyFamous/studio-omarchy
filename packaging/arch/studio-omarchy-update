#!/bin/bash

set -euo pipefail

readonly github_repo='RegionallyFamous/studio-omarchy'
readonly releases_api="https://api.github.com/repos/$github_repo/releases/latest"
readonly release_json_max_bytes=262144
readonly checksum_max_bytes=512
package_max_bytes=2147483648
test_mode=false

fail() {
  echo "WordPress Studio installation failed: $*" >&2
  exit 1
}

test_mode_request=${STUDIO_OMARCHY_TEST_MODE:-0}
[[ $test_mode_request == 0 || $test_mode_request == 1 ]] ||
  fail 'invalid test mode request'

if [[ $test_mode_request == 1 ]]; then
  [[ -n ${STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES:-} && -n ${STUDIO_OMARCHY_DOWNLOAD_DIR:-} ]] ||
    fail 'test mode requires an isolated download directory and package byte budget'
  test_mode=true
elif [[ ! -f /etc/arch-release ]]; then
  fail 'WordPress Studio for Omarchy requires Omarchy or Arch Linux'
fi

if [[ $test_mode == true ]]; then
  [[ $STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES =~ ^[1-9][0-9]*$ ]] ||
    fail 'invalid test package byte budget'
  package_max_bytes=$STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES
fi

download_bounded() {
  local url="$1"
  local output="$2"
  local max_bytes="$3"
  local max_seconds="$4"
  local partial="$output.part"
  local outer_seconds=$((max_seconds + 10))
  local size

  [[ $url == https://* ]] || fail "refusing a non-HTTPS download"
  [[ ! -e $partial && ! -L $partial ]] || fail "refusing an existing partial download: $partial"

  timeout --signal=TERM --kill-after=5s "${outer_seconds}s" \
    curl --fail --show-error --location \
      --proto '=https' \
      --proto-redir '=https' \
      --connect-timeout 10 \
      --max-time "$max_seconds" \
      --max-filesize "$max_bytes" \
      --output "$partial" \
      "$url"

  [[ -f $partial && ! -L $partial ]] || fail "download did not produce a regular file"
  size=$(wc -c <"$partial")
  (( size > 0 && size <= max_bytes )) || fail "download exceeded its byte budget"
  mv -- "$partial" "$output"
}

install_verified_package() {
  local source_path="$1"
  local package_name="$2"
  local expected_hash="$3"
  local max_bytes="$4"
  local actual_hash hash_limit

  [[ -f $source_path && ! -L $source_path ]] ||
    fail 'the verified package is not a regular file'
  hash_limit=$((max_bytes + 1))
  actual_hash=$(
    timeout --signal=TERM --kill-after=5s 120s \
      head -c "$hash_limit" "$source_path" |
      sha256sum |
      cut -d ' ' -f 1
  ) || fail 'the package checksum could not be read within its safety budget'
  [[ $actual_hash == "$expected_hash" ]] || fail 'the package checksum does not match'
  printf '%s: OK\n' "$package_name"

  sudo /usr/bin/bash -c '
set -euo pipefail
export LC_ALL=C

source_path=$1
package_name=$2
expected_hash=$3
max_bytes=$4
staging_dir=""

privileged_fail() {
  echo "WordPress Studio installation failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n $staging_dir && $staging_dir == /var/tmp/studio-omarchy-install.* ]]; then
    /usr/bin/rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT

[[ $package_name =~ ^wordpress-studio-omarchy-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] ||
  privileged_fail "the privileged package handoff name is unsafe"
[[ $expected_hash =~ ^[0-9a-f]{64}$ ]] ||
  privileged_fail "the privileged package handoff checksum is unsafe"
[[ $max_bytes =~ ^[1-9][0-9]*$ ]] && (( max_bytes <= 2147483648 )) ||
  privileged_fail "the privileged package handoff byte budget is unsafe"
[[ $source_path == /* && ${source_path##*/} == "$package_name" ]] ||
  privileged_fail "the privileged package handoff source path is unsafe"

umask 077
staging_dir=$(/usr/bin/mktemp -d /var/tmp/studio-omarchy-install.XXXXXXXXXX)
[[ $staging_dir == /var/tmp/studio-omarchy-install.* && -d $staging_dir && ! -L $staging_dir ]] ||
  privileged_fail "could not create a safe privileged package staging directory"
staged_path="$staging_dir/$package_name"
copy_limit=$((max_bytes + 1))

if ! /usr/bin/timeout --signal=TERM --kill-after=5s 120s \
  /usr/bin/dd \
    if="$source_path" \
    of="$staged_path" \
    iflag=nofollow,nonblock,fullblock,count_bytes \
    bs=1M \
    count="$copy_limit" \
    status=none; then
  privileged_fail "the privileged package handoff copy failed or exceeded its deadline"
fi
[[ ! -L $staged_path && -f $staged_path ]] ||
  privileged_fail "the privileged package handoff did not produce a regular file"
/usr/bin/chmod 600 -- "$staged_path"
IFS="|" read -r staged_type staged_uid staged_gid staged_mode staged_links staged_bytes < <(
  /usr/bin/stat -c "%F|%u|%g|%a|%h|%s" -- "$staged_path"
) || privileged_fail "the privileged package handoff metadata could not be read"
[[ $staged_type == "regular file" && $staged_uid == 0 && $staged_gid == 0 &&
  $staged_mode == 600 && $staged_links == 1 && $staged_bytes =~ ^[1-9][0-9]*$ ]] ||
  privileged_fail "the privileged package handoff metadata is unsafe"
(( staged_bytes <= max_bytes )) ||
  privileged_fail "the package changed beyond its byte budget before installation"
read -r staged_hash _ < <(
  /usr/bin/timeout --signal=TERM --kill-after=5s 120s \
    /usr/bin/sha256sum "$staged_path"
) ||
  privileged_fail "the privileged package handoff checksum could not be read"
[[ $staged_hash == "$expected_hash" ]] ||
  privileged_fail "the package changed before the privileged installation handoff"

/usr/bin/pacman -U --needed --noconfirm -- "$staged_path"
' bash "$source_path" "$package_name" "$expected_hash" "$max_bytes"
}

for command_name in curl jq pacman realpath sha256sum sudo timeout; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

machine_arch=$(uname -m)
[[ $machine_arch == "x86_64" ]] ||
  fail "unsupported architecture: $machine_arch; WordPress Studio for Omarchy releases are currently available only for x86_64"
package_arch='x86_64'

if [[ $test_mode == true ]]; then
  [[ $STUDIO_OMARCHY_DOWNLOAD_DIR == /* ]] || fail 'the download directory must be absolute'
  if [[ -e $STUDIO_OMARCHY_DOWNLOAD_DIR || -L $STUDIO_OMARCHY_DOWNLOAD_DIR ]]; then
    [[ -d $STUDIO_OMARCHY_DOWNLOAD_DIR && ! -L $STUDIO_OMARCHY_DOWNLOAD_DIR ]] ||
      fail 'the download directory must be a real directory, not a link or special file'
  else
    mkdir -p -- "$STUDIO_OMARCHY_DOWNLOAD_DIR"
    chmod 700 "$STUDIO_OMARCHY_DOWNLOAD_DIR"
  fi
  download_dir=$(realpath -- "$STUDIO_OMARCHY_DOWNLOAD_DIR")
else
  download_dir=$(mktemp -d)
  trap 'rm -rf -- "$download_dir"' EXIT
fi

[[ -d $download_dir && ! -L $download_dir && -w $download_dir ]] ||
  fail 'the download directory is not a writable regular directory'

release_file="$download_dir/release.json"
download_bounded "$releases_api" "$release_file" "$release_json_max_bytes" 30

asset_count=$(jq -er 'select((.assets | type) == "array") | .assets | length' "$release_file") ||
  fail 'the GitHub release response has no asset list'
(( asset_count > 0 && asset_count <= 64 )) || fail 'the GitHub release asset count is outside the safety budget'

release_tag=$(jq -er '.tag_name | select(type == "string")' "$release_file") ||
  fail 'the GitHub release has no tag'
[[ $release_tag =~ ^omarchy-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'the release tag is not an Omarchy Studio version'
version=${release_tag#omarchy-v}

package_name=$(jq -er \
  --arg prefix "wordpress-studio-omarchy-$version-" \
  --arg suffix "-$package_arch.pkg.tar.zst" \
  '[
    .assets[].name
    | select(type == "string")
    | select(startswith($prefix) and endswith($suffix))
    | { name: ., pkgrel: (ltrimstr($prefix) | rtrimstr($suffix) | tonumber) }
  ] | select(length > 0) | max_by(.pkgrel).name' "$release_file") ||
  fail "the release has no package for $package_arch"

[[ $package_name =~ ^wordpress-studio-omarchy-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] ||
  fail 'the selected package name is unsafe'
checksum_name="$package_name.sha256"

jq -e --arg package "$package_name" --arg checksum "$checksum_name" '
  ([.assets[] | select(.name == $package)] | length) == 1 and
  ([.assets[] | select(.name == $checksum)] | length) == 1
' "$release_file" >/dev/null || fail 'the release must contain exactly one package and checksum pair'

release_url="https://github.com/$github_repo/releases/download/$release_tag"
package_path="$download_dir/$package_name"
checksum_path="$download_dir/$checksum_name"

echo "Downloading WordPress Studio $version for Omarchy..."
download_bounded "$release_url/$package_name" "$package_path" "$package_max_bytes" 1800
download_bounded "$release_url/$checksum_name" "$checksum_path" "$checksum_max_bytes" 30

checksum_bytes=$(wc -c <"$checksum_path")
(( checksum_bytes > 0 && checksum_bytes <= checksum_max_bytes )) || fail 'the checksum file is outside its byte budget'
IFS=' ' read -r expected_hash expected_name extra <"$checksum_path" || true
[[ ${expected_hash:-} =~ ^[0-9a-f]{64}$ && ${expected_name:-} == "$package_name" && -z ${extra:-} ]] ||
  fail 'the checksum file has an unexpected format or filename'

install_verified_package "$package_path" "$package_name" "$expected_hash" "$package_max_bytes"

if [[ $test_mode == false ]]; then
  studio_root='/usr/lib/studio'
  studio_binary="$studio_root/studio"
  studio_sandbox="$studio_root/chrome-sandbox"

  [[ -d $studio_root && ! -L $studio_root ]] || fail 'the installed Studio directory is unsafe'
  if [[ ! -x $studio_root ]]; then
    sudo chmod 755 -- "$studio_root"
  fi
  [[ -f $studio_binary && ! -L $studio_binary ]] || fail 'the installed Studio executable is unsafe'
  [[ -f $studio_sandbox && ! -L $studio_sandbox ]] || fail 'the installed Studio sandbox is unsafe'

  if [[ ! -r $studio_binary || ! -x $studio_binary || ! -r $studio_sandbox ]]; then
    sudo chmod -R a+rX -- "$studio_root"
  fi
  sudo chmod 4755 -- "$studio_sandbox"
fi

echo "WordPress Studio $version is installed. Launch it from the app menu or run: studio"
