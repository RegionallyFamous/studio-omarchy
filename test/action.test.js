const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const actionScript = path.join(root, 'scripts', 'action.sh')

function runAction(action, { graphical = false, luaFocusFails = false } = {}) {
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
  fs.writeFileSync(
    path.join(binDir, 'hyprctl'),
    `#!/bin/bash
if [[ $1 == '-j' && $2 == 'clients' ]]; then
  printf '%s\\n' '[{"address":"0x111","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"Omarchy"},{"address":"0x222","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"studio-omarchy-unrelated"},{"address":"0x123","mapped":true,"class":"org.omarchy.terminal","initialClass":"org.omarchy.terminal","title":"studio-omarchy-11111111-2222-3333-4444-555555555555"}]'
elif [[ $1 == '-j' && $2 == 'activewindow' ]]; then
  if [[ -e $STUDIO_FOCUS_LOG ]]; then
    printf '%s\\n' '{"address":"0x123"}'
  else
    printf '%s\\n' '{"address":"0x999"}'
  fi
elif [[ $1 == 'dispatch' ]]; then
  if [[ $2 == hl.dsp.focus* ]]; then
    [[ $STUDIO_HYPR_LUA_FAIL != 'true' ]] || exit 1
    printf '%s\\n' "$2" >"$STUDIO_FOCUS_LOG"
  elif [[ $2 == 'focuswindow' ]]; then
    printf '%s\\n' "$3" >"$STUDIO_FOCUS_LOG"
  fi
fi
`,
    { mode: 0o755 }
  )
  fs.writeFileSync(
    path.join(binDir, 'uuidgen'),
    '#!/bin/bash\nprintf \'%s\\n\' \'11111111-2222-3333-4444-555555555555\'\n',
    { mode: 0o755 }
  )
  fs.writeFileSync(
    path.join(binDir, 'timeout'),
    '#!/bin/bash\nshift\nexec "$@"\n',
    { mode: 0o755 }
  )

  const result = spawnSync(actionScript, [action], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH}`,
      STUDIO_ACTION_LOG: logPath,
      STUDIO_FOCUS_LOG: path.join(fixtureRoot, 'focus.log'),
      STUDIO_HYPR_LUA_FAIL: luaFocusFails ? 'true' : 'false',
      WAYLAND_DISPLAY: graphical ? 'wayland-test' : '',
      HYPRLAND_INSTANCE_SIGNATURE: graphical ? 'hyprland-test' : ''
    }
  })
  const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8').trim() : ''
  const focusPath = path.join(fixtureRoot, 'focus.log')
  const focus = fs.existsSync(focusPath) ? fs.readFileSync(focusPath, 'utf8').trim() : ''
  fs.rmSync(fixtureRoot, { recursive: true, force: true })
  return { result, log, focus }
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

test('runs the fixed Studio remover in a visible terminal', () => {
  const { result, log } = runAction('remove')
  assert.equal(result.status, 0, result.stderr)
  assert.equal(log, `'${path.join(root, 'scripts', 'remove.sh')}'`)
})

test('focuses the newly opened Studio action terminal under Hyprland', () => {
  const { result, log, focus } = runAction('remove', { graphical: true })
  assert.equal(result.status, 0, result.stderr)
  assert.match(log, /studio-omarchy-11111111-2222-3333-4444-555555555555/)
  assert.match(log, new RegExp(`'${path.join(root, 'scripts', 'remove.sh')}'`))
  assert.match(log, /\(exit \$action_status\)/)
  assert.equal(focus, 'hl.dsp.focus({ window = "address:0x123" })')
})

test('uses the exact-address classic focus fallback when Quattro focus fails', () => {
  const { result, focus } = runAction('remove', { graphical: true, luaFocusFails: true })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(focus, 'address:0x123')
})

test('rejects unknown actions before spawning anything', () => {
  const { result, log } = runAction('private-command')
  assert.equal(result.status, 2)
  assert.equal(log, '')
})
