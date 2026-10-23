const fs = require('node:fs');

function releaseMetadata(source, ref = '') {
  const version = source.match(/^version:\s*(\d+\.\d+\.\d+(?:-(?:beta|nightly)\.[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)(?:\+\d+)?\s*$/m)?.[1];
  if (!version) throw new Error('Invalid pubspec.yaml version or update channel');
  const tagged = ref.startsWith('refs/tags/');
  if (tagged && ref !== `refs/tags/v${version}`) {
    throw new Error(`Release requires a pushed v${version} tag matching pubspec.yaml`);
  }
  const channel = tagged ? (version.includes('-') ? version.split('-')[1].split('.')[0] : 'stable') : 'nightly';
  return {version, channel, tag: `v${version}`, prerelease: channel !== 'stable'};
}

module.exports = releaseMetadata;
if (require.main === module) {
  const result = releaseMetadata(fs.readFileSync('pubspec.yaml', 'utf8'), process.env.GITHUB_REF);
  if (process.env.GITHUB_ENV) fs.appendFileSync(process.env.GITHUB_ENV, `OPLAYER_UPDATE_CHANNEL=${result.channel}\n`);
  console.log(JSON.stringify(result));
}
