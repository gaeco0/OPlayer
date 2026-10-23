const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('plugins/site.disable-devtool.js', 'utf8');
const manifest = JSON.parse(source.split('\n')[0].slice(12));
const rule = new RegExp(manifest.blockRules[0].urlFilter);
for (const url of [
  'https://cdn.jsdelivr.net/npm/disable-devtool@latest',
  'https://cdn.jsdelivr.net/npm/disable-devtool@0.3.8/disable-devtool.min.js',
  'https://site.example/js/disable-devtool.min.js?v=1',
  'https://unpkg.com/disable-devtool',
]) assert(rule.test(url), url);
for (const url of ['https://example.com/video.mp4', 'https://example.com/app.js?name=disable-devtool']) {
  assert(!rule.test(url), url);
}

function environment(config = {}) {
  let logged = 0;
  const error = () => {};
  const window = {console: {log() { logged++; }, warn: error, error}};
  const context = vm.createContext({window});
  vm.runInContext(source, context);
  context.plugin.page({config});
  return {window, context, error, logged: () => logged};
}
const guard = environment();
assert.equal(guard.window.DisableDevtool().success, true);
assert.equal(guard.window.DisableDevtool.isRunning, false);
assert.equal(guard.window.DisableDevtool.isDevToolOpened(), false);
const original = () => { throw Error('must not execute detector'); };
guard.window.DisableDevtool = original;
assert.equal(original.isSuspend, true);
assert.equal(guard.window.DisableDevtool().success, true);
guard.window.console.log({get id() { throw Error('must not inspect getters'); }});
assert.equal(guard.logged(), 0);
assert.equal(guard.window.console.error, guard.error);
assert.equal(guard.window.console.warn, guard.error);
const first = guard.window.DisableDevtool;
guard.context.plugin.page({config: {}});
assert.equal(guard.window.DisableDevtool, first);

const optional = environment({consoleGuard: false});
optional.window.console.log('normal log');
assert.equal(optional.logged(), 1);
// Do not tamper with fetch, XHR, timers, history, or navigation APIs.
assert.equal(optional.window.fetch, undefined);
assert.equal(optional.window.history, undefined);
assert.equal(optional.window.setInterval, undefined);
console.log('disable-devtool request rules, API guard, optional console guard passed');
