const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const installScriptPath = path.join(root, 'packaging', 'arch', 'studio.install')
const installScript = fs.readFileSync(installScriptPath, 'utf8')

function transformedRemovalScript(tmpDir, updateCommand = ':') {
  const caPath = path.join(tmpDir, 'studio-ca.crt')
  const lockPath = path.join(tmpDir, 'studio-ca.lock')
  return {
    caPath,
    lockPath,
    script: installScript
      .replace(
        "_studio_ca='/etc/ca-certificates/trust-source/anchors/studio-ca.crt'",
        `_studio_ca='${caPath}'`
      )
      .replace(
        "_studio_ca_lock='/run/lock/wordpress-studio-ca.lock'",
        `_studio_ca_lock='${lockPath}'`
      )
      .replaceAll('update-ca-trust extract', updateCommand)
      .replaceAll('update-desktop-database -q', ':')
  }
}

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise(resolve => {
    child.once('close', (code, signal) => resolve({ code, signal }))
  })
}

async function waitForFile(file, milliseconds = 2000) {
  const deadline = Date.now() + milliseconds
  while (!fs.existsSync(file)) {
    assert.ok(Date.now() < deadline, `timed out waiting for ${file}`)
    await new Promise(resolve => setTimeout(resolve, 10))
  }
}

test('Arch package removal takes the shared certificate lock before touching the anchor', () => {
  const lockIndex = installScript.indexOf('/usr/bin/flock -x 9')
  const removeIndex = installScript.indexOf('rm -f "$_studio_ca"')

  assert.match(installScript, /_studio_ca_lock='\/run\/lock\/wordpress-studio-ca\.lock'/)
  assert.match(installScript, /exec 9>"\$_studio_ca_lock"/)
  assert.ok(lockIndex > 0)
  assert.ok(removeIndex > lockIndex)
  assert.match(installScript, /if \([\s\S]+\/usr\/bin\/flock -x 9 \|\| exit 1[\s\S]+\); then/)
  assert.match(installScript, /unable to remove the system trust anchor safely/)
})

test('Arch package removal fails closed when the certificate lock cannot be acquired', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-ca-lock-failure-'))
  try {
    const fixture = transformedRemovalScript(tmpDir)
    const scriptPath = path.join(tmpDir, 'studio.install')
    fs.writeFileSync(fixture.caPath, 'existing anchor')
    fs.writeFileSync(
      scriptPath,
      fixture.script.replace('/usr/bin/flock -x 9', '/bin/false')
    )

    const result = spawnSync('/bin/bash', ['-c', `. '${scriptPath}'; post_remove`], {
      encoding: 'utf8'
    })

    assert.notEqual(result.status, 0)
    assert.equal(fs.readFileSync(fixture.caPath, 'utf8'), 'existing anchor')
    assert.match(result.stderr, /unable to remove the system trust anchor safely/)
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true })
  }
})

test('Arch package removal retries trust extraction after an earlier refresh failure', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-ca-refresh-retry-'))
  try {
    const updateScript = path.join(tmpDir, 'update-trust')
    const counterPath = path.join(tmpDir, 'update-count')
    const fixture = transformedRemovalScript(tmpDir, `'${updateScript}'`)
    const scriptPath = path.join(tmpDir, 'studio.install')
    fs.writeFileSync(fixture.caPath, 'existing anchor')
    fs.writeFileSync(
      updateScript,
      `#!/bin/bash
count=0
[[ ! -e '${counterPath}' ]] || count=$(<'${counterPath}')
(( count += 1 ))
printf '%s\n' "$count" >'${counterPath}'
(( count > 1 ))
`,
      { mode: 0o755 }
    )
    fs.writeFileSync(scriptPath, fixture.script.replace('/usr/bin/flock -x 9', ':'))

    const first = spawnSync('/bin/bash', ['-c', `. '${scriptPath}'; post_remove`], {
      encoding: 'utf8'
    })
    assert.notEqual(first.status, 0)
    assert.equal(fs.existsSync(fixture.caPath), false)
    assert.equal(fs.readFileSync(counterPath, 'utf8').trim(), '1')

    const second = spawnSync('/bin/bash', ['-c', `. '${scriptPath}'; post_remove`], {
      encoding: 'utf8'
    })
    assert.equal(second.status, 0, second.stderr)
    assert.equal(fs.readFileSync(counterPath, 'utf8').trim(), '2')
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true })
  }
})

test(
  'Arch package removal waits for an active certificate transaction',
  { skip: process.platform !== 'linux' || !fs.existsSync('/usr/bin/flock') },
  async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-ca-lock-overlap-'))
    const readyPath = path.join(tmpDir, 'lock-ready')
    const releasePath = path.join(tmpDir, 'release-lock')
    const scriptPath = path.join(tmpDir, 'studio.install')
    const fixture = transformedRemovalScript(tmpDir)
    let holder
    let remover
    try {
      fs.writeFileSync(fixture.caPath, 'existing anchor')
      fs.writeFileSync(scriptPath, fixture.script)
      holder = spawn('/bin/bash', [
        '-c',
        `set -e; exec 9>'${fixture.lockPath}'; /usr/bin/flock -x 9; : >'${readyPath}'; while [[ ! -e '${releasePath}' ]]; do /usr/bin/sleep 0.01; done`
      ])
      await waitForFile(readyPath)

      remover = spawn('/bin/bash', ['-c', `. '${scriptPath}'; post_remove`])
      await new Promise(resolve => setTimeout(resolve, 100))
      assert.equal(remover.exitCode, null)
      assert.equal(fs.readFileSync(fixture.caPath, 'utf8'), 'existing anchor')

      const holderExit = waitForExit(holder)
      const removerExit = waitForExit(remover)
      fs.writeFileSync(releasePath, '')
      assert.deepEqual(await holderExit, { code: 0, signal: null })
      assert.deepEqual(await removerExit, { code: 0, signal: null })
      assert.equal(fs.existsSync(fixture.caPath), false)
    } finally {
      holder?.kill('SIGKILL')
      remover?.kill('SIGKILL')
      fs.rmSync(tmpDir, { recursive: true, force: true })
    }
  }
)
