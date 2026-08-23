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

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, { mode: 0o755 })
}

function createFixture() {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-trust-cleanup-'))
  const home = path.join(fixtureRoot, 'home')
  const bin = path.join(fixtureRoot, 'bin')
  const timeoutLog = path.join(fixtureRoot, 'timeout.log')
  fs.mkdirSync(home)
  fs.mkdirSync(bin)

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
  [[ -f $entry ]] || exit 1
  if [[ $ascii == true ]]; then
    cat "$entry"
  fi
elif [[ $action == "-D" && $nickname == "${studioNickname}" ]]; then
  [[ -f $entry ]] || exit 1
  [[ \${STUDIO_TEST_DELETE_FAIL:-0} != 1 ]] || exit 3
  rm -f -- "$entry"
else
  exit 2
fi
`
  )

  return { fixtureRoot, home, bin, timeoutLog }
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
  return spawnSync(cleanupScript, [], {
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: fixture.home,
      PATH: `${fixture.bin}:${process.env.PATH}`,
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
