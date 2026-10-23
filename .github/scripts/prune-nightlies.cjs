const nightly = /^v\d+\.\d+\.\d+-nightly\.[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*$/;

function obsoleteNightlies(releases) {
  return releases.filter(r => r.draft === false && r.prerelease === true && nightly.test(r.tag_name))
    .sort((a, b) => b.tag_name.localeCompare(a.tag_name, 'en', {numeric: true})).slice(3);
}

async function pruneNightlies({github, context, core}) {
  const repository = {owner: context.repo.owner, repo: context.repo.repo};
  const releases = await github.paginate(github.rest.repos.listReleases, {...repository, per_page: 100});
  for (const release of obsoleteNightlies(releases)) {
    // Removing a release also removes its assets; commits and branches are untouched.
    try {
      await github.rest.repos.deleteRelease({...repository, release_id: release.id});
    } catch (error) { if (error.status !== 404) throw error; }
    try {
      await github.rest.git.deleteRef({...repository, ref: `tags/${release.tag_name}`});
    } catch (error) { if (error.status !== 404) throw error; }
    core.info(`Removed old nightly release and tag: ${release.tag_name}`);
  }
}

module.exports = {obsoleteNightlies, pruneNightlies};
