const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const acceptance = fs.readFileSync(path.join(__dirname, 'omarchy-acceptance.sh'), 'utf8')

test('guest idempotence check recognizes the fixed absolute pacman invocation', () => {
  assert.match(acceptance, /Running '\/usr\/bin\/pacman -U --needed --noconfirm/)
  assert.doesNotMatch(acceptance, /Running 'pacman -U --needed --noconfirm/)
})

test('custom-domain entry waits for and focuses the mounted field before typing', () => {
  const fieldReady = acceptance.indexOf('custom-domain field renders')
  const fieldFocused = acceptance.indexOf('custom-domain field is focused')
  const domainTyped = acceptance.indexOf('wtype -d 75 "$domain"')

  assert.notEqual(fieldReady, -1)
  assert.notEqual(fieldFocused, -1)
  assert.notEqual(domainTyped, -1)
  assert.ok(fieldReady < fieldFocused)
  assert.ok(fieldFocused < domainTyped)
})
