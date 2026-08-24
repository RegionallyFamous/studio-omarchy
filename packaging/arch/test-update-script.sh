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

cat >"$test_root/bin/dd-no-follow" <<'EOF'
#!/bin/bash
set -euo pipefail
input=''
output=''
count=''
for argument in "$@"; do
  case $argument in
    if=*) input=${argument#if=} ;;
    of=*) output=${argument#of=} ;;
    count=*) count=${argument#count=} ;;
    iflag=nofollow,nonblock,fullblock,count_bytes | bs=1M | status=none) ;;
    *) exit 2 ;;
  esac
done
[[ -n $input && -n $output && $count =~ ^[1-9][0-9]*$ && ! -L $input ]] || exit 1
exec /bin/dd if="$input" of="$output" bs=1 count="$count" 2>/dev/null
EOF

cat >"$test_root/bin/chmod-gnu" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == "600" && ${2:-} == "--" && $# == 3 ]]
exec /bin/chmod 600 "$3"
EOF

cat >"$test_root/bin/gnu-stat" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == "-c" && ${3:-} == "--" && $# == 4 ]]
format=$2
path=$4

if [[ $format == "%s" ]]; then
  if /usr/bin/stat -c '%s' -- "$path" 2>/dev/null; then
    :
  else
    /usr/bin/stat -f '%z' "$path"
  fi
elif [[ $format == "%F|%u|%g|%a|%h|%s" ]]; then
  if metadata=$(/usr/bin/stat -c '%F|%a|%h|%s' -- "$path" 2>/dev/null); then
    IFS='|' read -r type mode links size <<<"$metadata"
    [[ $type == "regular file" ]]
  else
    IFS='|' read -r type mode links size < <(/usr/bin/stat -f '%HT|%Lp|%l|%z' "$path")
    [[ $type == "Regular File" ]]
  fi
  printf 'regular file|0|0|%s|%s|%s\n' "$mode" "$links" "$size"
else
  exit 2
fi
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
set -euo pipefail
printf '%s\n' "$*" >"$STUDIO_UPDATE_RUN_ROOT/sudo-command"
id -u >"$STUDIO_UPDATE_RUN_ROOT/sudo-uid"

if [[ -n ${STUDIO_UPDATE_ADVERSARY_DIR:-} ]]; then
  : >"$STUDIO_UPDATE_ADVERSARY_DIR/sudo-boundary"
  for (( attempt = 0; attempt < 500; attempt++ )); do
    [[ ! -e $STUDIO_UPDATE_ADVERSARY_DIR/substitution-complete ]] || break
    sleep 0.01
  done
  [[ -e $STUDIO_UPDATE_ADVERSARY_DIR/substitution-complete ]]
fi

[[ ${1:-} == "/usr/bin/bash" && ${2:-} == "-c" && -n ${3:-} ]]
script=$3
shift 3
script=${script//\/usr\/bin\/bash/\/bin\/bash}
script=${script//\/usr\/bin\/chmod/$STUDIO_UPDATE_TEST_BIN\/chmod-gnu}
script=${script//\/usr\/bin\/dd/$STUDIO_UPDATE_TEST_BIN\/dd-no-follow}
script=${script//\/usr\/bin\/pacman/$STUDIO_UPDATE_TEST_BIN\/pacman}
script=${script//\/usr\/bin\/rm/\/bin\/rm}
script=${script//\/usr\/bin\/sha256sum/$STUDIO_UPDATE_TEST_SHA256SUM}
script=${script//\/usr\/bin\/stat/$STUDIO_UPDATE_TEST_BIN\/gnu-stat}
script=${script//\/usr\/bin\/timeout/$STUDIO_UPDATE_TEST_BIN\/timeout}
exec /bin/bash -c "$script" "$@"
EOF

cat >"$test_root/bin/pacman" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >"$STUDIO_UPDATE_RUN_ROOT/pacman-command"
package_path=''
for argument in "$@"; do
  package_path=$argument
done
[[ -n $package_path ]]
printf '%s\n' "$package_path" >"$STUDIO_UPDATE_RUN_ROOT/pacman-package-path"
cp -- "$package_path" "$STUDIO_UPDATE_RUN_ROOT/pacman-package"
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
    STUDIO_UPDATE_ADVERSARY_DIR="${STUDIO_UPDATE_ADVERSARY_DIR:-}" \
    STUDIO_UPDATE_TEST_BIN="$test_root/bin" \
    STUDIO_UPDATE_TEST_SHA256SUM="$(command -v sha256sum)" \
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
grep -qF -- "/usr/bin/bash -c" "$success_root/sudo-command"
grep -qF -- "/usr/bin/dd" "$success_root/sudo-command"
grep -qF -- "/usr/bin/pacman" "$success_root/sudo-command"
if grep -qF -- "$test_root/bin" "$success_root/sudo-command"; then
  echo 'The production sudo handoff accepted a test-controlled executable path.' >&2
  exit 1
fi
grep -qF -- "$resolved_success_downloads/$package_name $package_name" "$success_root/sudo-command"
grep -Eq "^-U --needed --noconfirm -- /var/tmp/studio-omarchy-install\.[^/]+/$package_name$" \
  "$success_root/pacman-command"
cmp "$package_fixture" "$success_root/pacman-package"
staged_success_package=$(<"$success_root/pacman-package-path")
[[ $staged_success_package != "$resolved_success_downloads/$package_name" ]]
[[ ! -e ${staged_success_package%/*} ]]

substitution_root="$test_root/runs/same-uid-substitution"
substitution_sync="$substitution_root/adversary"
mkdir -p "$substitution_sync"
(
  for (( attempt = 0; attempt < 500; attempt++ )); do
    [[ ! -e $substitution_sync/sudo-boundary ]] || break
    sleep 0.01
  done
  [[ -e $substitution_sync/sudo-boundary ]]
  ln -s "$package_fixture" "$substitution_sync/package-link"
  mv -f -- "$substitution_sync/package-link" "$substitution_root/downloads/$package_name"
  id -u >"$substitution_sync/uid"
  : >"$substitution_sync/substitution-complete"
) &
substitution_pid=$!
export STUDIO_UPDATE_ADVERSARY_DIR="$substitution_sync"
expect_failure 'same-UID symlink substitution at the privileged handoff' \
  run_installer "$substitution_root" "$exact_release"
unset STUDIO_UPDATE_ADVERSARY_DIR
wait "$substitution_pid"
grep -qF 'the privileged package handoff copy failed or exceeded its deadline' "$test_root/failure-output"
[[ $(<"$substitution_sync/uid") == "$(<"$substitution_root/sudo-uid")" ]]
[[ ! -e $substitution_root/pacman-command ]]

mutation_root="$test_root/runs/same-uid-inode-mutation"
mutation_sync="$mutation_root/adversary"
mkdir -p "$mutation_sync"
(
  for (( attempt = 0; attempt < 500; attempt++ )); do
    [[ ! -e $mutation_sync/sudo-boundary ]] || break
    sleep 0.01
  done
  [[ -e $mutation_sync/sudo-boundary ]]
  printf '%s\n' 'same-UID mutated package' >"$mutation_root/downloads/$package_name"
  id -u >"$mutation_sync/uid"
  : >"$mutation_sync/substitution-complete"
) &
mutation_pid=$!
export STUDIO_UPDATE_ADVERSARY_DIR="$mutation_sync"
expect_failure 'same-UID in-place mutation at the privileged handoff' \
  run_installer "$mutation_root" "$exact_release"
unset STUDIO_UPDATE_ADVERSARY_DIR
wait "$mutation_pid"
grep -qF 'the package changed before the privileged installation handoff' "$test_root/failure-output"
[[ $(<"$mutation_sync/uid") == "$(<"$mutation_root/sudo-uid")" ]]
[[ ! -e $mutation_root/pacman-command ]]

handoff_overflow_root="$test_root/runs/same-uid-handoff-overflow"
handoff_overflow_sync="$handoff_overflow_root/adversary"
mkdir -p "$handoff_overflow_sync"
(
  for (( attempt = 0; attempt < 500; attempt++ )); do
    [[ ! -e $handoff_overflow_sync/sudo-boundary ]] || break
    sleep 0.01
  done
  [[ -e $handoff_overflow_sync/sudo-boundary ]]
  printf x >>"$handoff_overflow_root/downloads/$package_name"
  : >"$handoff_overflow_sync/substitution-complete"
) &
handoff_overflow_pid=$!
export STUDIO_UPDATE_ADVERSARY_DIR="$handoff_overflow_sync"
expect_failure 'same-UID growth one byte over the privileged handoff ceiling' \
  run_installer "$handoff_overflow_root" "$exact_release"
unset STUDIO_UPDATE_ADVERSARY_DIR
wait "$handoff_overflow_pid"
grep -qF 'the package changed beyond its byte budget before installation' "$test_root/failure-output"
[[ ! -e $handoff_overflow_root/pacman-command ]]

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

echo 'Verified x86_64-only release selection, bounded metadata/package/checksum ingress, malformed and failed children, safe paths, checksum validation, root-private pacman staging, and same-UID substitution rejection.'
