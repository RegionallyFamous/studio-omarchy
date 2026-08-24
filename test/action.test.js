const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const actionScript = path.join(root, 'scripts', 'action.sh')
const actionSource = fs.readFileSync(actionScript, 'utf8')

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, { mode: 0o755 })
}

function createFixture({ symlinkLauncher = false, packagedLauncher = false } = {}) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-action-'))
  const pluginRoot = path.join(fixtureRoot, 'plugin')
  const scriptsDir = path.join(pluginRoot, 'scripts')
  const packagingDir = path.join(pluginRoot, 'packaging', 'arch')
  const systemBin = path.join(fixtureRoot, 'system-bin')
  const attackerBin = path.join(fixtureRoot, 'attacker-bin')
  const omarchyRoot = path.join(fixtureRoot, 'omarchy')
  const omarchyBin = path.join(omarchyRoot, 'bin')
  const logPath = path.join(fixtureRoot, 'action.log')
  const focusPath = path.join(fixtureRoot, 'focus.log')
  const attackPath = path.join(fixtureRoot, 'attacker.log')
  const childEnvPath = path.join(fixtureRoot, 'child-env.log')
  const processEnviron = path.join(fixtureRoot, 'process-environ')

  for (const directory of [scriptsDir, packagingDir, systemBin, attackerBin, omarchyBin]) {
    fs.mkdirSync(directory, { recursive: true })
  }

  assert.equal(systemBin.includes("'"), false)
  let testActionSource = actionSource.replace(
    "readonly SYSTEM_BIN='/usr/bin'",
    `readonly SYSTEM_BIN='${systemBin}'`
  )
  testActionSource = testActionSource.replace(
    "readonly PROCESS_ENVIRON='/proc/self/environ'",
    `readonly PROCESS_ENVIRON='${processEnviron}'`
  )
  if (packagedLauncher) {
    testActionSource = testActionSource.replace(
      "readonly PACKAGED_OMARCHY_ROOT='/usr/share/omarchy'",
      `readonly PACKAGED_OMARCHY_ROOT='${fs.realpathSync(omarchyRoot)}'`
    )
  }
  assert.notEqual(testActionSource, actionSource, 'the action fixture must replace the fixed system root')
  writeExecutable(path.join(scriptsDir, 'action.sh'), testActionSource)
  fs.writeFileSync(processEnviron, 'BASH_FUNC_printf%%=fixture\0PATH=/fixture\0')

  writeExecutable(
    path.join(packagingDir, 'studio-omarchy-update'),
    `#!/bin/bash
{
  printf 'PATH=%s\n' "$PATH"
  printf 'mode=%s\n' "\${STUDIO_OMARCHY_TEST_MODE-unset}"
  printf 'future=%s\n' "\${STUDIO_OMARCHY_TEST_FUTURE-unset}"
  printf 'download=%s\n' "\${STUDIO_OMARCHY_DOWNLOAD_DIR-unset}"
  printf 'bash_env=%s\n' "\${BASH_ENV-unset}"
} >"$STUDIO_ACTION_CHILD_ENV_LOG"
`
  )
  writeExecutable(path.join(scriptsDir, 'remove.sh'), '#!/bin/bash\nexit 0\n')

  const launcherPath = path.join(omarchyBin, 'omarchy-launch-floating-terminal-with-presentation')
  const launcherTarget = symlinkLauncher
    ? path.join(fixtureRoot, 'unsafe-launcher-target')
    : (packagedLauncher
      ? path.join(systemBin, 'omarchy-launch-floating-terminal-with-presentation')
      : launcherPath)
  writeExecutable(
    launcherTarget,
    `#!/bin/bash
printf '%s\n' "$*" >"$STUDIO_ACTION_LOG"
if [[ \${STUDIO_ACTION_REINTRODUCE_TEST_ENV:-false} == true ]]; then
  export STUDIO_OMARCHY_TEST_MODE=reintroduced
  export STUDIO_OMARCHY_TEST_FUTURE=reintroduced
  export STUDIO_OMARCHY_DOWNLOAD_DIR=/reintroduced
fi
/bin/bash -c "$1"
`
  )
  if (symlinkLauncher || packagedLauncher) fs.symlinkSync(launcherTarget, launcherPath)

  writeExecutable(
    path.join(systemBin, 'realpath'),
    `#!/bin/bash
[[ $1 == '-e' && $2 == '--' && -e $3 ]] || exit 1
if [[ -L $3 ]]; then
  /usr/bin/readlink "$3"
else
  directory=$(cd -- "$(/usr/bin/dirname -- "$3")" && pwd -P) || exit
  builtin printf '%s/%s\n' "$directory" "$(/usr/bin/basename -- "$3")"
fi
`
  )

  writeExecutable(
    path.join(systemBin, 'uwsm-app'),
    '#!/bin/bash\nprintf \'%s\\n\' "$*" >"$STUDIO_ACTION_LOG"\n'
  )
  writeExecutable(
    path.join(systemBin, 'env'),
    '#!/bin/bash -p\nexec /usr/bin/env "$@"\n'
  )
  writeExecutable(
    path.join(systemBin, 'hyprctl'),
    `#!/bin/bash
if [[ $1 == '-j' && $2 == 'clients' ]]; then
  printf '%s\n' '[{"address":"0x111","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"Omarchy"},{"address":"0x222","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"studio-omarchy-unrelated"},{"address":"0x123","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"studio-omarchy-11111111-2222-3333-4444-555555555555"}]'
elif [[ $1 == '-j' && $2 == 'activewindow' ]]; then
  if [[ -e $STUDIO_FOCUS_LOG ]]; then
    printf '%s\n' '{"address":"0x123"}'
  else
    printf '%s\n' '{"address":"0x999"}'
  fi
elif [[ $1 == 'dispatch' ]]; then
  if [[ $2 == hl.dsp.focus* ]]; then
    [[ $STUDIO_HYPR_LUA_FAIL != 'true' ]] || exit 1
    printf '%s\n' "$2" >"$STUDIO_FOCUS_LOG"
  elif [[ $2 == 'focuswindow' ]]; then
    printf '%s\n' "$3" >"$STUDIO_FOCUS_LOG"
  fi
fi
`
  )
  writeExecutable(
    path.join(systemBin, 'uuidgen'),
    '#!/bin/bash\nprintf \'%s\\n\' \'11111111-2222-3333-4444-555555555555\'\n'
  )
  writeExecutable(
    path.join(systemBin, 'timeout'),
    '#!/bin/bash\nshift\nexec "$@"\n'
  )
  writeExecutable(path.join(systemBin, 'sleep'), '#!/bin/bash\nexit 0\n')

  writeExecutable(
    path.join(systemBin, 'jq'),
    `#!/bin/bash
IFS= read -r input || true
if [[ $1 == '-ce' ]]; then
  printf '%s\n' '{"address":"0x123","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"studio-omarchy-11111111-2222-3333-4444-555555555555"}'
elif [[ $input == *'0x123'* ]]; then
  printf '%s\n' '0x123'
elif [[ $input == *'0x999'* ]]; then
  printf '%s\n' '0x999'
fi
`
  )

  for (const command of [
    'omarchy-launch-floating-terminal-with-presentation',
    'env',
    'uwsm-app',
    'hyprctl',
    'uuidgen',
    'timeout',
    'jq',
    'sleep'
  ]) {
    writeExecutable(
      path.join(attackerBin, command),
      `#!/bin/bash
printf '%s\n' '${command}' >>"$STUDIO_ACTION_ATTACK_LOG"
exit 97
`
    )
  }

  return {
    fixtureRoot,
    pluginRoot,
    pluginRootReal: fs.realpathSync(pluginRoot),
    actionScript: path.join(scriptsDir, 'action.sh'),
    systemBin,
    attackerBin,
    omarchyRoot,
    omarchyRootReal: fs.realpathSync(omarchyRoot),
    omarchyBin,
    omarchyBinReal: fs.realpathSync(omarchyBin),
    logPath,
    focusPath,
    attackPath,
    childEnvPath
  }
}

function runAction(action, {
  graphical = false,
  luaFocusFails = false,
  omarchyPath,
  symlinkLauncher = false,
  packagedLauncher = false,
  extraEnv = {}
} = {}) {
  const fixture = createFixture({ symlinkLauncher, packagedLauncher })
  const result = spawnSync(fixture.actionScript, [action], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${fixture.attackerBin}:${process.env.PATH}`,
      OMARCHY_PATH: omarchyPath === undefined ? fixture.omarchyRootReal : omarchyPath,
      STUDIO_ACTION_LOG: fixture.logPath,
      STUDIO_ACTION_CHILD_ENV_LOG: fixture.childEnvPath,
      STUDIO_ACTION_ATTACK_LOG: fixture.attackPath,
      STUDIO_FOCUS_LOG: fixture.focusPath,
      STUDIO_HYPR_LUA_FAIL: luaFocusFails ? 'true' : 'false',
      WAYLAND_DISPLAY: graphical ? 'wayland-test' : '',
      HYPRLAND_INSTANCE_SIGNATURE: graphical ? 'hyprland-test' : '',
      ...extraEnv
    }
  })
  const log = fs.existsSync(fixture.logPath) ? fs.readFileSync(fixture.logPath, 'utf8').trim() : ''
  const focus = fs.existsSync(fixture.focusPath) ? fs.readFileSync(fixture.focusPath, 'utf8').trim() : ''
  const attack = fs.existsSync(fixture.attackPath) ? fs.readFileSync(fixture.attackPath, 'utf8').trim() : ''
  const childEnv = fs.existsSync(fixture.childEnvPath)
    ? fs.readFileSync(fixture.childEnvPath, 'utf8').trim()
    : ''
  fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true })
  return { result, log, focus, attack, childEnv, fixture }
}

test('opens the fixed checksum-verifying updater in a visible terminal', () => {
  const { result, log, attack, fixture } = runAction('update')
  assert.equal(result.status, 0, result.stderr)
  assert.match(log, /export PATH='/)
  assert.match(log, new RegExp(`'${path.join(fixture.pluginRootReal, 'packaging', 'arch', 'studio-omarchy-update')}'`))
  assert.equal(attack, '')
})

test('launches the fixed Studio executable under the graphical session manager', () => {
  const { result, log, attack } = runAction('launch')
  assert.equal(result.status, 0, result.stderr)
  assert.equal(log, '-- /usr/bin/studio')
  assert.equal(attack, '')
})

test('runs the fixed Studio remover in a visible terminal', () => {
  const { result, log, attack, fixture } = runAction('remove')
  assert.equal(result.status, 0, result.stderr)
  assert.match(log, new RegExp(`'${path.join(fixture.pluginRootReal, 'scripts', 'remove.sh')}'`))
  assert.equal(attack, '')
})

test('focuses the newly opened Studio action terminal under Hyprland', () => {
  const { result, log, focus, attack, fixture } = runAction('remove', { graphical: true })
  assert.equal(result.status, 0, result.stderr)
  assert.match(log, /studio-omarchy-11111111-2222-3333-4444-555555555555/)
  assert.match(log, new RegExp(`'${path.join(fixture.pluginRootReal, 'scripts', 'remove.sh')}'`))
  assert.match(log, /\(exit \$action_status\)/)
  assert.equal(focus, 'hl.dsp.focus({ window = "address:0x123" })')
  assert.equal(attack, '')
})

test('uses the exact-address classic focus fallback when Quattro focus fails', () => {
  const { result, focus, attack } = runAction('remove', { graphical: true, luaFocusFails: true })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(focus, 'address:0x123')
  assert.equal(attack, '')
})

test('clears inherited and launcher-reintroduced updater test controls', () => {
  const { result, childEnv, attack, fixture } = runAction('update', {
    extraEnv: {
      STUDIO_OMARCHY_TEST_MODE: '1',
      STUDIO_OMARCHY_TEST_FUTURE: 'poison',
      STUDIO_OMARCHY_DOWNLOAD_DIR: '/poison',
      BASH_ENV: '/poison',
      STUDIO_ACTION_REINTRODUCE_TEST_ENV: 'true'
    }
  })

  assert.equal(result.status, 0, result.stderr)
  assert.equal(
    childEnv,
    [
      `PATH=${fixture.systemBin}:${fixture.omarchyBinReal}:/bin`,
      'mode=unset',
      'future=unset',
      'download=unset',
      'bash_env=unset'
    ].join('\n')
  )
  assert.equal(attack, '')
})

test('removes inherited exported Bash functions before crossing nested launcher shells', () => {
  const { result, log, attack } = runAction('remove', {
    extraEnv: {
      'BASH_FUNC_printf%%':
        '() { /bin/echo exported-function >>"$STUDIO_ACTION_ATTACK_LOG"; builtin printf "$@"; }'
    }
  })

  assert.equal(result.status, 0, result.stderr)
  assert.notEqual(log, '')
  assert.equal(attack, '')
})

test('removes inherited exported Bash functions before the graphical app launcher', () => {
  const { result, log, attack } = runAction('launch', {
    extraEnv: {
      'BASH_FUNC_printf%%':
        '() { /bin/echo exported-function >>"$STUDIO_ACTION_ATTACK_LOG"; builtin printf "$@"; }'
    }
  })

  assert.equal(result.status, 0, result.stderr)
  assert.equal(log, '-- /usr/bin/studio')
  assert.equal(attack, '')
})

test('rejects a symlinked fixed Omarchy terminal launcher', () => {
  const { result, log, attack } = runAction('update', { symlinkLauncher: true })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /fixed Omarchy terminal launcher is unavailable or unsafe/)
  assert.equal(log, '')
  assert.equal(attack, '')
})

test('accepts the package-managed terminal launcher symlink to the fixed system target', () => {
  const { result, log, attack } = runAction('update', { packagedLauncher: true })
  assert.equal(result.status, 0, result.stderr)
  assert.notEqual(log, '')
  assert.equal(attack, '')
})

test('rejects a packaged terminal launcher symlink to any other target', () => {
  const { result, log, attack } = runAction('update', {
    packagedLauncher: true,
    symlinkLauncher: true
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /packaged Omarchy terminal launcher link has an unexpected target/)
  assert.equal(log, '')
  assert.equal(attack, '')
})

test('rejects an unsafe OMARCHY_PATH before resolving any PATH shadow', () => {
  const { result, log, attack } = runAction('update', { omarchyPath: 'relative/omarchy' })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /refusing an unsafe OMARCHY_PATH/)
  assert.equal(log, '')
  assert.equal(attack, '')
})

test('rejects unknown actions before spawning anything', () => {
  const { result, log, attack } = runAction('private-command')
  assert.equal(result.status, 2)
  assert.equal(log, '')
  assert.equal(attack, '')
})
