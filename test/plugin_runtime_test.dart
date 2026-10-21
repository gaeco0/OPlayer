import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';

OPlugin sample(String body) => OPlugin.parse(
  '''// @oplayer {"api":1,"id":"test.site","name":"Test","version":"1","kind":"site","sites":["example.com"],"hosts":["api.example.com"]}
globalThis.plugin = {$body};
''',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('plugin scopes are exact or explicit wildcard, never suffix lookalikes', () {
    final plugin = sample('');
    expect(plugin.matches('https://example.com/watch'), true);
    expect(plugin.matches('https://evil-example.com/watch'), false);
    expect(plugin.matches('https://example.com.evil/watch'), false);
    expect(plugin.allows('https://api.example.com/data'), true);
    expect(plugin.allows('http://api.example.com/data'), false);
    expect(OPlugin.matchesHost('cdn.example.com', ['*.example.com']), true);
    expect(OPlugin.matchesHost('example.com', ['*.example.com']), false);
    expect(() => repositoryUri('file:///private'), throwsFormatException);
    expect(() => OPlugin.parse('// @oplayer {"api":99}'), throwsFormatException);
  });
  test('JS executes synchronously and asynchronously with host-scoped HTTP', () async {
    final plugin = sample(
      "async resolveDownload({url}) { const a = await OPlayer.request('https://api.example.com/resolve'); return {url:a.url, headers:{Referer:url}}; }",
    );
    var requests = 0;
    final result =
        await callPlugin(
              plugin,
              'resolveDownload',
              {'url': 'https://example.com/watch'},
              request: (url, options) async {
                requests++;
                return {'url': 'https://cdn.example.com/movie.m3u8'};
              },
            )
            as Map;
    expect(requests, 1);
    expect(result['url'], 'https://cdn.example.com/movie.m3u8');
    expect(result['headers'], {'Referer': 'https://example.com/watch'});
    expect(await callPlugin(sample(''), 'resolveDownload', {}), null);
  });
  test('network outside declared domains is rejected before sending', () async {
    var sent = false;
    await expectLater(
      callPlugin(
        sample("resolveDownload() { return OPlayer.request('https://evil.example/private'); }"),
        'resolveDownload',
        {},
        request: (_, __) async {
          sent = true;
          return {};
        },
      ),
      throwsStateError,
    );
    expect(sent, false);
  });
  test('native interrupt terminates infinite JS and promise loops', () async {
    final timer = Stopwatch()..start();
    await expectLater(
      callPlugin(sample('resolveDownload() { while(true) {} }'), 'resolveDownload', {}),
      throwsStateError,
    );
    expect(timer.elapsed.inSeconds, lessThan(4));
    await expectLater(
      callPlugin(sample('async resolveDownload() { while(true) { await Promise.resolve(); } }'), 'resolveDownload', {}),
      throwsStateError,
    );
  });
  test('bundled cloud plugins preserve pagination and stream contracts', () async {
    for (final id in ['gdrive', 'dropbox', 'onedrive']) {
      final p = OPlugin.parse(await File('plugins/cloud.$id.js').readAsString());
      var page = 0;
      final rows =
          await callPlugin(
                p,
                'list',
                {'path': id == 'dropbox' ? '' : 'root'},
                request: (url, options) async {
                  page++;
                  if (id == 'gdrive') {
                    return {
                      'files': [
                        {'name': 'video.mp4', 'id': 'file', 'mimeType': 'video/mp4'},
                      ],
                      if (page == 1) 'nextPageToken': 'next',
                    };
                  }
                  if (id == 'dropbox') {
                    return {
                      'entries': [
                        {'name': 'video.mp4', 'path_lower': '/video.mp4', '.tag': 'file'},
                      ],
                      'has_more': page == 1,
                      'cursor': 'next',
                    };
                  }
                  return {
                    'value': [
                      {'name': 'video.mp4', 'id': 'file'},
                    ],
                    if (page == 1) '@odata.nextLink': 'https://graph.microsoft.com/next',
                  };
                },
              )
              as List;
      expect(page, 2);
      expect(rows.length, 2);
      expect(rows.first['name'], 'video.mp4');
    }
  });
}
