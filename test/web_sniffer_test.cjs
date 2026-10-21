// Run with node test/web_sniffer_test.cjs (no packages required).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const dart = fs.readFileSync(path.join(__dirname, '../lib/features/web/web_browser_page.dart'), 'utf8');
const script = dart.match(/const _snifferJs = r'''([\s\S]*?)''';/)[1];

const messages = [];
const listeners = {};
const playlist = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://key.test/v/session?v=video&p=0&t=browser&e=100"\n#EXTINF:4,\nseg.ts\n';
const media = () => messages.findLast(m => m[0] === 'oplayerMedia');
class XHR {
  open(method, url) { this.responseURL = url; }
  setRequestHeader() {}
  addEventListener(name, fn) { this.load = fn; }
  getResponseHeader(name) { return name === 'content-type' ? 'application/vnd.apple.mpegurl' : '0'; }
  finish() { this.load(); }
}
const context = {
  Headers, URL, TextDecoder, Uint8Array, XMLHttpRequest: XHR,
  document: {title: 'player', readyState: 'complete', querySelectorAll: () => [], addEventListener() {}},
  location: {href: 'https://player.test/embed'},
  setInterval() {}, addEventListener(name, fn) { (listeners[name] ||= []).push(fn); },
  flutter_inappwebview: {callHandler: (...args) => messages.push(args)},
  fetch: async (input) => ({
    url: String(input.url || input),
    headers: new Headers({'content-type': 'application/vnd.apple.mpegurl'}),
    clone: () => ({text: async () => playlist}),
  }),
};
context.window = context;
context.top = context;
vm.runInNewContext(script, context);

(async () => {
  const url = 'https://cdn.test/master.m3u8';
  await context.fetch(new Request(url, {headers: {'Authorization': 'Bearer first'}}));
  assert.equal(media()[6].authorization, 'Bearer first');
  await context.fetch(new Request(url, {headers: {'Authorization': 'old'}}), {
    headers: [['X-Token', 'new']],
  });
  assert.equal(media()[6]['x-token'], 'new');
  assert.equal(media()[6].authorization, undefined);
  await context.fetch(new URL(url), {headers: new Headers({'X-Token': 'url-object'})});
  assert.equal(media()[6]['x-token'], 'url-object');

  const xhr = new XHR();
  xhr.open('GET', url);
  xhr.setRequestHeader('X-Token', 'a');
  xhr.setRequestHeader('x-token', 'b');
  xhr.finish();
  assert.equal(media()[6]['x-token'], 'a, b');
  xhr.open('GET', url);
  xhr.setRequestHeader('Authorization', 'Bearer next');
  xhr.finish();
  assert.equal(media()[6].authorization, 'Bearer next');
  assert.equal(media()[6]['x-token'], undefined);
  assert.equal(media()[5], 'https://player.test/embed');
  xhr.responseType = 'text';
  xhr.responseText = playlist;
  xhr.finish();
  assert.equal(messages.at(-1)[0], 'oplayerHlsPlaylist');
  assert.equal(messages.at(-1)[2], playlist);
  class Hls { trigger() { return 'original-result'; } }
  context.Hls = Hls;
  const hls = new context.Hls();
  const key = new Uint8Array(16).fill(7);
  const decryptdata = {method: 'AES-128', keyFormat: 'identity', uri: url + '?key=1', key};
  assert.equal(hls.trigger('hlsKeyLoaded', {frag: {decryptdata}}), 'original-result');
  assert.equal(messages.at(-1)[0], 'oplayerHlsKey');
  assert.equal(messages.at(-1)[1], decryptdata.uri);
  assert.deepEqual(Array.from(messages.at(-1)[2]), Array.from(key));
  const count = messages.length;
  hls.trigger('hlsKeyLoaded', {frag: {decryptdata}});
  hls.trigger('hlsKeyLoaded', {frag: {decryptdata: {...decryptdata, method: 'SAMPLE-AES'}}});
  hls.trigger('hlsKeyLoaded', {frag: {decryptdata: {...decryptdata, keyFormat: 'com.widevine'}}});
  hls.trigger('hlsKeyLoaded', {frag: {decryptdata: {...decryptdata, key: new Uint8Array(32)}}});
  assert.equal(messages.length, count);
  const next = {...decryptdata, uri: url + '?key=2'};
  // hls.js 1.5.15 stores KeyLoader on StreamController, not on Hls itself.
  hls.streamController = {keyLoader: {keyUriToKeyInfo: {[next.uri]: {decryptdata: next}}}};
  hls.trigger('hlsFragChanged');
  assert.equal(messages.at(-1)[1], next.uri);
  const rotated = [3, 4].map(n => ({decryptdata: {...decryptdata, uri: url + '?key=' + n, key: null}}));
  hls.url = url;
  hls.levels = [{details: {fragments: [{decryptdata}, ...rotated, rotated[0]]}}];
  const requested = [];
  hls.streamController.keyLoader.load = async frag => {
    requested.push(frag.decryptdata.uri);
    frag.decryptdata.key = new Uint8Array(16).fill(requested.length);
    return {frag};
  };
  for (const fn of listeners.message) fn({data: {__oplayerPrepareKeys: url}});
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(requested, rotated.map(f => f.decryptdata.uri));
  for (const frag of rotated) assert(messages.some(m => m[0] === 'oplayerHlsKey' && m[1] === frag.decryptdata.uri));
  const failed = {...decryptdata, uri: url + '?key=failed', key: null};
  hls.levels = [{details: {fragments: [{decryptdata: failed}]}}];
  hls.streamController.keyLoader.load = async () => { throw {data:{error:Error('key request rejected')}}; };
  for (const fn of listeners.message) fn({data: {__oplayerPrepareKeys: url}});
  await new Promise(resolve => setImmediate(resolve));
  assert(messages.some(m => m[0] === 'oplayerHlsPrepareError' && m[1] === url && m[2] === 'key request rejected'));
  console.log('fetch / XHR header and resolved HLS key capture passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
