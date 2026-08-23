#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/fixtures" "$test_root/runs"

version='9.8.7'
package_arch='x86_64'
package_name="wordpress-studio-omarchy-$version-2-$package_arch.pkg.tar.zst"
checksum_name="$package_name.sha256"
package_fixture="$test_root/fixtures/$package_name"
checksum_fixture="$test_root/fixtures/$checksum_name"

head -c 64 /dev/zero | tr '\0' x >"$package_fixture"
(
  cd "$test_root/fixtures"
  sha256sum "$package_name" >"$checksum_name"
)

cat >"$test_root/bin/timeout" <<'EOF'
#!/bin/bash
set -euo pipefail
shift 3
exec "$@"
EOF

cat >"$test_root/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=''
url=''
while (( $# > 0 )); do
  case $1 in
    --output) output=$2; shift 2 ;;
    --connect-timeout | --max-time | --max-filesize | --proto | --proto-redir) shift 2 ;;
    --fail | --show-error | --location) shift ;;
    *) url=$1; shift ;;
  esac
done

[[ -n $output && -n $url ]]
if [[ ${STUDIO_CURL_FAIL:-0} == 1 ]]; then
  exit 7
elif [[ $url == */releases/latest ]]; then
  cp -- "$STUDIO_UPDATE_RELEASE_FILE" "$output"
else
  cp -- "$STUDIO_UPDATE_FIXTURES/${url##*/}" "$output"
fi
EOF

cat >"$test_root/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$STUDIO_UPDATE_RUN_ROOT/sudo-command"
EOF

cat >"$test_root/bin/pacman" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$test_root/bin/uname" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == "-m" ]]
printf '%s\n' "${STUDIO_UPDATE_TEST_ARCH:-x86_64}"
EOF

chmod 755 "$test_root/bin"/*

write_release() {
  local output="$1"
  local asset_count="$2"
  local target_bytes="${3:-0}"
  local prefix suffix padding_size
  local assets=''

  assets="{\"name\":\"$package_name\"},{\"name\":\"$checksum_name\"}"
  for (( index = 2; index < asset_count; index++ )); do
    assets+=",{\"name\":\"extra-$index\"}"
  done

  prefix="{\"tag_name\":\"omarchy-v$version\",\"assets\":[$assets],\"padding\":\""
  suffix='"}'$'\n'
  if (( target_bytes > 0 )); then
    padding_size=$((target_bytes - ${#prefix} - ${#suffix}))
    (( padding_size >= 0 ))
    printf '%s' "$prefix" >"$output"
    head -c "$padding_size" /dev/zero | tr '\0' x >>"$output"
    printf '%s' "$suffix" >>"$output"
  else
    printf '%s%s' "$prefix" "$suffix" >"$output"
  fi
}

run_installer() {
  local run_root="$1"
  local release_file="$2"
  shift 2

  mkdir -p "$run_root/downloads"
  STUDIO_OMARCHY_TEST_MODE=1 \
    STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES=64 \
    STUDIO_OMARCHY_DOWNLOAD_DIR="$run_root/downloads" \
    STUDIO_UPDATE_FIXTURES="$test_root/fixtures" \
    STUDIO_UPDATE_RELEASE_FILE="$release_file" \
    STUDIO_UPDATE_RUN_ROOT="$run_root" \
    STUDIO_UPDATE_TEST_ARCH="${STUDIO_UPDATE_TEST_ARCH:-x86_64}" \
    PATH="$test_root/bin:$PATH" \
    "$@" \
    "$script_dir/studio-omarchy-update"
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >"$test_root/failure-output" 2>&1; then
    echo "Expected failure: $description" >&2
    exit 1
  fi
}

bare_test_mode_root="$test_root/runs/bare-test-mode"
mkdir -p "$bare_test_mode_root"
STUDIO_OMARCHY_TEST_MODE=1 \
  STUDIO_UPDATE_RUN_ROOT="$bare_test_mode_root" \
  STUDIO_UPDATE_TEST_ARCH=x86_64 \
  PATH="$test_root/bin:$PATH" \
  expect_failure 'bare test mode fails before download or sudo' \
  "$script_dir/studio-omarchy-update"
grep -qF 'test mode requires an isolated download directory and package byte budget' \
  "$test_root/failure-output"
[[ ! -e $bare_test_mode_root/sudo-command ]]

exact_release="$test_root/release-exact.json"
write_release "$exact_release" 2 262144

for unsupported_arch in aarch64 arm64; do
  unsupported_root="$test_root/runs/$unsupported_arch"
  STUDIO_UPDATE_TEST_ARCH="$unsupported_arch" \
    expect_failure "$unsupported_arch fails before release lookup" run_installer "$unsupported_root" "$exact_release"
  grep -qF "unsupported architecture: $unsupported_arch; WordPress Studio for Omarchy releases are currently available only for x86_64" \
    "$test_root/failure-output"
  [[ ! -e $unsupported_root/downloads/release.json ]]
  [[ ! -e $unsupported_root/sudo-command ]]
done

success_root="$test_root/runs/success"
run_installer "$success_root" "$exact_release"
[[ -f $success_root/downloads/$package_name ]]
[[ -f $success_root/downloads/$checksum_name ]]
resolved_success_downloads=$(realpath -- "$success_root/downloads")
grep -qxF "pacman -U --needed --noconfirm -- $resolved_success_downloads/$package_name" "$success_root/sudo-command"

oversized_release="$test_root/release-oversized.json"
write_release "$oversized_release" 2 262145
oversized_root="$test_root/runs/oversized-release"
expect_failure 'release metadata one byte over the raw ceiling' run_installer "$oversized_root" "$oversized_release"
[[ ! -e $oversized_root/sudo-command ]]

too_many_assets="$test_root/release-too-many-assets.json"
write_release "$too_many_assets" 65
assets_root="$test_root/runs/assets"
expect_failure 'release asset count one over the ceiling' run_installer "$assets_root" "$too_many_assets"
[[ ! -e $assets_root/sudo-command ]]

malformed_release="$test_root/release-malformed.json"
printf '{"tag_name":' >"$malformed_release"
malformed_root="$test_root/runs/malformed"
expect_failure 'malformed release metadata' run_installer "$malformed_root" "$malformed_release"
[[ ! -e $malformed_root/sudo-command ]]

curl_root="$test_root/runs/curl-failure"
export STUDIO_CURL_FAIL=1
expect_failure 'metadata child-process failure' run_installer "$curl_root" "$exact_release"
unset STUDIO_CURL_FAIL
[[ ! -e $curl_root/sudo-command ]]

cp -- "$package_fixture" "$test_root/fixtures/$package_name.valid"
printf x >>"$package_fixture"
package_root="$test_root/runs/package-overflow"
expect_failure 'package one byte over the configured ceiling' run_installer "$package_root" "$exact_release"
[[ ! -e $package_root/sudo-command ]]
mv -- "$test_root/fixtures/$package_name.valid" "$package_fixture"

cp -- "$checksum_fixture" "$test_root/fixtures/$checksum_name.valid"
head -c 512 /dev/zero | tr '\0' x >"$checksum_fixture"
checksum_exact_root="$test_root/runs/checksum-exact"
expect_failure 'checksum at the raw ceiling but with malformed structure' run_installer "$checksum_exact_root" "$exact_release"
[[ ! -e $checksum_exact_root/sudo-command ]]

printf x >>"$checksum_fixture"
checksum_over_root="$test_root/runs/checksum-overflow"
expect_failure 'checksum one byte over the raw ceiling' run_installer "$checksum_over_root" "$exact_release"
[[ ! -e $checksum_over_root/sudo-command ]]
mv -- "$test_root/fixtures/$checksum_name.valid" "$checksum_fixture"

symlink_root="$test_root/runs/symlink"
mkdir -p "$symlink_root/real-downloads"
ln -s "$symlink_root/real-downloads" "$symlink_root/downloads"
expect_failure 'symlink download directory' env \
  STUDIO_OMARCHY_TEST_MODE=1 \
  STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES=64 \
  STUDIO_OMARCHY_DOWNLOAD_DIR="$symlink_root/downloads" \
  STUDIO_UPDATE_FIXTURES="$test_root/fixtures" \
  STUDIO_UPDATE_RELEASE_FILE="$exact_release" \
  STUDIO_UPDATE_RUN_ROOT="$symlink_root" \
  PATH="$test_root/bin:$PATH" \
  "$script_dir/studio-omarchy-update"

fifo_root="$test_root/runs/fifo"
mkdir -p "$fifo_root"
mkfifo "$fifo_root/downloads"
expect_failure 'non-directory download path' env \
  STUDIO_OMARCHY_TEST_MODE=1 \
  STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES=64 \
  STUDIO_OMARCHY_DOWNLOAD_DIR="$fifo_root/downloads" \
  STUDIO_UPDATE_FIXTURES="$test_root/fixtures" \
  STUDIO_UPDATE_RELEASE_FILE="$exact_release" \
  STUDIO_UPDATE_RUN_ROOT="$fifo_root" \
  PATH="$test_root/bin:$PATH" \
  "$script_dir/studio-omarchy-update"

cmp "$script_dir/../../install.sh" "$script_dir/studio-omarchy-update"

echo 'Verified x86_64-only release selection, bounded metadata/package/checksum ingress, malformed and failed children, safe paths, checksum validation, and pacman handoff.'
