const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const docs = path.join(__dirname, '..', 'docs');
const script = fs.readFileSync(path.join(docs, 'legacy-redirect.js'), 'utf8');
function redirect(url) {
  const source = new URL(url);
  let destination;
  const location = {
    hostname: source.hostname, pathname: source.pathname,
    search: source.search, hash: source.hash,
    replace(value) { destination = value; },
  };
  vm.runInNewContext(script, { window: { location } });
  return destination;
}
for (const page of ['', 'privacy.html', 'terms.html', 'sitemap.html']) {
  const file = page || 'index.html';
  assert.match(fs.readFileSync(path.join(docs, file), 'utf8'), /<script src="legacy-redirect\.js"><\/script>/);
  for (const host of ['gaeco0.github.io', 'oplayer.gaeco.kr']) {
    assert.equal(redirect(`https://${host}/OPlayer/${page}?review=1#details`), `https://oplayer.gaeco.kr/${page}?review=1#details`);
  }
}
assert.equal(redirect('https://gaeco0.github.io/OPlayer'), 'https://oplayer.gaeco.kr/');
for (const url of ['https://oplayer.gaeco.kr/', 'https://oplayer.gaeco.kr/privacy.html', 'https://example.com/OPlayer/privacy.html', 'https://gaeco0.github.io/OPlayerOther/']) {
  assert.equal(redirect(url), undefined);
}
console.log('Legacy page redirects preserve paths, queries and fragments without looping on the canonical site.');
