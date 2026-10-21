import 'dart:convert';
import 'package:crypto/crypto.dart';

/// SigV4 stays native: scripts receive only the bucket URL and listing version.
class S3Credentials {
  S3Credentials(this.values) {
    for (final key in ['endpoint', 'bucket', 'region', 'accessKeyId', 'secretAccessKey']) {
      if (values[key] is! String || (values[key] as String).trim().isEmpty) {
        throw FormatException('S3 $key 값을 입력해 주세요');
      }
    }
    final endpoint = Uri.parse(values['endpoint'] as String);
    if (endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.scheme != 'https' &&
            !(endpoint.scheme == 'http' && ['localhost', '127.0.0.1'].contains(endpoint.host)))) {
      throw const FormatException('S3 Endpoint는 쿼리·인증정보 없는 HTTPS URL이어야 합니다');
    }
    final bucket = values['bucket'] as String;
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$').hasMatch(bucket) || bucket.contains('..')) {
      throw const FormatException('S3 버킷 이름을 확인해 주세요');
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(values['region'] as String)) {
      throw const FormatException('S3 리전을 확인해 주세요');
    }
    if (values['virtualHosted'] == true && (endpoint.path != '' && endpoint.path != '/')) {
      throw const FormatException('가상 호스트 방식에서는 Endpoint 경로를 비워 주세요');
    }
    final base = endpoint.pathSegments.toList();
    while (base.isNotEmpty && base.last.isEmpty) {
      base.removeLast();
    }
    final bucketEndpoint = endpoint.replace(
      host: values['virtualHosted'] == true ? '$bucket.${endpoint.host}' : endpoint.host,
      pathSegments: [...base, if (values['virtualHosted'] != true) bucket, ''],
    );
    bucketUri = bucketEndpoint.path.isEmpty ? bucketEndpoint.replace(path: '/') : bucketEndpoint;
  }
  final Map<String, dynamic> values;
  late final Uri bucketUri;
  Map<String, dynamic> get publicConfig => {
    'bucketUrl': bucketUri.toString(),
    'bucket': values['bucket'],
    'listV1': values['listV1'] == true,
  };

  bool allows(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.origin != bucketUri.origin) {
      return false;
    }
    final root = bucketUri.path.endsWith('/') ? bucketUri.path.substring(0, bucketUri.path.length - 1) : bucketUri.path;
    return (uri.path == root || uri.path.startsWith('$root/')) && !uri.pathSegments.any((s) => s == '.' || s == '..');
  }

  Uri presign(Uri uri, {String method = 'GET', DateTime? now, int expires = 3600}) {
    if (!allows(uri.toString()) || !['GET', 'HEAD'].contains(method) || expires < 1 || expires > 604800) {
      throw const FormatException('허용되지 않은 S3 서명 요청');
    }
    final dateTime =
        '${(now ?? DateTime.now()).toUtc().toIso8601String().split('.').first.replaceAll(RegExp('[-:]'), '')}Z';
    final date = dateTime.substring(0, 8);
    final region = values['region'] as String;
    final scope = '$date/$region/s3/aws4_request';
    final params =
        <MapEntry<String, String>>[
          for (final e in uri.queryParametersAll.entries)
            if (!e.key.toLowerCase().startsWith('x-amz-'))
              for (final v in e.value) MapEntry(e.key, v),
          const MapEntry('X-Amz-Algorithm', 'AWS4-HMAC-SHA256'),
          MapEntry('X-Amz-Credential', '${values['accessKeyId']}/$scope'),
          MapEntry('X-Amz-Date', dateTime),
          MapEntry('X-Amz-Expires', '$expires'),
          const MapEntry('X-Amz-SignedHeaders', 'host'),
          if ('${values['sessionToken'] ?? ''}'.isNotEmpty)
            MapEntry('X-Amz-Security-Token', values['sessionToken'] as String),
        ].map((e) => MapEntry(awsEncode(e.key), awsEncode(e.value))).toList()..sort((a, b) {
          final c = a.key.compareTo(b.key);
          return c == 0 ? a.value.compareTo(b.value) : c;
        });
    final query = params.map((e) => '${e.key}=${e.value}').join('&');
    final path = '/${uri.pathSegments.map(awsEncode).join('/')}';
    final canonical = '$method\n$path\n$query\nhost:${uri.authority}\n\nhost\nUNSIGNED-PAYLOAD';
    final toSign = 'AWS4-HMAC-SHA256\n$dateTime\n$scope\n${sha256.convert(utf8.encode(canonical))}';
    List<int> hmac(List<int> key, String value) => Hmac(sha256, key).convert(utf8.encode(value)).bytes;
    var key = hmac(utf8.encode('AWS4${values['secretAccessKey']}'), date);
    for (final value in [region, 's3', 'aws4_request']) {
      key = hmac(key, value);
    }
    final signature = Hmac(sha256, key).convert(utf8.encode(toSign)).toString();
    return Uri.parse('${uri.scheme}://${uri.authority}$path?$query&X-Amz-Signature=$signature');
  }
}

String awsEncode(String value) => utf8
    .encode(value)
    .map(
      (c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || [45, 46, 95, 126].contains(c)
          ? String.fromCharCode(c)
          : '%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    )
    .join();
