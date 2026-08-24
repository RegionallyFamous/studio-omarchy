const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const workflowPath = path.join(root, '.github', 'workflows', 'publish-omarchy-release.yml')
const workflow = fs.readFileSync(workflowPath, 'utf8')
const buildWorkflowPath = path.join(root, '.github', 'workflows', 'build-package.yml')
const buildWorkflow = fs.readFileSync(buildWorkflowPath, 'utf8')

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

test('external Studio builds cannot rewrite trusted packaging or verification policy', () => {
  assert.match(
    buildWorkflow,
    /container: archlinux:base-devel@sha256:[0-9a-f]{64}/,
  )
  assert.doesNotMatch(buildWorkflow, /chown -R builder:builder "\$GITHUB_WORKSPACE"/)
  assert.match(buildWorkflow, /chown -R root:root "\$GITHUB_WORKSPACE"/)
  assert.match(buildWorkflow, /chmod -R go-w "\$GITHUB_WORKSPACE"/)
  assert.match(buildWorkflow, /runuser -u builder -- \/usr\/bin\/env -i/)
  assert.match(buildWorkflow, /runuser -u packager -- \/usr\/bin\/env -i/)
  assert.match(buildWorkflow, /PKGDEST="\$package_output_root"/)
  assert.match(buildWorkflow, /STUDIO_CHROME_SANDBOX_SOURCE="\$chrome_sandbox_source"/)
  assert.match(buildWorkflow, /STUDIO_CHROME_SANDBOX_SHA256="\$chrome_sandbox_hash"/)
  assert.match(buildWorkflow, /STUDIO_NODE_SOURCE="\$node_source"/)
  assert.match(buildWorkflow, /STUDIO_NODE_SHA256="\$node_hash"/)
  assert.match(buildWorkflow, /STUDIO_EXPECTED_CHROME_SANDBOX_SHA256:/)
  assert.match(buildWorkflow, /STUDIO_EXPECTED_NODE_SHA256:/)
  assert.match(buildWorkflow, /electron\/electron\/releases\/download\/v\$electron_version/)
  assert.match(buildWorkflow, /nodejs\.org\/dist\/v\$node_version/)
  assert.match(buildWorkflow, /raw\.githubusercontent\.com\/Automattic\/studio\/\$UPSTREAM_COMMIT/)
  assert.match(buildWorkflow, /current_node_version == "\$node_version"/)
  assert.match(buildWorkflow, /declared_electron_version == "\$electron_version"/)
  assert.match(buildWorkflow, /Official runtime sources are not immutable root-owned single-link files/)
  assert.match(buildWorkflow, /terminate_user_processes builder/)
  assert.match(buildWorkflow, /terminate_user_processes packager/)
  assert.match(buildWorkflow, /pgrep --uid "\$account_uid"/)
  assert.match(buildWorkflow, /ps -eo uid=,stat=,pid=,ppid=,args=/)
  assert.match(buildWorkflow, /\$2 !~ \/\^Z\//)

  const pinnedMetadata = buildWorkflow.indexOf(
    'download_root_bounded "$upstream_raw_url/package-lock.json"',
  )
  const externalBuild = buildWorkflow.indexOf('runuser -u builder')
  const builderReaped = buildWorkflow.indexOf('terminate_user_processes builder')
  const trustedRuntimeDownload = buildWorkflow.indexOf(
    'download_root_bounded "$electron_base_url/SHASUMS256.txt"',
  )
  const trustedPackaging = buildWorkflow.indexOf('runuser -u packager')
  const packagerReaped = buildWorkflow.indexOf('terminate_user_processes packager')
  const trustedVerification = buildWorkflow.indexOf('packaging/arch/verify-package.sh')
  assert.ok(pinnedMetadata >= 0)
  assert.ok(pinnedMetadata < externalBuild)
  assert.ok(externalBuild >= 0)
  assert.ok(externalBuild < builderReaped)
  assert.ok(builderReaped < trustedRuntimeDownload)
  assert.ok(trustedRuntimeDownload < trustedPackaging)
  assert.ok(builderReaped < trustedPackaging)
  assert.ok(trustedPackaging < packagerReaped)
  assert.ok(packagerReaped < trustedVerification)
})

test('base release revisions have one unambiguous source tag mapping', () => {
  assert.equal(
    (workflow.match(/base_target=\$\(resolve_remote_tag/g) || []).length,
    2,
  )
  assert.equal(
    (workflow.match(/if \[\[ \$expected_pkgrel == "\$base_pkgrel" \]\]; then/g) || []).length,
    2,
  )
  assert.equal(
    (workflow.match(/has forbidden revision shadow/g) || []).length,
    2,
  )
  assert.equal(
    (workflow.match(/candidate_target=\$\(resolve_remote_tag "\$candidate_tag"\) \|\|/g) || []).length,
    2,
  )
  assert.doesNotMatch(
    workflow,
    /candidate_target=\$\(resolve_remote_tag "\$candidate_tag" \|\| true\)[\s\S]{0,160}candidate_tag=(?:\$release_tag|\$RELEASE_TAG)/,
  )

  const prepublicationMapping = workflow.indexOf(
    'resolve_revision_source "$VERSION" "$PKGREL"',
  )
  const releaseUpload = workflow.indexOf('gh release upload')
  const releaseCreate = workflow.indexOf('gh release create')
  assert.ok(prepublicationMapping >= 0)
  assert.ok(prepublicationMapping < releaseUpload)
  assert.ok(prepublicationMapping < releaseCreate)
})
