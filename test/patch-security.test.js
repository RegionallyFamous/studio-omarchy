const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const patchPath =
  process.env.STUDIO_OMARCHY_PATCH_PATH || path.join(root, 'patches', 'studio-omarchy.patch')
const patch = fs.readFileSync(patchPath, 'utf8')

function addedSource(file) {
  const header = `diff --git a/${file} b/${file}`
  const start = patch.indexOf(header)
  assert.notEqual(start, -1, `missing patch for ${file}`)
  const next = patch.indexOf('\ndiff --git ', start + header.length)
  const section = patch.slice(start, next === -1 ? patch.length : next)
  return section
    .split('\n')
    .filter(line => line.startsWith('+') && !line.startsWith('+++'))
    .map(line => line.slice(1))
    .join('\n')
}

test('the compiled Omarchy build cannot fall back to the Debian updater', () => {
  const updater = addedSource('apps/studio/src/lib/linux-update.ts')
  const updateUi = addedSource('apps/studio/src/updates.ts')
  const combined = `${updater}\n${updateUi}`

  assert.match(updater, /command: '\/usr\/bin\/studio-omarchy-update'/)
  assert.match(updater, /shouldDownload: false/)
  assert.doesNotMatch(combined, /STUDIO_OMARCHY_PACKAGE|OMARCHY_PATH/)
  assert.doesNotMatch(combined, /sudo apt install|shouldDownload: true|\.deb\b/)
})

test('Linux hosts replacement validates root metadata and pins target identity at commit', () => {
  const hosts = addedSource('apps/cli/lib/hosts-file.ts')

  assert.match(hosts, /fs\.promises\.lstat\( hostsPath, \{ bigint: true \} \)/)
  assert.match(hosts, /root-owned, single-link regular file/)
  assert.match(hosts, /\/usr\/bin\/stat --format=/)
  assert.match(hosts, /\/usr\/bin\/ln --/)
  assert.match(hosts, /\/usr\/bin\/test '[^']+' -ef '[^']+'/)
  assert.match(hosts, /0:1:regular file/)
  assert.match(hosts, /sha256sum --check --strict --status/)
  assert.ok(hosts.lastIndexOf("[ ! -L '${ hostsPath }' ]") > hosts.indexOf('/usr/bin/mv -fT'))
})

test('browser trust imports require the fixed root anchor to match the current CA exactly', () => {
  const trust = addedSource('packages/common/lib/linux-trust-store.ts')
  const cli = addedSource('apps/cli/lib/certificate-manager.ts')
  const desktop = addedSource('apps/studio/src/lib/certificate-manager.ts')

  assert.match(trust, /readLinuxTrustCertificate\( trustStorePath \)\.equals\( certificate \)/)
  for (const manager of [cli, desktop]) {
    assert.match(manager, /isLinuxTrustAnchorCurrent\( certificate, trustStorePath \)/)
    assert.match(manager, /installed Linux trust anchor does not match the current Studio CA/)
    assert.ok(
      manager.indexOf('installed Linux trust anchor does not match') <
        manager.indexOf('importCAIntoUserNssDbsLinux( trustStorePath )')
    )
  }
})

test('failed trust rollback retains recovery unless refresh and restored identity both verify', () => {
  const trust = addedSource('packages/common/lib/linux-trust-store.ts')

  assert.match(trust, /rollbackFailureCleanupPaths/)
  assert.match(trust, /\/usr\/bin\/cmp --silent/)
  assert.match(trust, /verifyRestoredTarget/)
  assert.match(trust, /verifyRestoredDerivedTrust/)
  assert.match(trust, /updateCommand[\s\S]+openssl verify -CAfile/)
  assert.match(trust, /rollback needs recovery; retained transaction state/)
  assert.doesNotMatch(trust, /\|\| true/)
})

test('Debian purge removes only the root-owned anchor matching its recorded fingerprint', () => {
  const postrm = addedSource('apps/studio/installers/linux/postrm.sh')
  const trust = addedSource('packages/common/lib/linux-trust-store.ts')

  assert.match(postrm, /STUDIO_CA_FINGERPRINT_PATH=.*studio-ca\.crt\.sha256/)
  assert.match(postrm, /sha256sum --check --strict --status/)
  assert.match(postrm, /stat --format='%u:%h:%F'/)
  assert.match(postrm, /\/bin\/rm -f --/)
  assert.doesNotMatch(postrm, /(^|\s)rm -f/)
  assert.match(trust, /isArchBasedLinux\( distribution \)[\s\S]+\? undefined/)
})
