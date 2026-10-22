// @oplayer {"api":4,"id":"site.example","name":"사이트 확장 예제","version":"1.0.1","kind":"browser","sites":["example.com"],"hosts":["example.com"],"blockRules":[{"urlFilter":"^https?://ads\\.example\\.com/"}],"capabilities":["page","resolveDownload","blockRequests"]}
globalThis.plugin = {
  // Runs in matching pages only. The API reports media to OPlayer's detected list.
  page(api) {
    const scan = () => document.querySelectorAll('video[src], source[src], a[data-oplayer-media]').forEach(e =>
      api.reportMedia(e.src || e.href, /\.m3u8(?:\?|$)/i.test(e.src || e.href) ? 'hls' : ''));
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan, {once:true}); else scan();
  },
  // Used for BOTH playback and download. Real plugins may call OPlayer.request.
  resolveDownload(media) { return {url:media.url, headers:media.headers, kind:media.kind}; }
};
