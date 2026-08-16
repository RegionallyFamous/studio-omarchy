# WordPress Studio for Omarchy

A native Omarchy/Arch package of
[Automattic's WordPress Studio](https://github.com/Automattic/studio), with direct installation and
automated releases for each compatible upstream version.

This is a community port maintained by Regionally Famous. It is not an Automattic or Basecamp
release.

## Install

On an x86_64 Omarchy system, download and run the installer:

```bash
curl -fsSLo /tmp/install-studio-omarchy \
  https://raw.githubusercontent.com/RegionallyFamous/studio-omarchy/main/install.sh
bash /tmp/install-studio-omarchy
```

The installer discovers the latest package from this repository's
[GitHub Releases](https://github.com/RegionallyFamous/studio-omarchy/releases), downloads the package
and its SHA-256 checksum into a temporary directory, verifies it, and asks `pacman` to install it.
Only `pacman` runs with `sudo`.

Launch **WordPress Studio** from the Omarchy app menu or run:

```bash
studio
```

## Update

The package installs its own checksum-verifying updater:

```bash
studio-omarchy-update
```

You can also rerun the installation command. Both paths install only a newer package unless you
explicitly confirm otherwise through `pacman`.

## Remove

```bash
sudo pacman -Rns wordpress-studio-omarchy
```

Uninstalling also removes Studio's certificate authority anchor from the Arch trust store.

## What the port changes

- Uses native Wayland in Hyprland sessions.
- Uses Arch's p11-kit certificate anchor and `update-ca-trust` flow.
- Registers the `wp-studio://` login callback and desktop launcher.
- Grants the bundled proxy runtime access to ports 80 and 443 without running Studio as root.
- Replaces the incompatible DEB updater with `studio-omarchy-update`.

## Automated upstream releases

Every six hours, CI checks the latest stable
[Studio release](https://github.com/Automattic/studio/releases). A new release is checked out in an
isolated build directory, the audited Omarchy patch is applied, and the full Studio lint, typecheck,
and test suites run. CI then creates and verifies a native Arch package before publishing it here.

Patch conflicts or failed tests stop the release and open an issue. No package is published on a
failed compatibility check.

## Local build

On Omarchy with the Node major required by upstream Studio:

```bash
./packaging/arch/build-omarchy-package.sh
sudo pacman -U ./packaging/arch/wordpress-studio-omarchy-*.pkg.tar.zst
```

See [packaging/arch/README.md](packaging/arch/README.md) for package internals and the manual desktop
test checklist.

WordPress Studio is GPL-2.0-or-later. See [LICENSE.md](LICENSE.md).
