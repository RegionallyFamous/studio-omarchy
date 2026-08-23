# WordPress Studio for Omarchy

A native Omarchy/Arch package of [Automattic's WordPress Studio](https://github.com/Automattic/studio), paired with a Quattro bar plugin for installation, updates, launch, status, and removal.

This is a community port maintained by RegionallyFamous. It is not an Automattic or Basecamp release.

## Install through Quattro

```bash
omarchy plugin add https://github.com/RegionallyFamous/studio-omarchy.git --enable
```

The WordPress icon appears in the right side of the Omarchy bar. Open it and choose **Install Studio**. The plugin opens Omarchy's visible terminal, downloads the latest native package and checksum from this repository's GitHub release, verifies the pair, and hands the local package to `pacman`. The visible terminal requests elevation for the package transaction. The package installs a root-owned `/usr/lib/studio/chrome-sandbox` with mode `4755` (setuid) for Chromium's sandbox; after installation, the installer always restores that fixed mode and may repair read and execute permissions under `/usr/lib/studio`. Studio otherwise runs as the current desktop user, and the plugin never reads or supplies the password.

The panel is fully keyboard-driven: use Up and Down to choose an action, Enter to run it, and Escape to close it.

## Runtime and external dependencies

The Quattro integration requires Omarchy with its shared shell and visible terminal. Published packages and the install and update helpers are supported and tested only on x86_64 Omarchy/Arch. `pacman` resolves the native libraries listed by the package, including Wayland, GTK, NSS, libsecret, polkit, and certificate utilities. Install and update need HTTPS access to this repository's GitHub release metadata and package assets. Studio runs as the current desktop user, starts local WordPress processes only while sites are running, and stores its configuration and sites under the user's home directory. The plugin itself installs no background service. Optional upstream Studio features can also contact Automattic or WordPress.com when a user enables analytics, logs in, Syncs, or creates a public preview.

## Direct installation

The native package can still be installed without the bar plugin:

```bash
studio_installer=$(mktemp)
trap 'rm -f -- "$studio_installer"' EXIT
curl -fsSLo "$studio_installer" \
  https://raw.githubusercontent.com/RegionallyFamous/studio-omarchy/main/install.sh
bash "$studio_installer"
```

Launch **WordPress Studio** from the Omarchy app menu or run:

```bash
studio
```

### Remove a direct installation

Package revision 3 and later includes the same fingerprint-matched current-user browser trust cleanup used by the Quattro action. On Omarchy, run it before dropping the package:

```bash
studio-omarchy-cleanup-user-trust &&
  omarchy-pkg-drop wordpress-studio-omarchy
```

On another supported x86_64 Arch environment, use the native package manager after the same cleanup:

```bash
studio-omarchy-cleanup-user-trust &&
  sudo pacman -Rns wordpress-studio-omarchy
```

This removes the package, its system Arch trust anchor, and only a matching `WordPress Studio CA` entry from the current user's bounded Chromium and Firefox NSS databases. Studio sites and other user data are preserved.

## What the port changes

- Uses native Wayland in Hyprland sessions.
- Uses Arch's p11-kit certificate anchor and `update-ca-trust` flow.
- Registers the `wp-studio://` login callback and desktop launcher.
- Attempts to grant the bundled proxy runtime access to ports 80 and 443 without running Studio as root, and prints a visible package warning if the filesystem refuses that capability.
- Replaces the incompatible DEB updater with `studio-omarchy-update`.
- Adds a theme-native Quattro panel for install, update, launch, status, and removal.

## Updates

Open the Quattro panel and choose **Update Studio**, or run:

```bash
studio-omarchy-update
```

Both paths select the highest package revision for the latest compatible Studio release, enforce HTTPS and download timeouts, cap release metadata before parsing, verify the expected checksum filename and SHA-256 value, and install only the verified local package.

## Remove

Choose **Remove Studio** in the Quattro panel. Remove the shell integration itself with:

```bash
omarchy plugin remove io.github.regionallyfamous.studio
```

Removing Studio through the Quattro panel also removes its Arch trust anchor and fingerprint-matched certificate from the current user's Chromium and bounded Firefox profile trust databases. Studio sites and other user data are preserved, and unrelated browser certificates are never removed. Restart an open browser after removal so it discards any cached trust state.

## Automated upstream releases

Every six hours, CI checks the latest stable [Studio release](https://github.com/Automattic/studio/releases). A new release is checked out in an isolated build directory, the audited Omarchy patch is applied, and the full Studio lint, typecheck, and test suites run. CI then creates and verifies a native Arch package before publishing it here.

Patch conflicts or failed tests stop the release and open an issue. No package is published on a failed compatibility check. Package and plugin manifest versions are advanced together.

## Local development

On Omarchy with the Node major required by upstream Studio:

```bash
./packaging/arch/build-omarchy-package.sh
sudo pacman -U ./packaging/arch/wordpress-studio-omarchy-*.pkg.tar.zst
```

With Node.js, `shellcheck`, and `actionlint` installed, run the repository-public checks with:

```bash
packaging/arch/test-update-script.sh
tools/lint-manifest.sh
shellcheck -e SC1091 install.sh scripts/*.sh test/*.sh tools/*.sh \
  packaging/arch/*.sh packaging/arch/studio-launcher \
  packaging/arch/studio-omarchy-update packaging/arch/studio.install
actionlint .github/workflows/*.yml
node --test test/*.test.js
```

The real-guest acceptance lane runs separately in a disposable x86_64 Omarchy VM; that maintainer infrastructure is not a repository dependency. Together, the checks are designed to cover manifest identity, package/plugin version lockstep, installer ingress ceilings, malformed metadata, failed helpers, checksum and package byte limits, symlink and special-file rejection, bounded package status, plain-text rendering of dynamic panel status, keyboard interaction, a real package install, native Wayland launch, and removal.

The real-guest acceptance flow also uses genuine pointer input to exercise the visible product instead of stopping at process checks. It clicks the Quattro install, update, launch, and remove actions; creates two uniquely named local WordPress sites through Studio; verifies their persisted configuration, WordPress files, SQLite databases, and simultaneous REST availability; loads a running site in an external browser; stops one site and proves it is offline; starts it again and proves it serves WordPress; then deletes both sites and verifies their Studio records and local paths are gone. Screenshots are captured for every materially distinct panel, terminal, Studio, and browser state and must be visually reviewed along with any failure screenshots.

### Tested scope and limitations

The full acceptance lane is designed to cover the local two-site lifecycle on x86_64 Omarchy: creation, persistence, simultaneous serving, external-browser loading, stop, restart, deletion, and the Quattro install, update, launch, and removal controls. It does not cover WordPress.com login or signup, connecting or importing remote sites, custom-domain or HTTPS configuration, or aarch64 runtime behavior. Those flows should not be treated as verified by this port's acceptance lane.

## Marketplace preview

A RegionallyFamous marketplace submission is not release-ready until the repository root contains a supported preview image, such as `preview.png`, that is part of the exact commit which passes the final release gate. Capture it from the real Omarchy guest after dismissing unrelated notifications, show the plugin's useful open-panel state with legible text, exclude secrets and diagnostics, and avoid decorative edits that could misrepresent runtime behavior. Visually inspect the final root asset itself and re-check the live marketplace filename, size, and pixel limits before submission; the test suite does not generate this publication asset.

See [packaging/arch/README.md](packaging/arch/README.md) for package internals and the extended application checklist.

WordPress Studio is GPL-2.0-or-later. See [LICENSE.md](LICENSE.md).
