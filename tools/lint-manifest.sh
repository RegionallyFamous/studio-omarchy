#!/bin/bash

set -euo pipefail

plugin_root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
manifest="$plugin_root/manifest.json"
package_version=$(sed -n 's/^pkgver=//p' "$plugin_root/packaging/arch/PKGBUILD")

jq -e --arg version "$package_version" '
  .schemaVersion == 1 and
  .id == "io.github.regionallyfamous.studio" and
  .name == "WordPress Studio" and
  .version == $version and
  .author == "RegionallyFamous" and
  .license == "GPL-2.0-or-later" and
  .kinds == ["bar-widget"] and
  .entryPoints.barWidget == "BarWidget.qml" and
  .barWidget.defaultSection == "right" and
  .barWidget.allowMultiple == false
' "$manifest" >/dev/null

[[ -f $plugin_root/BarWidget.qml ]]
[[ -f $plugin_root/Panel.qml ]]
[[ -x $plugin_root/scripts/status.sh ]]
[[ -x $plugin_root/scripts/action.sh ]]
[[ -x $plugin_root/scripts/cleanup-user-trust.sh ]]
[[ -x $plugin_root/scripts/remove.sh ]]
cmp "$plugin_root/install.sh" "$plugin_root/packaging/arch/studio-omarchy-update"

upstream_commit=$(<"$plugin_root/packaging/arch/upstream-commit")
[[ $upstream_commit =~ ^[0-9a-f]{40}$ ]]
grep -qxF "readonly upstream_commit='$upstream_commit'" \
  "$plugin_root/packaging/arch/build-omarchy-package.sh"
grep -qxF "git -C \"\$studio_root\" fetch --depth 1 origin $upstream_commit" \
  "$plugin_root/packaging/arch/build-omarchy-package.sh"
grep -qxF "git -C \"\$studio_root\" checkout --detach $upstream_commit &&" \
  "$plugin_root/packaging/arch/build-omarchy-package.sh"

updater_hash=$(sha256sum "$plugin_root/packaging/arch/studio-omarchy-update" | cut -d ' ' -f 1)
pkgbuild_updater_hash=$(
  sed -n "s/^  '\([0-9a-f]\{64\}\)'$/\1/p" "$plugin_root/packaging/arch/PKGBUILD" |
    sed -n '2p'
)
[[ $updater_hash == "$pkgbuild_updater_hash" ]]

cleanup_hash=$(sha256sum "$plugin_root/scripts/cleanup-user-trust.sh" | cut -d ' ' -f 1)
pkgbuild_cleanup_hash=$(
  sed -n "s/^  '\([0-9a-f]\{64\}\)'$/\1/p" "$plugin_root/packaging/arch/PKGBUILD" |
    sed -n '4p'
)
[[ $cleanup_hash == "$pkgbuild_cleanup_hash" ]]
grep -qxF "  'cleanup-user-trust.sh'" "$plugin_root/packaging/arch/PKGBUILD"
grep -qxF "    \"\$pkgdir/usr/bin/studio-omarchy-cleanup-user-trust\"" \
  "$plugin_root/packaging/arch/PKGBUILD"

panel_text_items=$(grep -Ec '^[[:space:]]+Text \{$' "$plugin_root/Panel.qml")
panel_plain_text_items=$(grep -Ec '^[[:space:]]+textFormat: Text\.PlainText$' "$plugin_root/Panel.qml")
(( panel_text_items > 0 ))
(( panel_text_items == panel_plain_text_items ))

dynamic_status_sink=$(
  sed -n '/text: !root\.statusReady/,/wrapMode: Text\.WordWrap/p' "$plugin_root/Panel.qml"
)
[[ $dynamic_status_sink == *'textFormat: Text.PlainText'* ]]
[[ $dynamic_status_sink == *'"Unable to check installation"'* ]]

panel_status_parser=$(
  sed -n '/function applyStatus(raw) {/,/^  }/p' "$plugin_root/Panel.qml"
)
[[ $panel_status_parser == *'statusError = true'* ]]
[[ $panel_status_parser == *'if (value === "missing") {'* ]]
[[ $panel_status_parser == *'statusError = false'* ]]

panel_open_state=$(sed -n '/function open() {/,/^  }/p' "$plugin_root/Panel.qml")
for reset in \
  'statusReady = false' \
  'statusError = false' \
  'installed = false' \
  'installedVersion = ""'; do
  [[ $panel_open_state == *"$reset"* ]]
done

printf 'ok - Studio manifest, immutable upstream pin, helpers, and updater contract\n'
