const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

module.exports = async ({github, context, core}) => {
  const match = fs.readFileSync('pubspec.yaml', 'utf8').match(/^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+\d+)?\s*$/m);
  if (!match) throw new Error('Invalid pubspec.yaml version');
  const tag = `v${match[1]}`;
  if (context.eventName !== 'push' || context.ref !== `refs/tags/${tag}`) {
    throw new Error(`Release requires a pushed ${tag} tag matching pubspec.yaml`);
  }
  const section = fs.readFileSync('CHANGELOG.md', 'utf8').split(/^## /m)
    .find(value => value.split(/\r?\n/, 1)[0].trim() === `[${match[1]}]`);
  const releaseNotes = section?.split(/\r?\n/).slice(1).join('\n').trim();
  if (!releaseNotes) throw new Error(`Missing release notes for ${tag} in CHANGELOG.md`);
  const repository = {owner: context.repo.owner, repo: context.repo.repo};
  const files = fs.readdirSync('release-assets').filter(name => name !== 'SHA256SUMS.txt').sort();
  if (files.filter(name => name.endsWith('.apk')).length !== 6 ||
      files.filter(name => name.endsWith('.zip')).length !== 2 ||
      files.filter(name => name.endsWith('.tar.gz')).length !== 1 || files.length !== 9) {
    throw new Error('Expected six APKs and three desktop archives');
  }
  const checksums = files.map(name => {
    const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join('release-assets', name))).digest('hex');
    return `${digest}  ${name}\n`;
  }).join('');
  fs.writeFileSync('release-assets/SHA256SUMS.txt', checksums);
  files.push('SHA256SUMS.txt');
  let release;
  try {
    release = (await github.rest.repos.getReleaseByTag({...repository, tag})).data;
  } catch (error) {
    if (error.status !== 404) throw error;
    release = (await github.rest.repos.createRelease({
      ...repository, tag_name: tag, target_commitish: context.sha,
      name: `OPlayer ${tag}`, draft: true, prerelease: match[1].includes('-'),
    })).data;
  }
  const assets = await github.paginate(github.rest.repos.listReleaseAssets, {...repository, release_id: release.id});
  for (const name of files) {
    const data = fs.readFileSync(path.join('release-assets', name));
    const previous = assets.find(asset => asset.name === name);
    if (previous) {
      const digest = `sha256:${crypto.createHash('sha256').update(data).digest('hex')}`;
      if (previous.digest === digest) continue;
      await github.rest.repos.deleteReleaseAsset({...repository, asset_id: previous.id});
    }
    await github.rest.repos.uploadReleaseAsset({
      ...repository, release_id: release.id, name, data,
      headers: {'content-type': 'application/octet-stream', 'content-length': data.length},
    });
  }
  await github.rest.repos.updateRelease({
    ...repository, release_id: release.id, draft: false,
    body: [
      releaseNotes, '', '---', '',
      'Windows · Android · Android TV · Linux · macOS 배포 빌드입니다.', '',
      '- Android: mobile APK / Android TV: tv APK (arm64-v8a, armeabi-v7a, x86_64)',
      '- Windows x64: ZIP을 풀고 oplayer.exe 실행',
      '- Linux x64: tar.gz 압축 해제 후 실행 (시스템 의존성은 README 참고)',
      '- macOS Apple Silicon: ZIP 안의 OPlayer.app (Developer ID 서명·공증 미포함)',
      '- SHA256SUMS.txt: 배포 파일 무결성 확인', '',
      `빌드 커밋: ${context.sha}`,
      `Actions: ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
    ].join('\n'),
  });
  await core.summary.addLink('Release downloads', release.html_url).write();
};
