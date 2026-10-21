import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../sources/dlna_source.dart';

class DlnaRenderer {
  DlnaRenderer(this.device);
  final DlnaDevice device;
  static String _esc(String value) => XmlText(value).toString();

  Future<XmlDocument> _soap(
    String action,
    Map<String, String> args, {
    bool rendering = false,
  }) async {
    final type = rendering
        ? 'urn:schemas-upnp-org:service:RenderingControl:1'
        : device.serviceType;
    final url = rendering ? device.renderingControlUrl : device.controlUrl;
    if (url == null) throw const FormatException('이 기기는 음량 원격 조절을 지원하지 않습니다');
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:$action xmlns:u="$type">'
        '${args.entries.map((e) => '<${e.key}>${_esc(e.value)}</${e.key}>').join()}'
        '</u:$action></s:Body></s:Envelope>';
    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$type#$action"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 10));
    final doc = XmlDocument.parse(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    final fault = doc
        .findAllElements('errorDescription')
        .firstOrNull
        ?.innerText;
    if (response.statusCode >= 300 || fault != null) {
      throw FormatException('DLNA: ${fault ?? response.statusCode}');
    }
    return doc;
  }

  Future<void> load(String url, String title, String mime) async {
    final metadata =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1"><dc:title>${_esc(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:${_esc(mime)}:*">${_esc(url)}</res></item></DIDL-Lite>';
    await _soap('SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url,
      'CurrentURIMetaData': metadata,
    });
    await play();
  }

  Future<void> play() async {
    await _soap('Play', {'InstanceID': '0', 'Speed': '1'});
  }

  Future<void> pause() async {
    await _soap('Pause', {'InstanceID': '0'});
  }

  Future<void> stop() async {
    await _soap('Stop', {'InstanceID': '0'});
  }

  Future<void> seek(Duration at) async {
    final time =
        '${at.inHours.toString().padLeft(2, '0')}:'
        '${(at.inMinutes % 60).toString().padLeft(2, '0')}:${(at.inSeconds % 60).toString().padLeft(2, '0')}';
    await _soap('Seek', {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': time,
    });
  }

  Future<void> volume(double value) async {
    await _soap('SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${(value.clamp(0, 1) * 100).round()}',
    }, rendering: true);
  }

  Future<({bool playing, Duration position, Duration duration})>
  status() async {
    final responses = await Future.wait([
      _soap('GetTransportInfo', {'InstanceID': '0'}),
      _soap('GetPositionInfo', {'InstanceID': '0'}),
    ]);
    String value(XmlDocument doc, String name) =>
        doc.findAllElements(name).firstOrNull?.innerText ?? '';
    return (
      playing: value(responses[0], 'CurrentTransportState') == 'PLAYING',
      position: parseTime(value(responses[1], 'RelTime')),
      duration: parseTime(value(responses[1], 'TrackDuration')),
    );
  }

  static Duration parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 3) return Duration.zero;
    return Duration(
      milliseconds:
          (((double.tryParse(parts[0]) ?? 0) * 3600 +
                      (double.tryParse(parts[1]) ?? 0) * 60 +
                      (double.tryParse(parts[2]) ?? 0)) *
                  1000)
              .round(),
    );
  }
}
