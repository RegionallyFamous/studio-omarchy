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

test('launch handles only the exact native Studio update notice before onboarding', () => {
  const helperStart = acceptance.indexOf('dismiss_studio_update_notice_if_present()')
  const helperEnd = acceptance.indexOf('\n}\n', helperStart)
  const helper = acceptance.slice(helperStart, helperEnd)
  const launchStart = acceptance.indexOf("wait_until 'WordPress Studio launches'")
  const launchEnd = acceptance.indexOf("screenshot 'success-studio-05-fresh-welcome'", launchStart)
  const launch = acceptance.slice(launchStart, launchEnd)

  assert.match(helper, /--arg title 'New Version Available'/)
  assert.match(helper, /if length == 1 then \.\[0\]\.address else empty end/)
  assert.match(helper, /active_region_contains 'New Version Available' '20 0 80 30'/)
  assert.match(
    helper,
    /click_active_phrase 'Later' '50 70 100 100'[\s\\]*'the optional Studio update notice Later button is clicked with the pointer'/
  )
  assert.match(helper, /studio_update_notice_absent/)
  assert.doesNotMatch(helper, /wtype -k (esc|enter)|ydotool click/)
  assert.match(
    launch,
    /studio_welcome_or_update_notice_present[\s\S]*sleep 5[\s\S]*dismiss_studio_update_notice_if_present[\s\S]*screen_contains 'WordPress Studio'[\s\S]*screen_contains 'Skip'[\s\S]*dismiss_studio_update_notice_if_present[\s\S]*screen_contains 'WordPress Studio'[\s\S]*screen_contains 'Skip'/
  )
})
