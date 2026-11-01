import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// WebView creation and navigation callbacks can wrap the same platform view in
// different Dart controllers. Wrapper identity must not block normal navigation.
bool isSameBrowserView(InAppWebViewController first, InAppWebViewController? second) =>
    second != null && identical(first.platform, second.platform);

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

const browserLinkMenuScript = r'''
(function(){
  if (window.__oplayerLinkMenu) return;
  window.__oplayerLinkMenu = true;
  window.addEventListener('contextmenu', function(e){
    var node = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    var bridge = window.flutter_inappwebview;
    if (!node || !bridge || typeof bridge.callHandler !== 'function') return;
    if (!/^https?:\/\//i.test(node.href)) return;
    e.preventDefault();
    e.stopPropagation();
    bridge.callHandler('oplayerLinkMenu', node.href);
  }, true);
})();
''';
