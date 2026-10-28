import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/network_service.dart';
import 'plugin.dart';
import 'upscale_network.dart';
import 'plugin_runtime.dart';
import 'plugin_store.dart';

const maxUpscaleModelBytes = 512 * 1024;

/// A fragment-only CNN program: no external textures/files, compute buffers,
/// loops or unbounded render targets. Models are data, never native commands.
void validateUpscaleShader(String shader) {
  if (shader.isEmpty || utf8.encode(shader).length > maxUpscaleModelBytes || shader.contains('\u0000')) {
    throw const FormatException('모델은 512KB 이하의 mpv GLSL 텍스트여야 합니다');
  }
  final code = shader.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\n]*'), '');
  if (RegExp(r'#\s*(include|extension|version)\b|\b(for|while|do|imageStore|atomicAdd)\b').hasMatch(code)) {
    throw const FormatException('지원하지 않는 셰이더 명령입니다');
  }
  var hooks = 0;
  final widths = <String, int>{'LUMA': 1, 'MAIN': 1, 'RGB': 1};
  final heights = Map<String, int>.of(widths);
  String? hook, saved, root;
  var width = 1, height = 1;
  void finishPass() {
    if (hook == null) return;
    widths[saved ?? hook] = width;
    heights[saved ?? hook] = height;
  }

  for (final line in const LineSplitter().convert(shader)) {
    if (!line.trimLeft().startsWith('//!')) continue;
    final directive = line.trimLeft().substring(3).trim();
    final key = directive.split(RegExp(r'\s+')).first;
    final value = directive.substring(key.length).trim();
    if (!const {'DESC', 'HOOK', 'BIND', 'SAVE', 'WIDTH', 'HEIGHT', 'COMPONENTS', 'WHEN'}.contains(key)) {
      throw FormatException('지원하지 않는 셰이더 지시어: $key');
    }
    if (key == 'HOOK') {
      finishPass();
      hooks++;
      if (!const {'LUMA', 'MAIN', 'RGB'}.contains(value) || root != null && root != value) {
        throw const FormatException('모델은 하나의 LUMA·MAIN·RGB 입력을 사용해야 합니다');
      }
      root = value;
      hook = value;
      saved = null;
      width = widths[value]!;
      height = heights[value]!;
    }
    if ((key == 'SAVE' || key == 'BIND') && !RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(value)) {
      throw const FormatException('외부 파일·텍스처를 참조할 수 없습니다');
    }
    if ((key == 'WIDTH' || key == 'HEIGHT') && !RegExp(r'^[A-Za-z][A-Za-z0-9_]*\.[wh](?: [12] \*)?$').hasMatch(value)) {
      throw const FormatException('모델은 한 단계 최대 2배 확대만 지원합니다');
    }
    if (key == 'SAVE') saved = value;
    if (key == 'WIDTH' || key == 'HEIGHT') {
      final name = value.split('.').first;
      final size = (key == 'WIDTH' ? widths : heights)[name];
      final scaled = (size ?? 0) * (value.endsWith('2 *') ? 2 : 1);
      if (scaled < 1 || scaled > 2) throw const FormatException('모델의 전체 출력은 최대 2배여야 합니다');
      if (key == 'WIDTH') {
        width = scaled;
      } else {
        height = scaled;
      }
    }
    if (key == 'COMPONENTS' && !const {'1', '2', '3', '4'}.contains(value)) {
      throw const FormatException('잘못된 모델 채널 수');
    }
  }
  if (hooks == 0 || hooks > 32 || !RegExp(r'\bvec4\s+hook\s*\(').hasMatch(code)) {
    throw const FormatException('mpv GLSL 모델이 아닙니다. ONNX·NCNN 파일은 지원하지 않습니다');
  }
}

class UpscaleModel {
  UpscaleModel(this.key, this.name, this.description, this.digest, this.license, this.source, {this.provider, this.id});
  final String key, name, description, digest, license, source;
  final OPlugin? provider;
  final String? id;
}

/// Only installed, enabled JS providers expose AI models. User URL models
/// are downloaded once; only verified text in our own cache reaches libmpv.
class UpscaleModels {
  UpscaleModels({PluginStore? store, this.directory, http.Client Function()? clientFactory})
    : store = store ?? PluginStore.instance,
      _clientFactory = clientFactory ?? (() => IOClient(NetworkService.instance.createHttpClient(browser: true)));
  static final instance = UpscaleModels();
  final PluginStore store;
  final Directory? directory;
  final http.Client Function() _clientFactory;
  final errors = <String, String>{};
  final _pending = <String, Future<File>>{};
  Future<Directory> _directory() async =>
      directory ?? Directory('${(await getApplicationSupportDirectory()).path}/ai-upscale');
  bool get available => store.enabled.any((p) => p.supports('upscaling'));
  void _requireProvider() {
    if (!available) throw StateError('업스케일 모델 확장앱을 설치하고 켜 주세요');
  }

  Future<List<UpscaleModel>> fromPlugin(OPlugin provider) async {
    if (provider.kind != 'player' || !provider.supports('upscaling')) throw StateError('업스케일 확장앱이 아닙니다');
    final result = await callPlugin(provider, 'upscaleModels', {}, config: store.publicSettings(provider));
    if (result is! List || result.length > 30) throw const FormatException('잘못된 모델 목록');
    final ids = <String>{};
    return result.map((item) {
      if (item is! Map ||
          !RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch('${item['id']}') ||
          !ids.add(item['id'] as String) ||
          item['format'] != 'mpv-glsl' ||
          item['scale'] != 2 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch('${item['sha256']}') ||
          [
            'name',
            'description',
            'license',
            'source',
          ].any((k) => item[k] is! String || (item[k] as String).length > 512)) {
        throw const FormatException('모델 이름·형식·라이선스·SHA-256을 확인해 주세요');
      }
      repositoryUri(item['source'] as String);
      return UpscaleModel(
        '${provider.id}/${item['id']}',
        item['name'] as String,
        item['description'] as String,
        item['sha256'] as String,
        item['license'] as String,
        item['source'] as String,
        provider: provider,
        id: item['id'] as String,
      );
    }).toList();
  }

  Future<List<UpscaleModel>> catalog() async {
    errors.clear();
    final result = <UpscaleModel>[];
    if (!available) return result;
    final providers = store.enabled.where((p) => p.supports('upscaling'));
    for (final provider in providers) {
      try {
        result.addAll(await fromPlugin(provider));
      } catch (e) {
        errors[provider.name] = '$e';
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final entry in prefs.getStringList('upscaleUrlModels') ?? <String>[]) {
      final data = jsonDecode(entry) as Map;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch('${data['sha256']}')) continue;
      result.add(
        UpscaleModel(
          'url/${data['sha256']}',
          data['name'] as String,
          'URL로 추가한 모델',
          data['sha256'] as String,
          '사용자 모델 · 원본 라이선스 확인',
          data['url'] as String,
        ),
      );
    }
    return result;
  }

  Future<File> _file(String digest) async => File('${(await _directory()).path}/$digest.glsl');
  Future<File> materialize(UpscaleModel model) async {
    _requireProvider();
    if (model.provider != null) store.require(model.provider!.id);
    final job = _pending[model.digest] ?? _materialize(model);
    _pending[model.digest] = job;
    try {
      final file = await job;
      _requireProvider();
      if (model.provider != null) store.require(model.provider!.id);
      return file;
    } finally {
      if (_pending[model.digest] == job) _pending.remove(model.digest);
    }
  }

  Future<File> _materialize(UpscaleModel model) async {
    final file = await _file(model.digest);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (sha256.convert(bytes).toString() == model.digest) {
        validateUpscaleShader(utf8.decode(bytes));
        return file;
      }
    }
    final provider = model.provider;
    if (provider == null) throw StateError('모델 파일이 없거나 손상됐습니다. URL로 다시 추가해 주세요');
    store.require(provider.id);
    final result = await callPlugin(provider, 'upscaleModel', {'id': model.id}, config: store.publicSettings(provider));
    if (result is! Map || result['format'] != 'mpv-glsl' || result['shader'] is! String) {
      throw const FormatException('모델 응답은 mpv GLSL 셰이더여야 합니다');
    }
    final shader = result['shader'] as String;
    validateUpscaleShader(shader);
    if (sha256.convert(utf8.encode(shader)).toString() != model.digest) throw StateError('모델 SHA-256이 일치하지 않습니다');
    await file.parent.create(recursive: true);
    await file.writeAsString(shader, flush: true);
    return file;
  }

  Future<String> resolve(String key) async {
    final models = await catalog();
    final model = models.where((m) => m.key == key).firstOrNull;
    if (model == null) throw StateError('선택한 모델의 확장앱을 켜거나 다른 모델을 선택해 주세요');
    return (await materialize(model)).absolute.path;
  }

  Future<String?> network(String key) async {
    final model = (await catalog()).where((m) => m.key == key).firstOrNull;
    if (model == null) throw StateError('모델 확장앱을 켜 주세요');
    final shader = await materialize(model);
    final bytes = upscaleNetwork(await shader.readAsString());
    if (bytes == null) return null;
    final file = File('${shader.path}.ous');
    if (!await file.exists() || sha256.convert(await file.readAsBytes()) != sha256.convert(bytes)) {
      await file.writeAsBytes(bytes, flush: true);
    }
    _requireProvider();
    if (model.provider != null) store.require(model.provider!.id);
    return file.absolute.path;
  }

  Future<UpscaleModel> addUrl(String value, String name) async {
    _requireProvider();
    final uri = repositoryUri(value);
    final fallback = (uri.pathSegments.lastOrNull ?? '사용자 모델').replaceFirst(
      RegExp(r'\.glsl$', caseSensitive: false),
      '',
    );
    if (name.trim().isEmpty) {
      final derived = fallback.isEmpty ? '사용자 모델' : fallback;
      name = derived.substring(0, derived.length > 100 ? 100 : derived.length);
    }
    if (uri.scheme != 'https' || uri.hasFragment || name.trim().isEmpty || name.length > 100) {
      throw const FormatException('모델 이름과 HTTPS GLSL 주소를 입력해 주세요');
    }
    final client = _clientFactory();
    final bytes = <int>[];
    try {
      await (() async {
        var current = uri;
        for (var count = 0; count <= 5; count++) {
          final response = await client
              .send(http.Request('GET', current)..followRedirects = false)
              .timeout(const Duration(seconds: 20));
          if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
            await response.stream.drain<void>().timeout(const Duration(seconds: 10));
            final location = response.headers['location'];
            if (location == null || count == 5) throw StateError('모델 다운로드 리디렉션 오류');
            current = repositoryUri(current.resolve(location).toString());
            if (current.scheme != 'https') throw StateError('모델 다운로드는 HTTPS만 지원합니다');
            continue;
          }
          if (response.statusCode != 200) throw StateError('모델 다운로드 실패: HTTP ${response.statusCode}');
          await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
            bytes.addAll(chunk);
            if (bytes.length > maxUpscaleModelBytes) throw const FormatException('모델은 512KB 이하여야 합니다');
          }
          break;
        }
      })().timeout(const Duration(seconds: 45));
    } finally {
      client.close();
    }
    _requireProvider();
    final shader = utf8.decode(bytes);
    validateUpscaleShader(shader);
    final digest = sha256.convert(bytes).toString();
    final file = await _file(digest);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    final prefs = await SharedPreferences.getInstance();
    final entries = [...?prefs.getStringList('upscaleUrlModels')];
    entries.removeWhere((e) => (jsonDecode(e) as Map)['sha256'] == digest);
    if (entries.length >= 30) throw StateError('URL 모델은 최대 30개까지 추가할 수 있습니다');
    entries.add(jsonEncode({'sha256': digest, 'url': uri.toString(), 'name': name.trim()}));
    if (!await prefs.setStringList('upscaleUrlModels', entries)) throw StateError('모델 목록을 저장하지 못했습니다');
    return UpscaleModel('url/$digest', name.trim(), 'URL로 추가한 모델', digest, '사용자 모델', uri.toString());
  }

  Future<void> removeUrl(UpscaleModel model) async {
    if (!model.key.startsWith('url/')) throw StateError('기본·확장앱 모델은 삭제할 수 없습니다');
    final prefs = await SharedPreferences.getInstance();
    final entries = [...?prefs.getStringList('upscaleUrlModels')];
    entries.removeWhere((e) => (jsonDecode(e) as Map)['sha256'] == model.digest);
    if (!await prefs.setStringList('upscaleUrlModels', entries)) throw StateError('모델 삭제를 저장하지 못했습니다');
    // Keep content-addressed cache files: a playing renderer may still use one,
    // and another provider can legitimately reference the same shader.
  }
}
