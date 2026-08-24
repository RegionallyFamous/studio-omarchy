#!/bin/bash -p

set -euo pipefail

readonly PATH='/usr/bin:/usr/sbin'
readonly LC_ALL='C'
export PATH LC_ALL
unset BASH_ENV CURL_CA_BUNDLE CURL_HOME ENV LD_LIBRARY_PATH LD_PRELOAD SSL_CERT_DIR SSL_CERT_FILE

readonly github_repo='RegionallyFamous/studio-omarchy'
readonly releases_api="https://api.github.com/repos/$github_repo/releases/latest"
readonly system_ca_bundle='/etc/ssl/certs/ca-certificates.crt'
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

  /usr/bin/timeout --signal=TERM --kill-after=5s "${outer_seconds}s" \
    /usr/bin/env -i PATH="$PATH" LC_ALL="$LC_ALL" \
    /usr/bin/curl --disable --fail --show-error --location \
      --proto '=https' \
      --proto-redir '=https' \
      --cacert "$system_ca_bundle" \
      --connect-timeout 10 \
      --max-time "$max_seconds" \
      --max-filesize "$max_bytes" \
      --output "$partial" \
      "$url"

  [[ -f $partial && ! -L $partial ]] || fail "download did not produce a regular file"
  size=$(/usr/bin/wc -c <"$partial")
  (( size > 0 && size <= max_bytes )) || fail "download exceeded its byte budget"
  /usr/bin/mv -- "$partial" "$output"
}

download_bounded_memory() {
  local output_name=$1
  local url=$2
  local max_bytes=$3
  local max_seconds=$4
  local outer_seconds=$((max_seconds + 10))
  local encoded encoded_bytes padding=0 response_bytes

  [[ $output_name =~ ^[a-z_][a-z0-9_]*$ ]] || fail 'the HTTPS response destination is unsafe'
  [[ $url == https://* ]] || fail 'refusing a non-HTTPS download'

  encoded=$(
    /usr/bin/timeout --signal=TERM --kill-after=5s "${outer_seconds}s" \
      /usr/bin/env -i PATH="$PATH" LC_ALL="$LC_ALL" \
      /usr/bin/curl --disable --fail --show-error --location \
        --proto '=https' \
        --proto-redir '=https' \
        --cacert "$system_ca_bundle" \
        --connect-timeout 10 \
        --max-time "$max_seconds" \
        --max-filesize "$max_bytes" \
        "$url" | \
      /usr/bin/head -c "$((max_bytes + 1))" | \
      /usr/bin/base64 --wrap=0
  ) || fail 'the HTTPS response could not be read within its safety budget'

  [[ $encoded =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || fail 'the HTTPS response encoding is invalid'
  encoded_bytes=${#encoded}
  (( encoded_bytes > 0 && encoded_bytes % 4 == 0 )) || fail 'the HTTPS response is empty or truncated'
  if [[ $encoded == *== ]]; then
    padding=2
  elif [[ $encoded == *= ]]; then
    padding=1
  fi
  response_bytes=$((encoded_bytes * 3 / 4 - padding))
  (( response_bytes > 0 && response_bytes <= max_bytes )) ||
    fail 'the HTTPS response exceeded its byte budget'
  printf -v "$output_name" '%s' "$encoded"
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
    /usr/bin/timeout --signal=TERM --kill-after=5s 120s \
      /usr/bin/head -c "$hash_limit" "$source_path" |
      /usr/bin/sha256sum |
      /usr/bin/cut -d ' ' -f 1
  ) || fail 'the package checksum could not be read within its safety budget'
  [[ $actual_hash == "$expected_hash" ]] || fail 'the package checksum does not match'
  printf '%s: OK\n' "$package_name"

  /usr/bin/sudo /usr/bin/bash -c '
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

for command_path in /usr/bin/awk /usr/bin/base64 /usr/bin/chmod /usr/bin/curl \
  /usr/bin/cut /usr/bin/env /usr/bin/head /usr/bin/jq /usr/bin/mkdir /usr/bin/mktemp \
  /usr/bin/mv /usr/bin/pacman /usr/bin/realpath /usr/bin/rm /usr/bin/sha256sum \
  /usr/bin/sudo /usr/bin/timeout /usr/bin/uname /usr/bin/wc; do
  [[ -x $command_path ]] || fail "required command is missing: $command_path"
done
[[ -r $system_ca_bundle ]] || fail "the system CA bundle is unavailable: $system_ca_bundle"

machine_arch=$(/usr/bin/uname -m)
[[ $machine_arch == "x86_64" ]] ||
  fail "unsupported architecture: $machine_arch; WordPress Studio for Omarchy releases are currently available only for x86_64"
package_arch='x86_64'

if [[ $test_mode == true ]]; then
  [[ $STUDIO_OMARCHY_DOWNLOAD_DIR == /* ]] || fail 'the download directory must be absolute'
  if [[ -e $STUDIO_OMARCHY_DOWNLOAD_DIR || -L $STUDIO_OMARCHY_DOWNLOAD_DIR ]]; then
    [[ -d $STUDIO_OMARCHY_DOWNLOAD_DIR && ! -L $STUDIO_OMARCHY_DOWNLOAD_DIR ]] ||
      fail 'the download directory must be a real directory, not a link or special file'
  else
    /usr/bin/mkdir -p -- "$STUDIO_OMARCHY_DOWNLOAD_DIR"
    /usr/bin/chmod 700 "$STUDIO_OMARCHY_DOWNLOAD_DIR"
  fi
  download_dir=$(/usr/bin/realpath -- "$STUDIO_OMARCHY_DOWNLOAD_DIR")
else
  download_dir=$(/usr/bin/mktemp -d /tmp/studio-omarchy-download.XXXXXXXXXX)
  trap '/usr/bin/rm -rf -- "$download_dir"' EXIT
fi

[[ -d $download_dir && ! -L $download_dir && -w $download_dir ]] ||
  fail 'the download directory is not a writable regular directory'

release_json=''
download_bounded_memory release_json "$releases_api" "$release_json_max_bytes" 30

asset_count=$(builtin printf '%s' "$release_json" | /usr/bin/base64 --decode | \
  /usr/bin/jq -er 'select((.assets | type) == "array") | .assets | length') ||
  fail 'the GitHub release response has no asset list'
(( asset_count > 0 && asset_count <= 64 )) || fail 'the GitHub release asset count is outside the safety budget'

release_tag=$(builtin printf '%s' "$release_json" | /usr/bin/base64 --decode | \
  /usr/bin/jq -er '.tag_name | select(type == "string")') ||
  fail 'the GitHub release has no tag'
[[ $release_tag =~ ^omarchy-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'the release tag is not an Omarchy Studio version'
version=${release_tag#omarchy-v}

package_name=$(builtin printf '%s' "$release_json" | /usr/bin/base64 --decode | \
  /usr/bin/jq -er \
  --arg prefix "wordpress-studio-omarchy-$version-" \
  --arg suffix "-$package_arch.pkg.tar.zst" \
  '[
    .assets[].name
    | select(type == "string")
    | select(startswith($prefix) and endswith($suffix))
    | { name: ., pkgrel: (ltrimstr($prefix) | rtrimstr($suffix) | tonumber) }
  ] | select(length > 0) | max_by(.pkgrel).name') ||
  fail "the release has no package for $package_arch"

[[ $package_name =~ ^wordpress-studio-omarchy-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-x86_64\.pkg\.tar\.zst$ ]] ||
  fail 'the selected package name is unsafe'
checksum_name="$package_name.sha256"

builtin printf '%s' "$release_json" | /usr/bin/base64 --decode | \
  /usr/bin/jq -e --arg package "$package_name" --arg checksum "$checksum_name" '
  ([.assets[] | select(.name == $package)] | length) == 1 and
  ([.assets[] | select(.name == $checksum)] | length) == 1
' >/dev/null || fail 'the release must contain exactly one package and checksum pair'

release_url="https://github.com/$github_repo/releases/download/$release_tag"
package_path="$download_dir/$package_name"

echo "Downloading WordPress Studio $version for Omarchy..."
download_bounded "$release_url/$package_name" "$package_path" "$package_max_bytes" 1800
checksum_payload=''
download_bounded_memory checksum_payload \
  "$release_url/$checksum_name" "$checksum_max_bytes" 30
expected_hash=$(builtin printf '%s' "$checksum_payload" | /usr/bin/base64 --decode | \
  /usr/bin/awk -v expected_name="$package_name" '
    {
      records++
      if (records == 1 && length($0) == 66 + length(expected_name) &&
          substr($0, 1, 64) ~ /^[0-9a-f]{64}$/ &&
          substr($0, 65, 2) == "  " && substr($0, 67) == expected_name) {
        expected_hash=substr($0, 1, 64)
      }
    }
    END {
      if (records != 1 || expected_hash == "") exit 1
      print expected_hash
    }
  ') || fail 'the checksum file has an unexpected format or filename'

install_verified_package "$package_path" "$package_name" "$expected_hash" "$package_max_bytes"

if [[ $test_mode == false ]]; then
  studio_root='/usr/lib/studio'
  studio_binary="$studio_root/studio"
  studio_sandbox="$studio_root/chrome-sandbox"

  [[ -d $studio_root && ! -L $studio_root ]] || fail 'the installed Studio directory is unsafe'
  if [[ ! -x $studio_root ]]; then
    /usr/bin/sudo /usr/bin/chmod 755 -- "$studio_root"
  fi
  [[ -f $studio_binary && ! -L $studio_binary ]] || fail 'the installed Studio executable is unsafe'
  [[ -f $studio_sandbox && ! -L $studio_sandbox ]] || fail 'the installed Studio sandbox is unsafe'

  if [[ ! -r $studio_binary || ! -x $studio_binary || ! -r $studio_sandbox ]]; then
    /usr/bin/sudo /usr/bin/chmod -R a+rX -- "$studio_root"
  fi
  /usr/bin/sudo /usr/bin/chmod 4755 -- "$studio_sandbox"
fi

echo "WordPress Studio $version is installed. Launch it from the app menu or run: studio"
