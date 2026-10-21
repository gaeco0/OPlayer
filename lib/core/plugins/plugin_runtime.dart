import 'dart:async';
import 'dart:convert';
import 'package:quickjs_engine/quickjs_engine.dart';
import 'plugin.dart';
import 'plugin_values.dart';
import 'plugin_parser.dart';

typedef PluginRequest = Future<Object?> Function(String url, Map<String, dynamic> options);

/// No filesystem, native methods, fetch or credentials are exposed to scripts.
/// Native interrupt budget also stops synchronous loops and promise loops.
Future<Object?> callPlugin(
  OPlugin plugin,
  String method,
  Map<String, dynamic> input, {
  PluginRequest? request,
  Map<String, dynamic> config = const {},
  Map<String, dynamic> credentials = const {},
  bool Function(String)? allowsRequest,
  bool validateOnly = false,
}) async {
  if (!RegExp(r'^[a-zA-Z]+$').hasMatch(method)) throw ArgumentError.value(method);
  final js = QuickJsRuntime2(timeout: 200, memoryLimit: 32 * 1024 * 1024, stackSize: 512 * 1024);
  final parser = PluginParser();
  Object? evaluate(String code) {
    final result = js.evaluate(code);
    if (result.isError) throw StateError('${plugin.name}: ${result.stringResult}');
    return jsonDecode(result.stringResult);
  }

  try {
    // Turn off timer callbacks so no disposed runtime can be called later.
    evaluate('''
      globalThis.setTimeout = undefined;
      globalThis.sendMessage = undefined;
      globalThis.console = {log(){},warn(){},error(){}};
      globalThis.__queue = []; globalThis.__waiting = {}; globalThis.__seq = 0;
      globalThis.__host = (op, args) => new Promise((resolve, reject) => {
        const id = ++__seq; __waiting[id] = {resolve, reject}; __queue.push({id,op,...args});
      });
      $pluginParserFactory
      globalThis.OPlayer = Object.freeze({
        config: Object.freeze(${jsonEncode(config)}),
        secret: (name, options = {}) => ({\$secret:name, ...options}),
        parse: createOPlayerParser(args => __host('parse',{args})),
        crypto: Object.freeze({
          hash: (algorithm,data) => __host('crypto',{args:{method:'hash',algorithm,data}}),
          hmac: (algorithm,key,data,keyEncoding='utf8') => __host('crypto',{args:{method:'hmac',algorithm,key,data,keyEncoding}})
        }),
        request: (url, options = {}) => __host('request',{url,options})
      });
      null
    ''');
    final loaded = js.evaluate('${plugin.source}\n;null', sourceUrl: '${plugin.id}.js');
    if (loaded.isError) throw StateError('${plugin.name}: ${loaded.stringResult}');
    if (validateOnly) {
      final methods =
          evaluate("JSON.stringify(Object.keys(plugin).filter(k => typeof plugin[k] === 'function'))") as List;
      if (plugin.manifest['canDelete'] == true && !methods.contains('delete')) {
        throw StateError('삭제를 지원하는 확장앱에는 delete 함수가 필요합니다');
      }
      if (plugin.cloud
          ? !['accountName', 'list', 'stream'].every(methods.contains)
          : !methods.contains('page') &&
                !methods.contains('resolveDownload') &&
                (plugin.manifest['blockRules'] as List? ?? []).isEmpty) {
        throw StateError('필수 확장앱 기능이 없습니다');
      }
      return null;
    }
    evaluate('''
      globalThis.__done = false; globalThis.__value = null; globalThis.__error = null;
      Promise.resolve().then(() => {
        if (typeof plugin[${jsonEncode(method)}] !== 'function') return null;
        return plugin[${jsonEncode(method)}](${jsonEncode(input)});
      }).then(v => { __value = v ?? null; __done = true; }, e => { __error = String(e); __done = true; });
      null
    ''');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var requests = 0;
    while (DateTime.now().isBefore(deadline)) {
      js.executePendingJob();
      final state =
          evaluate('JSON.stringify({done:__done,value:__value,error:__error,queue:__queue.splice(0)})') as Map;
      if (state['done'] == true) {
        if (state['error'] != null) throw StateError('${plugin.name}: ${state['error']}');
        return state['value'];
      }
      final queue = state['queue'] as List;
      if (queue.isEmpty) throw StateError('${plugin.name}: 완료되지 않은 비동기 작업');
      for (final item in queue.cast<Map>()) {
        if (++requests > 200) throw StateError('확장앱 요청 횟수 제한 초과');
        final id = item['id'] as int;
        if (item['op'] == 'parse') {
          try {
            final value = parser.call(item['args'] as Map);
            evaluate('__waiting[$id].resolve(${jsonEncode(value)}); delete __waiting[$id]; null');
          } catch (e) {
            evaluate('__waiting[$id].reject(${jsonEncode('$e')}); delete __waiting[$id]; null');
          }
          continue;
        }
        if (item['op'] == 'crypto') {
          final value = pluginCrypto(item['args'] as Map, credentials);
          evaluate('__waiting[$id].resolve(${jsonEncode(value)}); delete __waiting[$id]; null');
          continue;
        }
        final url = item['url'] as String;
        final options = (item['options'] as Map).cast<String, dynamic>();
        if (!(allowsRequest?.call(url) ?? plugin.allows(url)) || request == null) {
          throw StateError('허용되지 않은 확장앱 요청: ${Uri.tryParse(url)?.host}');
        }
        try {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) throw TimeoutException('확장앱 실행 시간 초과');
          final result = await request(
            url,
            options,
          ).timeout(remaining < const Duration(seconds: 30) ? remaining : const Duration(seconds: 30));
          evaluate('__waiting[$id].resolve(${jsonEncode(result)}); delete __waiting[$id]; null');
        } catch (e) {
          evaluate('__waiting[$id].reject(${jsonEncode('$e')}); delete __waiting[$id]; null');
        }
      }
    }
    throw TimeoutException('확장앱 실행 시간 초과');
  } finally {
    js.dispose();
  }
}
