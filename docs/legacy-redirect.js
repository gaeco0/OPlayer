// GitHub Pages inherits the account domain but keeps the /OPlayer prefix.
// The canonical site is served separately at the custom domain's root.
(() => {
  const { hostname, pathname, search, hash } = window.location;
  if (!['gaeco0.github.io', 'oplayer.gaeco.kr'].includes(hostname)) return;
  if (pathname !== '/OPlayer' && !pathname.startsWith('/OPlayer/')) return;
  const path = pathname.slice('/OPlayer'.length) || '/';
  window.location.replace(`https://oplayer.gaeco.kr${path}${search}${hash}`);
})();
