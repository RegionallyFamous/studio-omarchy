const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const acceptance = fs.readFileSync(path.join(__dirname, 'omarchy-acceptance.sh'), 'utf8')
const remover = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'remove.sh'), 'utf8')

test('guest idempotence check recognizes the fixed absolute pacman invocation', () => {
  assert.match(acceptance, /Running '\/usr\/bin\/pacman -U --needed --noconfirm/)
  assert.doesNotMatch(acceptance, /Running 'pacman -U --needed --noconfirm/)
})

test('guest executes the exact installer handoff as root without exposing host pacman', () => {
  const extractionStart = acceptance.indexOf('extract_installer_privileged_handoff()')
  const exerciseStart = acceptance.indexOf('exercise_real_privileged_handoff()')
  const exerciseEnd = acceptance.indexOf('\nstudio_updater_process_absent()', exerciseStart)
  const extraction = acceptance.slice(extractionStart, exerciseStart)
  const exercise = acceptance.slice(exerciseStart, exerciseEnd)

  assert.match(extraction, /line == "  \/usr\/bin\/sudo \/usr\/bin\/bash -c '"/)
  assert.match(
    extraction,
    /line == "' bash \\"\\\$source_path\\" \\"\\\$package_name\\" \\"\\\$expected_hash\\" \\"\\\$max_bytes\\""/
  )
  assert.doesNotMatch(extraction, /sed|replace|sub\(/)
  assert.match(exercise, /handoff_script=\$\(extract_installer_privileged_handoff "\$installer"\)/)
  assert.match(exercise, /\/usr\/bin\/sudo \/usr\/bin\/bash -p -s --/)
  assert.match(exercise, /\/usr\/bin\/unshare --mount --propagation private/)
  assert.match(exercise, /\/usr\/bin\/mount --bind "\$1" \/usr\/bin\/pacman/)
  assert.match(exercise, /\/usr\/bin\/cmp --silent -- "\$1" \/usr\/bin\/pacman/)
  assert.match(exercise, /\/usr\/bin\/bash -c "\$root_script" bash/)
  assert.match(exercise, /directory\|0\|0\|700/)
  assert.match(exercise, /regular file\|0\|0\|600\|1/)
  assert.match(exercise, /expect_rejection "\$run_root\/symlink\/\$package_name"/)
  assert.match(exercise, /expect_rejection "\$run_root\/fifo\/\$package_name"/)
  assert.match(exercise, /expect_rejection "\$run_root\/oversize\/\$package_name"/)
  assert.match(exercise, /\$status == 1 && ! -e \$marker && ! -L \$marker/)
  assert.match(
    exercise,
    /\[\[ \$\(\/usr\/bin\/sha256sum \/usr\/bin\/pacman\) == "\$host_pacman_hash  \/usr\/bin\/pacman" \]\]/
  )
})

test('guest verifies exact installed privileged runtime metadata, hashes, and capability', () => {
  const verifyStart = acceptance.indexOf('verify_installed_runtime_contract()')
  const verifyEnd = acceptance.indexOf('\nexercise_real_privileged_handoff()', verifyStart)
  const verify = acceptance.slice(verifyStart, verifyEnd)

  assert.match(verify, /regular file\|0\|0\|4755\|1/)
  assert.match(verify, /regular file\|0\|0\|755\|1/)
  assert.match(verify, /regular file\|0\|0\|644\|1/)
  assert.match(verify, /\^\(\[0-9a-f\]\{64\}\).*chrome-sandbox/)
  assert.match(verify, /\^\(\[0-9a-f\]\{64\}\).*resources\/bin\/node/)
  assert.match(verify, /\/usr\/bin\/sha256sum -- \/usr\/lib\/studio\/chrome-sandbox/)
  assert.match(verify, /\/usr\/bin\/sha256sum -- "\$BUNDLED_NODE"/)
  assert.match(verify, /\/usr\/bin\/getcap "\$BUNDLED_NODE"/)
  assert.match(verify, /\$BUNDLED_NODE cap_net_bind_service=ep/)
  assert.match(verify, /getcap \/usr\/lib\/studio\/studio/)
  assert.match(verify, /getcap \/usr\/lib\/studio\/chrome-sandbox/)
  assert.match(acceptance, /verify_installed_runtime_contract 'the installer'/)
  assert.match(acceptance, /verify_installed_runtime_contract 'the same-version updater'/)
})

test('status containment rewrites only disposable copies of the fixed pacman path', () => {
  assert.match(
    acceptance,
    /exercise_status_containment\(\)[\s\S]*sed "s\|\/usr\/bin\/pacman\|\$run_root\/bin\/pacman\|"[\s\S]*"\$run_root\/status\.sh"/
  )
  assert.match(
    acceptance,
    /exercise_status_pre_ready_containment\(\)[\s\S]*sed "s\|\/usr\/bin\/pacman\|\$run_root\/bin\/pacman\|"[\s\S]*"\$run_root\/status\.base\.sh"/
  )
})

test('removal resolves its package helper only through the validated Omarchy runtime', () => {
  assert.match(remover, /export PATH=\/usr\/bin\nreadonly PATH\nunset BASH_ENV ENV CDPATH/)
  assert.match(
    remover,
    /omarchy_config='\/etc\/omarchy\.conf'[\s\S]*validate_omarchy_runtime\(\)[\s\S]*config_uid == 0[\s\S]*8#\$config_mode & 8#022[\s\S]*\$OMARCHY_PATH == "\$configured_path"/
  )
  assert.match(
    remover,
    /resolved_path=\$\(\/usr\/bin\/realpath -e -- "\$OMARCHY_PATH"\)[\s\S]*\$resolved_path == "\$OMARCHY_PATH"/
  )
  assert.match(
    remover,
    /helper_path="\$OMARCHY_PATH\/bin\/omarchy-pkg-drop"[\s\S]*\$OMARCHY_PATH == "\/usr\/share\/omarchy"[\s\S]*-L \$helper_path[\s\S]*\$helper_link_uid == 0[\s\S]*\$resolved_helper == "\/usr\/bin\/omarchy-pkg-drop"[\s\S]*! -L \$helper_path[\s\S]*8#\$helper_mode & 8#022/
  )
  assert.match(
    remover,
    /\$OMARCHY_PATH == "\/usr\/share\/omarchy"[\s\S]*\$helper_uid == 0[\s\S]*\/usr\/bin\/pacman -Qq -- omarchy-dev[\s\S]*\$helper_uid == "\$current_uid"/
  )
  assert.match(
    remover,
    /\/usr\/bin\/env -i PATH=\/usr\/bin TERM="\$\{TERM:-dumb\}"[\s\\]*"\$omarchy_pkg_drop" wordpress-studio-omarchy\s*$/
  )
  assert.doesNotMatch(remover, /\nomarchy-pkg-drop wordpress-studio-omarchy/)
  assert.match(
    acceptance,
    /pgrep -u "\$\(id -u\)" -f "\^\/bin\/bash -p \$PLUGIN_DIR\/scripts\/remove\[\.\]sh\( \|\$\)"/
  )
  assert.match(
    acceptance,
    /OMARCHY_PATH='\/usr\/share\/omarchy' PATH="\$run_root\/bin:\$PATH"[\s\S]*the package-absent remover accepts the configured Omarchy runtime/
  )
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
