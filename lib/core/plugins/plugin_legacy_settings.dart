import 'dart:io';
import '../secure_store.dart';
import '../../sources/cloud/cloud_config.dart';

/// Read-only migration of registrations saved before extension-owned settings.
/// New providers never add entries here.
Future<Map<String, dynamic>> legacyPluginSettings(String id) async {
  final clientId = legacyPluginClientId(id);
  return {
    if (clientId.isNotEmpty) 'clientId': clientId,
    if (id == 'cloud.gdrive' && !Platform.isAndroid && clientId.isNotEmpty)
      'clientSecret': await SecureStore.instance.readRequired('google_oauth_secret_$clientId') ?? '',
  };
}

// Historical registrations are read only here. Execution does not branch by provider.
String legacyPluginClientId(String id) => switch (id) {
  'cloud.dropbox' => CloudConfig.dropboxAppKey,
  'cloud.onedrive' => CloudConfig.oneDriveClientId,
  'cloud.gdrive' => CloudConfig.googleClientId,
  _ => '',
};
