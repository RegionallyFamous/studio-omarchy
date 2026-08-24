const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8')
const protectedEntrypoints = [
  'install.sh',
  'packaging/arch/studio-launcher',
  'packaging/arch/studio-omarchy-update',
  'scripts/action.sh',
  'scripts/cleanup-user-trust.sh',
  'scripts/remove.sh',
  'scripts/status.sh'
]

test('security-sensitive shell entrypoints suppress BASH_ENV before their first line', () => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-shell-startup-'))
  const bashEnv = path.join(fixtureRoot, 'bash-env')
  const marker = path.join(fixtureRoot, 'bash-env-ran')

  fs.writeFileSync(bashEnv, `printf 'ran\n' >>${JSON.stringify(marker)}\n`)
  try {
    for (const relative of protectedEntrypoints) {
      const script = path.join(root, relative)
      assert.equal(fs.readFileSync(script, 'utf8').startsWith('#!/bin/bash -p\n'), true, relative)
      const result = spawnSync(script, ['invalid-test-action'], {
        encoding: 'utf8',
        env: {
          ...process.env,
          BASH_ENV: bashEnv,
          ENV: bashEnv,
          STUDIO_OMARCHY_TEST_MODE: 'invalid',
          OMARCHY_PATH: '/nonexistent-studio-test-omarchy'
        },
        input: '',
        timeout: 5000
      })
      assert.notEqual(result.error?.code, 'ETIMEDOUT', `${relative} exceeded the startup test deadline`)
      assert.equal(fs.existsSync(marker), false, `${relative} evaluated BASH_ENV before hardening`)
    }
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true })
  }
})

test('the supported direct installer preserves privileged Bash startup mode', () => {
  assert.match(
    readme,
    /\/usr\/bin\/timeout --signal=TERM --kill-after=5s 50s[\s\S]*\/usr\/bin\/curl --disable[\s\S]*--cacert \/etc\/ssl\/certs\/ca-certificates\.crt[\s\S]*--connect-timeout 10 --max-time 30 --max-filesize 1048576[\s\S]*install\.sh &&\n  \/bin\/bash -p "\$studio_installer"/
  )

  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-direct-bash-'))
  const bashEnv = path.join(fixtureRoot, 'bash-env')
  const marker = path.join(fixtureRoot, 'bash-env-ran')
  fs.writeFileSync(bashEnv, `printf 'ran\\n' >>${JSON.stringify(marker)}\\n`)
  try {
    const result = spawnSync('/bin/bash', ['-p', '-c', 'exit 0'], {
      env: { ...process.env, BASH_ENV: bashEnv },
      encoding: 'utf8'
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.existsSync(marker), false)
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true })
  }
})

test('the supported direct installer never executes a failed partial download', () => {
  const block = readme.match(/## Direct installation[\s\S]*?```bash\n([\s\S]*?)```/)
  assert.ok(block, 'README direct installer block is missing')
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-direct-bootstrap-'))
  const installer = path.join(fixtureRoot, 'installer')
  const marker = path.join(fixtureRoot, 'installer-ran')
  const fakeMktemp = path.join(fixtureRoot, 'mktemp')
  const fakeTimeout = path.join(fixtureRoot, 'timeout')
  const fakeCurl = path.join(fixtureRoot, 'curl')
  const fakeBash = path.join(fixtureRoot, 'bash')

  fs.writeFileSync(fakeMktemp, `#!/bin/bash\nprintf '%s\\n' ${JSON.stringify(installer)}\n`, { mode: 0o755 })
  fs.writeFileSync(fakeTimeout, '#!/bin/bash\nshift 3\nexec "$@"\n', { mode: 0o755 })
  fs.writeFileSync(
    fakeCurl,
    `#!/bin/bash\nprintf 'partial download\\n' >${JSON.stringify(installer)}\nexit 7\n`,
    { mode: 0o755 }
  )
  fs.writeFileSync(fakeBash, `#!/bin/bash\nprintf 'ran\\n' >${JSON.stringify(marker)}\n`, { mode: 0o755 })

  const instrumented = block[1]
    .replaceAll('/usr/bin/mktemp', fakeMktemp)
    .replaceAll('/usr/bin/timeout', fakeTimeout)
    .replaceAll('/usr/bin/curl', fakeCurl)
    .replaceAll('/usr/bin/rm', '/bin/rm')
    .replaceAll('/bin/bash', fakeBash)
  try {
    const result = spawnSync('/bin/bash', ['-c', instrumented], { encoding: 'utf8' })
    assert.equal(result.status, 7, result.stderr)
    assert.equal(fs.existsSync(marker), false)
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true })
  }
})
