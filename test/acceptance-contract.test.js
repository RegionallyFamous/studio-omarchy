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

test('Studio 1.19 workbench navigation clicks visible tabs and expects Shortcuts', () => {
  assert.match(
    acceptance,
    /click_active_phrase 'Settings' '20 5 50 25' 'the visible site Settings tab is clicked'/
  )
  assert.match(
    acceptance,
    /click_active_phrase 'Debugging' '20 5 50 25' 'the visible site Debugging tab is clicked'/
  )
  assert.match(
    acceptance,
    /click_active_phrase 'Overview' '20 5 50 25' 'the visible site Overview tab is clicked'[\s\S]*screen_contains 'Shortcuts'/
  )
  assert.doesNotMatch(acceptance, /screen_contains 'Customize'/)
  assert.doesNotMatch(
    acceptance,
    /click_active_relative_control (?:35 14|41 14|29 14)/
  )
})

test('preview and Add site icon controls are identified by their visible tooltips', () => {
  assert.match(
    acceptance,
    /hover_active_tooltip\(\)[\s\S]*Base UI tooltips open after 600ms[\s\S]*sleep 0\.8[\s\S]*screen_contains "\$tooltip"/
  )

  const previewStart = acceptance.indexOf("click_active_tooltip 'Hide preview'")
  const previewEnd = acceptance.indexOf("click_active_phrase 'Open site'", previewStart)
  const preview = acceptance.slice(previewStart, previewEnd)

  assert.match(
    preview,
    /click_active_tooltip 'Hide preview'[\s\S]*active_region_absent 'Hello world'[\s\S]*click_active_tooltip 'Show preview'/
  )
  assert.match(
    preview,
    /click_active_tooltip 'Show preview'[\s\S]*active_region_contains "\$SITE_ONE_NAME"[\s\S]*click_active_tooltip 'Refresh'[\s\S]*site_frontend_ready "\$SITE_ONE_PORT"[\s\S]*active_region_contains "\$SITE_ONE_NAME"/
  )
  assert.match(
    preview,
    /click_active_tooltip 'Hide preview'[\s\S]*active_region_absent 'Hello world'[\s\S]*hover_active_tooltip 'Show preview'/
  )
  assert.match(
    acceptance,
    /click_active_tooltip 'Add site' 3 25 12[\s\\]*'the sidebar Add site icon button is identified and clicked with the pointer'/
  )
  assert.doesNotMatch(
    acceptance,
    /click_active_relative_control (?:55 95|97 95|60 7|17 3)/
  )
})

test('site deletion OCR-clicks the visible lower-right confirmation button', () => {
  const deletionStart = acceptance.indexOf('for site_name in "$SITE_TWO_NAME" "$SITE_ONE_NAME"; do')
  const deletionEnd = acceptance.indexOf("screenshot 'success-studio-17-sites-deleted'", deletionStart)
  const deletion = acceptance.slice(deletionStart, deletionEnd)

  assert.match(
    deletion,
    /screen_contains "Delete \$site_name"[\s\S]*active_window_matches "\$STUDIO_CLASS"[\s\S]*click_screen_phrase 'Delete site' '50 50 75 80'[\s\\]*"the \$site_name visible bottom-right Delete site button is clicked with the pointer"/
  )
  assert.doesNotMatch(deletion, /click_active_centered_control/)
  assert.doesNotMatch(acceptance, /fixed 560px|click_active_centered_control 212 56/)
})
