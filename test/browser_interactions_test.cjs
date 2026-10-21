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
