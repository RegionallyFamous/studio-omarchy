const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const installers = [
  ['public installer', path.join(root, 'install.sh')],
  ['packaged updater', path.join(root, 'packaging', 'arch', 'studio-omarchy-update')]
]
const version = '9.8.7'
const packageName = `wordpress-studio-omarchy-${version}-2-x86_64.pkg.tar.zst`
const checksumName = `${packageName}.sha256`
const packageLimit = 64
const copyLimit = packageLimit + 1
const verifiedPackage = Buffer.from('V'.repeat(packageLimit))
const undisclosedMarker = 'ATTACK-CONTENT-MUST-NOT-BE-DISCLOSED'

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, { mode: 0o755 })
}

function checksum(contents) {
  return crypto.createHash('sha256').update(contents).digest('hex')
}

function writeChecksum(file, contents) {
  fs.writeFileSync(file, `${checksum(contents)}  ${packageName}\n`)
}

function commandPath(name) {
  const result = spawnSync(`command -v ${name}`, [], {
    shell: true,
    encoding: 'utf8'
  })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trim()
}

function createFixture({ preopenMutation = '', holdStage = '' } = {}) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-privileged-handoff-'))
  const bin = path.join(fixtureRoot, 'bin')
  const downloads = path.join(fixtureRoot, 'downloads')
  const fixtures = path.join(fixtureRoot, 'fixtures')
  const privilegedTmp = path.join(fixtureRoot, 'privileged-tmp')
  const promptMarker = path.join(fixtureRoot, 'sudo-prompt-reached')
  const promptRelease = path.join(fixtureRoot, 'sudo-prompt-release')
  const sudoExecutable = path.join(fixtureRoot, 'sudo-executable')
  const rootScriptLog = path.join(fixtureRoot, 'root-script')
  const fakeBashMarker = path.join(fixtureRoot, 'path-injected-bash-ran')
  const ddLimitLog = path.join(fixtureRoot, 'dd-limit')
  const ddBytesLog = path.join(fixtureRoot, 'dd-bytes')
  const ddSourceLog = path.join(fixtureRoot, 'dd-source')
  const pacmanLog = path.join(fixtureRoot, 'pacman-command')
  const installedBytes = path.join(fixtureRoot, 'installed-package')
  const releaseFile = path.join(fixtures, 'release.json')
  const packageFixture = path.join(fixtures, packageName)
  const checksumFixture = path.join(fixtures, checksumName)
  const preopenSymlinkTarget = path.join(fixtureRoot, 'preopen-symlink-target')
  const caBundle = path.join(fixtureRoot, 'system-ca-bundle')

  for (const directory of [bin, downloads, fixtures, privilegedTmp]) {
    fs.mkdirSync(directory)
  }
  fs.chmodSync(downloads, 0o700)
  fs.writeFileSync(packageFixture, verifiedPackage)
  fs.writeFileSync(preopenSymlinkTarget, verifiedPackage)
  fs.writeFileSync(caBundle, 'test-only CA bundle placeholder\n')
  writeChecksum(checksumFixture, verifiedPackage)
  fs.writeFileSync(
    releaseFile,
    JSON.stringify({
      tag_name: `omarchy-v${version}`,
      assets: [{ name: packageName }, { name: checksumName }]
    }) + '\n'
  )
  if (preopenMutation) fs.writeFileSync(path.join(fixtureRoot, 'preopen-mutation'), preopenMutation)
  if (holdStage) fs.writeFileSync(path.join(fixtureRoot, `hold-${holdStage}`), '')

  writeExecutable(
    path.join(bin, 'bash'),
    `#!/bin/bash
: >"$STUDIO_HANDOFF_FAKE_BASH_MARKER"
exit 97
`
  )
  writeExecutable(
    path.join(bin, 'timeout'),
    `#!/bin/bash
set -euo pipefail
shift 3
exec "$@"
`
  )
  writeExecutable(
    path.join(bin, 'base64'),
    `#!/bin/bash
set -euo pipefail
if [[ \${1:-} == "--wrap=0" && $# == 1 ]]; then
  /usr/bin/base64 | /usr/bin/tr -d '\\n'
elif [[ \${1:-} == "--decode" && $# == 1 ]]; then
  /usr/bin/base64 -d
else
  exit 2
fi
`
  )
  writeExecutable(
    path.join(bin, 'dd-no-follow'),
    `#!/bin/bash
set -euo pipefail
input=
output=
count=
for argument in "$@"; do
  case $argument in
    if=*) input=\${argument#if=} ;;
    of=*) output=\${argument#of=} ;;
    count=*) count=\${argument#count=} ;;
    iflag=nofollow,nonblock,fullblock,count_bytes|bs=1M|status=none) ;;
    *) exit 2 ;;
  esac
done
[[ -n $input && -n $output && $count =~ ^[1-9][0-9]*$ ]]
if [[ -L $input ]]; then
  printf 'symlink|%s\n' "$input" >"$STUDIO_HANDOFF_DD_SOURCE_LOG"
else
  printf 'other|%s\n' "$input" >"$STUDIO_HANDOFF_DD_SOURCE_LOG"
fi
[[ ! -L $input ]] || exit 1
printf '%s\n' "$count" >"$STUDIO_HANDOFF_DD_LIMIT_LOG"
if /bin/dd if="$input" of="$output" bs=1 count="$count" 2>/dev/null; then
  wc -c <"$output" | tr -d ' ' >"$STUDIO_HANDOFF_DD_BYTES_LOG"
else
  status=$?
  if [[ -e $output ]]; then
    wc -c <"$output" | tr -d ' ' >"$STUDIO_HANDOFF_DD_BYTES_LOG"
  fi
  exit "$status"
fi
`
  )
  writeExecutable(
    path.join(bin, 'gnu-stat'),
    `#!/bin/bash
set -euo pipefail
[[ \${1:-} == "-c" && \${3:-} == "--" && $# == 4 ]]
format=$2
target=$4
if [[ $format == "%F|%u|%g|%a|%h|%s" ]]; then
  if metadata=$(/usr/bin/stat -c '%F|%a|%h|%s' -- "$target" 2>/dev/null); then
    IFS='|' read -r type mode links size <<<"$metadata"
    [[ $type == "regular file" ]]
  else
    IFS='|' read -r type mode links size < <(/usr/bin/stat -f '%HT|%Lp|%l|%z' "$target")
    [[ $type == "Regular File" ]]
  fi
  printf 'regular file|0|0|%s|%s|%s\n' "$mode" "$links" "$size"
else
  exit 2
fi
`
  )
  writeExecutable(
    path.join(bin, 'chmod'),
    `#!/bin/bash
set -euo pipefail
[[ \${1:-} == "600" && \${2:-} == "--" && $# == 3 ]]
exec /bin/chmod "$1" "$3"
`
  )
  writeExecutable(
    path.join(bin, 'curl'),
    `#!/bin/bash
set -euo pipefail
fixture_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=
url=
[[ \${1:-} == "--disable" ]]
shift
while (( $# > 0 )); do
  case $1 in
    --output)
      output=$2
      shift 2
      ;;
    --cacert|--connect-timeout|--max-time|--max-filesize|--proto|--proto-redir)
      shift 2
      ;;
    --fail|--show-error|--location)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[[ -n $url ]]
hold_after_output() {
  local stage=$1
  if [[ -e $fixture_root/hold-$stage ]]; then
    : >"$fixture_root/$stage-bytes-emitted"
    for (( attempt = 0; attempt < 1000; attempt++ )); do
      [[ ! -e $fixture_root/$stage-continue ]] || return 0
      /bin/sleep 0.01
    done
    exit 124
  fi
}

if [[ $url == */releases/latest ]]; then
  [[ -z $output ]]
  /bin/cat "$fixture_root/fixtures/release.json"
  hold_after_output release
elif [[ $url == */"${checksumName}" ]]; then
  [[ -z $output ]]
  /bin/cat "$fixture_root/fixtures/${checksumName}"
  hold_after_output checksum
else
  [[ -n $output ]]
  /bin/cp -- "$fixture_root/fixtures/\${url##*/}" "$output"
fi
if [[ $url == */"${checksumName}" ]]; then
  mutation=
  [[ ! -f $fixture_root/preopen-mutation ]] || IFS= read -r mutation <"$fixture_root/preopen-mutation"
  case $mutation in
    '') ;;
    symlink)
      /bin/rm -f -- "$fixture_root/downloads/${packageName}"
      /bin/ln -s -- "$fixture_root/preopen-symlink-target" "$fixture_root/downloads/${packageName}"
      ;;
    fifo)
      /bin/rm -f -- "$fixture_root/downloads/${packageName}"
      /usr/bin/mkfifo "$fixture_root/downloads/${packageName}"
      ;;
    *) exit 2 ;;
  esac
fi
`
  )
  writeExecutable(
    path.join(bin, 'sudo'),
    `#!/bin/bash
set -euo pipefail
printf '%s\n' "\${1:-}" >"$STUDIO_HANDOFF_SUDO_EXECUTABLE"
: >"$STUDIO_HANDOFF_PROMPT_MARKER"
for (( attempt = 0; attempt < 1000; attempt++ )); do
  [[ ! -e $STUDIO_HANDOFF_PROMPT_RELEASE ]] || break
  /bin/sleep 0.01
done
[[ -e $STUDIO_HANDOFF_PROMPT_RELEASE ]] || exit 124

[[ \${1:-} == "/usr/bin/bash" && \${2:-} == "-c" && -n \${3:-} ]]
script=$3
printf '%s' "$script" >"$STUDIO_HANDOFF_ROOT_SCRIPT_LOG"
shift 3
script=\${script//\\/usr\\/bin\\/bash/\\/bin\\/bash}
script=\${script//\\/usr\\/bin\\/chmod/$STUDIO_HANDOFF_TEST_BIN\\/chmod}
script=\${script//\\/usr\\/bin\\/dd/$STUDIO_HANDOFF_TEST_BIN\\/dd-no-follow}
script=\${script//\\/usr\\/bin\\/pacman/$STUDIO_HANDOFF_TEST_BIN\\/pacman}
script=\${script//\\/usr\\/bin\\/rm/\\/bin\\/rm}
script=\${script//\\/usr\\/bin\\/sha256sum/$STUDIO_HANDOFF_SHA256SUM}
script=\${script//\\/usr\\/bin\\/stat/$STUDIO_HANDOFF_TEST_BIN\\/gnu-stat}
script=\${script//\\/usr\\/bin\\/timeout/$STUDIO_HANDOFF_TEST_BIN\\/timeout}
script=\${script//\\/var\\/tmp/$STUDIO_HANDOFF_PRIVILEGED_TMP}
exec /bin/bash -c "$script" "$@"
`
  )
  writeExecutable(
    path.join(bin, 'pacman'),
    `#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >"$STUDIO_HANDOFF_PACMAN_LOG"
package_path=\${!#}
[[ -f $package_path && ! -L $package_path ]]
/bin/cp -- "$package_path" "$STUDIO_HANDOFF_INSTALLED_BYTES"
`
  )
  writeExecutable(
    path.join(bin, 'uname'),
    `#!/bin/bash
set -euo pipefail
[[ \${1:-} == "-m" ]]
printf '%s\n' x86_64
`
  )

  return {
    fixtureRoot,
    bin,
    downloads,
    fixtures,
    privilegedTmp,
    promptMarker,
    promptRelease,
    sudoExecutable,
    rootScriptLog,
    fakeBashMarker,
    ddLimitLog,
    ddBytesLog,
    ddSourceLog,
    pacmanLog,
    installedBytes,
    releaseFile,
    packageFixture,
    checksumFixture,
    packagePath: path.join(downloads, packageName),
    checksumPath: path.join(downloads, checksumName),
    preopenMutation,
    preopenSymlinkTarget,
    caBundle,
    holdStage,
    stageBytesEmitted: holdStage ? path.join(fixtureRoot, `${holdStage}-bytes-emitted`) : '',
    stageContinue: holdStage ? path.join(fixtureRoot, `${holdStage}-continue`) : ''
  }
}

function sha256sumPath() {
  return commandPath('sha256sum')
}

function adaptInstaller(installer, fixture) {
  const source = fs.readFileSync(installer, 'utf8')
  const handoffStart = "  /usr/bin/sudo /usr/bin/bash -c '\n"
  const handoffEnd = `\n' bash "$source_path" "$package_name" "$expected_hash" "$max_bytes"`
  const startIndex = source.indexOf(handoffStart)
  const endIndex = source.indexOf(handoffEnd, startIndex)
  assert.notEqual(startIndex, -1, 'production installer has no fixed privileged handoff start')
  assert.notEqual(endIndex, -1, 'production installer has no fixed privileged handoff end')
  assert.match(source, /^#!\/bin\/bash -p\n/)
  assert.match(source, /readonly PATH='\/usr\/bin:\/usr\/sbin'/)
  assert.match(source, /\/usr\/bin\/curl --disable --fail/)
  assert.match(source, /\/usr\/bin\/env -i PATH="\$PATH" LC_ALL="\$LC_ALL"/)
  assert.match(source, /\/usr\/bin\/base64 --wrap=0/)
  assert.doesNotMatch(source, /release_file=.*release\.json/)
  assert.doesNotMatch(source, /checksum_path=/)

  const callerPaths = new Map([
    ['/etc/ssl/certs/ca-certificates.crt', fixture.caBundle],
    ['/usr/bin/awk', commandPath('awk')],
    ['/usr/bin/base64', path.join(fixture.bin, 'base64')],
    ['/usr/bin/chmod', commandPath('chmod')],
    ['/usr/bin/curl', path.join(fixture.bin, 'curl')],
    ['/usr/bin/cut', commandPath('cut')],
    ['/usr/bin/env', commandPath('env')],
    ['/usr/bin/head', commandPath('head')],
    ['/usr/bin/jq', commandPath('jq')],
    ['/usr/bin/mkdir', commandPath('mkdir')],
    ['/usr/bin/mktemp', commandPath('mktemp')],
    ['/usr/bin/mv', commandPath('mv')],
    ['/usr/bin/pacman', path.join(fixture.bin, 'pacman')],
    ['/usr/bin/realpath', commandPath('realpath')],
    ['/usr/bin/rm', commandPath('rm')],
    ['/usr/bin/sha256sum', sha256sumPath()],
    ['/usr/bin/sudo', path.join(fixture.bin, 'sudo')],
    ['/usr/bin/timeout', path.join(fixture.bin, 'timeout')],
    ['/usr/bin/uname', path.join(fixture.bin, 'uname')],
    ['/usr/bin/wc', commandPath('wc')]
  ])
  const replaceCallerPaths = input => {
    let output = input
    for (const [productionPath, testPath] of callerPaths) {
      output = output.replaceAll(productionPath, testPath)
    }
    return output
  }

  const privilegedEnd = endIndex + handoffEnd.length
  const callerPrefix = replaceCallerPaths(source.slice(0, startIndex))
  const privilegedHandoff = source
    .slice(startIndex, privilegedEnd)
    .replace('/usr/bin/sudo /usr/bin/bash', `${path.join(fixture.bin, 'sudo')} /usr/bin/bash`)
  const callerSuffix = replaceCallerPaths(source.slice(privilegedEnd))
  const adapted = path.join(fixture.fixtureRoot, 'adapted-installer')
  writeExecutable(adapted, callerPrefix + privilegedHandoff + callerSuffix)
  return adapted
}

function startInstaller(installer, fixture) {
  const adaptedInstaller = adaptInstaller(installer, fixture)
  const child = spawn(adaptedInstaller, [], {
    env: {
      ...process.env,
      PATH: `${fixture.bin}:${process.env.PATH}`,
      STUDIO_OMARCHY_TEST_MODE: '1',
      STUDIO_OMARCHY_TEST_PACKAGE_MAX_BYTES: String(packageLimit),
      STUDIO_OMARCHY_DOWNLOAD_DIR: fixture.downloads,
      STUDIO_HANDOFF_FIXTURES: fixture.fixtures,
      STUDIO_HANDOFF_RELEASE_FILE: fixture.releaseFile,
      STUDIO_HANDOFF_PREOPEN_MUTATION: fixture.preopenMutation,
      STUDIO_HANDOFF_DOWNLOAD_PACKAGE: fixture.packagePath,
      STUDIO_HANDOFF_PREOPEN_SYMLINK_TARGET: fixture.preopenSymlinkTarget,
      STUDIO_HANDOFF_PROMPT_MARKER: fixture.promptMarker,
      STUDIO_HANDOFF_PROMPT_RELEASE: fixture.promptRelease,
      STUDIO_HANDOFF_SUDO_EXECUTABLE: fixture.sudoExecutable,
      STUDIO_HANDOFF_ROOT_SCRIPT_LOG: fixture.rootScriptLog,
      STUDIO_HANDOFF_FAKE_BASH_MARKER: fixture.fakeBashMarker,
      STUDIO_HANDOFF_TEST_BIN: fixture.bin,
      STUDIO_HANDOFF_PRIVILEGED_TMP: fixture.privilegedTmp,
      STUDIO_HANDOFF_SHA256SUM: sha256sumPath(),
      STUDIO_HANDOFF_DD_LIMIT_LOG: fixture.ddLimitLog,
      STUDIO_HANDOFF_DD_BYTES_LOG: fixture.ddBytesLog,
      STUDIO_HANDOFF_DD_SOURCE_LOG: fixture.ddSourceLog,
      STUDIO_HANDOFF_PACMAN_LOG: fixture.pacmanLog,
      STUDIO_HANDOFF_INSTALLED_BYTES: fixture.installedBytes
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  let stdout = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', chunk => { stdout += chunk })
  child.stderr.on('data', chunk => { stderr += chunk })
  const completion = new Promise(resolve => {
    child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr }))
  })
  return { child, completion }
}

async function waitForFile(file, completion, maxMilliseconds = 5000) {
  const deadline = Date.now() + maxMilliseconds
  while (!fs.existsSync(file)) {
    const earlyResult = await Promise.race([
      completion,
      new Promise(resolve => setTimeout(() => resolve(null), 10))
    ])
    if (earlyResult) {
      assert.fail(`installer exited before the authentication boundary: ${earlyResult.stderr}`)
    }
    if (Date.now() >= deadline) {
      assert.fail(`timed out waiting for ${file}`)
    }
  }
}

async function waitForResult(completion, maxMilliseconds = 10000) {
  const timedOut = Symbol('timed-out')
  const result = await Promise.race([
    completion,
    new Promise(resolve => setTimeout(() => resolve(timedOut), maxMilliseconds))
  ])
  assert.notEqual(result, timedOut, 'installer exceeded the regression-test deadline')
  return result
}

function assertNoDisclosure(result) {
  const output = `${result.stdout}\n${result.stderr}`
  assert.equal(output.includes(undisclosedMarker), false, output)
}

function assertNoInstallation(fixture) {
  assert.equal(fs.existsSync(fixture.pacmanLog), false, 'unsafe input reached pacman')
  assert.equal(fs.existsSync(fixture.installedBytes), false, 'unsafe package bytes were installed')
}

function assertFixedPrivilegedShell(fixture) {
  assert.equal(fs.readFileSync(fixture.sudoExecutable, 'utf8').trim(), '/usr/bin/bash')
  assert.equal(fs.existsSync(fixture.fakeBashMarker), false, 'PATH-injected bash ran after sudo')
  const script = fs.readFileSync(fixture.rootScriptLog, 'utf8')
  assert.match(script, /copy_limit=\$\(\(max_bytes \+ 1\)\)/)
  assert.match(script, /trap cleanup EXIT/)
  assert.match(script, /\/usr\/bin\/rm -rf -- "\$staging_dir"/)
  assert.equal(
    script.match(/\/usr\/bin\/timeout --signal=TERM --kill-after=5s 120s/g)?.length,
    2,
    'both privileged reads must have a fixed absolute timeout and deadline'
  )
  assert.match(script, /\/usr\/bin\/dd[\s\S]+count="\$copy_limit"/)
  assert.match(script, /\/usr\/bin\/chmod 600 -- "\$staged_path"/)
  assert.match(script, /\/usr\/bin\/stat -c "%F\|%u\|%g\|%a\|%h\|%s" -- "\$staged_path"/)
  assert.match(script, /\$staged_uid == 0 && \$staged_gid == 0/)
  assert.match(script, /\$staged_mode == 600 && \$staged_links == 1/)
  assert.match(script, /\[\[ \$staged_hash == "\$expected_hash" \]\]/)
  assert.match(script, /\/usr\/bin\/pacman -U --needed --noconfirm -- "\$staged_path"/)
  assert.deepEqual(
    fs.readdirSync(fixture.privilegedTmp),
    [],
    'privileged staging must be empty after every completed handoff'
  )
}

async function exerciseAtPrompt(installer, mutate) {
  const fixture = createFixture()
  const { child, completion } = startInstaller(installer, fixture)
  let writer
  try {
    await waitForFile(fixture.promptMarker, completion)
    assert.equal(fs.readFileSync(fixture.packagePath).length, packageLimit)
    const pending = await Promise.race([
      completion.then(() => false),
      new Promise(resolve => setTimeout(() => resolve(true), 50))
    ])
    assert.equal(pending, true, 'fake sudo did not hold the authentication boundary')

    writer = await mutate(fixture)
    fs.writeFileSync(fixture.promptRelease, '')
    const result = await waitForResult(completion)
    return { fixture, result, writer }
  } catch (error) {
    child.kill('SIGKILL')
    fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    throw error
  } finally {
    if (writer && writer.exitCode === null && writer.signalCode === null) {
      writer.kill('SIGKILL')
    }
  }
}

async function exerciseBeforePrompt(installer, preopenMutation) {
  const fixture = createFixture({ preopenMutation })
  const { child, completion } = startInstaller(installer, fixture)
  try {
    const result = await waitForResult(completion)
    return { fixture, result }
  } catch (error) {
    child.kill('SIGKILL')
    fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    throw error
  }
}

async function exerciseDuringMemoryDownload(installer, stage, mutate) {
  const fixture = createFixture({ holdStage: stage })
  const { child, completion } = startInstaller(installer, fixture)
  try {
    await waitForFile(fixture.stageBytesEmitted, completion)
    await mutate(fixture)
    fs.writeFileSync(fixture.stageContinue, '')
    return { fixture, child, completion }
  } catch (error) {
    child.kill('SIGKILL')
    fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    throw error
  }
}

for (const [label, installer] of installers) {
  test(`${label} pins release metadata in memory before a same-UID replacement`, async () => {
    const { fixture, child, completion } = await exerciseDuringMemoryDownload(
      installer,
      'release',
      async current => {
        assert.equal(fs.existsSync(path.join(current.downloads, 'release.json')), false)
        const maliciousRelease = `${undisclosedMarker}: malformed release metadata\n`
        fs.writeFileSync(current.releaseFile, maliciousRelease)
        fs.writeFileSync(path.join(current.downloads, 'release.json'), maliciousRelease)
      }
    )
    try {
      await waitForFile(fixture.promptMarker, completion)
      fs.writeFileSync(fixture.promptRelease, '')
      const result = await waitForResult(completion)
      assert.equal(result.status, 0, result.stderr)
      assertFixedPrivilegedShell(fixture)
      assert.deepEqual(fs.readFileSync(fixture.installedBytes), verifiedPackage)
      assertNoDisclosure(result)
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} rejects a package and checksum replacement before checksum parsing`, async () => {
    const maliciousPackage = Buffer.from(
      (undisclosedMarker + '|').repeat(3).slice(0, packageLimit)
    )
    const { fixture, child, completion } = await exerciseDuringMemoryDownload(
      installer,
      'checksum',
      async current => {
        assert.equal(fs.existsSync(current.checksumPath), false)
        const replacementPackage = path.join(current.fixtureRoot, 'pre-parse-package')
        fs.writeFileSync(replacementPackage, maliciousPackage)
        fs.renameSync(replacementPackage, current.packagePath)
        writeChecksum(current.checksumFixture, maliciousPackage)
        writeChecksum(current.checksumPath, maliciousPackage)
      }
    )
    try {
      const result = await waitForResult(completion)
      assert.notEqual(result.status, 0, 'pre-parse replacement unexpectedly installed')
      assert.equal(fs.existsSync(fixture.promptMarker), false, 'pre-parse replacement reached sudo')
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} uses fixed sudo argv and preserves the exact package-byte boundary`, async () => {
    const { fixture, result } = await exerciseAtPrompt(installer, async () => undefined)
    try {
      assert.equal(result.status, 0, result.stderr)
      assert.equal(result.signal, null)
      assertFixedPrivilegedShell(fixture)
      assert.equal(fs.readFileSync(fixture.ddLimitLog, 'utf8').trim(), String(copyLimit))
      assert.equal(fs.readFileSync(fixture.ddBytesLog, 'utf8').trim(), String(packageLimit))
      assert.deepEqual(fs.readFileSync(fixture.installedBytes), verifiedPackage)
      assert.match(fs.readFileSync(fixture.pacmanLog, 'utf8'), /^-U --needed --noconfirm -- /)
      assert.match(fs.readFileSync(fixture.pacmanLog, 'utf8'), /studio-omarchy-install\./)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} rejects matching regular-file replacements at the authentication boundary`, async () => {
    const maliciousPackage = Buffer.from(
      (undisclosedMarker + '|').repeat(3).slice(0, packageLimit)
    )
    assert.equal(maliciousPackage.length, packageLimit)
    const { fixture, result } = await exerciseAtPrompt(installer, async current => {
      const replacementPackage = path.join(current.fixtureRoot, 'replacement-package')
      const replacementChecksum = path.join(current.fixtureRoot, 'replacement-checksum')
      fs.writeFileSync(replacementPackage, maliciousPackage)
      writeChecksum(replacementChecksum, maliciousPackage)
      fs.renameSync(replacementPackage, current.packagePath)
      fs.renameSync(replacementChecksum, current.checksumPath)
    })
    try {
      assert.notEqual(result.status, 0, 'replaced package unexpectedly installed')
      assertFixedPrivilegedShell(fixture)
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} rejects a post-authentication symlink swap before pacman`, async () => {
    const { fixture, result } = await exerciseAtPrompt(installer, async current => {
      const symlinkTarget = path.join(current.fixtureRoot, 'verified-but-untrusted-target')
      fs.writeFileSync(symlinkTarget, verifiedPackage)
      fs.unlinkSync(current.packagePath)
      fs.symlinkSync(symlinkTarget, current.packagePath)
    })
    try {
      assert.notEqual(
        result.status,
        0,
        JSON.stringify({
          stderr: result.stderr,
          sourceIsSymlink: fs.lstatSync(fixture.packagePath).isSymbolicLink(),
          ddLimit: fs.existsSync(fixture.ddLimitLog)
            ? fs.readFileSync(fixture.ddLimitLog, 'utf8').trim()
            : 'absent',
          ddSource: fs.existsSync(fixture.ddSourceLog)
            ? fs.readFileSync(fixture.ddSourceLog, 'utf8').trim()
            : 'absent',
          installedBytes: fs.existsSync(fixture.installedBytes)
            ? fs.readFileSync(fixture.installedBytes, 'utf8')
            : 'absent'
        })
      )
      assertFixedPrivilegedShell(fixture)
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} rejects a post-authentication special-file swap before pacman`, async () => {
    const { fixture, result, writer } = await exerciseAtPrompt(installer, async current => {
      fs.unlinkSync(current.packagePath)
      const mkfifo = spawnSync('mkfifo', [current.packagePath], { encoding: 'utf8' })
      assert.equal(mkfifo.status, 0, mkfifo.stderr)
      return spawn(
        '/bin/bash',
        ['-c', 'printf %s "$STUDIO_HANDOFF_SPECIAL_CONTENT" >"$STUDIO_HANDOFF_SPECIAL_PATH"'],
        {
          env: {
            ...process.env,
            STUDIO_HANDOFF_SPECIAL_CONTENT: undisclosedMarker,
            STUDIO_HANDOFF_SPECIAL_PATH: current.packagePath
          },
          stdio: 'ignore'
        }
      )
    })
    try {
      if (writer && writer.exitCode === null && writer.signalCode === null) {
        writer.kill('SIGKILL')
      }
      assert.notEqual(result.status, 0, 'special-file package unexpectedly installed')
      assertFixedPrivilegedShell(fixture)
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} bounds a one-over package replacement to max plus one byte`, async () => {
    const oneOverPackage = Buffer.from(
      (undisclosedMarker + '|').repeat(3).slice(0, copyLimit)
    )
    assert.equal(oneOverPackage.length, copyLimit)
    const { fixture, result } = await exerciseAtPrompt(installer, async current => {
      const replacement = path.join(current.fixtureRoot, 'one-over-package')
      fs.writeFileSync(replacement, oneOverPackage)
      fs.renameSync(replacement, current.packagePath)
    })
    try {
      assert.notEqual(result.status, 0, 'one-over package unexpectedly installed')
      assertFixedPrivilegedShell(fixture)
      assert.equal(fs.readFileSync(fixture.ddLimitLog, 'utf8').trim(), String(copyLimit))
      assert.equal(fs.readFileSync(fixture.ddBytesLog, 'utf8').trim(), String(copyLimit))
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  test(`${label} rejects same-inode truncation during the authentication delay`, async () => {
    const { fixture, result } = await exerciseAtPrompt(installer, async current => {
      fs.truncateSync(current.packagePath, 0)
    })
    try {
      assert.notEqual(result.status, 0, 'truncated package unexpectedly installed')
      assertFixedPrivilegedShell(fixture)
      assertNoInstallation(fixture)
      assertNoDisclosure(result)
    } finally {
      fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
    }
  })

  for (const mutation of ['symlink', 'fifo']) {
    test(`${label} rejects a ${mutation} present before the privileged handoff`, async () => {
      const { fixture, result } = await exerciseBeforePrompt(installer, mutation)
      try {
        assert.notEqual(result.status, 0, `${mutation} unexpectedly reached sudo`)
        assert.equal(fs.existsSync(fixture.promptMarker), false, `${mutation} reached sudo`)
        assert.equal(fs.existsSync(fixture.fakeBashMarker), false)
        assertNoInstallation(fixture)
        assertNoDisclosure(result)
      } finally {
        fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
      }
    })
  }
}
