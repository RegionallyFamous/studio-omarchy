# WordPress Studio for Omarchy

A native Omarchy/Arch package of [Automattic's WordPress Studio](https://github.com/Automattic/studio), paired with a Quattro bar plugin for installation, updates, launch, status, and removal.

This is a community port maintained by RegionallyFamous. It is not an Automattic or Basecamp release.

## Install through Quattro

```bash
omarchy plugin add https://github.com/RegionallyFamous/studio-omarchy.git --enable
```

The WordPress icon appears in the right side of the Omarchy bar. Open it and choose **Install Studio**. The plugin opens Omarchy's visible terminal, downloads the latest native package and checksum from this repository's GitHub release, verifies the pair, and hands the local package to `pacman`. Only the terminal-bound package transaction asks for elevated privileges.

The panel is fully keyboard-driven: use Up and Down to choose an action, Enter to run it, and Escape to close it.

## Direct installation

The native package can still be installed without the bar plugin:

```bash
curl -fsSLo /tmp/install-studio-omarchy \
  https://raw.githubusercontent.com/RegionallyFamous/studio-omarchy/main/install.sh
bash /tmp/install-studio-omarchy
```

Launch **WordPress Studio** from the Omarchy app menu or run:

```bash
studio
```

## What the port changes

- Uses native Wayland in Hyprland sessions.
- Uses Arch's p11-kit certificate anchor and `update-ca-trust` flow.
- Registers the `wp-studio://` login callback and desktop launcher.
- Grants the bundled proxy runtime access to ports 80 and 443 without running Studio as root.
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

Removing the package also removes Studio's certificate authority anchor from the Arch trust store.

## Automated upstream releases

Every six hours, CI checks the latest stable [Studio release](https://github.com/Automattic/studio/releases). A new release is checked out in an isolated build directory, the audited Omarchy patch is applied, and the full Studio lint, typecheck, and test suites run. CI then creates and verifies a native Arch package before publishing it here.

Patch conflicts or failed tests stop the release and open an issue. No package is published on a failed compatibility check. Package and plugin manifest versions are advanced together.

## Local development

On Omarchy with the Node major required by upstream Studio:

```bash
./packaging/arch/build-omarchy-package.sh
sudo pacman -U ./packaging/arch/wordpress-studio-omarchy-*.pkg.tar.zst
```

Run the free Quattro publication checks with:

```bash
/Users/nick/Documents/ChatGPT/omarchy-test-lab/bin/omarchy-test-lab quick .
```

The test suite covers manifest identity, package/plugin version lockstep, installer ingress ceilings, malformed metadata, failed helpers, checksum and package byte limits, symlink and special-file rejection, bounded package status, keyboard interaction, a real package install, native Wayland launch, and removal in a disposable Omarchy guest.

See [packaging/arch/README.md](packaging/arch/README.md) for package internals and the extended application checklist.

WordPress Studio is GPL-2.0-or-later. See [LICENSE.md](LICENSE.md).
