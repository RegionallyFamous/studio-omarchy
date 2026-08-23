const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const actionScript = path.join(root, 'scripts', 'action.sh')

function runAction(action) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-action-'))
  const binDir = path.join(fixtureRoot, 'bin')
  const logPath = path.join(fixtureRoot, 'action.log')
  fs.mkdirSync(binDir)

  for (const command of ['omarchy-launch-floating-terminal-with-presentation', 'uwsm-app']) {
    fs.writeFileSync(
      path.join(binDir, command),
      '#!/bin/bash\nprintf \'%s\\n\' "$*" >"$STUDIO_ACTION_LOG"\n',
      { mode: 0o755 }
    )
  }

  const result = spawnSync(actionScript, [action], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH}`,
      STUDIO_ACTION_LOG: logPath
    }
  })
  const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').trim() : ''
  fs.rmSync(fixtureRoot, { recursive: true, force: true })
  return { result, log }
}

test('opens the fixed checksum-verifying updater in a visible terminal', () => {
  const { result, log } = runAction('update')
  assert.equal(result.status, 0, result.stderr)
  assert.equal(log, `'${path.join(root, 'packaging', 'arch', 'studio-omarchy-update')}'`)
})

test('launches the fixed Studio executable under the graphical session manager', () => {
  const { result, log } = runAction('launch')
  assert.equal(result.status, 0, result.stderr)
  assert.equal(log, '-- /usr/bin/studio')
})

test('removes only the fixed Studio package through the Omarchy package helper', () => {
  const { result, log } = runAction('remove')
  assert.equal(result.status, 0, result.stderr)
  assert.equal(
    log,
    `'${path.join(root, 'scripts', 'cleanup-user-trust.sh')}' && omarchy-pkg-drop wordpress-studio-omarchy`
  )
})

test('rejects unknown actions before spawning anything', () => {
  const { result, log } = runAction('private-command')
  assert.equal(result.status, 2)
  assert.equal(log, '')
})
