const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const packagingRoot = path.join(root, 'packaging', 'arch')
const buildHelper = fs.readFileSync(path.join(packagingRoot, 'build-omarchy-package.sh'), 'utf8')
const pkgbuild = fs.readFileSync(path.join(packagingRoot, 'PKGBUILD'), 'utf8')
const installHook = fs.readFileSync(path.join(packagingRoot, 'studio.install'), 'utf8')
const verifier = fs.readFileSync(path.join(packagingRoot, 'verify-package.sh'), 'utf8')

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function writeFile(rootPath, relative, contents, mode = 0o644) {
  const destination = path.join(rootPath, relative)
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 })
  fs.writeFileSync(destination, contents, { mode })
  fs.chmodSync(destination, mode)
}

function archiveFixture(fixtureRoot, packagePath) {
  fs.rmSync(packagePath, { force: true })
  const result = spawnSync(
    'bsdtar',
    [
      '-caf', packagePath,
      '--uid', '0', '--gid', '0',
      '-C', fixtureRoot,
      '.BUILDINFO', '.INSTALL', '.MTREE', '.PKGINFO', 'usr'
    ],
    { encoding: 'utf8' }
  )
  assert.equal(result.status, 0, result.stderr)
}

test('trusted Electron and Node bytes are independently downloaded and handed across packaging', () => {
  assert.match(buildHelper, /PATH=\/usr\/bin:\/usr\/sbin\nreadonly PATH\nexport PATH/)
  assert.match(buildHelper, /curl --disable --fail --silent --show-error --location/)
  assert.match(buildHelper, /--proto '=https' --proto-redir '=https'/)
  assert.match(buildHelper, /electron\/electron\/releases\/download\/v\$electron_version/)
  assert.match(buildHelper, /nodejs\.org\/dist\/v\$node_version/)
  assert.match(buildHelper, /SHASUMS256\.txt/)
  assert.match(buildHelper, /count != 1/)
  assert.match(buildHelper, /bsdtar -xOf "\$archive_path" "\$member_name"/)

  for (const name of [
    'STUDIO_CHROME_SANDBOX_SOURCE',
    'STUDIO_CHROME_SANDBOX_SHA256',
    'STUDIO_NODE_SOURCE',
    'STUDIO_NODE_SHA256'
  ]) {
    assert.match(buildHelper, new RegExp(`${name}="\\$`))
    assert.match(pkgbuild, new RegExp(`${name}:-`))
  }
  assert.match(buildHelper, /STUDIO_EXPECTED_CHROME_SANDBOX_SHA256=/)
  assert.match(buildHelper, /STUDIO_EXPECTED_NODE_SHA256=/)

  const downloadIndex = buildHelper.indexOf('trusted_sandbox_hash=$(download_verified_member')
  const upstreamExecutionIndex = buildHelper.indexOf('npm --prefix "$studio_root" ci')
  assert.ok(downloadIndex >= 0)
  assert.ok(downloadIndex < upstreamExecutionIndex)
})

test('package recipe replaces upstream-controlled privileged files before granting modes', () => {
  const copyIndex = pkgbuild.indexOf('cp -a "$app_source/."')
  const removeIndex = pkgbuild.indexOf('rm -f -- "$pkgdir/usr/lib/studio/chrome-sandbox"')
  const sandboxInstallIndex = pkgbuild.indexOf('install -Dm4755 "$sandbox_source"')
  const nodeInstallIndex = pkgbuild.indexOf('install -Dm755 "$node_source"')
  const manifestIndex = pkgbuild.indexOf('.omarchy-runtime-integrity')
  const rootOwnershipIndex = pkgbuild.indexOf('chown -R 0:0 "$pkgdir/usr"')

  assert.ok(copyIndex >= 0)
  assert.ok(copyIndex < removeIndex)
  assert.ok(removeIndex < sandboxInstallIndex)
  assert.ok(removeIndex < nodeInstallIndex)
  assert.ok(sandboxInstallIndex < rootOwnershipIndex)
  assert.ok(nodeInstallIndex < rootOwnershipIndex)
  assert.ok(manifestIndex < rootOwnershipIndex)
  assert.match(pkgbuild, /sha256sum -- "\$pkgdir\/usr\/lib\/studio\/chrome-sandbox"/)
  assert.match(pkgbuild, /sha256sum -- "\$pkgdir\/usr\/lib\/studio\/resources\/bin\/node"/)
  assert.match(pkgbuild, /'0:0:1:4755'/)
  assert.match(pkgbuild, /'0:0:1:755'/)
  assert.match(pkgbuild, /'0:0:1:644'/)
})

test('install hook verifies bytes and metadata before granting the Node capability', () => {
  const integrityIndex = installHook.indexOf('_load_studio_integrity ||')
  const sandboxIndex = installHook.indexOf('_verify_studio_runtime_file "$_studio_sandbox"')
  const nodeIndex = installHook.indexOf('_verify_studio_runtime_file "$_studio_node"')
  const setcapIndex = installHook.indexOf("/usr/bin/setcap 'cap_net_bind_service=+ep'")
  const getcapIndex = installHook.indexOf('/usr/bin/getcap "$_studio_node"')

  assert.ok(integrityIndex >= 0)
  assert.ok(integrityIndex < sandboxIndex)
  assert.ok(sandboxIndex < setcapIndex)
  assert.ok(nodeIndex < setcapIndex)
  assert.ok(setcapIndex < getcapIndex)
  assert.match(installHook, /'%F\|%u\|%g\|%a\|%h\|%s'/)
  assert.match(installHook, /uid == 0 && gid == 0 && links == 1/)
  assert.match(installHook, /\/usr\/bin\/sha256sum/)
  assert.match(installHook, /\/usr\/bin\/chmod 0755 "\$_studio_sandbox"/)
  assert.doesNotMatch(installHook, /(^|\n)\s*setcap\s/m)
  assert.doesNotMatch(installHook, /(^|\n)\s*rm\s/m)
})

test(
  'install hook refuses a changed runtime before granting privilege',
  { skip: process.platform !== 'linux' || process.getuid() !== 0 },
  () => {
    const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-runtime-hook-'))
    const studioRoot = path.join(fixtureRoot, 'studio')
    const sandboxPath = path.join(studioRoot, 'chrome-sandbox')
    const nodePath = path.join(studioRoot, 'resources', 'bin', 'node')
    const manifestPath = path.join(studioRoot, '.omarchy-runtime-integrity')
    const setcapStub = path.join(fixtureRoot, 'setcap')
    const getcapStub = path.join(fixtureRoot, 'getcap')
    const capabilityLog = path.join(fixtureRoot, 'capability.log')
    const scriptPath = path.join(fixtureRoot, 'studio.install')
    const sandboxBytes = Buffer.from('official sandbox bytes\n')
    const nodeBytes = Buffer.from('official node bytes\n')

    try {
      writeFile(studioRoot, 'chrome-sandbox', sandboxBytes, 0o4755)
      writeFile(studioRoot, 'resources/bin/node', nodeBytes, 0o755)
      writeFile(
        studioRoot,
        '.omarchy-runtime-integrity',
        `${sha256(sandboxBytes)}  chrome-sandbox\n${sha256(nodeBytes)}  resources/bin/node\n`
      )
      writeFile(
        fixtureRoot,
        'setcap',
        `#!/bin/bash\nprintf '%s\\n' "$*" >>${JSON.stringify(capabilityLog)}\n`,
        0o755
      )
      writeFile(
        fixtureRoot,
        'getcap',
        `#!/bin/bash\nprintf '%s cap_net_bind_service=ep\\n' "$1"\n`,
        0o755
      )

      const transformed = installHook
        .replace("_studio_node='/usr/lib/studio/resources/bin/node'", `_studio_node='${nodePath}'`)
        .replace("_studio_sandbox='/usr/lib/studio/chrome-sandbox'", `_studio_sandbox='${sandboxPath}'`)
        .replace("_studio_integrity='/usr/lib/studio/.omarchy-runtime-integrity'", `_studio_integrity='${manifestPath}'`)
        .replaceAll("'/usr/lib/studio'", `'${studioRoot}'`)
        .replaceAll("'/usr/lib/studio/resources'", `'${path.join(studioRoot, 'resources')}'`)
        .replaceAll("'/usr/lib/studio/resources/bin'", `'${path.join(studioRoot, 'resources', 'bin')}'`)
        .replaceAll('/usr/bin/setcap', setcapStub)
        .replaceAll('/usr/bin/getcap', getcapStub)
        .replaceAll('PATH=/usr/bin:/usr/sbin update-desktop-database -q', ':')
      fs.writeFileSync(scriptPath, transformed)

      const first = spawnSync('/bin/bash', ['-c', `. '${scriptPath}'; post_install`], {
        encoding: 'utf8'
      })
      assert.equal(first.status, 0, first.stderr)
      assert.match(fs.readFileSync(capabilityLog, 'utf8'), /cap_net_bind_service=\+ep/)

      fs.appendFileSync(nodePath, 'changed')
      const second = spawnSync('/bin/bash', ['-c', `. '${scriptPath}'; post_upgrade`], {
        encoding: 'utf8'
      })
      assert.notEqual(second.status, 0)
      assert.match(second.stderr, /refusing privileged runtime setup/)
      const grants = fs.readFileSync(capabilityLog, 'utf8').match(/cap_net_bind_service=\+ep/g) || []
      assert.equal(grants.length, 1)
      assert.equal(fs.statSync(sandboxPath).mode & 0o7777, 0o755)
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true })
    }
  }
)

test('package verifier binds archive ownership, runtime hashes, and independent expectations', () => {
  assert.match(verifier, /bsdtar --numeric-owner -tvf/)
  assert.match(verifier, /\$3 != "0" \|\| \$4 != "0"/)
  assert.match(verifier, /verify_archive_regular_root_file 'usr\/lib\/studio\/chrome-sandbox'/)
  assert.match(verifier, /verify_archive_regular_root_file 'usr\/lib\/studio\/resources\/bin\/node'/)
  assert.match(verifier, /runtime integrity manifest must have exactly two records/)
  assert.match(verifier, /actual_sandbox_hash == "\$declared_sandbox_hash"/)
  assert.match(verifier, /actual_node_hash == "\$declared_node_hash"/)
  assert.match(verifier, /STUDIO_EXPECTED_CHROME_SANDBOX_SHA256/)
  assert.match(verifier, /STUDIO_EXPECTED_NODE_SHA256/)
})

test(
  'package verifier accepts exact committed bytes and rejects either changed bytes or expectations',
  {
    skip: process.platform !== 'linux' ||
      spawnSync('bsdtar', ['--version']).status !== 0
  },
  () => {
    const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-package-verifier-'))
    const pkgver = pkgbuild.match(/^pkgver=(.+)$/m)[1]
    const pkgrel = pkgbuild.match(/^pkgrel=(.+)$/m)[1]
    const packagePath = path.join(
      fixtureRoot,
      `wordpress-studio-omarchy-${pkgver}-${pkgrel}-x86_64.pkg.tar.zst`
    )
    const sandboxBytes = Buffer.from('official sandbox bytes\n')
    const nodeBytes = Buffer.from('official node bytes\n')
    const sandboxHash = sha256(sandboxBytes)
    const nodeHash = sha256(nodeBytes)

    try {
      writeFile(fixtureRoot, '.BUILDINFO', 'format = 2\n')
      writeFile(fixtureRoot, '.MTREE', '#mtree\n')
      writeFile(
        fixtureRoot,
        '.PKGINFO',
        `pkgname = wordpress-studio-omarchy\npkgver = ${pkgver}-${pkgrel}\narch = x86_64\n`
      )
      writeFile(fixtureRoot, '.INSTALL', installHook)
      writeFile(fixtureRoot, 'usr/bin/studio', fs.readFileSync(path.join(packagingRoot, 'studio-launcher')), 0o755)
      writeFile(
        fixtureRoot,
        'usr/bin/studio-omarchy-cleanup-user-trust',
        fs.readFileSync(path.join(root, 'scripts', 'cleanup-user-trust.sh')),
        0o755
      )
      writeFile(
        fixtureRoot,
        'usr/bin/studio-omarchy-update',
        fs.readFileSync(path.join(packagingRoot, 'studio-omarchy-update')),
        0o755
      )
      writeFile(
        fixtureRoot,
        'usr/lib/studio/.omarchy-runtime-integrity',
        `${sandboxHash}  chrome-sandbox\n${nodeHash}  resources/bin/node\n`
      )
      writeFile(fixtureRoot, 'usr/lib/studio/chrome-sandbox', sandboxBytes, 0o4755)
      writeFile(fixtureRoot, 'usr/lib/studio/resources/app.asar', 'asar\n')
      writeFile(fixtureRoot, 'usr/lib/studio/resources/bin/node', nodeBytes, 0o755)
      writeFile(fixtureRoot, 'usr/lib/studio/resources/bin/studio-cli.sh', '#!/bin/bash\n', 0o755)
      writeFile(fixtureRoot, 'usr/lib/studio/resources/cli/main.mjs', 'export {}\n')
      writeFile(fixtureRoot, 'usr/lib/studio/studio', '#!/bin/sh\n', 0o755)
      writeFile(
        fixtureRoot,
        'usr/share/applications/studio.desktop',
        fs.readFileSync(path.join(packagingRoot, 'studio.desktop'))
      )
      writeFile(fixtureRoot, 'usr/share/icons/hicolor/512x512/apps/studio.png', 'png\n')
      writeFile(
        fixtureRoot,
        'usr/share/licenses/wordpress-studio-omarchy/LICENSE.md',
        fs.readFileSync(path.join(root, 'LICENSE.md'))
      )
      archiveFixture(fixtureRoot, packagePath)

      const exact = spawnSync(path.join(packagingRoot, 'verify-package.sh'), [packagePath], {
        encoding: 'utf8',
        env: {
          ...process.env,
          STUDIO_EXPECTED_CHROME_SANDBOX_SHA256: sandboxHash,
          STUDIO_EXPECTED_NODE_SHA256: nodeHash
        }
      })
      assert.equal(exact.status, 0, exact.stderr)

      const wrongExpectation = spawnSync(
        path.join(packagingRoot, 'verify-package.sh'),
        [packagePath],
        {
          encoding: 'utf8',
          env: {
            ...process.env,
            STUDIO_EXPECTED_CHROME_SANDBOX_SHA256: '0'.repeat(64),
            STUDIO_EXPECTED_NODE_SHA256: nodeHash
          }
        }
      )
      assert.notEqual(wrongExpectation.status, 0)
      assert.match(wrongExpectation.stderr, /independently verified runtime/)

      fs.appendFileSync(path.join(fixtureRoot, 'usr/lib/studio/chrome-sandbox'), 'changed')
      fs.chmodSync(path.join(fixtureRoot, 'usr/lib/studio/chrome-sandbox'), 0o4755)
      archiveFixture(fixtureRoot, packagePath)
      const changedBytes = spawnSync(path.join(packagingRoot, 'verify-package.sh'), [packagePath], {
        encoding: 'utf8',
        env: {
          ...process.env,
          STUDIO_EXPECTED_CHROME_SANDBOX_SHA256: sandboxHash,
          STUDIO_EXPECTED_NODE_SHA256: nodeHash
        }
      })
      assert.notEqual(changedBytes.status, 0)
      assert.match(changedBytes.stderr, /does not match its integrity record/)
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true })
    }
  }
)
