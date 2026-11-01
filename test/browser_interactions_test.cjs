const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../lib/features/web/browser_interactions.dart'), 'utf8').match(/r'''([\s\S]*?)''';/)[1];
let wheel;
const root = {nodeType: 1, scrollTop: 100, scrollLeft: 0, clientHeight: 600, scrollHeight: 3000, clientWidth: 800, scrollWidth: 800};
const nested = {nodeType: 1, parentElement: root, scrollTop: 50, scrollLeft: 0, clientHeight: 100, scrollHeight: 500, clientWidth: 100, scrollWidth: 100};
const context = {
  window: {innerWidth: 800, innerHeight: 600, addEventListener: (name, fn) => { wheel = fn; }},
  document: {scrollingElement: root},
  getComputedStyle: () => ({overflowY: 'auto', overflowX: 'auto'}),
};
vm.runInNewContext(source, context);
function scroll(extra = {}) {
  const event = {cancelable: true, deltaY: 120, deltaX: 0, deltaMode: 0, target: nested,
    preventDefault() { this.defaultPrevented = true; }, ...extra};
  wheel(event);
  return event;
}
assert(scroll().defaultPrevented);
assert.equal(nested.scrollTop, 98);
assert.equal(root.scrollTop, 100);
nested.scrollTop = 0;
scroll({deltaY: -120});
assert.equal(root.scrollTop, 52);
assert(!scroll({ctrlKey: true}).defaultPrevented);
assert(!scroll({cancelable: false}).defaultPrevented);
assert(!scroll({target: {...nested, closest: () => ({})}}).defaultPrevented);
scroll({deltaMode: 1, deltaY: 3, target: root});
assert.equal(root.scrollTop, 71.2);
console.log('browser wheel scaling and nested scrolling passed');

const linkScript = fs.readFileSync(path.join(__dirname, '../lib/features/web/browser_interactions.dart'), 'utf8')
  .match(/const browserLinkMenuScript = r'''([\s\S]*?)''';/)[1];
let menu;
const calls = [];
const linkWindow = {
  flutter_inappwebview: {callHandler: (...args) => calls.push(args)},
  addEventListener: (name, fn) => { assert.equal(name, 'contextmenu'); menu = fn; },
};
vm.runInNewContext(linkScript, {window: linkWindow});
function contextMenu(href, raw = href) {
  const event = {
    target: {closest: () => href == null ? null : {href, getAttribute: () => raw, textContent: 'Link'}},
    preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; },
  };
  menu(event);
  return event;
}
assert(contextMenu('https://example.com/relative', '/relative').prevented);
assert.deepEqual(calls[0], ['oplayerLinkMenu', 'https://example.com/relative']);
assert(contextMenu('https://example.com/image-link').stopped);
assert(!contextMenu(null).prevented);
assert(!contextMenu('javascript:alert(1)').prevented);
assert(!contextMenu('magnet:?xt=urn:btih:123').prevented);
delete linkWindow.flutter_inappwebview;
assert(!contextMenu('https://example.com/no-bridge').prevented);
console.log('browser link context menu preserves relative links and non-link gestures');
