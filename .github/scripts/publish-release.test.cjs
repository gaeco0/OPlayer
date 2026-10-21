const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const publish = require('./publish-release.cjs');

(async () => {
  const original = process.cwd();
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'oplayer-release-'));
  try {
    process.chdir(temporary);
    fs.writeFileSync('pubspec.yaml', 'version: 0.1.0+2\n');
    fs.mkdirSync('release-assets');
    const calls = [];
    const github = {paginate: async () => [], rest: {repos: {
      getReleaseByTag: async () => {throw Object.assign(new Error('missing'), {status: 404});},
      createRelease: async args => {assert.equal(args.draft, true); return {data: {id: 1, html_url: 'test'}};},
      listReleaseAssets: () => {},
      uploadReleaseAsset: async args => calls.push(args.name),
      updateRelease: async args => {assert.equal(args.draft, false); calls.push('published');},
    }}};
    const args = {github, context: {repo: {owner: 'test', repo: 'test'}, sha: 'commit'}, core: {notice: () => {}, summary: {addLink: () => ({write: async () => {}})}}};
    await assert.rejects(() => publish(args), /Expected six APKs/);
    for (const flavor of ['mobile', 'tv']) {
      for (const abi of ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
        fs.writeFileSync(`release-assets/OPlayer-0.1.0-android-${flavor}-${abi}.apk`, abi);
      }
    }
    for (const file of ['windows-x64.zip', 'linux-x64.tar.gz', 'macos-arm64.zip']) {
      fs.writeFileSync(`release-assets/OPlayer-0.1.0-${file}`, file);
    }
    await publish(args);
    assert.equal(calls.length, 11);
    assert.equal(calls.at(-1), 'published');
    assert.ok(calls.includes('SHA256SUMS.txt'));
    assert.equal(fs.readFileSync('release-assets/SHA256SUMS.txt', 'utf8').trim().split('\n').length, 9);
    // An existing version changes only after an explicit manual replacement.
    assert.notEqual(temporary, original);
    const git = (...command) => execFileSync('git', command, {cwd: temporary, stdio: 'pipe'});
    git('init');
    git('add', 'pubspec.yaml');
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'Initial');
    git('tag', 'v0.1.0');
    fs.appendFileSync(path.join(temporary, 'pubspec.yaml'), '# modified app source\n');
    git('add', 'pubspec.yaml');
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'Updated');
    github.rest.repos.getReleaseByTag = async () => ({data: {id: 1, html_url: 'test'}});
    github.paginate = async () => fs.readdirSync('release-assets').map((name, id) => ({id, name, digest: 'old'}));
    github.rest.repos.deleteReleaseAsset = async args => calls.push(`delete:${args.asset_id}`);
    github.rest.git = {updateRef: async args => {assert.equal(args.force, true); assert.equal(args.sha, 'commit'); calls.push('tag');}};
    calls.length = 0;
    args.context.eventName = 'push';
    args.context.payload = {inputs: {replace_release: 'true'}};
    await publish(args);
    assert.equal(calls.length, 0);
    args.context.eventName = 'workflow_dispatch';
    await publish(args);
    assert.equal(calls.filter(call => call.startsWith('delete:')).length, 10);
    assert.equal(calls.at(-2), 'tag');
    assert.equal(calls.at(-1), 'published');
    console.log('Release publication checks passed');
  } finally {
    process.chdir(original);
    fs.rmSync(temporary, {recursive: true, force: true});
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
