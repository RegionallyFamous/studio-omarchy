const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const statusScript = path.join(root, 'scripts', 'status.sh')
const packageName = 'wordpress-studio-omarchy'
const rawLimit = 96

function runStatus(output, pacmanStatus = 0) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-status-'))
  const binDir = path.join(fixtureRoot, 'bin')
  fs.mkdirSync(binDir)

  fs.writeFileSync(
    path.join(binDir, 'setsid'),
    '#!/bin/bash\nexec "$@"\n',
    { mode: 0o755 }
  )
  fs.writeFileSync(
    path.join(binDir, 'ps'),
    '#!/bin/bash\nprintf \'%s\\n\' "${@: -1}"\n',
    { mode: 0o755 }
  )
  fs.writeFileSync(
    path.join(binDir, 'pacman'),
    [
      '#!/bin/bash',
      'printf \'%s\' "${STUDIO_STATUS_OUTPUT:-}"',
      'exit "${STUDIO_STATUS_EXIT:-0}"',
      ''
    ].join('\n'),
    { mode: 0o755 }
  )

  const result = spawnSync(statusScript, [], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH}`,
      STUDIO_STATUS_OUTPUT: output,
      STUDIO_STATUS_EXIT: String(pacmanStatus)
    }
  })
  fs.rmSync(fixtureRoot, { recursive: true, force: true })
  return result
}

function statusLineAtBytes(targetBytes, multibyte = false) {
  const prefix = `${packageName} `
  const suffix = '\n'
  let remaining = targetBytes - Buffer.byteLength(prefix + suffix)
  assert.ok(remaining > 0)
  let version = ''
  if (multibyte) {
    version = '猫'.repeat(Math.floor(remaining / 3))
    remaining -= Buffer.byteLength(version)
  }
  version += 'x'.repeat(remaining)
  const line = prefix + version + suffix
  assert.equal(Buffer.byteLength(line), targetBytes)
  return line
}

test('reports an installed package with the exact version field ceiling', () => {
  const version = 'v'.repeat(64)
  const result = runStatus(`${packageName} ${version}\n`)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, `installed\t${version}\n`)
})

test('reports a missing package without exposing pacman output', () => {
  const result = runStatus('private pacman diagnostic', 1)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'missing\n')
})

test('rejects status output at the exact raw ceiling when the field is oversized', () => {
  const result = runStatus(statusLineAtBytes(rawLimit))
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'error\n')
})

test('rejects status output one byte over the raw ceiling without partial data', () => {
  const result = runStatus(statusLineAtBytes(rawLimit + 1))
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'error\n')
})

test('counts multibyte status input by bytes and returns no partial value', () => {
  const result = runStatus(statusLineAtBytes(rawLimit, true))
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'error\n')
})

test('contains child-process failure as a shaped error', () => {
  const failed = runStatus('private failure', 7)
  assert.equal(failed.status, 0, failed.stderr)
  assert.equal(failed.stdout, 'error\n')
})
