const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const cleanupScript = path.join(root, 'scripts', 'cleanup-user-trust.sh')
const studioNickname = 'WordPress Studio CA'
const matchingFingerprint = '11'.repeat(32)
const differentFingerprint = '22'.repeat(32)
const maxCertificateBytes = 64 * 1024

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, { mode: 0o755 })
}

function shellQuote(value) {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

function createInstrumentedCleanupScript(fixtureRoot, tools, trustedTempParent) {
  const testScript = path.join(fixtureRoot, 'cleanup-user-trust.test.sh')
  let source = fs.readFileSync(cleanupScript, 'utf8')
  const replacements = new Map([
    ["readonly TIMEOUT_BIN='/usr/bin/timeout'", `readonly TIMEOUT_BIN=${shellQuote(tools.timeout)}`],
    ["readonly FIND_BIN='/usr/bin/find'", "readonly FIND_BIN='/usr/bin/find'"],
    ["readonly MKTEMP_BIN='/usr/bin/mktemp'", `readonly MKTEMP_BIN=${shellQuote(tools.mktemp)}`],
    ["readonly CHMOD_BIN='/usr/bin/chmod'", "readonly CHMOD_BIN='/bin/chmod'"],
    ["readonly RM_BIN='/usr/bin/rm'", "readonly RM_BIN='/bin/rm'"],
    ["readonly CERTUTIL_BIN='/usr/bin/certutil'", `readonly CERTUTIL_BIN=${shellQuote(tools.certutil)}`],
    ["readonly OPENSSL_BIN='/usr/bin/openssl'", `readonly OPENSSL_BIN=${shellQuote(tools.openssl)}`],
    ["readonly ID_BIN='/usr/bin/id'", `readonly ID_BIN=${shellQuote(tools.id)}`],
    ["readonly GETENT_BIN='/usr/bin/getent'", `readonly GETENT_BIN=${shellQuote(tools.getent)}`],
    ["readonly HEAD_BIN='/usr/bin/head'", "readonly HEAD_BIN='/usr/bin/head'"],
    ["readonly STAT_BIN='/usr/bin/stat'", `readonly STAT_BIN=${shellQuote(tools.stat)}`],
    ["readonly TRUST_TEMP_PARENT='/tmp'", `readonly TRUST_TEMP_PARENT=${shellQuote(trustedTempParent)}`]
  ])

  for (const [productionLine, testLine] of replacements) {
    assert.equal(
      source.split(productionLine).length - 1,
      1,
      `expected one production constant: ${productionLine}`
    )
    source = source.replace(productionLine, () => testLine)
  }
  fs.writeFileSync(testScript, source, { mode: 0o755 })
  return testScript
}

function createFixture() {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-trust-cleanup-'))
  const home = path.join(fixtureRoot, 'home')
  const bin = path.join(fixtureRoot, 'bin')
  const trustedTempParent = path.join(fixtureRoot, 'trusted-temp')
  const timeoutLog = path.join(fixtureRoot, 'timeout.log')
  fs.mkdirSync(home)
  fs.mkdirSync(bin)
  fs.mkdirSync(trustedTempParent)

  writeExecutable(
    path.join(bin, 'timeout'),
    `#!/bin/bash
printf '%s|%s|%s|%s|%s\\n' "$1" "$2" "$3" "$4" "$5" >>"$STUDIO_TEST_TIMEOUT_LOG"
shift 4
exec "$@"
`
  )
  writeExecutable(
    path.join(bin, 'openssl'),
    `#!/bin/bash
input_file=
while (( $# > 0 )); do
  if [[ $1 == "-in" ]]; then
    input_file=$2
    shift 2
  else
    shift
  fi
done

if [[ -n $input_file ]]; then
  fingerprint=$STUDIO_TEST_CA_FINGERPRINT
else
  IFS= read -r certificate_kind || true
  if [[ $certificate_kind == "MATCH" ]]; then
    fingerprint=$STUDIO_TEST_CA_FINGERPRINT
  else
    fingerprint=$STUDIO_TEST_OTHER_FINGERPRINT
  fi
fi
printf 'SHA256 Fingerprint=%s\\n' "$fingerprint"
`
  )
  writeExecutable(
    path.join(bin, 'certutil'),
    `#!/bin/bash
action=
database=
nickname=
ascii=false
while (( $# > 0 )); do
  case $1 in
    -L|-D)
      action=$1
      shift
      ;;
    -d)
      database=\${2#sql:}
      shift 2
      ;;
    -n)
      nickname=$2
      shift 2
      ;;
    -a)
      ascii=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

entry="$database/.studio-test-entry"
if [[ $action == "-L" && -z $nickname ]]; then
  [[ -f $database/cert9.db ]]
elif [[ $action == "-L" && $nickname == "${studioNickname}" ]]; then
  if [[ -f $entry ]]; then
    if [[ -n \${STUDIO_TEST_LOOKUP_FAIL_STATUS:-} ]]; then
      exit "$STUDIO_TEST_LOOKUP_FAIL_STATUS"
    fi
  else
    if [[ -n \${STUDIO_TEST_VERIFY_LOOKUP_FAIL_STATUS:-} ]]; then
      exit "$STUDIO_TEST_VERIFY_LOOKUP_FAIL_STATUS"
    fi
    exit 1
  fi
  if [[ $ascii == true ]]; then
    /bin/cat "$entry"
  fi
elif [[ $action == "-D" && $nickname == "${studioNickname}" ]]; then
  [[ -f $entry ]] || exit 1
  [[ \${STUDIO_TEST_DELETE_FAIL:-0} != 1 ]] || exit 3
  /bin/rm -f -- "$entry"
else
  exit 2
fi
`
  )

  writeExecutable(
    path.join(bin, 'id'),
    `#!/bin/bash
[[ $# == 1 && $1 == "-u" ]] || exit 2
printf '%s\\n' "$STUDIO_TEST_UID"
`
  )
  writeExecutable(
    path.join(bin, 'getent'),
    `#!/bin/bash
[[ $# == 2 && $1 == "passwd" && $2 == "$STUDIO_TEST_UID" ]] || exit 2
printf 'studio:x:%s:100:Studio Test:%s:/bin/bash\\n' "$STUDIO_TEST_UID" "$STUDIO_TEST_PASSWD_HOME"
`
  )
  writeExecutable(
    path.join(bin, 'mktemp'),
    `#!/bin/bash
parent=
template=
while (( $# > 0 )); do
  case $1 in
    -d)
      shift
      ;;
    --tmpdir=*)
      parent=\${1#--tmpdir=}
      shift
      ;;
    *)
      template=$1
      shift
      ;;
  esac
done
[[ -n $parent && -n $template ]] || exit 2
if [[ -n \${STUDIO_TEST_MKTEMP_RESULT:-} ]]; then
  printf '%s\\n' "$STUDIO_TEST_MKTEMP_RESULT"
  exit 0
fi
exec /usr/bin/mktemp -d "$parent/$template"
`
  )
  writeExecutable(
    path.join(bin, 'stat'),
    `#!/bin/bash
[[ $# == 4 && $1 == "-c" && $2 == "%s" && $3 == "--" ]] || exit 2
size=$(/usr/bin/wc -c <"$4") || exit
printf '%s\n' "\${size//[[:space:]]/}"
`
  )

  const tools = {
    timeout: path.join(bin, 'timeout'),
    mktemp: path.join(bin, 'mktemp'),
    certutil: path.join(bin, 'certutil'),
    openssl: path.join(bin, 'openssl'),
    id: path.join(bin, 'id'),
    getent: path.join(bin, 'getent'),
    stat: path.join(bin, 'stat')
  }
  const testScript = createInstrumentedCleanupScript(fixtureRoot, tools, trustedTempParent)

  return { fixtureRoot, home, bin, trustedTempParent, testScript, timeoutLog }
}

function createStudioCa(home) {
  const caDir = path.join(home, '.studio', 'certificates')
  fs.mkdirSync(caDir, { recursive: true })
  const caFile = path.join(caDir, 'studio-ca.crt')
  fs.writeFileSync(caFile, 'fixture Studio CA\n')
  return caFile
}

function createNssDb(home, relativePath, entryKind) {
  const database = path.join(home, relativePath)
  fs.mkdirSync(database, { recursive: true })
  fs.writeFileSync(path.join(database, 'cert9.db'), 'fixture database\n')
  fs.writeFileSync(path.join(database, 'unrelated-certificate'), 'keep me\n')
  if (entryKind) {
    fs.writeFileSync(path.join(database, '.studio-test-entry'), `${entryKind}\n`)
  }
  return database
}

function runCleanup(fixture, extraEnv = {}) {
  return spawnSync(fixture.testScript, [], {
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: fixture.home,
      PATH: `${fixture.bin}:${process.env.PATH}`,
      STUDIO_TEST_UID: String(process.getuid()),
      STUDIO_TEST_PASSWD_HOME: fixture.home,
      STUDIO_TEST_CA_FINGERPRINT: matchingFingerprint,
      STUDIO_TEST_OTHER_FINGERPRINT: differentFingerprint,
      STUDIO_TEST_TIMEOUT_LOG: fixture.timeoutLog,
      ...extraEnv
    }
  })
}

function removeFixture(fixture) {
  fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
}

test('removes only fingerprint-matched entries from bounded Chromium and Firefox databases', () => {
  const fixture = createFixture()
  try {
    const caFile = createStudioCa(fixture.home)
    const standardDb = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')
    const snapDb = createNssDb(
      fixture.home,
      path.join('snap', 'chromium', 'current', '.pki', 'nssdb'),
      'MATCH'
    )
    const aptFirefoxDb = createNssDb(
      fixture.home,
      path.join('.mozilla', 'firefox', 'apt.default-release'),
      'MATCH'
    )
    const snapFirefoxDb = createNssDb(
      fixture.home,
      path.join('snap', 'firefox', 'common', '.mozilla', 'firefox', 'snap.default'),
      'MATCH'
    )
    const flatpakFirefoxDb = createNssDb(
      fixture.home,
      path.join('.var', 'app', 'org.mozilla.firefox', '.mozilla', 'firefox', 'flatpak.default-esr'),
      'MATCH'
    )
    const customFirefoxDb = createNssDb(
      fixture.home,
      path.join('.mozilla', 'firefox', 'custom.profile'),
      'MATCH'
    )

    const result = runCleanup(fixture)

    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /removed 5 matching current-user browser trust entries/)
    assert.equal(fs.existsSync(path.join(standardDb, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(path.join(snapDb, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(path.join(aptFirefoxDb, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(path.join(snapFirefoxDb, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(path.join(flatpakFirefoxDb, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(path.join(customFirefoxDb, '.studio-test-entry')), true)
    assert.equal(fs.readFileSync(path.join(standardDb, 'unrelated-certificate'), 'utf8'), 'keep me\n')
    assert.equal(fs.readFileSync(path.join(snapDb, 'unrelated-certificate'), 'utf8'), 'keep me\n')
    assert.equal(fs.readFileSync(caFile, 'utf8'), 'fixture Studio CA\n')

    const timeoutCalls = fs.readFileSync(fixture.timeoutLog, 'utf8').trim().split('\n')
    assert.ok(timeoutCalls.length > 0)
    for (const call of timeoutCalls) {
      assert.deepEqual(call.split('|').slice(0, 4), [
        '--foreground',
        '--signal=TERM',
        '--kill-after=2s',
        '6s'
      ])
    }
  } finally {
    removeFixture(fixture)
  }
})

test('preserves a same-nickname certificate when its fingerprint differs', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'OTHER')

    const result = runCleanup(fixture)

    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stderr, /preserving a different certificate/)
    assert.equal(fs.readFileSync(path.join(database, '.studio-test-entry'), 'utf8'), 'OTHER\n')
  } finally {
    removeFixture(fixture)
  }
})

test('is idempotent when a readable Chromium database has no Studio entry or CA file', () => {
  const fixture = createFixture()
  try {
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'))

    const result = runCleanup(fixture)

    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /no matching current-user browser trust entry found/)
    assert.equal(fs.readFileSync(path.join(database, 'unrelated-certificate'), 'utf8'), 'keep me\n')
  } finally {
    removeFixture(fixture)
  }
})

test('accepts a Studio CA at the exact certificate byte ceiling', () => {
  const fixture = createFixture()
  try {
    const caFile = createStudioCa(fixture.home)
    fs.writeFileSync(caFile, Buffer.alloc(maxCertificateBytes, 'A'))
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture)

    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), false)
  } finally {
    removeFixture(fixture)
  }
})

test('rejects a Studio CA one byte over the certificate ceiling', () => {
  const fixture = createFixture()
  try {
    const caFile = createStudioCa(fixture.home)
    fs.writeFileSync(caFile, Buffer.alloc(maxCertificateBytes + 1, 'A'))
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /Studio CA larger than 65536 bytes/)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), true)
  } finally {
    removeFixture(fixture)
  }
})

test('accepts an exported browser certificate at the exact byte ceiling', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')
    const entry = path.join(database, '.studio-test-entry')
    fs.writeFileSync(entry, `MATCH\n${'A'.repeat(maxCertificateBytes - 6)}`)

    const result = runCleanup(fixture)

    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.existsSync(entry), false)
  } finally {
    removeFixture(fixture)
  }
})

test('rejects an exported browser certificate one byte over the certificate ceiling', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')
    const entry = path.join(database, '.studio-test-entry')
    fs.writeFileSync(entry, `MATCH\n${'A'.repeat(maxCertificateBytes - 5)}`)

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /browser Studio certificate larger than 65536 bytes/)
    assert.equal(fs.existsSync(entry), true)
  } finally {
    removeFixture(fixture)
  }
})

test('uses the current UID passwd home instead of an inherited alternate-owned HOME', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const canonicalDatabase = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')
    const alternateHome = path.join(fixture.fixtureRoot, 'alternate-owned-home')
    fs.mkdirSync(alternateHome)
    createStudioCa(alternateHome)
    const alternateDatabase = createNssDb(alternateHome, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture, { HOME: alternateHome })

    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.existsSync(path.join(canonicalDatabase, '.studio-test-entry')), false)
    assert.equal(fs.readFileSync(path.join(alternateDatabase, '.studio-test-entry'), 'utf8'), 'MATCH\n')
  } finally {
    removeFixture(fixture)
  }
})

test('ignores inherited PATH and TMPDIR tools while cleaning through fixed tool paths', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')
    const hostileBin = path.join(fixture.fixtureRoot, 'hostile-bin')
    const hostileTmp = path.join(fixture.fixtureRoot, 'hostile-tmp')
    const canary = path.join(fixture.fixtureRoot, 'path-tool-ran')
    fs.mkdirSync(hostileBin)
    fs.mkdirSync(hostileTmp)
    fs.writeFileSync(path.join(hostileTmp, 'keep-me'), 'not a cleanup target\n')
    for (const tool of [
      'timeout',
      'find',
      'mktemp',
      'chmod',
      'rm',
      'certutil',
      'openssl',
      'id',
      'getent',
      'head',
      'stat'
    ]) {
      writeExecutable(
        path.join(hostileBin, tool),
        `#!/bin/bash
printf '%s\\n' "$0" >>"$STUDIO_TEST_PATH_CANARY"
exit 99
`
      )
    }

    const result = runCleanup(fixture, {
      PATH: hostileBin,
      TMPDIR: hostileTmp,
      STUDIO_TEST_PATH_CANARY: canary
    })

    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), false)
    assert.equal(fs.existsSync(canary), false)
    assert.deepEqual(fs.readdirSync(hostileTmp), ['keep-me'])
    assert.deepEqual(fs.readdirSync(fixture.trustedTempParent), [])
  } finally {
    removeFixture(fixture)
  }
})

test('refuses an unvalidated temporary directory without arming a destructive trap', () => {
  const fixture = createFixture()
  try {
    const outsideDirectory = path.join(fixture.fixtureRoot, 'not-the-trusted-temp-parent')
    const sentinel = path.join(outsideDirectory, 'keep-me')
    fs.mkdirSync(outsideDirectory)
    fs.writeFileSync(sentinel, 'preserve this directory\n')

    const result = runCleanup(fixture, { STUDIO_TEST_MKTEMP_RESULT: outsideDirectory })

    assert.equal(result.status, 1)
    assert.match(result.stderr, /refusing an unsafe private browser trust cleanup directory/)
    assert.equal(fs.readFileSync(sentinel, 'utf8'), 'preserve this directory\n')
    assert.deepEqual(fs.readdirSync(fixture.trustedTempParent), [])
  } finally {
    removeFixture(fixture)
  }
})

test('rejects a symlinked CA file and leaves the browser entry untouched', () => {
  const fixture = createFixture()
  try {
    const caDir = path.join(fixture.home, '.studio', 'certificates')
    fs.mkdirSync(caDir, { recursive: true })
    const externalCa = path.join(fixture.fixtureRoot, 'external-ca.crt')
    fs.writeFileSync(externalCa, 'outside fixture CA\n')
    fs.symlinkSync(externalCa, path.join(caDir, 'studio-ca.crt'))
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /cannot fingerprint a safe, regular current-user Studio CA file/)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), true)
  } finally {
    removeFixture(fixture)
  }
})

test('rejects a symlinked Chromium database and never mutates its target', () => {
  const fixture = createFixture()
  try {
    const externalDb = path.join(fixture.fixtureRoot, 'external-nssdb')
    fs.mkdirSync(externalDb)
    fs.writeFileSync(path.join(externalDb, 'cert9.db'), 'outside database\n')
    fs.writeFileSync(path.join(externalDb, '.studio-test-entry'), 'MATCH\n')
    fs.mkdirSync(path.join(fixture.home, '.pki'))
    fs.symlinkSync(externalDb, path.join(fixture.home, '.pki', 'nssdb'))

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /refusing unsafe NSS database path/)
    assert.equal(fs.readFileSync(path.join(externalDb, '.studio-test-entry'), 'utf8'), 'MATCH\n')
  } finally {
    removeFixture(fixture)
  }
})

test('rejects a symlinked Firefox profile and never mutates its target', () => {
  const fixture = createFixture()
  try {
    const externalDb = path.join(fixture.fixtureRoot, 'external-firefox-profile')
    fs.mkdirSync(externalDb)
    fs.writeFileSync(path.join(externalDb, 'cert9.db'), 'outside database\n')
    fs.writeFileSync(path.join(externalDb, '.studio-test-entry'), 'MATCH\n')
    const firefoxRoot = path.join(fixture.home, '.mozilla', 'firefox')
    fs.mkdirSync(firefoxRoot, { recursive: true })
    fs.symlinkSync(externalDb, path.join(firefoxRoot, 'unsafe.default'))

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /refusing unsafe NSS database path/)
    assert.equal(fs.readFileSync(path.join(externalDb, '.studio-test-entry'), 'utf8'), 'MATCH\n')
  } finally {
    removeFixture(fixture)
  }
})

test('surfaces a partial cleanup failure after preserving the entry', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture, { STUDIO_TEST_DELETE_FAIL: '1' })

    assert.equal(result.status, 1)
    assert.match(result.stderr, /package was removed, but current-user browser trust cleanup was incomplete/)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), true)
  } finally {
    removeFixture(fixture)
  }
})

test('fails closed when the initial Studio nickname lookup times out', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture, { STUDIO_TEST_LOOKUP_FAIL_STATUS: '124' })

    assert.equal(result.status, 1)
    assert.match(result.stderr, /Studio certificate lookup timed out or failed/)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), true)
  } finally {
    removeFixture(fixture)
  }
})

test('fails closed when the post-delete Studio nickname lookup times out', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const database = createNssDb(fixture.home, path.join('.pki', 'nssdb'), 'MATCH')

    const result = runCleanup(fixture, { STUDIO_TEST_VERIFY_LOOKUP_FAIL_STATUS: '124' })

    assert.equal(result.status, 1)
    assert.match(result.stderr, /could not verify Studio trust removal/)
    assert.match(result.stderr, /current-user browser trust cleanup was incomplete/)
    assert.equal(fs.existsSync(path.join(database, '.studio-test-entry')), false)
  } finally {
    removeFixture(fixture)
  }
})

test('caps Firefox profile cleanup and reports uninspected candidates', () => {
  const fixture = createFixture()
  try {
    createStudioCa(fixture.home)
    const firefoxRoot = path.join(fixture.home, '.mozilla', 'firefox')
    const databases = []
    for (let index = 0; index < 25; index += 1) {
      const profile = `${String(index).padStart(3, '0')}.default`
      databases.push(createNssDb(fixture.home, path.join('.mozilla', 'firefox', profile), 'MATCH'))
    }

    const result = runCleanup(fixture)

    assert.equal(result.status, 1)
    assert.match(result.stderr, /refusing to inspect more than 24 Firefox profile databases/)
    const remainingEntries = databases.filter((database) =>
      fs.existsSync(path.join(database, '.studio-test-entry'))
    )
    assert.equal(remainingEntries.length, 1)
    assert.equal(fs.readFileSync(path.join(remainingEntries[0], '.studio-test-entry'), 'utf8'), 'MATCH\n')
    assert.equal(fs.existsSync(firefoxRoot), true)
  } finally {
    removeFixture(fixture)
  }
})
