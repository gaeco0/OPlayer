const assert = require('node:assert/strict');
const metadata = require('./release-metadata.cjs');
assert.equal(metadata('version: 0.1.6+2').channel, 'nightly');
assert.equal(metadata('version: 0.1.7+2', 'refs/heads/main').channel, 'nightly');
for (const [version, channel] of [['0.1.7', 'stable'], ['0.1.7-beta.2', 'beta'], ['0.1.7-nightly.20261023.1', 'nightly']]) {
  const result = metadata(`version: ${version}+2`, `refs/tags/v${version}`);
  assert.equal(result.channel, channel);
  assert.equal(result.prerelease, channel !== 'stable');
}
assert.throws(() => metadata('version: 0.1.7-rc.1+2'), /Invalid/);
assert.throws(() => metadata('version: 0.1.7-beta.1+2', 'refs/tags/v0.1.7'), /matching/);
console.log('Update channel metadata checks passed');
