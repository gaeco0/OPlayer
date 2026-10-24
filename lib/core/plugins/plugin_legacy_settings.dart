import 'dart:io';
import '../settings.dart';
import '../secure_store.dart';
import '../../sources/cloud/cloud_config.dart';

/// Read-only migration of registrations saved before extension-owned settings.
/// New providers never add entries here.
Future<Map<String, dynamic>> legacyPluginSettings(String id) async {
  final s = AppSettings.instance;
  final clientId = switch (id) {
    'cloud.dropbox' => s.dropboxAppKey,
    'cloud.onedrive' => s.oneDriveClientId,
    'cloud.gdrive' => CloudConfig.googleClientId,
    _ => '',
  };
  return {
    if (clientId.isNotEmpty) 'clientId': clientId,
    if (id == 'cloud.gdrive' && !Platform.isAndroid && clientId.isNotEmpty)
      'clientSecret': await SecureStore.instance.readRequired('google_oauth_secret_$clientId') ?? '',
  };
}
