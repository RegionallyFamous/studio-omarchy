const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const workflowPath = path.join(root, '.github', 'workflows', 'publish-omarchy-release.yml')
const workflow = fs.readFileSync(workflowPath, 'utf8')

test('manual releases must resolve to the published latest stable upstream release', () => {
  assert.match(workflow, /repos\/Automattic\/studio\/releases\/tags\/\$upstream_tag/)
  assert.match(workflow, /\.draft == false and\s+\.prerelease == false/)
  assert.match(workflow, /\[\[ \$upstream_tag == "\$latest_tag" \]\]/)
  assert.match(workflow, /Refusing to publish Studio \$version as latest/)
  assert.match(workflow, /Refusing to downgrade the repository/)
  assert.match(workflow, /no longer matches the repository's immutable commit pin/)
  assert.doesNotMatch(workflow, /repos\/Automattic\/studio\/git\/ref\/tags\/\$upstream_tag/)
})

test('publication remains bound to the triggering and tagged source commits', () => {
  assert.match(workflow, /TRIGGER_COMMIT: \$\{\{ github\.sha \}\}/)
  assert.match(workflow, /origin\/main moved after this release workflow started/)
  assert.match(workflow, /origin\/main moved while the package was building/)
  assert.match(workflow, /origin\/main moved before asset publication/)
  assert.match(workflow, /source_commit: \$\{\{ steps\.source\.outputs\.source_commit \}\}/)
  assert.match(workflow, /SOURCE_COMMIT: \$\{\{ needs\.tag-source\.outputs\.source_commit \}\}/)
  assert.match(workflow, /\$source_tag == "\$SOURCE_TAG" && \$tag_target == "\$expected_commit"/)
})

test('existing assets require complete revision pairs, digests, checksum contents, and source tags', () => {
  assert.match(workflow, /\.digest \/\/ ""/)
  assert.match(workflow, /Accept: application\/octet-stream/)
  assert.match(workflow, /checksum_hash == "\$package_digest"/)
  assert.match(workflow, /contains an incomplete package\/checksum set/)
  assert.match(workflow, /Accept: application\/vnd\.github\.raw\+json/)
  assert.match(workflow, /does not declare Studio \$expected_version-\$expected_pkgrel/)
  assert.match(workflow, /Existing package \$package_name belongs to \$expected_source_tag/)
  assert.match(workflow, /\.immutable != true/)
  assert.match(workflow, /verify_release_assets "\$before_release" "\$VERSION" "\$PKGREL" "\$SOURCE_COMMIT" false/)
})

test('reruns never clobber or move an immutable release identity', () => {
  assert.match(workflow, /Refusing to move immutable source tag \$SOURCE_TAG/)
  assert.match(workflow, /should_build=false/)
  assert.match(workflow, /changed after detection or cannot accept immutable assets/)
  assert.doesNotMatch(workflow, /--clobber/)
  assert.doesNotMatch(workflow, /git tag[^\n]*--force/)
})
