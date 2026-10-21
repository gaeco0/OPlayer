/// Scale mouse wheels inside the web page, preserving nested scrolling and zoom.
const browserInteractionScript = r'''
(function(){
  if (window.__oplayerWheel) return;
  window.__oplayerWheel = true;
  window.addEventListener('wheel', function(e){
    if (!e.cancelable || e.defaultPrevented || e.ctrlKey || e.metaKey || document.fullscreenElement) return;
    if (e.target && e.target.closest && e.target.closest('video,input,select,[contenteditable="true"]')) return;
    var dx = e.deltaX || 0, dy = e.deltaY || 0;
    if (e.deltaMode === 1) { dx *= 16; dy *= 16; }
    if (e.deltaMode === 2) { dx *= window.innerWidth; dy *= window.innerHeight; }
    if (e.shiftKey && !dx) { dx = dy; dy = 0; }
    dx *= 0.4; dy *= 0.4;
    var root = document.scrollingElement;
    for (var node = e.target; node; node = node.parentElement) {
      if (node.nodeType !== 1) continue;
      var style = getComputedStyle(node);
      var vertical = dy && (node === root || /auto|scroll|overlay/.test(style.overflowY)) &&
        (dy < 0 ? node.scrollTop > 0 : node.scrollTop + node.clientHeight < node.scrollHeight);
      var horizontal = dx && (node === root || /auto|scroll|overlay/.test(style.overflowX)) &&
        (dx < 0 ? node.scrollLeft > 0 : node.scrollLeft + node.clientWidth < node.scrollWidth);
      if (vertical || horizontal) {
        e.preventDefault();
        node.scrollTop += dy;
        node.scrollLeft += dx;
        return;
      }
    }
  }, {passive: false, capture: true});
})();
''';
