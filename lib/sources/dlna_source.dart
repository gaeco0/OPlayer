import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/media_item.dart';
import 'media_source.dart';

/// 발견된 UPnP 미디어 서버 (Plex, Jellyfin, Synology Media Server, Windows 미디어 공유 등)
class DlnaDevice {
  DlnaDevice({
    required this.udn,
    required this.name,
    required this.controlUrl,
    this.iconUrl,
    this.serviceType = 'urn:schemas-upnp-org:service:ContentDirectory:1',
    this.renderingControlUrl,
  });
  final String udn;
  final String name;
  final String controlUrl;
  final String? iconUrl;
  final String serviceType;
  final String? renderingControlUrl;
}

class DlnaDiscovery {
  static const _st = 'urn:schemas-upnp-org:service:ContentDirectory:1';

  /// SSDP M-SEARCH로 ContentDirectory 서비스를 가진 장치를 찾는다.
  static Stream<DlnaDevice> discover({Duration timeout = const Duration(seconds: 4), String serviceType = _st}) {
    final ctrl = StreamController<DlnaDevice>();
    final seen = <String>{};
    RawDatagramSocket? socket;
    Timer? timer;

    Future<void> handleLocation(String location) async {
      if (!seen.add(location)) return;
      try {
        final dev = await _describe(location, serviceType);
        if (dev != null && !ctrl.isClosed) ctrl.add(dev);
      } catch (_) {}
    }

    () async {
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket!.broadcastEnabled = true;
        socket!.listen((ev) {
          if (ev != RawSocketEvent.read) return;
          final dg = socket!.receive();
          if (dg == null) return;
          final text = utf8.decode(dg.data, allowMalformed: true);
          final m = RegExp(r'^location:\s*(.+)$', caseSensitive: false, multiLine: true).firstMatch(text);
          if (m != null) handleLocation(m.group(1)!.trim());
        });
        final msg = utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $serviceType\r\n\r\n',
        );
        final group = InternetAddress('239.255.255.250');
        for (var i = 0; i < 3; i++) {
          socket!.send(msg, group, 1900);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } catch (e) {
        if (!ctrl.isClosed) ctrl.addError(e);
      }
      timer = Timer(timeout, () {
        socket?.close();
        ctrl.close();
      });
    }();

    ctrl.onCancel = () {
      timer?.cancel();
      socket?.close();
    };
    return ctrl.stream;
  }

  static Future<DlnaDevice?> _describe(String location, String serviceType) async {
    final res = await http.get(Uri.parse(location)).timeout(const Duration(seconds: 4));
    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    String? text(XmlElement e, String name) => e.findAllElements(name).firstOrNull?.innerText.trim();
    final base = text(doc.rootElement, 'URLBase') ?? location;
    final device = doc.findAllElements('device').firstOrNull;
    if (device == null) return null;
    for (final svc in doc.findAllElements('service')) {
      final type = text(svc, 'serviceType') ?? '';
      if (!type.startsWith(serviceType.substring(0, serviceType.lastIndexOf(':') + 1))) continue;
      final control = text(svc, 'controlURL');
      if (control == null) continue;
      final icon = doc.findAllElements('icon').map((i) => text(i, 'url')).whereType<String>().firstOrNull;
      return DlnaDevice(
        udn: text(device, 'UDN') ?? location,
        name: text(device, 'friendlyName') ?? Uri.parse(location).host,
        controlUrl: Uri.parse(base).resolve(control).toString(),
        iconUrl: icon == null ? null : Uri.parse(base).resolve(icon).toString(),
        serviceType: type,
        renderingControlUrl: doc
            .findAllElements('service')
            .where((s) => (text(s, 'serviceType') ?? '').contains(':RenderingControl:'))
            .map((s) => text(s, 'controlURL'))
            .whereType<String>()
            .map((s) => Uri.parse(base).resolve(s).toString())
            .firstOrNull,
      );
    }
    return null;
  }
}

/// ContentDirectory Browse로 폴더 탐색. 항목의 res URL을 그대로 재생.
class DlnaSource extends MediaSource {
  DlnaSource(this.device);
  final DlnaDevice device;

  @override
  String get scheme => 'dlna';
  @override
  String get id => device.udn;
  @override
  String get displayName => device.name;
  @override
  String get rootPath => '0';

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final out = <RemoteEntry>[];
    var start = 0;
    while (true) {
      final body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
          '<ObjectID>${_esc(path)}</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>'
          '<Filter>*</Filter><StartingIndex>$start</StartingIndex><RequestedCount>500</RequestedCount>'
          '<SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>';
      final res = await http.post(
        Uri.parse(device.controlUrl),
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPACTION': '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"',
        },
        body: body,
      );
      if (res.statusCode >= 300) throw 'DLNA 오류 ${res.statusCode}';
      final env = XmlDocument.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
      final result = env.findAllElements('Result').firstOrNull?.innerText ?? '';
      final returned = int.tryParse(env.findAllElements('NumberReturned').firstOrNull?.innerText ?? '') ?? 0;
      final total = int.tryParse(env.findAllElements('TotalMatches').firstOrNull?.innerText ?? '') ?? 0;
      if (result.isNotEmpty) out.addAll(_parseDidl(result));
      start += returned;
      if (returned == 0 || start >= total) break;
    }
    return out;
  }

  List<RemoteEntry> _parseDidl(String xml) {
    final doc = XmlDocument.parse(xml);
    final out = <RemoteEntry>[];
    for (final c in doc.findAllElements('container')) {
      out.add(
        RemoteEntry(
          name: c.findAllElements('title').firstOrNull?.innerText ?? '(이름 없음)',
          path: c.getAttribute('id') ?? '',
          isDir: true,
        ),
      );
    }
    for (final it in doc.findAllElements('item')) {
      final cls = it.findAllElements('class', namespace: '*').firstOrNull?.innerText ?? '';
      final resList = it.findAllElements('res').toList();
      final videoRes =
          resList.where((r) => (r.getAttribute('protocolInfo') ?? '').contains('video')).firstOrNull ??
          (cls.contains('videoItem') ? resList.firstOrNull : null);
      if (videoRes == null) continue;
      final title = it.findAllElements('title', namespace: '*').firstOrNull?.innerText ?? '(이름 없음)';
      out.add(
        RemoteEntry(
          name: title,
          path: it.getAttribute('id') ?? '',
          isDir: false,
          size: int.tryParse(videoRes.getAttribute('size') ?? '') ?? 0,
          thumbnailUrl: it.findAllElements('albumArtURI', namespace: '*').firstOrNull?.innerText,
          directUrl: videoRes.innerText.trim(),
        ),
      );
      // 자막(res protocolInfo에 text/srt 등)이 있으면 함께 붙임
    }
    return out;
  }

  static String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => MediaItem(
    // DLNA는 장치를 매번 다시 찾아야 하므로 재생 URL 자체를 키로 쓴다 → 최근 재생에서 바로 다시 열 수 있음
    key: e.directUrl!,
    uri: e.directUrl!,
    title: e.name,
  );
}
