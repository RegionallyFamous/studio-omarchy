const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const acceptance = fs.readFileSync(path.join(__dirname, 'omarchy-acceptance.sh'), 'utf8')

test('guest idempotence check recognizes the fixed absolute pacman invocation', () => {
  assert.match(acceptance, /Running '\/usr\/bin\/pacman -U --needed --noconfirm/)
  assert.doesNotMatch(acceptance, /Running 'pacman -U --needed --noconfirm/)
})

test('custom-domain entry lets the field mount before tabbing into it', () => {
  const functionStart = acceptance.indexOf('create_https_site_with_pointer()')
  const functionEnd = acceptance.indexOf('\n}\n', functionStart)
  const createHttpsSite = acceptance.slice(functionStart, functionEnd)

  assert.match(
    createHttpsSite,
    /click_active_phrase 'Use custom domain'[\s\S]*sleep 1\n  wtype -k tab[\s\S]*wtype -d 75 "\$domain"/
  )
})
