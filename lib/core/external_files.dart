import 'package:flutter/services.dart';

/// Native document events are queued until Flutter and the app lock are ready.
const externalFilesChannel = MethodChannel('oplayer/open_files');

class ExternalFile {
  const ExternalFile(this.uri, {this.name = '', this.mime = ''});
  final String uri;
  final String name;
  final String mime;

  static List<ExternalFile> decode(Object? value) => value is List
      ? value
            .whereType<Map>()
            .where((e) => e['uri'] is String)
            .map(
              (e) => ExternalFile(
                e['uri'] as String,
                name: e['name'] is String ? e['name'] as String : '',
                mime: e['mime'] is String ? e['mime'] as String : '',
              ),
            )
            .toList()
      : [];
}
