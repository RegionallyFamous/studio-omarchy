# Native package

The package recipe preserves Studio's bundled Electron, Node, PHP, and WordPress Playground runtimes. It does not replace them with rolling system versions.

`build-omarchy-package.sh` checks out the Studio release matching `pkgver`, applies `patches/studio-omarchy.patch`, builds the application, creates the pacman package, and verifies its contents.

The package:

- registers the application and `wp-studio://` URL handler;
- launches Electron with Omarchy's native Wayland flags;
- uses Arch's p11-kit trust store and certificate tooling;
- snapshots and validates the generated Studio CA before elevation, then uses one root-side lifecycle lock to atomically install and repeatedly re-verify only that immutable certificate snapshot;
- serializes hosts-file writers and stages changes beside `/etc/hosts` with payload, conflict, and post-commit verification around atomic replacement;
- binds custom-domain, Playground/Sandbox WordPress, native PHP, and diagnostic listeners only to IPv4 and IPv6 loopback as appropriate;
- attempts to grant the bundled Node runtime access to privileged local ports and warns visibly if the filesystem refuses the capability;
- installs `studio-omarchy-update` for checksum-verified updates from GitHub Releases with a root-owned, re-verified pre-`pacman` handoff;
- installs `studio-omarchy-cleanup-user-trust` for bounded, fingerprint-matched current-user browser trust removal; and
- removes Studio's Arch trust anchor when uninstalled.

## Manual desktop test checklist

1. Install with the repository's direct installer and launch from both the app menu and terminal.
2. Create, stop, restart, and delete a local site.
3. Open WP Admin and a site preview in Chromium.
4. Trust a custom-domain certificate and verify it in Chromium and Firefox.
5. Complete a WordPress.com login through the `wp-studio://` callback.
6. Exercise file dialogs, editor launch, CLI installation, Sync, and public previews.
7. Check normal and fractional scaling, dark/light themes, keyboard navigation, and restoration.
8. Run `studio-omarchy-update`, then remove the package and confirm the trust anchor is removed.
