import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';

OPlugin parserPlugin(String body) => OPlugin.parse(
  '// @oplayer {"api":3,"id":"test.parser","name":"Parser","version":"1","kind":"site","sites":["example.com"],"hosts":["example.com"]}\n'
  'globalThis.plugin = {async resolveDownload(input) {$body}};',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTML5 parsing supports CSS, entities, attributes, child queries and inert scripts', () async {
    final result =
        await callPlugin(
              parserPlugin(r'''
      const doc = await OPlayer.parse.html(input.html);
      const a = await doc.querySelector('#list > a.media[data-id="2"]');
      const rows = await doc.querySelectorAll('#list a.media');
      const bold = await a.querySelector('b');
      const children = await a.children();
      const missing = await doc.querySelector('.absent');
      const data = OPlayer.parse.json((await doc.querySelector('script[type="application/json"]')).textContent);
      const result = {text:a.textContent,href:a.getAttribute('href'),name:bold.localName,
        absent:a.getAttribute('absent'),children:children.length,missing,count:rows.length,
        data,inert:globalThis.shouldNotRun == null};
      await doc.dispose();
      try { await a.querySelector('b'); } catch(e) { result.disposed = true; }
      return result;
    '''),
              'resolveDownload',
              {
                'html': '''<!doctype html><div id="list"><a class="media" href="first">One</a>
        <a class="media" data-id="2" href="https://cdn.example/movie?a=1&amp;b=2">둘 &amp; <b>Three</b></a></div>
        <script>globalThis.shouldNotRun = true;</script><script type="application/json">{"items":[1,true,null]}</script>''',
              },
            )
            as Map;
    expect(result, {
      'text': '둘 & Three',
      'href': 'https://cdn.example/movie?a=1&b=2',
      'name': 'b',
      'absent': null,
      'children': 1,
      'missing': null,
      'count': 2,
      'data': {
        'items': [1, true, null],
      },
      'inert': true,
      'disposed': true,
    });
  });

  test('XML supports qualified names, namespace matching, attributes and CDATA', () async {
    final result = await callPlugin(
      parserPlugin(r'''
      const doc = await OPlayer.parse.xml(input.xml);
      const root = (await doc.findElements('feed'))[0];
      const entries = await root.findAllElements('item', 'urn:media');
      const qualified = await doc.findAllElements('m:item');
      const wildcard = await doc.findAllElements('item', '*');
      const first = entries[0];
      return {name:first.name,local:first.localName,namespace:first.namespaceUri,
        id:first.getAttribute('id'),text:first.textContent,qualified:qualified.length,
        wildcard:wildcard.length,children:(await root.children()).length};
    '''),
      'resolveDownload',
      {'xml': '<feed xmlns:m="urn:media"><m:item id="1"><![CDATA[A < B]]> &amp; C</m:item><item>Other</item></feed>'},
    );
    expect(result, {
      'name': 'm:item',
      'local': 'item',
      'namespace': 'urn:media',
      'id': '1',
      'text': 'A < B & C',
      'qualified': 1,
      'wildcard': 2,
      'children': 2,
    });
  });

  test('parser errors are catchable and input, depth, entity and result limits apply', () async {
    final result = await callPlugin(
      parserPlugin(r'''
      const errors = [];
      for (const f of [
        () => OPlayer.parse.xml('<bad>'),
        () => OPlayer.parse.xml('<!DOCTYPE a SYSTEM "https://evil.example"><a/>'),
        () => OPlayer.parse.json('{bad}'),
        () => OPlayer.parse.html('x'.repeat(1048577)),
        () => OPlayer.parse.xml('<a>'.repeat(130) + '</a>'.repeat(130)),
        async () => (await OPlayer.parse.html('<p>x</p>'.repeat(2001))).querySelectorAll('p'),
        async () => (await OPlayer.parse.html('<div>'.repeat(100)+'x'.repeat(40000)+'</div>'.repeat(100))).querySelectorAll('div')
      ]) { try { await f(); errors.push(false); } catch(e) { errors.push(true); } }
      return errors;
    '''),
      'resolveDownload',
      {},
    );
    expect(result, List.filled(7, true));
  });

  test('parser example resolves fetched HTML through the common plugin runtime', () async {
    final plugin = OPlugin.parse(await File('plugins/examples/site.parser.example.js').readAsString());
    expect(
      await callPlugin(
        plugin,
        'resolveDownload',
        {
          'pageUrl': 'https://example.com/watch',
          'title': 'Old',
          'headers': {'Referer': 'https://example.com/watch'},
        },
        request: (url, options) async {
          expect(options['response'], 'text');
          return '<a data-media href="https://example.com/movie.mp4">New title</a>';
        },
      ),
      {
        'url': 'https://example.com/movie.mp4',
        'title': 'New title',
        'headers': {'Referer': 'https://example.com/watch'},
      },
    );
    // Native JSON can also return primitive values rather than just objects.
    expect(
      await callPlugin(parserPlugin('return OPlayer.parse.json(input.text);'), 'resolveDownload', {
        'text': jsonEncode(42),
      }),
      42,
    );
  });
}
