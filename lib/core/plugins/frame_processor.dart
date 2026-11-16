import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../network/network_service.dart';
import 'plugin.dart';
import 'plugin_runtime.dart';

/// A provider's frame program runs against native frame buffers. Pixels never
/// cross the JSON bridge; native inference/shaders return them to the renderer.
Future<Map<String, dynamic>?> frameProcessor(
  OPlugin plugin,
  Map<String, dynamic> input, {
  Map<String, dynamic> config = const {},
}) async {
  final result = await callPlugin(plugin, 'frameProcessor', input, config: config);
  if (result == null) return null;
  if (result is! Map ||
      result['engine'] is! String ||
      result['inputFrames'] is! int ||
      result['outputFrames'] is! int ||
      (result['inputFrames'] as int) < 1 ||
      (result['inputFrames'] as int) > 2 ||
      result['outputFrames'] != 1) {
    throw const FormatException('잘못된 프레임 처리 프로그램');
  }
  return result.cast<String, dynamic>();
}

final _frameJobs = <String, Set<Future<String>>>{};

Future<String> prepareFrameModel(
  OPlugin plugin,
  Map<String, dynamic> program, {
  Directory? directory,
  http.Client Function()? clientFactory,
}) async {
  final job = _prepareFrameModel(plugin, program, directory: directory, clientFactory: clientFactory);
  final jobs = _frameJobs.putIfAbsent(plugin.id, () => {});
  jobs.add(job);
  try {
    return await job;
  } finally {
    jobs.remove(job);
    if (jobs.isEmpty) _frameJobs.remove(plugin.id);
  }
}

Future<void> removeFrameModelCache(String pluginId, {Directory? directory}) async {
  for (final job in [...?_frameJobs[pluginId]]) {
    try {
      await job;
    } catch (_) {
      /* Failed model preparations have no usable program. */
    }
  }
  final base = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'frame-processors'));
  final target = Directory(p.join(base.path, pluginId));
  if (!p.isWithin(base.absolute.path, target.absolute.path)) throw ArgumentError.value(pluginId);
  if (await target.exists()) await target.delete(recursive: true);
}

/// Model graph/weights, names and digests come from the provider, not app assets.
Future<String> _prepareFrameModel(
  OPlugin plugin,
  Map<String, dynamic> program, {
  Directory? directory,
  http.Client Function()? clientFactory,
}) async {
  final artifacts = program['artifacts'];
  if (artifacts is! List || artifacts.isEmpty || artifacts.length > 8) throw const FormatException('잘못된 프레임 모델 파일 목록');
  final names = <String>{};
  for (final item in artifacts) {
    if (item is! Map ||
        item['name'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]+\.(param|bin)$').hasMatch(item['name'] as String) ||
        !names.add(item['name'] as String) ||
        item['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['sha256'] as String) ||
        item['url'] is! String ||
        !plugin.allows(item['url'] as String)) {
      throw const FormatException('프레임 모델 파일의 이름·해시·도메인을 확인하세요');
    }
  }
  final digest = sha256.convert(utf8.encode(jsonEncode(artifacts))).toString();
  final base = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'frame-processors'));
  final target = Directory(p.join(base.path, plugin.id, digest));
  await target.create(recursive: true);
  final staging = await target.createTemp('.prepare-');
  final client = (clientFactory ?? () => IOClient(NetworkService.instance.createHttpClient()))();
  try {
    for (final item in artifacts) {
      final file = File(p.join(target.path, item['name'] as String));
      if (await file.exists() && sha256.convert(await file.readAsBytes()).toString() == item['sha256']) continue;
      var url = item['url'] as String;
      final output = File(p.join(staging.path, item['name'] as String));
      var downloaded = false;
      for (var redirects = 0; redirects <= 5; redirects++) {
        if (!plugin.allows(url)) throw const FormatException('허용되지 않은 모델 다운로드 주소');
        final response = await client
            .send(http.Request('GET', Uri.parse(url))..followRedirects = false)
            .timeout(const Duration(seconds: 30));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          await response.stream.drain<void>().timeout(const Duration(seconds: 30));
          final next = response.headers['location'];
          if (next == null) throw const FormatException('모델 다운로드 리디렉션 주소 없음');
          url = Uri.parse(url).resolve(next).toString();
          continue;
        }
        if (response.statusCode != 200) throw HttpException('모델 다운로드 HTTP ${response.statusCode}');
        var size = 0;
        final sink = output.openWrite();
        try {
          await sink.addStream(
            response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
              size += chunk.length;
              if (size > 64 * 1024 * 1024) throw const FormatException('모델 파일은 64MB 이하여야 합니다');
              return chunk;
            }),
          );
        } finally {
          await sink.close();
        }
        if (sha256.convert(await output.readAsBytes()).toString() != item['sha256']) {
          throw const FormatException('프레임 모델 무결성 확인 실패');
        }
        await output.rename(file.path);
        downloaded = true;
        break;
      }
      if (!downloaded) throw const FormatException('모델 다운로드 리디렉션 제한 초과');
    }
    return target.path;
  } finally {
    client.close();
    await staging.delete(recursive: true);
  }
}
