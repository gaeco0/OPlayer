import 'dart:io';
import 'package:path/path.dart' as p;

String linuxDesktopEntry(String executable) {
  // Desktop Exec has its own quoting rules; it is not a shell command.
  final quoted = executable.replaceAllMapped(RegExp(r'[\\"`$]'), (m) => '\\${m[0]}').replaceAll('%', '%%');
  final icon = p.join(p.dirname(executable), 'data', 'flutter_assets', 'assets', 'branding', 'oplayer.png');
  String desktopValue(String value) => value.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('\r', r'\r');
  return '''[Desktop Entry]
Type=Application
Name=OPlayer
Comment=Video, audio and photo viewer
Exec="${desktopValue(quoted)}" %F
Icon=${desktopValue(icon)}
Terminal=false
Categories=AudioVideo;Player;Viewer;
StartupWMClass=com.oplayer.oplayer
MimeType=video/mp4;video/x-matroska;video/x-msvideo;video/quicktime;video/x-ms-wmv;video/x-flv;video/webm;video/x-m4v;video/mp2t;video/3gpp;video/mpeg;video/dvd;video/ogg;application/vnd.rn-realmedia-vbr;video/x-ms-asf;audio/mpeg;audio/mp4;audio/aac;audio/flac;audio/x-wav;audio/ogg;audio/opus;audio/x-ms-wma;audio/x-aiff;audio/x-matroska;application/ogg;application/mp4;application/vnd.apple.mpegurl;application/x-mpegurl;audio/x-mpegurl;image/jpeg;image/png;image/webp;image/gif;image/bmp;image/avif;
''';
}

Future<void> registerLinuxFileAssociations() async {
  if (!Platform.isLinux) return;
  final home = Platform.environment['HOME'];
  final data = Platform.environment['XDG_DATA_HOME'];
  if ((data == null || !p.isAbsolute(data)) && home == null) return;
  final directory = Directory(
    p.join(data != null && p.isAbsolute(data) ? data : p.join(home!, '.local', 'share'), 'applications'),
  );
  final entry = File(p.join(directory.path, 'com.oplayer.oplayer.desktop'));
  final content = linuxDesktopEntry(Platform.resolvedExecutable);
  try {
    if (await entry.exists() && await entry.readAsString() == content) return;
    await directory.create(recursive: true);
    await entry.writeAsString(content, flush: true);
    await Process.run('update-desktop-database', [directory.path]);
  } on FileSystemException {
    // Read-only home directories still allow playback without registration.
  } on ProcessException {
    // The desktop entry remains usable without desktop-file-utils installed.
  }
}
