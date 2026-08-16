#!/bin/bash

set -euo pipefail

readonly github_repo='RegionallyFamous/studio-omarchy'
readonly releases_api="https://api.github.com/repos/$github_repo/releases/latest"

if [[ ! -f /etc/arch-release && ${STUDIO_OMARCHY_TEST_NON_ARCH:-0} != 1 ]]; then
  echo 'WordPress Studio for Omarchy requires Omarchy or Arch Linux.' >&2
  exit 1
fi

for command_name in curl jq sha256sum sudo pacman; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "WordPress Studio installation requires $command_name." >&2
    exit 1
  fi
done

case $(uname -m) in
  x86_64) package_arch='x86_64' ;;
  aarch64 | arm64) package_arch='aarch64' ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

release_json=$(curl --fail --silent --show-error --location \
  --header 'Accept: application/vnd.github+json' \
  "$releases_api")

release_tag=$(jq -er '.tag_name | select(startswith("omarchy-v"))' <<<"$release_json")
version=${release_tag#omarchy-v}
package_name=$(jq -er \
  --arg prefix "wordpress-studio-omarchy-$version-" \
  --arg suffix "-$package_arch.pkg.tar.zst" \
  '[
    .assets[].name
    | select(startswith($prefix) and endswith($suffix))
    | { name: ., pkgrel: (ltrimstr($prefix) | rtrimstr($suffix) | tonumber) }
  ] | max_by(.pkgrel).name' <<<"$release_json")
checksum_name="$package_name.sha256"

asset_url=$(jq -er --arg name "$package_name" \
  '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")
checksum_url=$(jq -er --arg name "$checksum_name" \
  '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")

if [[ -n ${STUDIO_OMARCHY_DOWNLOAD_DIR:-} ]]; then
  download_dir=$STUDIO_OMARCHY_DOWNLOAD_DIR
  mkdir -p "$download_dir"
else
  download_dir=$(mktemp -d)
  trap 'rm -rf "$download_dir"' EXIT
fi

package_path="$download_dir/$package_name"
checksum_path="$download_dir/$checksum_name"

echo "Downloading WordPress Studio $version for Omarchy..."
curl --fail --show-error --location --output "$package_path.part" "$asset_url"
mv -f "$package_path.part" "$package_path"
curl --fail --show-error --location --output "$checksum_path" "$checksum_url"

(
  cd "$download_dir"
  sha256sum --check "$checksum_name"
)

sudo pacman -U --needed "$package_path"
echo "WordPress Studio $version is installed. Launch it from the app menu or run: studio"
