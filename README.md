# WordPress Studio for Omarchy

A native Omarchy/Arch package of
[Automattic's WordPress Studio](https://github.com/Automattic/studio), plus a Quattro bar plugin for
installing, updating, launching, and removing it.

This is a community port maintained by Regionally Famous. It is not an Automattic or Basecamp
release.

## Install from Omarchy Plugins

```bash
omarchy plugin add https://github.com/RegionallyFamous/studio-omarchy.git --enable
```

Add the **WordPress Studio** widget to the Omarchy bar if it is not placed automatically. Open the
widget and select **Install Studio**. The installer downloads the latest native package and its
SHA-256 checksum from this repository's GitHub release, verifies it, and asks pacman to install it.

The plugin itself runs as your user. Pacman is the only privileged boundary, and Omarchy's normal
polkit/sudo prompt handles it in a visible terminal.

## Direct package installation

Download the current `.pkg.tar.zst` and `.sha256` files from
[Releases](https://github.com/RegionallyFamous/studio-omarchy/releases), verify the checksum, then:

```bash
sudo pacman -U ./wordpress-studio-omarchy-*.pkg.tar.zst
```

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

## Remove

Remove the application from the plugin panel or run:

```bash
sudo pacman -Rns wordpress-studio-omarchy
omarchy plugin remove io.github.regionallyfamous.studio
```

WordPress Studio is GPL-2.0-or-later. See [LICENSE.md](LICENSE.md).
