const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const publish = require('./publish-release.cjs');

(async () => {
  const original = process.cwd();
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'oplayer-release-'));
  try {
    process.chdir(temporary);
    fs.writeFileSync('pubspec.yaml', 'version: 0.1.0+2\n');
    const changelog = '# 변경 내역\n\n## [0.1.0]\n\n### 추가\n\n- 새 기능 설명\n\n## [0.0.9]\n\n- 이전 변경\n';
    fs.writeFileSync('CHANGELOG.md', changelog);
    fs.mkdirSync('release-assets');
    const calls = [];
    const releases = [{tag_name: 'v0.1.0-beta.1', draft: false, prerelease: true}];
    const github = {paginate: async method => method === github.rest.repos.listReleases ? releases : [], rest: {repos: {
      getReleaseByTag: async () => {throw Object.assign(new Error('missing'), {status: 404});},
      createRelease: async args => {assert.equal(args.draft, true); return {data: {id: 1, html_url: 'test'}};},
      listReleaseAssets: () => {},
      listReleases: () => {},
      uploadReleaseAsset: async args => calls.push(args.name),
      updateRelease: async args => {
        assert.equal(args.draft, false);
        assert.equal(args.make_latest, args.prerelease ? 'false' : 'true');
        assert.ok(args.body.includes('새 기능 설명'));
        assert.ok(!args.body.includes('이전 변경'));
        calls.push('published');
      },
    }}};
    const args = {github, context: {repo: {owner: 'test', repo: 'test'}, sha: 'commit', eventName: 'push', ref: 'refs/tags/v0.1.0'}, core: {summary: {addLink: () => ({write: async () => {}})}}};
    args.context.ref = 'refs/heads/main';
    await assert.rejects(() => publish(args), /requires a pushed/);
    args.context.ref = 'refs/tags/v0.1.1';
    await assert.rejects(() => publish(args), /matching pubspec/);
    args.context.ref = 'refs/tags/v0.1.0';
    args.context.eventName = 'workflow_dispatch';
    await assert.rejects(() => publish(args), /requires a pushed/);
    args.context.eventName = 'push';
    fs.writeFileSync('CHANGELOG.md', '## [Unreleased]\n\n- 아직 배포하지 않은 변경\n');
    await assert.rejects(() => publish(args), /Missing release notes/);
    fs.writeFileSync('CHANGELOG.md', '## [0.1.0]');
    await assert.rejects(() => publish(args), /Missing release notes/);
    fs.writeFileSync('CHANGELOG.md', changelog);
    await assert.rejects(() => publish(args), /Expected six APKs/);
    for (const flavor of ['mobile', 'tv']) {
      for (const abi of ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
        fs.writeFileSync(`release-assets/OPlayer-0.1.0-android-${flavor}-${abi}.apk`, abi);
      }
    }
    for (const file of ['windows-x64.zip', 'windows-arm64.zip', 'linux-x64.tar.gz', 'linux-arm64.tar.gz', 'macos-arm64.zip']) {
      fs.writeFileSync(`release-assets/OPlayer-0.1.0-${file}`, file);
    }
    await publish(args);
    assert.equal(calls.length, 13);
    assert.equal(calls.at(-1), 'published');
    assert.ok(calls.includes('SHA256SUMS.txt'));
    assert.equal(fs.readFileSync('release-assets/SHA256SUMS.txt', 'utf8').trim().split('\n').length, 11);
    // Only an explicitly pushed matching tag can replace existing assets; CI never moves tags.
    github.rest.repos.getReleaseByTag = async () => ({data: {id: 1, html_url: 'test'}});
    github.paginate = async method => method === github.rest.repos.listReleases ? releases : fs.readdirSync('release-assets').map((name, id) => ({id, name, digest: 'old'}));
    github.rest.repos.deleteReleaseAsset = async args => calls.push(`delete:${args.asset_id}`);
    calls.length = 0;
    await publish(args);
    assert.equal(calls.filter(call => call.startsWith('delete:')).length, 12);
    assert.equal(calls.includes('tag'), false);
    assert.equal(calls.at(-1), 'published');
    releases.length = 0;
    await assert.rejects(() => publish(args), /stable requires a published.*beta/);
    for (const predecessor of [
      {tag_name: 'v0.1.0-nightly.1', draft: true, prerelease: true},
      {tag_name: 'v0.0.9-nightly.1', draft: false, prerelease: true},
    ]) {
      releases.push(predecessor);
      await assert.rejects(() => publish(args), /stable requires a published/);
      releases.length = 0;
    }
    releases.push({tag_name: 'v0.1.0-nightly.1', draft: false, prerelease: true});
    await publish(args);
    releases.length = 0;
    for (const channel of ['nightly', 'beta']) {
      const version = `0.1.0-${channel}.1`;
      fs.writeFileSync('pubspec.yaml', `version: ${version}+2\n`);
      fs.writeFileSync('CHANGELOG.md', `## [${version}]\n\n새 기능 설명\n`);
      args.context.ref = `refs/tags/v${version}`;
      for (const name of fs.readdirSync('release-assets').filter(name => name.startsWith('OPlayer-'))) {
        const suffix = name.replace(/^OPlayer-.*?-(android-|windows-|linux-|macos-)/, '$1');
        fs.renameSync(path.join('release-assets', name), path.join('release-assets', `OPlayer-${version}-${suffix}`));
      }
      github.paginate = async () => releases;
      if (channel === 'beta') {
        await assert.rejects(() => publish(args), /beta requires a published.*nightly/);
        releases.push({tag_name: 'v0.1.0-nightly.1', draft: false, prerelease: true});
      }
      await publish(args);
    }
    console.log('Release publication checks passed');
  } finally {
    process.chdir(original);
    fs.rmSync(temporary, {recursive: true, force: true});
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
