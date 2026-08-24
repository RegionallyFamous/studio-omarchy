# WordPress Studio for Omarchy

A native Omarchy/Arch package of [Automattic's WordPress Studio](https://github.com/Automattic/studio), paired with a Quattro bar plugin for installation, updates, launch, status, and removal.

This is a community port maintained by RegionallyFamous. It is not an Automattic or Basecamp release.

## Install through Quattro

```bash
omarchy plugin add https://github.com/RegionallyFamous/studio-omarchy.git --enable
```

The WordPress icon appears in the right side of the Omarchy bar. Open it and choose **Install Studio**. The plugin opens Omarchy's visible terminal, downloads the latest native package and checksum from this repository's GitHub release, verifies the pair, and asks for elevation. After authorization, a fixed root-side helper copies the package without following a final symlink into a private root-owned staging directory, enforces the same byte ceiling, verifies its metadata and checksum again, and gives only that immutable staged copy to `pacman`. The package installs a root-owned `/usr/lib/studio/chrome-sandbox` with mode `4755` (setuid) for Chromium's sandbox; after installation, the installer always restores that fixed mode and may repair read and execute permissions under `/usr/lib/studio`. Studio otherwise runs as the current desktop user, and the plugin never reads or supplies the password.

The panel is fully keyboard-driven: use Up and Down to choose an action, Enter to run it, and Escape to close it.

## Runtime and external dependencies

The Quattro integration requires Omarchy with its shared shell, visible terminal, and systemd user manager. Published packages and the install and update helpers are supported and tested only on x86_64 Omarchy/Arch. `pacman` resolves the native libraries listed by the package, including Wayland, GTK, NSS, libsecret, polkit, and certificate utilities. Install and update need HTTPS access to this repository's GitHub release metadata and package assets. Studio runs as the current desktop user, starts local WordPress processes only while sites are running, and stores its configuration and sites under the user's home directory. The plugin itself installs no persistent background service; its removal action creates one short-lived transient user scope solely to contain the bounded site-shutdown command and all of its descendants. Optional upstream Studio features can also contact Automattic or WordPress.com when a user enables analytics, logs in, Syncs, or creates a public preview.

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

Package revision 3 and later includes the same fingerprint-matched current-user browser trust cleanup used by the Quattro action. Quit Studio normally first so its active Sync confirmation can finish or cancel work safely. Then, on Omarchy, stop any remaining background sites before dropping the package:

```bash
timeout --signal=TERM --kill-after=5s 60s \
  /usr/lib/studio/resources/bin/node --experimental-wasm-jspi \
  /usr/lib/studio/resources/cli/main.mjs site stop --all --avoid-telemetry &&
! pgrep -u "$(id -u)" -f '^/usr/lib/studio/' &&
studio-omarchy-cleanup-user-trust &&
  omarchy-pkg-drop wordpress-studio-omarchy
```

On another supported x86_64 Arch environment, use the native package manager after the same normal quit, background-site stop, and cleanup:

```bash
timeout --signal=TERM --kill-after=5s 60s \
  /usr/lib/studio/resources/bin/node --experimental-wasm-jspi \
  /usr/lib/studio/resources/cli/main.mjs site stop --all --avoid-telemetry &&
! pgrep -u "$(id -u)" -f '^/usr/lib/studio/' &&
studio-omarchy-cleanup-user-trust &&
  sudo pacman -Rns wordpress-studio-omarchy
```

This removes the package, its system Arch trust anchor, and only a matching `WordPress Studio CA` entry from the current user's bounded Chromium and Firefox NSS databases. Studio sites and other user data are preserved.

## What the port changes

- Uses native Wayland in Hyprland sessions.
- Uses Arch's p11-kit certificate anchor and `update-ca-trust` flow.
- Snapshots and validates Studio's generated CA before authorization, installs only those embedded bytes through an atomic root-side trust-store update, and imports browser trust only from the installed system anchor.
- Updates `/etc/hosts` from an embedded, size-bounded snapshot under a root-side writer lock, with pre-commit conflict detection, exact post-commit verification, and same-directory atomic replacement.
- Registers the `wp-studio://` login callback and desktop launcher.
- Binds custom-domain HTTP, HTTPS, health, Playground/Sandbox WordPress, native PHP, and PHP diagnostic listeners only to IPv4 or IPv6 loopback as appropriate.
- Attempts to grant the bundled proxy runtime access to ports 80 and 443 without running Studio as root, and prints a visible package warning if the filesystem refuses that capability.
- Replaces the incompatible DEB updater with `studio-omarchy-update`.
- Adds a theme-native Quattro panel for install, update, launch, status, and removal.

## Updates

Open the Quattro panel and choose **Update Studio**, or run:

```bash
studio-omarchy-update
```

Both paths select the highest package revision attached to this repository's latest `omarchy-v<version>` release, enforce HTTPS and download timeouts, cap release metadata before parsing, verify the expected checksum filename and SHA-256 value, then repeat the size, file-type, and checksum checks on a private root-owned copy immediately before `pacman` opens it.

## Remove

Choose **Remove Studio** in the Quattro panel. If Studio has an open window, removal stops with instructions to quit it normally so Studio can finish or cancel active Sync work. Once the window is closed, bounded site-shutdown and browser-trust checks run first and verify that the current user's Studio processes are gone. This includes the background process intentionally retained by Studio's native **Keep site running** quit action. The visible, user-bound package transaction starts only after those checks pass. Remove the shell integration itself with:

```bash
omarchy plugin remove io.github.regionallyfamous.studio
```

Removing Studio through the Quattro panel also removes its Arch trust anchor and fingerprint-matched certificate from the current user's Chromium and bounded Firefox profile trust databases. Studio sites and other user data are preserved, and unrelated browser certificates are never removed. Restart an open browser after removal so it discards any cached trust state.

## Automated upstream releases

Every six hours, CI checks the latest stable [Studio release](https://github.com/Automattic/studio/releases). A new release is checked out in an isolated build directory, the audited Omarchy patch is applied, and the full Studio lint, typecheck, and test suites run. CI then creates and verifies a native Arch package before publishing it here.

Patch conflicts or failed tests stop the release and open an issue. No package is published if the patch, upstream test suite, or package verification fails. Publication also stops if `origin/main` moves while the package is building. Manual version requests must identify Automattic's current non-draft, non-prerelease latest release and cannot downgrade the repository. Existing release assets are accepted only when every revision has one exact package/checksum pair, GitHub's SHA-256 asset digests agree with the bounded checksum files, and the expected immutable source tag resolves to the exact source commit. For a new upstream release, the package version and plugin manifest version advance together; Omarchy-only rebuilds increment the package revision without changing the manifest's upstream Studio version.

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

The real-guest acceptance flow also uses genuine pointer input to exercise the visible product instead of stopping at process checks. It clicks the Quattro install, update, launch, and remove actions; creates two uniquely named local WordPress sites through Studio; verifies their persisted configuration, WordPress files, SQLite databases, and simultaneous REST availability; loads a running site in an external browser; stops one site and proves it is offline; starts it again and proves it serves WordPress; then deletes both sites and verifies their Studio records and local paths are gone. It also creates and trusts a custom HTTPS domain, verifies its IPv4 and IPv6 hosts entries, generated certificates, Arch trust anchor, system bundle, Chromium NSS database, and a real Firefox profile NSS database, loads the trusted domain in curl and Chromium, and proves site deletion and package removal clean up only Studio's matching trust material. It creates a final disposable removal fixture, proves removal refuses to run while Studio is open, quits Studio normally, and proves the successful retry stops background serving while preserving that site's record and files. Screenshots are captured for every materially distinct panel, terminal, Studio, and browser state and must be visually reviewed along with any failure screenshots.

### Tested scope and limitations

The full acceptance lane covers the local two-site lifecycle on x86_64 Omarchy: creation, persistence, simultaneous serving, external-browser loading, stop, restart, deletion, custom-domain HTTPS and browser/system trust, and the Quattro install, update, launch, Escape-close, and removal controls. It does not cover WordPress.com login or signup, connecting or importing remote sites, Sync, public previews, or aarch64 runtime behavior. Those flows should not be treated as verified by this port's acceptance lane.

## Marketplace preview

A RegionallyFamous marketplace submission is not release-ready until the repository root contains a supported preview image, such as `preview.png`, that is part of the exact commit which passes the final release gate. Capture it from the real Omarchy guest after dismissing unrelated notifications, show the plugin's useful open-panel state with legible text, exclude secrets and diagnostics, and avoid decorative edits that could misrepresent runtime behavior. Visually inspect the final root asset itself and re-check the live marketplace filename, size, and pixel limits before submission; the test suite does not generate this publication asset.

See [packaging/arch/README.md](packaging/arch/README.md) for package internals and the extended application checklist.

WordPress Studio is GPL-2.0-or-later. See [LICENSE.md](LICENSE.md).
