import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../sources/cloud/cloud_sources.dart';
import '../../sources/server_store.dart';

/// Provider transport is implemented by a resource extension with the sync capability.
class PluginSyncStorage {
  PluginSyncStorage(CloudAccount account, {this.clientFactory}) : source = CloudSource(account);
  final CloudSource source;
  final http.Client Function()? clientFactory;
  static const maxBytes = 4 * 1024 * 1024;
  Future<Object?> _call(String method, Map<String, dynamic> input) => clientFactory == null
      ? source.syncCall(method, input)
      : http.runWithClient(() => source.syncCall(method, input), clientFactory!);
  Future<({String id, String email})> account() async {
    final result = await _call('syncAccount', {});
    if (result is! Map || result['id'] is! String || (result['id'] as String).isEmpty || result['name'] is! String) {
      throw const FormatException('확장앱의 동기화 계정 응답이 올바르지 않습니다');
    }
    return (id: result['id'] as String, email: result['name'] as String);
  }

  Future<List<({String id, String name})>> files() async {
    final result = await _call('syncList', {});
    if (result is! List || result.length > 512) throw const FormatException('동기화 파일 목록이 올바르지 않습니다');
    final files = <({String id, String name})>[];
    for (final file in result) {
      if (file is! Map || file['id'] is! String || file['name'] is! String) throw const FormatException('잘못된 동기화 파일');
      files.add((id: file['id'] as String, name: file['name'] as String));
    }
    return files;
  }

  Future<Map<String, dynamic>> read(String id) async {
    final result = await _call('syncRead', {'id': id});
    if (result is! Map || utf8.encode(jsonEncode(result)).length > maxBytes) {
      throw const FormatException('동기화 문서가 올바르지 않거나 너무 큽니다');
    }
    return result.cast<String, dynamic>();
  }

  String fileName(String device) => 'oplayer-sync-v1-$device.json';
  Future<void> write(String device, Map<String, dynamic> document, {String? id}) async {
    if (utf8.encode(jsonEncode(document)).length > maxBytes) throw StateError('동기화 데이터는 4MiB까지 지원합니다');
    final result = await _call('syncWrite', {
      'name': fileName(device),
      'device': device,
      'document': document,
      if (id != null) 'id': id,
    });
    if (result != true) throw StateError('확장앱에서 동기화 저장을 확인하지 못했습니다');
  }

  Future<void> close() => source.close();
}
