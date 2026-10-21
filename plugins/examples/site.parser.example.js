// @oplayer {"api":3,"id":"site.parser.example","name":"HTML·XML·JSON 파서 예제","version":"1.0.0","kind":"site","sites":["example.com"],"hosts":["example.com"]}

globalThis.plugin = {
  async resolveDownload(media) {
    const text = await OPlayer.request(media.pageUrl, {response:'text'});
    const doc = await OPlayer.parse.html(text);
    const link = await doc.querySelector('a[data-media][href]');
    const title = link?.textContent.trim();
    const href = link?.getAttribute('href');
    await doc.dispose(); // Releases the parsed document and its node handles.
    if (!href) return null;
    // This example expects an absolute HTTPS URL in data-media links.
    return {url:href, title:title || media.title, headers:media.headers};
  }
};
