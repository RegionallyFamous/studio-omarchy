#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/downloads" "$test_root/fixtures"

case $(uname -m) in
  x86_64) package_arch='x86_64' ;;
  aarch64 | arm64) package_arch='aarch64' ;;
  *) echo "Unsupported test architecture: $(uname -m)" >&2; exit 1 ;;
esac

package_name="wordpress-studio-omarchy-9.8.7-2-$package_arch.pkg.tar.zst"
checksum_name="$package_name.sha256"
printf 'test package\n' >"$test_root/fixtures/$package_name"
(
  cd "$test_root/fixtures"
  sha256sum "$package_name" >"$checksum_name"
)

cat >"$test_root/release.json" <<EOF
{
  "tag_name": "omarchy-v9.8.7",
  "assets": [
    {"name": "wordpress-studio-omarchy-9.8.7-1-$package_arch.pkg.tar.zst", "browser_download_url": "https://example.test/obsolete.pkg.tar.zst"},
    {"name": "$package_name", "browser_download_url": "https://example.test/$package_name"},
    {"name": "$checksum_name", "browser_download_url": "https://example.test/$checksum_name"}
  ]
}
EOF

cat >"$test_root/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=''
url=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) output=$2; shift 2 ;;
    --header) shift 2 ;;
    --fail | --silent | --show-error | --location) shift ;;
    *) url=$1; shift ;;
  esac
done

if [[ -z $output ]]; then
  cat "$STUDIO_UPDATE_TEST_ROOT/release.json"
else
  cp "$STUDIO_UPDATE_TEST_ROOT/fixtures/${url##*/}" "$output"
fi
EOF

cat >"$test_root/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$STUDIO_UPDATE_TEST_ROOT/sudo-command"
EOF

cat >"$test_root/bin/pacman" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod 755 "$test_root/bin/curl" "$test_root/bin/sudo" "$test_root/bin/pacman"

STUDIO_UPDATE_TEST_ROOT="$test_root" \
  STUDIO_OMARCHY_TEST_NON_ARCH=1 \
  STUDIO_OMARCHY_DOWNLOAD_DIR="$test_root/downloads" \
  PATH="$test_root/bin:$PATH" \
  "$script_dir/studio-omarchy-update"

test -f "$test_root/downloads/$package_name"
test -f "$test_root/downloads/$checksum_name"
grep -qxF "pacman -U --needed $test_root/downloads/$package_name" "$test_root/sudo-command"

cmp "$script_dir/../../install.sh" "$script_dir/studio-omarchy-update"

echo 'Verified the direct installer download, checksum, pacman handoff, and packaged updater.'
