# Native package

The package recipe preserves Studio's bundled Electron, Node, PHP, and WordPress Playground
runtimes. It does not replace them with rolling system versions.

`build-omarchy-package.sh` checks out the Studio release matching `pkgver`, applies
`patches/studio-omarchy.patch`, builds the application, creates the pacman package, and verifies its
contents.

The package:

- registers the application and `wp-studio://` URL handler;
- launches Electron with Omarchy's native Wayland flags;
- uses Arch's p11-kit trust store and certificate tooling;
- grants the bundled Node runtime access to privileged local ports;
- installs `studio-omarchy-update` for checksum-verified updates from GitHub Releases; and
- removes Studio's Arch trust anchor when uninstalled.

## Manual desktop test checklist

1. Install from the Quattro plugin panel and launch from both the panel and app launcher.
2. Create, stop, restart, and delete a local site.
3. Open WP Admin and a site preview in Chromium.
4. Trust a custom-domain certificate and verify it in Chromium and Firefox.
5. Complete a WordPress.com login through the `wp-studio://` callback.
6. Exercise file dialogs, editor launch, CLI installation, Sync, and public previews.
7. Check normal and fractional scaling, dark/light themes, keyboard navigation, and restoration.
8. Run `studio-omarchy-update`, then remove the package and confirm the trust anchor is removed.
