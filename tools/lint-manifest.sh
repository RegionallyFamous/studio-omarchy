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
cmp "$plugin_root/install.sh" "$plugin_root/packaging/arch/studio-omarchy-update"

printf 'ok - Studio manifest, package version, helpers, and updater contract\n'
