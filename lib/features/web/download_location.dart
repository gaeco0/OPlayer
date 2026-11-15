import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Native storage locations are an OS adapter, independent of request policy.
Future<Directory> defaultDownloadDirectory() async {
  if (Platform.isAndroid) {
    final directory = Directory('/storage/emulated/0/Download/OPlayer');
    try {
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      return Directory(p.join((await getExternalStorageDirectory())!.path, 'Download'));
    }
  }
  if (Platform.isIOS) {
    return Directory(p.join((await getApplicationDocumentsDirectory()).path, 'Downloads'));
  }
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {}
  try {
    base ??= await getApplicationDocumentsDirectory();
  } catch (_) {}
  return Directory(p.join((base ?? Directory.systemTemp).path, 'OPlayer'));
}
