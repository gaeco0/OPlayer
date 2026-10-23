const assert = require('node:assert/strict');
const {obsoleteNightlies, pruneNightlies} = require('./prune-nightlies.cjs');
const item = (version, id, extra = {}) => ({tag_name: `v${version}`, id, draft: false, prerelease: true, ...extra});
const releases = [item('0.1.7-nightly.20261023.1', 1), item('0.1.7-nightly.20261023.10', 10),
  item('0.1.7-nightly.20261023.2', 2), item('0.1.8-nightly.20261024.1', 4),
  item('0.1.7-beta.1', 5), item('0.1.6', 6, {prerelease: false}),
  item('0.1.7-nightly.20261023.0', 7, {draft: true}), item('0.1.7-nightly.20261023.0', 8, {prerelease: false})];
assert.deepEqual(obsoleteNightlies(releases).map(r => r.id), [1]);
assert.deepEqual(obsoleteNightlies(releases.slice(0, 3)), []);
(async () => {
  const calls = [];
  const github = {paginate: async () => releases, rest: {repos: {
    listReleases() {}, deleteRelease: async ({release_id}) => calls.push(`release:${release_id}`),
  }, git: {deleteRef: async ({ref}) => calls.push(ref)}}};
  const args = {github, context: {repo: {owner: 'test', repo: 'test'}}, core: {info() {}}};
  await pruneNightlies(args);
  assert.deepEqual(calls, ['release:1', 'tags/v0.1.7-nightly.20261023.1']);
  calls.length = 0;
  github.rest.repos.deleteRelease = async () => {throw Object.assign(new Error('denied'), {status: 403});};
  await assert.rejects(() => pruneNightlies(args), /denied/);
  assert.deepEqual(calls, []);
  github.rest.repos.deleteRelease = github.rest.git.deleteRef = async () => {throw Object.assign(new Error('missing'), {status: 404});};
  await pruneNightlies(args);
  console.log('Nightly retention safety checks passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
