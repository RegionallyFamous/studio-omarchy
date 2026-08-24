const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const statusScript = path.join(root, 'scripts', 'status.sh')
const statusSource = fs.readFileSync(statusScript, 'utf8')
const packageName = 'wordpress-studio-omarchy'
const rawLimit = 96

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`
}

function replaceExactlyOnce(source, original, replacement) {
  assert.equal(source.split(original).length - 1, 1, `${original} must occur exactly once`)
  return source.replace(original, () => shellQuote(replacement))
}

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, { mode: 0o755 })
}

function runStatus(output, pacmanStatus = 0, { shadowPath = false, startupPoison = false } = {}) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-status-'))
  const trustedBin = path.join(fixtureRoot, 'trusted')
  const shadowBin = path.join(fixtureRoot, 'shadow')
  const outputFile = path.join(fixtureRoot, 'pacman-output')
  const shadowMarker = path.join(fixtureRoot, 'shadow-ran')
  const startupMarker = path.join(fixtureRoot, 'startup-ran')
  const bashEnv = path.join(fixtureRoot, 'bash-env')
  const instrumentedScript = path.join(fixtureRoot, 'status.sh')
  fs.mkdirSync(trustedBin)
  fs.writeFileSync(outputFile, output)

  writeExecutable(
    path.join(trustedBin, 'timeout'),
    '#!/bin/bash -p\nshift 3\nexec "$@"\n'
  )
  writeExecutable(
    path.join(trustedBin, 'bash'),
    '#!/bin/bash -p\nexec /bin/bash "$@"\n'
  )
  writeExecutable(
    path.join(trustedBin, 'pacman'),
    [
      '#!/bin/bash -p',
      '/bin/cat -- "$STUDIO_STATUS_OUTPUT_FILE"',
      'exit "${STUDIO_STATUS_EXIT:-0}"',
      ''
    ].join('\n')
  )

  let testSource = statusSource
  testSource = replaceExactlyOnce(testSource, '/usr/bin/timeout', path.join(trustedBin, 'timeout'))
  testSource = replaceExactlyOnce(testSource, '/usr/bin/bash', path.join(trustedBin, 'bash'))
  testSource = replaceExactlyOnce(testSource, '/usr/bin/pacman', path.join(trustedBin, 'pacman'))
  writeExecutable(instrumentedScript, testSource)

  if (shadowPath) {
    fs.mkdirSync(shadowBin)
    for (const tool of ['timeout', 'bash', 'pacman', 'head', 'od', 'tr']) {
      writeExecutable(
        path.join(shadowBin, tool),
        '#!/bin/bash\nprintf "%s\\n" "$0" >>"$STUDIO_STATUS_SHADOW_MARKER"\nexit 99\n'
      )
    }
  }
  if (startupPoison) {
    fs.writeFileSync(bashEnv, `printf 'bash-env\\n' >>${JSON.stringify(startupMarker)}\n`)
  }

  let result
  let shadowExecuted
  let startupExecuted
  try {
    result = spawnSync(instrumentedScript, [], {
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: shadowPath ? `${shadowBin}:${process.env.PATH}` : process.env.PATH,
        STUDIO_STATUS_OUTPUT_FILE: outputFile,
        STUDIO_STATUS_EXIT: String(pacmanStatus),
        STUDIO_STATUS_SHADOW_MARKER: shadowMarker,
        ...(startupPoison
          ? {
              BASH_ENV: bashEnv,
              ENV: bashEnv,
              'BASH_FUNC_printf%%':
                `() { /bin/echo exported-function >>${JSON.stringify(startupMarker)}; builtin printf "$@"; }`
            }
          : {})
      }
    })
    shadowExecuted = fs.existsSync(shadowMarker)
    startupExecuted = fs.existsSync(startupMarker)
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true })
  }
  return { ...result, shadowExecuted, startupExecuted }
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

test('pins the bounded query pipeline to trusted Arch tools', () => {
  assert.match(statusSource, /unset BASH_ENV ENV CDPATH/)
  assert.match(statusSource, /export PATH=\/usr\/bin\nreadonly PATH/)
  assert.match(
    statusSource,
    /\/usr\/bin\/timeout --signal=TERM --kill-after=1s 3s[\s\\]*\/usr\/bin\/bash -p -c/
  )
  assert.match(
    statusSource,
    /\/usr\/bin\/pacman -Q -- "\$1"[\s\S]*\/usr\/bin\/head -c "\$2"[\s\S]*\/usr\/bin\/od -An -v -tx1[\s\S]*\/usr\/bin\/tr -d/
  )
})

test('ignores inherited PATH shadows for every package-query tool', () => {
  const result = runStatus(`${packageName} 1.2.3-1\n`, 0, { shadowPath: true })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'installed\t1.2.3-1\n')
  assert.equal(result.shadowExecuted, false)
})

test('protects the nested query Bash from inherited startup code and exported functions', () => {
  const result = runStatus(`${packageName} 1.2.3-1\n`, 0, { startupPoison: true })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'installed\t1.2.3-1\n')
  assert.equal(result.startupExecuted, false)
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

test('rejects a valid-looking line padded past the byte ceiling with trailing newlines', () => {
  const validLine = `${packageName} v\n`
  const output = validLine + '\n'.repeat(rawLimit + 1 - Buffer.byteLength(validLine))
  assert.equal(Buffer.byteLength(output), rawLimit + 1)
  const result = runStatus(output)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'error\n')
})

test('rejects an embedded NUL instead of normalizing it away', () => {
  const output = Buffer.concat([
    Buffer.from(`${packageName} v`),
    Buffer.from([0]),
    Buffer.from('\n')
  ])
  const result = runStatus(output)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'error\n')
})

test('contains child-process failure as a shaped error', () => {
  const failed = runStatus('private failure', 7)
  assert.equal(failed.status, 0, failed.stderr)
  assert.equal(failed.stdout, 'error\n')
})
